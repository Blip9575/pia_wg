#!/bin/sh
#
# pia_wg.sh
# Script to setup and run PIA through WireGuard on OpenWrt
#
# Inspired from:
# - This thread: https://forum.openwrt.org/t/private-internet-access-pia-wireguard-vpn-on-openwrt/155475
# - And @Lazerdog's script: https://github.com/jimhall718/piawg/blob/main/piawgx.sh
#
# Version: 1.1.4
#
# ©2026 bOLEMO
# https://github.com/bolemo/pia_wg/
# Fork with offline cache and official PIA app login: https://github.com/Blip9575/pia_wg/
#
#########

SCRIPTDL="https://raw.githubusercontent.com/Blip9575/pia_wg/release/pia_wg.sh"
SCRIPTPATH="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)/${0##*/}"
SCRIPTNAME="${SCRIPTPATH##*/}"
CRON_TAG_WD='# pia watchdog' # (per interface: "# pia watchdog [name]"); cron entries are recognised by these tags, not by the file name
CRON_TAG_CACHE='# pia cache'
CRON_TAG_RENEW='# pia renew'
HOOKFILE='/etc/hotplug.d/iface/80-pia'
RENEW_SKIP=180        # seconds: a handshake this recent means the registration is alive
RUNDIR='/var/run/pia' # temporary files (RAM); created on demand, mode 0700
LOCKDIR="$RUNDIR/lock"
LEGACYTOK="$RUNDIR/legacy.token"                             # legacy 24h token (RAM only; one per account)
UCIP="uci -q -t $RUNDIR/persist"                             # view of the persistent config only (ignores the RAM-staged session)
WGPLACEHOLDER='Hy+p7zrRBZWl5uBqhcFvnvMrRWb7Glhq6P5xe2ZkyHw=' # fixed, never registered: keeps wireguard.sh from generating (and saving) a key
LOCK_WAIT=120                                                # seconds a manual command waits for another run
LOCK_STEAL=900                                               # seconds after which a run still holding the lock is considered stuck
LOGDEFPATH='/var/log/pia'
LOGNAME='pia.log'
PIACONF='/etc/config/pia' # one section per interface, named like it; the account, tokens, cache and log are shared
RESERVED_NAMES=' account apitoken vpntoken cache log '
PIAWG_IF='wg_pia'           # the interface being handled (-i NAME, or the only one configured)
CACHEDEFDIR='/mnt/usb/pia'  # external storage, to spare the router flash
CACHERAMDIR="$RUNDIR/cache" # used when the external storage is not mounted
SERVERLIST_URL='https://serverlist.piaservers.net/vpninfo/servers/v6'
META_MAX=6           # verified meta servers to keep in the cache
META_PROBES=40       # max meta servers to probe per refresh
LEGACY_MAXAGE=604800 # age (s) after which the legacy-token regions are probed again
CURVERS="$(awk '(index($0,"# Version: ")==1){print $3; exit}' "$SCRIPTPATH")"

# Create the run directory (falls back to /tmp/pia when /var/run is not
# writable), and remove the leftovers of runs that died: <kind>.<pid>.<ext>
rundir_init() {
  (umask 077 && mkdir -p "$RUNDIR") 2>/dev/null
  if [ ! -d "$RUNDIR" ] || [ ! -w "$RUNDIR" ]; then
    RUNDIR='/tmp/pia'
    (umask 077 && mkdir -p "$RUNDIR")
  fi
  chmod 700 "$RUNDIR" 2>/dev/null
  LOCKDIR="$RUNDIR/lock"
  CACHERAMDIR="$RUNDIR/cache"
  LEGACYTOK="$RUNDIR/legacy.token"
  UCIP="uci -q -t $RUNDIR/persist"
  mkdir -p "$RUNDIR/persist" "$RUNDIR/ucid" "$RUNDIR/ucid.t" 2>/dev/null
  for RF in "$RUNDIR"/*.fifo "$RUNDIR"/*.resp "$RUNDIR"/*.tmp; do
    [ -e "$RF" ] || continue
    RP="${RF##*/}"
    RP="${RP#*.}"
    RP="${RP%%.*}"
    case "$RP" in
    '' | *[!0-9]*) continue ;;
    esac
    pid_is_pia "$RP" || rm -f "$RF"
  done
}

# Endpoints in use by the interfaces: live ones and those staged
live_endpoints() {
  for LX in $(iface_list) "$PIAWG_IF"; do
    wg show "$LX" endpoints 2>/dev/null | awk -F'[[:space:]:]' '{print $2}'
    uci -q get "network.wgpeer_$LX.endpoint_host"
  done | sort -u | tr '\n' ' '
}

# Servers in use by the other interfaces (live, staged or registered)
sibling_endpoints() {
  for LX in $(iface_list); do
    [ "$LX" = "$PIAWG_IF" ] && continue
    wg show "$LX" endpoints 2>/dev/null | awk -F'[[:space:]:]' '{print $2}'
    uci -q get "network.wgpeer_$LX.endpoint_host"
    awk -F= '$1=="server_ip"{print $2}' "$RUNDIR/session.$LX" 2>/dev/null
  done | sort -u | tr '\n' ' '
}

# The regions of all the interfaces (their meta servers are kept in the cache)
all_regions() {
  for LX in $(iface_list); do uci -q get "pia.$LX.region_id"; done | sort -u | tr '\n' ' '
}

# The interfaces in the config: one section of type 'interface' per interface
iface_list() { uci -q show pia 2>/dev/null | sed -n 's/^pia\.\([A-Za-z0-9_]*\)=interface$/\1/p'; }
iface_exists() { [ "$(uci -q get "pia.$1")" = 'interface' ]; }

valid_ifname() {
  case "$1" in
  '' | *[!A-Za-z0-9_]*) return 1 ;;
  esac
  [ ${#1} -le 15 ] || return 1
  case "$RESERVED_NAMES" in
  *" $1 "*) return 1 ;;
  esac
  return 0
}

# Names and files that depend on the interface being handled
set_ifvars() {
  PIAWG_PEER="wgpeer_$PIAWG_IF"
  SESSION="$RUNDIR/session.$PIAWG_IF"
  WDFAIL="$RUNDIR/watchdog.$PIAWG_IF.fail"
  RENEWFAIL="$RUNDIR/renew.$PIAWG_IF.fail"
  CRON_TAG_WD="# pia watchdog [$PIAWG_IF]"
  # tunnels (ours, any other WireGuard interface): never "the WAN"
  PIAIFS=" $(iface_list | tr '\n' ' ') $PIAWG_IF $(wg show interfaces 2>/dev/null | tr '\t' ' ') "
}

# Is this pid a live pia.sh run (and not a reused pid)?
pid_is_pia() {
  kill -0 "$1" 2>/dev/null &&
    { grep -qF "$SCRIPTNAME" "/proc/$1/cmdline" 2>/dev/null || grep -qE 'pia(_wg)?\.sh' "/proc/$1/cmdline" 2>/dev/null; }
}

# lock_take <command...>: serialise the runs that act on the tunnel and tokens.
# The watchdog 'start' skips when busy (it runs again in a minute); the other
# commands wait up to $LOCK_WAIT seconds, then give up (exit 75). A lock whose
# run died is removed; one held for more than $LOCK_STEAL seconds is stuck.
lock_take() {
  LW=0
  LNP=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    LPID="$(cat "$LOCKDIR/pid" 2>/dev/null)"
    LSINCE="$(cat "$LOCKDIR/since" 2>/dev/null)"
    LCMD="$(cat "$LOCKDIR/cmd" 2>/dev/null)"
    if [ -z "$LPID" ]; then
      # being created by another run, or its creator died on the way
      LNP=$((LNP + 1))
      if [ $LNP -gt 5 ]; then
        mv "$LOCKDIR" "$LOCKDIR.old.$$" 2>/dev/null && rm -rf "$LOCKDIR.old.$$"
        LNP=0
      fi
    elif ! pid_is_pia "$LPID"; then
      [ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$LPID" ] &&
        mv "$LOCKDIR" "$LOCKDIR.old.$$" 2>/dev/null && rm -rf "$LOCKDIR.old.$$"
      continue
    elif [ $(($(date +%s) - ${LSINCE:-0})) -gt "$LOCK_STEAL" ]; then
      echo "Run $LPID ($LCMD) is stuck for more than $((LOCK_STEAL / 60)) minutes; terminating it" >&3
      kill "$LPID" 2>/dev/null
      sleep 2
      kill -9 "$LPID" 2>/dev/null
      mv "$LOCKDIR" "$LOCKDIR.old.$$" 2>/dev/null && rm -rf "$LOCKDIR.old.$$"
      continue
    else
      if [ "$1" = 'start' ]; then
        echo "Another pia.sh run is in progress (pid $LPID: $LCMD); skipping" >&3
        exit 0
      fi
      if [ $LW -ge "$LOCK_WAIT" ]; then
        echo "Another pia.sh run (pid $LPID: $LCMD) is still in progress after ${LOCK_WAIT}s; giving up" >&3
        exit 75
      fi
      [ $LW -eq 0 ] && echo "Waiting for another pia.sh run (pid $LPID: $LCMD)…" >&3
    fi
    LW=$((LW + 1))
    sleep 1
  done
  echo "$$" >"$LOCKDIR/pid"
  date +%s >"$LOCKDIR/since"
  echo "$*" >"$LOCKDIR/cmd"
  PIALOCK=1
}

# Remove what this run created (the lock only if it holds it)
# shellcheck disable=SC2329  # Function is used in trap below
cleanup() {
  [ -z "$BGPID" ] || kill "$BGPID" 2>/dev/null
  # files being written to replace cache files atomically
  [ -z "$PROBETMP" ] || rm -f "$PROBETMP"
  [ -z "$METATMP" ] || rm -f "$METATMP"
  [ -z "$LISTTMP" ] || rm -f "$LISTTMP"
  [ -z "$PIARESP" ] || rm -f "$PIARESP"
  [ -z "$FIFO" ] || {
    exec 3>&-
    rm -f "$FIFO"
  }
  [ -z "$PIALOCK" ] || rm -rf "$LOCKDIR"
}

# read_yn <question> [y|n]: ask a yes/no question; enter (or end of input)
# gives the default, shown in capitals; no default means asking until answered
read_yn() {
  case "$2" in
  y) HINT='Y/n' ;;
  n) HINT='y/N' ;;
  *) HINT='y/n' ;;
  esac
  while :; do
    printf "%s? (%s):" "$1" "$HINT"
    read -r AND || {
      [ "$2" = 'y' ]
      return
    }
    [ -z "$AND" ] && AND="$2"
    case "$AND" in
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
    [Nn] | [Nn][Oo]) return 1 ;;
    esac
  done
}

set_logpath() {
  if [ "$1" ]; then
    LOGPATH="$1"
  else
    LOGPATH="$(uci -q get pia.log.path)"
    echo "Current Directory Path is: $LOGPATH"
    printf "Enter the Directory Path for the log (press enter to keep current one): "
    read -r NEWLOGPATH
    [ -z "$NEWLOGPATH" ] || LOGPATH="$NEWLOGPATH"
  fi
  uci -q batch <<EOI >/dev/null
    set pia.log=log
    set pia.log.path="$LOGPATH"
    commit pia
EOI
}

logfile() {
  if LOGPATH=$(uci -q get pia.log.path); then
    [ -d "$LOGPATH" ] || mkdir -p "$LOGPATH" 2>/dev/null
    echo "$LOGPATH/$LOGNAME"
  else
    set_logpath "$LOGDEFPATH"
    echo "$LOGDEFPATH/$LOGNAME"
  fi
}

# Device PIA servers are reached through: the WAN used for the tunnel endpoint.
# PIA calls leave through it (curl --interface if!dev), so they work whether
# the PIA tunnel is up, down or dead, and addKey is accepted (PIA does not take
# it from inside its own tunnel). Empty when no tunnel is up: the default route
# is then the WAN anyway. Sets $WANDEV.
pia_wan() {
  [ -z "$WANDEV_SET" ] || return 0
  WANDEV_SET=1
  WANDEV=''
  # where the tunnel's packets leave, if it has a peer
  if wg show "$PIAWG_IF" >/dev/null 2>&1; then
    WEP="$(wg show "$PIAWG_IF" endpoints | awk -F'[[:space:]:]' '{print $2; exit}')"
    if [ -n "$WEP" ]; then
      WMK="$(wg show "$PIAWG_IF" fwmark)"
      [ "$WMK" = 'off' ] && WMK=''
      WANDEV="$(ip route get "$WEP" ${WMK:+mark "$WMK"} 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
      [ "$WANDEV" = "$PIAWG_IF" ] && WANDEV=''
    fi
  fi
  # otherwise (no peer yet): the best default route that is not the tunnel
  [ -n "$WANDEV" ] || WANDEV="$(ip -4 route show default | awk -v t="$PIAIFS" '
    {
      dev = ""; m = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") dev = $(i + 1)
        if ($i == "metric") m = $(i + 1)
      }
      if (dev != "" && index(t, " " dev " ") == 0 && dev !~ /^(tun|tap|ppp|wg)/) print m, dev
    }' | sort -n | awk 'NR==1{print $2}')"
  return 0
}

cache_dir() {
  CACHEDIR="$(uci -q get pia.cache.dir)" || CACHEDIR="$CACHEDEFDIR"
  if [ ! -d "$CACHEDIR" ]; then
    # Under /mnt or /media but not on a mounted filesystem (e.g. USB storage
    # not mounted yet): use RAM rather than writing to the router flash
    case "$CACHEDIR" in
    /mnt/* | /media/*)
      awk -v d="$CACHEDIR/" '$2 != "/" && index(d, $2 "/") == 1 {f = 1} END {exit !f}' /proc/mounts ||
        CACHEDIR="$CACHERAMDIR"
      ;;
    esac
    mkdir -p "$CACHEDIR"
  fi
  echo "$CACHEDIR"
}

# PIA RSA-4096 CA, as shipped by the official PIA apps (pia-foss)
pia_ca() {
  PIACA="$(cache_dir)/ca.rsa.4096.crt"
  [ -s "$PIACA" ] || cat >"$PIACA" <<'EOC'
-----BEGIN CERTIFICATE-----
MIIHqzCCBZOgAwIBAgIJAJ0u+vODZJntMA0GCSqGSIb3DQEBDQUAMIHoMQswCQYD
VQQGEwJVUzELMAkGA1UECBMCQ0ExEzARBgNVBAcTCkxvc0FuZ2VsZXMxIDAeBgNV
BAoTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMSAwHgYDVQQLExdQcml2YXRlIElu
dGVybmV0IEFjY2VzczEgMB4GA1UEAxMXUHJpdmF0ZSBJbnRlcm5ldCBBY2Nlc3Mx
IDAeBgNVBCkTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMS8wLQYJKoZIhvcNAQkB
FiBzZWN1cmVAcHJpdmF0ZWludGVybmV0YWNjZXNzLmNvbTAeFw0xNDA0MTcxNzQw
MzNaFw0zNDA0MTIxNzQwMzNaMIHoMQswCQYDVQQGEwJVUzELMAkGA1UECBMCQ0Ex
EzARBgNVBAcTCkxvc0FuZ2VsZXMxIDAeBgNVBAoTF1ByaXZhdGUgSW50ZXJuZXQg
QWNjZXNzMSAwHgYDVQQLExdQcml2YXRlIEludGVybmV0IEFjY2VzczEgMB4GA1UE
AxMXUHJpdmF0ZSBJbnRlcm5ldCBBY2Nlc3MxIDAeBgNVBCkTF1ByaXZhdGUgSW50
ZXJuZXQgQWNjZXNzMS8wLQYJKoZIhvcNAQkBFiBzZWN1cmVAcHJpdmF0ZWludGVy
bmV0YWNjZXNzLmNvbTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALVk
hjumaqBbL8aSgj6xbX1QPTfTd1qHsAZd2B97m8Vw31c/2yQgZNf5qZY0+jOIHULN
De4R9TIvyBEbvnAg/OkPw8n/+ScgYOeH876VUXzjLDBnDb8DLr/+w9oVsuDeFJ9K
V2UFM1OYX0SnkHnrYAN2QLF98ESK4NCSU01h5zkcgmQ+qKSfA9Ny0/UpsKPBFqsQ
25NvjDWFhCpeqCHKUJ4Be27CDbSl7lAkBuHMPHJs8f8xPgAbHRXZOxVCpayZ2SND
fCwsnGWpWFoMGvdMbygngCn6jA/W1VSFOlRlfLuuGe7QFfDwA0jaLCxuWt/BgZyl
p7tAzYKR8lnWmtUCPm4+BtjyVDYtDCiGBD9Z4P13RFWvJHw5aapx/5W/CuvVyI7p
Kwvc2IT+KPxCUhH1XI8ca5RN3C9NoPJJf6qpg4g0rJH3aaWkoMRrYvQ+5PXXYUzj
tRHImghRGd/ydERYoAZXuGSbPkm9Y/p2X8unLcW+F0xpJD98+ZI+tzSsI99Zs5wi
jSUGYr9/j18KHFTMQ8n+1jauc5bCCegN27dPeKXNSZ5riXFL2XX6BkY68y58UaNz
meGMiUL9BOV1iV+PMb7B7PYs7oFLjAhh0EdyvfHkrh/ZV9BEhtFa7yXp8XR0J6vz
1YV9R6DYJmLjOEbhU8N0gc3tZm4Qz39lIIG6w3FDAgMBAAGjggFUMIIBUDAdBgNV
HQ4EFgQUrsRtyWJftjpdRM0+925Y6Cl08SUwggEfBgNVHSMEggEWMIIBEoAUrsRt
yWJftjpdRM0+925Y6Cl08SWhge6kgeswgegxCzAJBgNVBAYTAlVTMQswCQYDVQQI
EwJDQTETMBEGA1UEBxMKTG9zQW5nZWxlczEgMB4GA1UEChMXUHJpdmF0ZSBJbnRl
cm5ldCBBY2Nlc3MxIDAeBgNVBAsTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMSAw
HgYDVQQDExdQcml2YXRlIEludGVybmV0IEFjY2VzczEgMB4GA1UEKRMXUHJpdmF0
ZSBJbnRlcm5ldCBBY2Nlc3MxLzAtBgkqhkiG9w0BCQEWIHNlY3VyZUBwcml2YXRl
aW50ZXJuZXRhY2Nlc3MuY29tggkAnS7684Nkme0wDAYDVR0TBAUwAwEB/zANBgkq
hkiG9w0BAQ0FAAOCAgEAJsfhsPk3r8kLXLxY+v+vHzbr4ufNtqnL9/1Uuf8NrsCt
pXAoyZ0YqfbkWx3NHTZ7OE9ZRhdMP/RqHQE1p4N4Sa1nZKhTKasV6KhHDqSCt/dv
Em89xWm2MVA7nyzQxVlHa9AkcBaemcXEiyT19XdpiXOP4Vhs+J1R5m8zQOxZlV1G
tF9vsXmJqWZpOVPmZ8f35BCsYPvv4yMewnrtAC8PFEK/bOPeYcKN50bol22QYaZu
LfpkHfNiFTnfMh8sl/ablPyNY7DUNiP5DRcMdIwmfGQxR5WEQoHL3yPJ42LkB5zs
6jIm26DGNXfwura/mi105+ENH1CaROtRYwkiHb08U6qLXXJz80mWJkT90nr8Asj3
5xN2cUppg74nG3YVav/38P48T56hG1NHbYF5uOCske19F6wi9maUoto/3vEr0rnX
JUp2KODmKdvBI7co245lHBABWikk8VfejQSlCtDBXn644ZMtAdoxKNfR2WTFVEwJ
iyd1Fzx0yujuiXDROLhISLQDRjVVAvawrAtLZWYK31bY7KlezPlQnl/D9Asxe85l
8jO5+0LdJ6VyOs/Hd4w52alDW/MFySDZSfQHMTIc30hLBJ8OnCEIvluVQQ2UQvoW
+no177N9L2Y+M9TcTA62ZyMXShHQGeh20rb4kK8f+iFX8NxtdHVSkxMEFSfDDyQ=
-----END CERTIFICATE-----
EOC
  echo "$PIACA"
}

# Meta servers ("ip cn") of the cached list: configured and extra regions first
meta_candidates() {
  SL="$(cache_dir)/servers.json"
  [ -s "$SL" ] || return
  jq -r --arg regs "$(all_regions) $(uci -q get pia.cache.regions)" '
    ($regs | split(" ") | map(select(length > 0))) as $r
    | [.regions[] | select(.offline == false)]
    | map(select(.id as $i | $r | index($i))) + map(select(.id as $i | $r | index($i) | not))
    | .[].servers.meta[]? | "\(.ip) \(.cn)"' "$SL"
}

# Keep the meta servers whose certificate validates against the PIA CA
meta_refresh() {
  pia_wan
  CD="$(cache_dir)"
  CA="$(pia_ca)"
  N=0
  P=0
  METATMP="$CD/meta.list.tmp"
  : >"$METATMP"
  while read -r IP CN; do
    [ "$IP" ] || continue
    [ $P -ge $META_PROBES ] && break
    P=$((P + 1))
    curl -s -o /dev/null --max-time 5 ${WANDEV:+--interface "if!$WANDEV"} --cacert "$CA" --connect-to "$CN::$IP:443" "https://$CN/" || continue
    echo "$IP $CN" >>"$CD/meta.list.tmp"
    N=$((N + 1))
    [ $N -ge $META_MAX ] && break
  done <<EOM
$(meta_candidates)
EOM
  METAN=$N
  if [ $N -eq 0 ]; then
    rm -f "$CD/meta.list.tmp"
    METARES='failed'
    return 1
  fi
  if cmp -s "$CD/meta.list.tmp" "$CD/meta.list"; then
    rm "$CD/meta.list.tmp"
    METARES='unchanged'
  else
    mv "$CD/meta.list.tmp" "$CD/meta.list"
    METARES='updated'
  fi
}

# Fetch the servers list through verified meta servers (by IP), then the public hostname
cache_refresh_list() {
  pia_wan
  CD="$(cache_dir)"
  CA="$(pia_ca)"
  TMP="$CD/servers.json.tmp"
  LISTTMP="$TMP"
  : >"$TMP"
  LISTVIA=''
  while read -r IP CN; do
    [ "$IP" ] || continue
    curl -sf --max-time 15 ${WANDEV:+--interface "if!$WANDEV"} --cacert "$CA" --connect-to "$CN::$IP:443" "https://$CN/vpninfo/servers/v6" | head -1 >"$TMP"
    jq -e '.regions | length > 0' "$TMP" >/dev/null 2>&1 && {
      LISTVIA="$CN"
      break
    }
  done <<EOM
$(cat "$CD/meta.list" 2>/dev/null)
EOM
  if [ -z "$LISTVIA" ]; then
    curl -sf --max-time 15 ${WANDEV:+--interface "if!$WANDEV"} "$SERVERLIST_URL" | head -1 >"$TMP"
    LISTVIA='serverlist.piaservers.net'
  fi
  if jq -e '.regions | length > 0' "$TMP" >/dev/null 2>&1; then
    LISTN="$(jq '.regions | length' "$TMP")"
    if cmp -s "$TMP" "$CD/servers.json"; then
      rm "$TMP"
      LISTRES='unchanged'
    else
      mv "$TMP" "$CD/servers.json"
      LISTRES='updated'
    fi
  else
    rm -f "$TMP"
    LISTRES='failed'
    return 1
  fi
}

# Days of validity left for the token stored in the section pia.<name>
token_days() {
  TDE="$(uci -q get "pia.$1.expires")"
  if [ "${TDE:-0}" -gt 0 ]; then
    echo "$(((TDE - $(date +%s)) / 86400)) days"
  else
    echo "an unknown time"
  fi
}

cache_refresh() {
  RSTART="$(date +%s)"
  R=0
  pia_wan
  if [ -n "$WANDEV" ]; then
    echo "Cache update (leaving via $WANDEV; PIA tunnel unchanged)" >&3
  else
    echo "Cache update (no PIA tunnel up; direct)" >&3
  fi
  if cache_refresh_list; then
    echo "  Servers list : $LISTN regions ($LISTRES, via $LISTVIA)" >&3
  else
    echo "  Servers list : NOT updated, keeping the cached copy" >&3
    R=1
  fi
  if meta_refresh; then
    echo "  Meta servers : $METAN verified ($METARES)" >&3
  else
    echo "  Meta servers : NONE reachable, keeping the cached ones" >&3
    R=1
  fi
  # Renew PIA tokens ahead of expiry
  if uci -q get pia.account >/dev/null; then
    if pia_tokens renew; then
      echo "  Tokens       : API token valid for $(token_days apitoken), VPN token for $(token_days vpntoken)" >&3
    else
      echo "  Tokens       : renewal FAILED" >&3
      R=1
    fi
  fi
  if [ $R -eq 0 ]; then
    echo "Done in $(($(date +%s) - RSTART))s" >&3
  else
    echo "Done in $(($(date +%s) - RSTART))s, with errors" >&3
  fi
  return $R
}

cache_installed() {
  grep -qF "$CRON_TAG_CACHE" /etc/crontabs/root 2>/dev/null
}

# (Re)write the entry, so that one pointing at another path (script moved or
# renamed) is replaced
cache_install() {
  grep -qF "/bin/sh $SCRIPTPATH cache refresh $CRON_TAG_CACHE" /etc/crontabs/root 2>/dev/null && return
  {
    crontab -l 2>/dev/null | grep -vF "$CRON_TAG_CACHE"
    echo "17 */6 * * * /bin/sh $SCRIPTPATH cache refresh $CRON_TAG_CACHE"
  } | crontab -
  echo "[$(date)] Cache refresh installed" >>"$PIALOG"
}

cache_remove() {
  cache_installed || return
  crontab -l | grep -vF "$CRON_TAG_CACHE" | crontab -
  echo "[$(date)] Cache refresh removed" >>"$PIALOG"
}

cache_show() {
  CD="$(cache_dir)"
  echo "Cache directory: $CD"
  [ "$CD" = "$CACHERAMDIR" ] && echo "  (RAM: configured directory not mounted)"
  cache_installed && echo "Cache refresh (cron) installed: YES" || echo "Cache refresh (cron) installed: NO"
  if [ -s "$CD/servers.json" ]; then
    echo "Servers list: $(jq '.regions | length' "$CD/servers.json") regions, updated $(date -r "$CD/servers.json")"
    PIAREGIONID="$(uci -q get "pia.$PIAWG_IF.region_id")" &&
      jq -r --arg r "$PIAREGIONID" '.regions[] | select(.id == $r) | .servers.wg[]? | "  wg   \(.ip) \(.cn)"' "$CD/servers.json"
  else
    echo "Servers list: none"
  fi
  LSTAMP="$(legacy_stamp)"
  if [ -n "$LSTAMP" ]; then
    echo "Regions needing the legacy token: $(legacy_ids | wc -w) (checked $(date -d "@$LSTAMP" 2>/dev/null))"
  fi
  [ -s "$CD/meta.list" ] && awk '{print "  meta "$0}' "$CD/meta.list" || echo "Verified meta servers: none"
}

set_cache() {
  CACHEDIR="$(uci -q get pia.cache.dir)" || CACHEDIR="$CACHEDEFDIR"
  printf "Directory for the offline cache (press enter for %s): " "$CACHEDIR"
  read -r NEWCACHEDIR
  [ -z "$NEWCACHEDIR" ] || CACHEDIR="$NEWCACHEDIR"
  printf "Extra region IDs to take meta servers from, space separated (press enter for none): "
  read -r CACHEREGIONS
  read_yn "Allow meta servers whose certificate is not signed by the PIA CA (insecure)" n && CACHEINSECURE=1 || CACHEINSECURE=0
  {
    echo "delete pia.cache"
    echo "set pia.cache=cache"
    echo "set pia.cache.dir=\"$CACHEDIR\""
    echo "set pia.cache.insecure_meta=\"$CACHEINSECURE\""
    for R in $CACHEREGIONS; do echo "add_list pia.cache.regions=\"$R\""; done
    echo "commit pia"
  } | uci -q batch >/dev/null
}

# Regions whose WireGuard servers refuse the VPN token (HTTP 401 on addKey) and
# only accept the legacy 24h token. addKey is called with a deliberately invalid
# public key: a server that accepts the token answers 409 (invalid key) and
# registers no key, one that refuses it answers 401. The first server of each
# online region is asked, then the others if it refuses; a region is listed (in
# $CACHE/legacy.list, after a '# <epoch>' line) only if all the servers that
# answered refused.
#
# A server removes the existing peer of the token making an addKey request
# before it checks the key, even when the request then fails. The server the
# tunnel is connected to is therefore never asked (it would drop the tunnel);
# a region is judged on its other servers, or keeps its previous result.
legacy_probe() {
  CD="$(cache_dir)"
  [ -s "$CD/servers.json" ] || {
    echo "No servers list yet; run 'cache refresh' first" >&3
    return 1
  }
  pia_tokens >/dev/null 2>&1 || {
    echo "Cannot get a PIA VPN token; regions not checked" >&3
    return 1
  }
  # PIA servers do not accept addKey from inside a PIA tunnel
  pia_wan
  # The servers the tunnel is connected to
  LIVEIPS=" $(live_endpoints) "
  echo "Checking the regions (leaving via ${WANDEV:-the default route}); this takes a few minutes" >&3
  CA="$(pia_ca)"
  LU="$(uci -q get pia.vpntoken.user)"
  LP="$(uci -q get pia.vpntoken.pass)"
  PROBETMP="$CD/legacy.list.tmp"
  echo "# $(date +%s)" >"$PROBETMP"
  # Run in the background and wait for it, so that a signal is handled at once
  # (a trap only runs after the foreground command ends); the loop stops by
  # itself when this run is gone
  MAINPID=$$
  {
    jq -r '.regions[] | select(.offline == false) | select((.servers.wg // []) | length > 0)
    | "\(.id) " + (.servers.wg | map("\(.ip),\(.cn)") | join(" "))' "$CD/servers.json" |
      while read -r RID SRVS; do
        kill -0 "$MAINPID" 2>/dev/null || exit 1
        REF=0
        TRY=0
        SKIPPED=0
        for SRV in $SRVS; do
          case "$LIVEIPS" in
          *" ${SRV%%,*} "*)
            SKIPPED=1
            continue
            ;;
          esac
          # Some servers answer differently from one request to the next: a
          # server counts as refusing only if it refuses twice in a row
          VERDICT=''
          for _ in 1 2; do
            CODE="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 8 -G \
              ${WANDEV:+--interface "if!$WANDEV"} --cacert "$CA" --connect-to "${SRV#*,}::${SRV%%,*}:1337" --user "$LU:$LP" \
              --data-urlencode "pubkey=probe" "https://${SRV#*,}:1337/addKey")"
            case "$CODE" in
            200 | 409)
              VERDICT='ok'
              break
              ;;
            401) VERDICT='refused' ;;
            *)
              VERDICT=''
              break
              ;;
            esac
          done
          case "$VERDICT" in
          ok)
            REF=0
            TRY=1
            break
            ;;
          refused)
            REF=$((REF + 1))
            TRY=$((TRY + 1))
            ;;
          esac
        done
        if [ $TRY -gt 0 ]; then
          [ $REF -eq $TRY ] && echo "$RID" >>"$CD/legacy.list.tmp"
        elif [ $SKIPPED -eq 1 ] && grep -qx "$RID" "$CD/legacy.list" 2>/dev/null; then
          # only the tunnel's server could have been asked: keep what we knew
          echo "$RID" >>"$CD/legacy.list.tmp"
        fi
        printf '.' >&3
      done
  } &
  BGPID=$!
  wait "$BGPID"
  WRC=$?
  BGPID=''
  echo >&3
  if [ $WRC -ne 0 ]; then
    rm -f "$CD/legacy.list.tmp"
    return 1
  fi
  mv "$CD/legacy.list.tmp" "$CD/legacy.list"
}

# Space separated ids of the regions known to need the legacy token
legacy_ids() {
  grep -v '^#' "$(cache_dir)/legacy.list" 2>/dev/null | tr '\n' ' '
}

# Epoch of the last legacy_probe, empty if never
legacy_stamp() {
  sed -n '1s/^# //p' "$(cache_dir)/legacy.list" 2>/dev/null
}

# Numbered list of the online WireGuard regions, (L) marking those needing the
# legacy token. Uses $PIAREGIONS, $PIASERVPF, $PIASERVGEO, $PIASERVSO and $LEGACYIDS.
region_names() {
  echo "$PIAREGIONS" | jq -r --arg l "$LEGACYIDS" ".[] | select(.offline==false) | select(.servers.wg) $PIASERVPF $PIASERVGEO $PIASERVSO |
    .id as \$id | .name + (if (\$l | split(\" \") | any(.[]; . == \$id)) then \" (L)\" else \"\" end)" | nl -v0
}

select_region() {
  echo "Fetching latest PIA servers list…"
  if cache_refresh_list; then
    echo "PIA servers list: $LISTN regions ($LISTRES)"
  else
    echo "Could not fetch the PIA servers list; using the cached one" >&3
  fi
  if ! PIAREGIONS="$(jq -e '.regions | sort_by(.name)' "$(cache_dir)/servers.json" 2>/dev/null)"; then
    echo "Error fetching PIA servers list!" >&3
    exit 1
  fi
  while :; do
    printf "Type the region ID if you know it or press enter for list selection: "
    read -r PIAREGIONID
    if [ -z "$PIAREGIONID" ]; then
      break
    else
      PIAREGIONNAME="$(echo "$PIAREGIONS" | jq -r ".[] | select(.id==\"$PIAREGIONID\") | .name")"
      if [ -z "$PIAREGIONNAME" ]; then
        echo "Invalid region ID: '$PIAREGIONID'"
      else
        break
      fi
    fi
  done
  if [ -z "$PIAREGIONID" ]; then
    LSTAMP="$(legacy_stamp)"
    if [ -z "$AUTO" ] && { [ -z "$LSTAMP" ] || [ $(($(date +%s) - LSTAMP)) -gt "$LEGACY_MAXAGE" ]; }; then
      read_yn "Check which regions need the legacy token (takes a few minutes)" y && legacy_probe
      LSTAMP="$(legacy_stamp)"
    fi
    LEGACYIDS="$(legacy_ids)"
    echo "Eliminating offline servers…"
    echo "Eliminating non WireGuard servers…"
    while :; do
      read_yn "Port forward only servers" n && PIASERVPF='| select(.port_forward==true) ' || PIASERVPF=''
      read_yn "Geo only servers" n && PIASERVGEO='| select(.geo==true) ' || PIASERVGEO=''
      # Streaming optimised regions: 'Streaming' in the name or '-so.' in the DNS
      # name (their ids do not all end in '-so', e.g. uk_2)
      read_yn "Stream optimised only servers" n && PIASERVSO='| select((.name | contains("Streaming")) or (.dns | contains("-so."))) ' || PIASERVSO=''
      REGIONNAMES="$(region_names)"
      [ -n "$REGIONNAMES" ] && break
      echo "No region matches these filters!"
    done
    echo "$REGIONNAMES"
    if [ -n "$LSTAMP" ]; then
      echo "(L) = needs the 24h legacy token (checked $(date -d "@$LSTAMP" 2>/dev/null))"
    fi
    while :; do
      printf "Select your region number: "
      read -r AND || exit 1
      case "$AND" in
      '' | *[!0-9]*) PIAREGIONID='' ;;
      *) PIAREGIONID="$(echo "$PIAREGIONS" | jq -r "[.[] | select(.offline==false) | select(.servers.wg) $PIASERVPF $PIASERVGEO $PIASERVSO ][$AND].id // empty")" ;;
      esac
      [ -n "$PIAREGIONID" ] && break
      echo "Invalid region number: '$AND'"
    done
  fi
  PIAREGIONNAME="$(echo "$PIAREGIONS" | jq -r ".[] | select(.id==\"$PIAREGIONID\") | .name")"
  PIAREGIONDNS="$(echo "$PIAREGIONS" | jq -r ".[] | select(.id==\"$PIAREGIONID\") | .dns")"
  echo "Region selected: $PIAREGIONNAME"
  uci -q batch <<EOI >/dev/null
    set pia.$PIAWG_IF=interface
    set pia.$PIAWG_IF.region_id="$PIAREGIONID"
    set pia.$PIAWG_IF.region_name="$PIAREGIONNAME"
    set pia.$PIAWG_IF.region_dns="$PIAREGIONDNS"
    commit pia
EOI
  echo "Checking PIA meta servers…"
  if meta_refresh; then
    echo "Verified PIA meta servers cached: $METAN"
  else
    echo "No verified PIA meta server reachable; keeping cached ones" >&3
  fi
}

set_piauser() {
  printf "PIA user id: "
  read -r PIAUSER
  printf "PIA password: "
  stty -echo
  read -r PIAPASS
  stty echo
  printf "\n"
  uci -q batch <<EOI >/dev/null
    set pia.account=account
    set pia.account.id="$PIAUSER"
    set pia.account.password="$PIAPASS"
    commit pia
EOI
}

# Private (mode 0600) file receiving PIA API responses; removed on exit
piaresp_init() {
  if [ -z "$PIARESP" ]; then
    PIARESP="$RUNDIR/api.$$.resp"
    : >"$PIARESP"
  fi
}

# pia_api <meta path> <subdomain> <domain path> [curl args…]
# Call the PIA API the way the official apps do: through cached meta servers
# by IP (certificate verified against the PIA CA), then unverified meta servers
# if pia.cache.insecure_meta is set, then privateinternetaccess.com and
# piaproxy.net. The response body is left in $PIARESP.
# Returns 0 on HTTP 2xx, 1 on HTTP 401 (bad credentials/token), 2 otherwise.
pia_api() {
  MPATH="$1"
  SUB="$2"
  DPATH="$3"
  shift 3
  piaresp_init
  pia_wan
  CA="$(pia_ca)"
  CD="$(cache_dir)"
  EPS="$(awk '{print $1, $2, "pin"}' "$CD/meta.list" 2>/dev/null)"
  [ "$(uci -q get pia.cache.insecure_meta)" = '1' ] &&
    EPS="$EPS
$(meta_candidates | head -n "$META_PROBES" | awk '{print $1, $2, "insecure"}')"
  EPS="$EPS
privateinternetaccess.com - domain
piaproxy.net - domain"
  while read -r EP CN MODE; do
    case "$MODE" in
    'pin') CODE="$(curl -s -o "$PIARESP" -w '%{http_code}' --connect-timeout 5 --max-time 15 ${WANDEV:+--interface "if!$WANDEV"} --cacert "$CA" --connect-to "$CN::$EP:443" "$@" "https://$CN$MPATH")" ;;
    'insecure') CODE="$(curl -s -k -o "$PIARESP" -w '%{http_code}' --connect-timeout 5 --max-time 15 ${WANDEV:+--interface "if!$WANDEV"} --connect-to "$CN::$EP:443" "$@" "https://$CN$MPATH")" ;;
    'domain') CODE="$(curl -s -o "$PIARESP" -w '%{http_code}' --connect-timeout 5 --max-time 15 ${WANDEV:+--interface "if!$WANDEV"} "$@" "https://$SUB.$EP$DPATH")" ;;
    *) continue ;;
    esac
    case "$CODE" in
    2??) return 0 ;;
    401) return 1 ;;
    esac
  done <<EOE
$EPS
EOE
  : >"$PIARESP"
  return 2
}

# ISO 8601 UTC date (as returned by the PIA API) to epoch; 0 if unknown.
# Only slices the string: jq on OpenWrt may be built without regex support.
iso2epoch() {
  jq -nr --arg d "$1" 'try (($d[0:19] + "Z") | fromdateiso8601) catch 0' 2>/dev/null || echo 0
}

# token_ok <section> [renew]: is the stored token in pia.<section>
# still usable (default) or still fresh (renew: before half of its life, at
# most 21 days before expiry, as the official apps do)
token_ok() {
  uci -q get "pia.$1" >/dev/null || return 1
  EXP="$(uci -q get "pia.$1.expires")"
  TS="$(uci -q get "pia.$1.timestamp")"
  EXP="${EXP:-0}"
  TS="${TS:-0}"
  NOW="$(date +%s)"
  if [ "$EXP" -gt 0 ]; then
    MARGIN=60
    if [ "$2" = 'renew' ]; then
      MARGIN=$(((EXP - TS) / 2))
      [ $MARGIN -gt 1814400 ] && MARGIN=1814400
    fi
    [ $((EXP - NOW)) -gt $MARGIN ]
  else
    [ "$2" = 'renew' ] && MAXAGE=43200 || MAXAGE=86400
    [ $((NOW - TS)) -lt "$MAXAGE" ]
  fi
}

store_apitoken() {
  APITOK="$(jq -r '.api_token // empty' "$PIARESP" 2>/dev/null)"
  [ "$APITOK" ] || return 1
  uci -q batch <<EOI >/dev/null
    delete pia.apitoken
    set pia.apitoken=token
    set pia.apitoken.token="$APITOK"
    set pia.apitoken.expires="$(iso2epoch "$(jq -r '.expires_at // empty' "$PIARESP")")"
    set pia.apitoken.timestamp="$(date +%s)"
    commit pia
EOI
}

# PIA API v5 login (username/password -> long lived API token)
api_login() {
  echo "Logging in to PIA" >&3
  uci -q get pia.account >/dev/null || {
    [ "$AUTO" ] && return 1 || set_piauser
  }
  pia_api /api/client/v5/api_token apiv5 /api/client/v5/api_token \
    --data-urlencode "username=$(uci -q get pia.account.id)" \
    --data-urlencode "password=$(uci -q get pia.account.password)"
  case $? in
  0) store_apitoken && return 0 ;;
  1) echo "PIA login refused; check your PIA username and password" >&3 ;;
  esac
  echo "Error: PIA login failed!" >&3
  return 1
}

# PIA API v5: renew the API token with itself
api_token_refresh() {
  echo "Renewing PIA API token" >&3
  pia_api /api/client/v5/refresh apiv5 /api/client/v5/refresh -d "" \
    --header "Authorization: Token $(uci -q get pia.apitoken.token)" &&
    store_apitoken
}

# PIA API v5: API token -> VPN token (used to authenticate on VPN servers)
vpn_token_get() {
  echo "Renewing PIA VPN token" >&3
  pia_api /api/client/v5/vpn_token apiv5 /api/client/v5/vpn_token -d "" \
    --header "Authorization: Token $(uci -q get pia.apitoken.token)" || return
  VPNS1="$(jq -r '.vpn_secret1 // empty' "$PIARESP" 2>/dev/null)"
  VPNS2="$(jq -r '.vpn_secret2 // empty' "$PIARESP" 2>/dev/null)"
  [ "$VPNS1" ] && [ "$VPNS2" ] || return 2
  uci -q batch <<EOI >/dev/null
    delete pia.vpntoken
    set pia.vpntoken=token
    set pia.vpntoken.user="vpn_token_$VPNS1"
    set pia.vpntoken.pass="$VPNS2"
    set pia.vpntoken.expires="$(iso2epoch "$(jq -r '.expires_at // empty' "$PIARESP")")"
    set pia.vpntoken.timestamp="$(date +%s)"
    commit pia
EOI
}

# pia_tokens [renew]: make sure a usable (or with renew: fresh) VPN token is stored
pia_tokens() {
  if ! token_ok apitoken "$1"; then
    if token_ok apitoken; then
      api_token_refresh || api_login || return 1
    else
      api_login || return 1
    fi
  fi
  token_ok vpntoken "$1" && return 0
  vpn_token_get
  case $? in
  0) return 0 ;;
  1) api_login && vpn_token_get ;; # API token refused: log in again
  *) return 1 ;;
  esac
}

pia_token_forget() {
  uci -q delete pia.vpntoken
  uci -q commit pia
}

# Register our WireGuard key on a server of the configured region, as the
# official apps do: by IP (certificate verified against the PIA CA) using the
# cached servers list, then through the region hostname (legacy behaviour).
# Response in $PIAADDKEY; $ADDKEYAUTHFAIL is set if a server refused the token.
pia_addkey() {
  piaresp_init
  pia_wan
  CA="$(pia_ca)"
  PUB="$WGPUB"
  if [ "$PIAAUTH" = 'vpn' ]; then
    set -- --user "$(uci -q get pia.vpntoken.user):$(uci -q get pia.vpntoken.pass)"
  else
    set -- --data-urlencode "pt=$(legacy_token_hash)"
  fi
  SERVERS="$(jq -r --arg r "$(uci -q get "pia.$PIAWG_IF.region_id")" \
    '.regions[] | select(.id == $r) | .servers.wg[]? | "\(.ip) \(.cn) ip"' "$(cache_dir)/servers.json" 2>/dev/null)
$(uci -q get "pia.$PIAWG_IF.region_dns") - dns"
  # one peer per token and server: keep off the servers of the other interfaces
  SIBIPS="$(sibling_endpoints)"
  SERVERS="$(echo "$SERVERS" | awk -v u="$SIBIPS" 'BEGIN{n=split(u,a," ");for(i=1;i<=n;i++)x[a[i]]=1} !($1 in x)')"
  unset ADDKEYAUTHFAIL
  while read -r HOST CN MODE; do
    case "$MODE" in
    'ip') CODE="$(curl -s -o "$PIARESP" -w '%{http_code}' --connect-timeout 5 --max-time 15 ${WANDEV:+--interface "if!$WANDEV"} --cacert "$CA" --connect-to "$CN::$HOST:1337" -G "$@" --data-urlencode "pubkey=$PUB" "https://$CN:1337/addKey")" ;;
    'dns') CODE="$(curl -s -k -o "$PIARESP" -w '%{http_code}' --connect-timeout 5 --max-time 15 ${WANDEV:+--interface "if!$WANDEV"} -G "$@" --data-urlencode "pubkey=$PUB" "https://$HOST:1337/addKey")" ;;
    *) continue ;;
    esac
    [ "$CODE" = '401' ] && ADDKEYAUTHFAIL=1
    PIAADDKEY="$(cat "$PIARESP")"
    [ "$(echo "$PIAADDKEY" | jq -r '.status' 2>/dev/null)" = 'OK' ] && return 0
  done <<EOS
$SERVERS
EOS
  return 1
}

# Is the configured region marked in the legacy list ('cache probe')?
region_needs_legacy() {
  LRID="$(uci -q get "pia.$PIAWG_IF.region_id")" || return 1
  [ -n "$LRID" ] || return 1
  case " $(legacy_ids) " in
  *" $LRID "*) return 0 ;;
  esac
  return 1
}

# Legacy (v2) tokens are valid for 24h
legacy_token_hash() { awk '{print $1; exit}' "$LEGACYTOK" 2>/dev/null; }
legacy_token_ensure() {
  LTS="$(awk '{print $2; exit}' "$LEGACYTOK" 2>/dev/null)"
  [ $(($(date +%s) - ${LTS:-0})) -lt 82800 ] || renew_piatoken
}

# Register our key with the VPN token. Some PIA servers still refuse the VPN
# token (HTTP 401) and only accept the legacy one: renew the VPN token once
# if it is not brand new, then fall back to the legacy token.
pia_addkey_any() {
  if [ "$PIAAUTH" = 'vpn' ]; then
    pia_addkey && return 0
    [ "$ADDKEYAUTHFAIL" ] || return 1
    VTS="$(uci -q get pia.vpntoken.timestamp)"
    if [ $(($(date +%s) - ${VTS:-0})) -gt 600 ]; then
      echo "PIA server refused the VPN token; renewing it" >&3
      pia_token_forget
      pia_tokens && pia_addkey && return 0
    fi
    echo "PIA servers refused the VPN token; trying the legacy token" >&3
    PIAAUTH='legacy'
    legacy_token_ensure
  fi
  pia_addkey && return 0
  [ "$ADDKEYAUTHFAIL" ] || return 1
  renew_piatoken
  pia_addkey
}

validate_dip() {
  DIPTOK="$(uci -q get "pia.$PIAWG_IF.dip_token")" || return
  token_ok apitoken || pia_tokens >/dev/null 2>&1
  # Try to fetch DIP info from API
  if uci -q get pia.apitoken.token >/dev/null; then
    pia_api /api/client/v5/dedicated_ip apiv5 /api/client/v5/dedicated_ip -X POST \
      --header 'Content-Type: application/json' \
      --header "Authorization: Token $(uci -q get pia.apitoken.token)" \
      -d '{ "tokens":["'"$DIPTOK"'"] }'
  else
    legacy_token_ensure
    pia_api /apiv2/dedicated_ip apiv2 /api/client/v2/dedicated_ip -X POST \
      --header 'Content-Type: application/json' \
      --header "Authorization: Token $(legacy_token_hash)" \
      -d '{ "tokens":["'"$DIPTOK"'"] }'
  fi
  DIPR="$(jq 'select(.[0]) | .[0]' "$PIARESP" 2>/dev/null)"
  # Extract status - if empty, API call failed (likely network down during restart)
  DIP_STATUS_NEW="$(echo "$DIPR" | jq -r 'select(.status) | .status')"
  if [ -z "$DIP_STATUS_NEW" ]; then
    # API call failed - preserve existing config if it exists
    DIP_STATUS_EXISTING="$(uci -q get "pia.$PIAWG_IF.dip_status")"
    if [ -n "$DIP_STATUS_EXISTING" ]; then
      echo "Cannot validate DIP (network down?), keeping existing config" >&3
      return 0
    else
      # No existing config and API failed - this is a real error
      echo "Warning: Cannot validate DIP token!" >&3
      return 1
    fi
  fi
  # API call succeeded - update UCI with fresh data
  # (written only when a value changed: spares the flash)
  DIPCH=''
  for DKV in "status|$DIP_STATUS_NEW" \
    "ip|$(echo "$DIPR" | jq -r 'select(.ip) | .ip')" \
    "cn|$(echo "$DIPR" | jq -r 'select(.cn) | .cn')" \
    "expire|$(echo "$DIPR" | jq -r 'select(.dip_expire) | .dip_expire')" \
    "id|$(echo "$DIPR" | jq -r 'select(.ip) | .id')"; do
    [ "$(uci -q get "pia.$PIAWG_IF.dip_${DKV%%|*}")" = "${DKV#*|}" ] && continue
    uci -q set "pia.$PIAWG_IF.dip_${DKV%%|*}=${DKV#*|}"
    DIPCH=1
  done
  [ -z "$DIPCH" ] || uci -q commit pia
}

# Remove the options of one group (iface_, peer_, dip_, region_) of the interface
clear_group() {
  for CG in $(uci -q show "pia.$PIAWG_IF" | sed -n "s/^pia\.$PIAWG_IF\.\($1[A-Za-z0-9_]*\)=.*/\1/p"); do
    uci -q delete "pia.$PIAWG_IF.$CG"
  done
}

set_dip() {
  while {
    printf "Dedicated IP token (press enter for none): "
    read -r DIPTOK
  }; do
    [ -z "$DIPTOK" ] && {
      clear_group dip_
      uci -q commit pia
      return
    }
    [ ${#DIPTOK} -eq 32 ] && [ "$(printf '%.3s' "$DIPTOK")" = "DIP" ] && break
    echo "Token starts with DIP and is 32 characters long!"
  done
  clear_group dip_
  uci -q set "pia.$PIAWG_IF=interface"
  uci -q set "pia.$PIAWG_IF.dip_token=$DIPTOK"
  uci -q commit pia
}

# Create an interface section ($1: the name; asked if missing)
set_iface() {
  NEWIF="$1"
  if [ -z "$NEWIF" ]; then
    printf "Name of the WireGuard network interface (press enter for %s): " "$PIAWG_IF"
    read -r NEWIF
    [ -z "$NEWIF" ] && NEWIF="$PIAWG_IF"
  fi
  valid_ifname "$NEWIF" || {
    echo "Invalid name: 1 to 15 letters, digits or underscore, and not one of:$RESERVED_NAMES" >&3
    return 1
  }
  PIAWG_IF="$NEWIF"
  set_ifvars
  if ! iface_exists "$PIAWG_IF"; then
    uci -q set "pia.$PIAWG_IF=interface"
    uci -q commit pia
  fi
  return 0
}

# Rename the interface being handled ($1: the new name); its network sections
# are removed (they are made again at the next start or renew)
rename_iface() {
  valid_ifname "$1" || {
    echo "Invalid name: 1 to 15 letters, digits or underscore, and not one of:$RESERVED_NAMES" >&2
    return 1
  }
  iface_exists "$PIAWG_IF" || {
    echo "No interface named '$PIAWG_IF' is configured!" >&2
    return 1
  }
  iface_exists "$1" && {
    echo "An interface named '$1' is already configured!" >&2
    return 1
  }
  ifdown "$PIAWG_IF" >/dev/null 2>&1
  uci -q delete "network.$PIAWG_IF"
  uci -q delete "network.$PIAWG_PEER"
  uci -q commit network
  uci -q rename "pia.$PIAWG_IF=$1"
  uci -q commit pia
  watchdog_remove
  rm -f "$SESSION"
  echo "Interface $PIAWG_IF is now $1 (start it again, and mind its firewall zone)"
  PIAWG_IF="$1"
  set_ifvars
}

# Forget an interface: its section, network sections, cron entry and session
remove_iface() {
  iface_exists "$1" || {
    echo "No interface named '$1' is configured!" >&2
    return 1
  }
  PIAWG_IF="$1"
  set_ifvars
  watchdog_remove
  ifdown "$PIAWG_IF" >/dev/null 2>&1
  uci -q delete "network.$PIAWG_IF"
  uci -q delete "network.$PIAWG_PEER"
  uci -q commit network
  uci -q delete "pia.$PIAWG_IF"
  uci -q commit pia
  rm -f "$SESSION"
  echo "Interface $PIAWG_IF removed"
}

set_defnetpeer() {
  clear_group peer_
  uci -q batch <<EOI >/dev/null
    set pia.$PIAWG_IF=interface
    set pia.$PIAWG_IF.peer_route_allowed_ips='1'
    set pia.$PIAWG_IF.peer_persistent_keepalive="25"
    add_list pia.$PIAWG_IF.peer_allowed_ips="::/0"
    add_list pia.$PIAWG_IF.peer_allowed_ips="0.0.0.0/0"
    commit pia
EOI
}

set_defnetiface() {
  clear_group iface_
  uci -q batch <<EOI >/dev/null
    set pia.$PIAWG_IF=interface
    set pia.$PIAWG_IF.iface_proto="wireguard"
    set pia.$PIAWG_IF.iface_defaultroute='1'
    set pia.$PIAWG_IF.iface_delegate='0' # No IPv6 with PIA
    commit pia
EOI
}

# ---- Session (RAM only), like the official apps ----
# The WireGuard key pair never touches the flash: it is generated for the
# session, registered with addKey, and kept in $SESSION (RAM) together with
# what addKey returned. The persistent network config only holds what never
# changes (interface name, proto, mtu, dns, allowed IPs, keepalive and a fixed
# placeholder key); key, address and server settings are staged in RAM.

session_get() { awk -F= -v k="$1" '$1==k{print substr($0,length(k)+2); exit}' "$SESSION" 2>/dev/null; }

session_scope() {
  if uci -q get "pia.$PIAWG_IF.dip_ip" >/dev/null; then
    echo "dip:$(uci -q get "pia.$PIAWG_IF.dip_ip")"
  else
    echo "region:$(uci -q get "pia.$PIAWG_IF.region_id")"
  fi
}

# A session exists and was made for the configured region / dedicated IP
session_valid() {
  [ -s "$SESSION" ] || return 1
  [ -n "$(session_get priv)" ] && [ -n "$(session_get server_key)" ] &&
    [ "$(session_get scope)" = "$(session_scope)" ]
}

# $1: private key; reads the addKey answer from $PIAADDKEY
session_save() {
  (
    umask 077
    {
      echo "scope=$(session_scope)"
      echo "priv=$1"
      echo "peer_ip=$WGPEERIP"
      echo "server_ip=$WGSERVIP"
      echo "server_port=$WGSERVPT"
      echo "server_key=$WGSERVKEY"
      echo "dns1=$WGDNS1"
      echo "dns2=$WGDNS2"
      echo "time=$(date +%s)"
    } >"$RUNDIR/session.$$.tmp" && mv "$RUNDIR/session.$$.tmp" "$SESSION"
  )
}

# Older versions: the config was /etc/config/pia_wg (anonymous sections), the
# cron tags and files were named pia_wg, and the keys and the legacy token were
# stored there. Convert once: config file, cache dir, cron entries, hook.
migrate_names() {
  OLDCONF='/etc/config/pia_wg'
  if [ -s "$OLDCONF" ] && [ ! -s "$PIACONF" ]; then
    migrate_config conf || return 1
  fi
  # cache dir on external storage
  if [ "$(uci -q get pia.cache.dir)" = '/mnt/usb/pia_wg' ]; then
    if [ -d /mnt/usb/pia_wg ] && [ ! -e /mnt/usb/pia ]; then
      mv /mnt/usb/pia_wg /mnt/usb/pia
    fi
    if [ -d /mnt/usb/pia ]; then
      uci -q set pia.cache.dir='/mnt/usb/pia'
      uci -q commit pia
    fi
  fi
  # cron tags and paths
  if grep -qF '# pia_wg ' /etc/crontabs/root 2>/dev/null; then
    MIGIF="$(iface_list | head -n 1)"
    crontab -l | sed \
      -e 's/# pia_wg cache/# pia cache/' \
      -e 's/# pia_wg renew/# pia renew/' \
      -e "s/# pia_wg watchdog/# pia watchdog [${MIGIF:-wg_pia}]/" \
      -e 's/# pia_wg expiry test/# pia expiry test/' \
      -e 's#/mnt/usb/pia_wg/#/mnt/usb/pia/#g' | crontab -
  fi
  if [ -e /etc/hotplug.d/iface/80-pia_wg ]; then
    rm -f /etc/hotplug.d/iface/80-pia_wg
    renew_installed && hook_install
  fi
  return 0
}

# /etc/config/pia_wg -> /etc/config/pia (one section per interface)
migrate_config() {
  MIGIF="$(uci -q get pia_wg.@iface[0].name)"
  valid_ifname "$MIGIF" || MIGIF='wg_pia'
  : >"$PIACONF"
  {
    MV="$(uci -q get pia_wg.@user[0].id)" && [ -n "$MV" ] && {
      echo "set pia.account=account"
      echo "set pia.account.id='$MV'"
      MV="$(uci -q get pia_wg.@user[0].password)" && echo "set pia.account.password='$MV'"
    }
    for MT in apitoken vpntoken; do
      uci -q get "pia_wg.@${MT}[0]" >/dev/null || continue
      echo "set pia.$MT=token"
      for MO in token user pass expires timestamp; do
        MV="$(uci -q get "pia_wg.@${MT}[0].$MO")" && echo "set pia.$MT.$MO='$MV'"
      done
    done
    uci -q get pia_wg.@cache[0] >/dev/null && {
      echo "set pia.cache=cache"
      for MO in dir insecure_meta; do
        MV="$(uci -q get "pia_wg.@cache[0].$MO")" && echo "set pia.cache.$MO='$MV'"
      done
      for MV in $(uci -q get pia_wg.@cache[0].regions); do echo "add_list pia.cache.regions='$MV'"; done
    }
    MV="$(uci -q get pia_wg.@log[0].path)" && {
      echo "set pia.log=log"
      echo "set pia.log.path='$MV'"
    }
    echo "set pia.$MIGIF=interface"
    for MO in id name dns; do
      MV="$(uci -q get "pia_wg.@region[0].$MO")" && echo "set pia.$MIGIF.region_$MO='$MV'"
    done
    for MO in token ip cn status expire id; do
      MV="$(uci -q get "pia_wg.@dip[0].$MO")" && echo "set pia.$MIGIF.dip_$MO='$MV'"
    done
    for MG in net_interface:iface net_peer:peer; do
      uci -q show "pia_wg.@${MG%%:*}[0]" | sed -n 's/^pia_wg\.[^.]*\.\([A-Za-z0-9_]*\)=\(.*\)$/\1 \2/p' |
        while read -r MK MR; do
          eval "set -- $MR"
          if [ $# -gt 1 ]; then
            for MV in "$@"; do echo "add_list pia.$MIGIF.${MG#*:}_$MK='$MV'"; done
          else
            echo "set pia.$MIGIF.${MG#*:}_$MK='$1'"
          fi
        done
    done
    echo "commit pia"
  } | uci -q batch >/dev/null
  # keep the old file unless the new one has what matters
  if [ "$(uci -q get pia.account.id)" = "$(uci -q get pia_wg.@user[0].id)" ] && iface_exists "$MIGIF"; then
    rm -f "$OLDCONF"
    # the peer used to be one constant section name; it is wgpeer_<interface> now
    if [ "$(uci -q get network.wgpeer_pia)" = "wireguard_$MIGIF" ]; then
      uci -q delete network.wgpeer_pia
      uci -q commit network
    fi
    echo "Configuration moved from $OLDCONF to $PIACONF (interface $MIGIF)"
  else
    echo "Could not convert $OLDCONF; it was left in place" >&2
    : >"$PIACONF"
    return 1
  fi
}

# Set a staged (RAM) option only if its effective value differs
stage_set() {
  [ "$(uci -q get "$1")" = "$2" ] && return 0
  uci -q set "$1=$2"
  NETCHANGED=1
}

# The persistent part of the interface and of the peer, as uci batch commands
persist_batch() {
  echo "delete network.$PIAWG_IF"
  echo "delete network.$PIAWG_PEER"
  echo "set network.$PIAWG_IF=interface"
  echo "set network.$PIAWG_IF.private_key=$WGPLACEHOLDER"
  echo "add_list network.$PIAWG_IF.dns=${WGDNS1:-10.0.0.243}"
  echo "add_list network.$PIAWG_IF.dns=${WGDNS2:-10.0.0.242}"
  echo "set network.$PIAWG_PEER=wireguard_${PIAWG_IF}"
  echo "set network.$PIAWG_PEER.description='PIA $(uci -q get "pia.$PIAWG_IF.region_name" | tr -d "'")'"
  # the interface's iface_* options go to the network interface, peer_* to the peer
  uci export pia | awk -v qn="'$PIAWG_IF'" -v ni="network.$PIAWG_IF" -v np="network.$PIAWG_PEER" '
    $1=="config"{d=($2=="interface" && $3==qn); next}
    d && ($1=="option" || $1=="list"){
      k=$2
      if (k ~ /^iface_/) { sub(/^iface_/, "", k); t=ni }
      else if (k ~ /^peer_/) { sub(/^peer_/, "", k); t=np }
      else next
      printf("%s %s.%s=%s\n", ($1=="option" ? "set" : "add_list"), t, k, $3)
    }'

}

# Create or update the persistent interface and peer, writing the flash only
# if what is there differs from what is wanted.
ensure_iface() {
  # own change directories: nothing must land in the RAM-staged session
  rm -f "$RUNDIR/persist"/* "$RUNDIR/ucid.t"/*
  : >"$RUNDIR/ucid/network"
  UCIS="uci -q -c $RUNDIR/ucid -t $RUNDIR/ucid.t"
  {
    persist_batch
    echo "commit network"
  } | $UCIS batch >/dev/null
  WANT="$($UCIS show network | sort)"
  HAVE="$( (
    $UCIP show "network.$PIAWG_IF"
    $UCIP show "network.$PIAWG_PEER"
  ) | sort)"
  [ "$WANT" = "$HAVE" ] && return 0
  {
    persist_batch
    echo "commit network"
  } | $UCIP batch >/dev/null
  NETCHANGED=1
}

# Stage the session key, address and server (RAM only)
stage_session() {
  stage_set "network.$PIAWG_IF.private_key" "$(session_get priv)"
  stage_set "network.$PIAWG_IF.addresses" "$(session_get peer_ip)"
  stage_set "network.$PIAWG_PEER.public_key" "$(session_get server_key)"
  stage_set "network.$PIAWG_PEER.endpoint_host" "$(session_get server_ip)"
  stage_set "network.$PIAWG_PEER.endpoint_port" "$(session_get server_port)"
}

# Is the session what netifd would use?
session_staged() {
  session_valid &&
    [ "$(uci -q get "network.$PIAWG_IF.private_key")" = "$(session_get priv)" ] &&
    [ "$(uci -q get "network.$PIAWG_PEER.public_key")" = "$(session_get server_key)" ] &&
    [ "$(uci -q get "network.$PIAWG_PEER.endpoint_host")" = "$(session_get server_ip)" ]
}

net_reload() {
  ubus call network reload >/dev/null 2>&1
  sleep 2
}

# Legacy PIA API v2 token (24h), used if the v5 API fails
renew_piatoken() {
  echo "Renewing PIA legacy token" >&3
  uci -q get pia.account >/dev/null || set_piauser

  pia_api /apiv2/token apiv2 /api/client/v2/token \
    --data-urlencode "username=$(uci -q get pia.account.id)" \
    --data-urlencode "password=$(uci -q get pia.account.password)"
  if [ $? -eq 2 ]; then
    echo "Error: Failed to connect to PIA authentication server!" >&3
    exit 1
  fi
  PIARESPONSE="$(cat "$PIARESP")"

  # Check if response is empty
  if [ -z "$PIARESPONSE" ]; then
    echo "Error: Empty response from PIA authentication server!" >&3
    exit 1
  fi

  # Check if response contains valid JSON with token field
  PIATOKEN="$(echo "$PIARESPONSE" | jq -r .token 2>/dev/null)"

  # Validate token format and handle errors
  if [ "$PIATOKEN" = "null" ] || [ -z "$PIATOKEN" ] || [ ${#PIATOKEN} -ne 128 ]; then
    echo "Error fetching PIA token!" >&3
    echo "Debug: Server response was:" >&3
    echo "$PIARESPONSE" | head -3 >&3
    # Check for common error patterns
    if echo "$PIARESPONSE" | jq -r .error 2>/dev/null | grep -q .; then
      echo "PIA Error: $(echo "$PIARESPONSE" | jq -r .error)" >&3
    elif echo "$PIARESPONSE" | grep -qi "invalid\|unauthorized\|credentials"; then
      echo "Hint: Check your PIA username and password" >&3
    fi
    exit 1
  fi

  (umask 077 && echo "$PIATOKEN $(date +%s)" >"$RUNDIR/legacy.$$.tmp" && mv "$RUNDIR/legacy.$$.tmp" "$LEGACYTOK")
}

# Show what is configured for one group of settings and ask whether to keep it
keep_conf_section() {
  KS="$PIAWG_IF"
  case "$1" in
  user) DESC='PIA user' KS='account' KP='' ;;
  net_interface) DESC='WireGuard network interface options' KP='iface_' ;;
  net_peer) DESC='WireGuard network PIA peer options' KP='peer_' ;;
  region) DESC='PIA region' KP='region_' ;;
  dip) DESC="Dedicated IP token" KP='dip_' ;;
  cache) DESC="Offline cache" KS='cache' KP='' ;;
  esac
  KOPTS="$(uci -q show "pia.$KS" | sed -n "s/^pia\.$KS\.\(${KP}[A-Za-z0-9_]*=.*\)/\1/p" | sed 's/^password=.*/password=<hidden>/')"
  if [ -n "$KOPTS" ]; then
    echo "A configuration already exists for '$DESC':"
    echo "$KOPTS" | sed 's/^/  /'
    read_yn "Keep this configuration" y
    return $?
  fi
  return 1
}

check_conf() {
  uci -q get pia.account >/dev/null &&
    echo "User is configured" ||
    {
      echo "User is not configured!" >&3
      sleep 1
      [ "$AUTO" ] && return 1 || set_piauser
    }
  iface_exists "$PIAWG_IF" || {
    echo "Interface $PIAWG_IF is not configured!" >&3
    [ "$AUTO" ] && return 1
    set_iface "$PIAWG_IF" || return 1
  }
  uci -q get "pia.$PIAWG_IF.iface_proto" >/dev/null &&
    echo "Network interface options are configured" ||
    {
      echo "Network interface options are not configured!" >&3
      sleep 1
      [ "$AUTO" ] && return 1 || set_defnetiface
    }
  uci -q get "pia.$PIAWG_IF.peer_allowed_ips" >/dev/null &&
    echo "Network peer options are configured" ||
    {
      echo "Network peer options are not configured!" >&3
      sleep 1
      [ "$AUTO" ] && return 1 || set_defnetpeer
    }
  if uci -q get "pia.$PIAWG_IF.dip_token" >/dev/null; then
    echo "Dedicated IP is configured"
    validate_dip
    DIP_STATUS="$(uci -q get "pia.$PIAWG_IF.dip_status")"
    [ "$DIP_STATUS" = 'active' ] &&
      echo "Dedicated IP is active" ||
      {
        echo "Dedicated IP status is $DIP_STATUS!" >&3
        sleep 1
        return 1
      }
  fi
  uci -q get "pia.$PIAWG_IF.region_id" >/dev/null &&
    echo "PIA region is configured" ||
    {
      echo "PIA region is not configured!" >&3
      sleep 1
      [ "$AUTO" ] && return 1 || select_region
    }
}

# Register the key and make netifd's config current. The session key is
# reused unless $NEWKEY is set (a start generates a new one, as the official
# apps do at each connection); only changed values are written.
set_netconf() {
  check_conf || {
    echo "Configuration is incomplete; exiting!" >&3
    exit 1
  }
  # if no DIP (DIP_STATUS is set from check_conf)
  if [ -z "$DIP_STATUS" ]; then
    if region_needs_legacy; then
      # Its servers refuse the VPN token: do not even try it
      echo "Region needs the legacy token; skipping the VPN token"
      legacy_token_ensure
      PIAAUTH='legacy'
    elif pia_tokens; then
      PIAAUTH='vpn'
    else
      echo "Could not get a PIA VPN token; trying the legacy token API" >&3
      legacy_token_ensure
      PIAAUTH='legacy'
    fi
  fi
  if [ -z "$NEWKEY" ] && session_valid; then
    WGPRIV="$(session_get priv)"
  else
    WGPRIV="$(wg genkey)"
  fi
  WGPUB="$(echo "$WGPRIV" | wg pubkey)"
  echo "Registering the key"

  if [ -z "$DIP_STATUS" ]; then
    pia_addkey_any
  else
    pia_wan
    PIAADDKEY="$(curl -s -k -G ${WANDEV:+--interface "if!$WANDEV"} --connect-to "$(uci -q get "pia.$PIAWG_IF.dip_cn")::$(uci -q get "pia.$PIAWG_IF.dip_ip")" --user "dedicated_ip_$(uci -q get "pia.$PIAWG_IF.dip_token"):$(uci -q get "pia.$PIAWG_IF.dip_ip")" --data-urlencode "pubkey=$WGPUB" "https://$(uci -q get "pia.$PIAWG_IF.dip_cn"):1337/addKey")"
  fi

  WGSERVSTATUS="$(echo "$PIAADDKEY" | jq -r '.status')"
  [ "$WGSERVSTATUS" = "OK" ] || {
    echo "PIA server status: $WGSERVSTATUS; Aborting!" >&3
    return 1
  }

  WGSERVIP="$(echo "$PIAADDKEY" | jq -r '.server_ip')"
  WGSERVPT="$(echo "$PIAADDKEY" | jq -r '.server_port')"
  WGSERVKEY="$(echo "$PIAADDKEY" | jq -r '.server_key')"
  WGDNS1="$(echo "$PIAADDKEY" | jq -r '.dns_servers[0]')"
  WGDNS2="$(echo "$PIAADDKEY" | jq -r '.dns_servers[1]')"
  WGPEERIP="$(echo "$PIAADDKEY" | jq -r '.peer_ip')"

  session_save "$WGPRIV"
  NETCHANGED=''
  OLDEP="$(uci -q get "network.$PIAWG_PEER.endpoint_host")"
  ensure_iface
  stage_session
  # The host route for the endpoint is made before the interface can come up,
  # and kept while it is down: otherwise its first packets loop (see below)
  endpoint_route "$WGSERVIP" pin
  [ -z "$OLDEP" ] || [ "$OLDEP" = "$WGSERVIP" ] || ip route del "$OLDEP/32" 2>/dev/null
  # netifd only rereads the config on a reload, which restarts a running
  # interface whose settings changed
  if [ -n "$NETCHANGED" ]; then
    if [ -n "$APPLY" ] || ! wg show "$PIAWG_IF" >/dev/null 2>&1; then
      net_reload
    else
      echo "Network settings changed; they apply at the next ifup (or use 'renew --apply')" >&3
    fi
  fi
  return 0
}

# The endpoint must never be routed through the tunnel itself: its encrypted
# packets would be fed back into the tunnel in a loop that saturates the CPU
# and takes the connection down. netifd does not always add a host route for
# it (not with a default route into the tunnel), so the script makes sure
# there is one, through the best default route that is not the tunnel.
#   endpoint_route <ip> pin    : install it
#   endpoint_route <ip> check  : install it only if the endpoint goes through
#                                the tunnel; fails if it still does
endpoint_route() {
  [ -n "$1" ] || return 0
  if [ "$2" = 'check' ]; then
    ERD="$(ip route get "$1" 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    [ "$ERD" = "$PIAWG_IF" ] || return 0
  fi
  ERL="$(ip -4 route show default | awk -v t="$PIAIFS" '
    {
      dev = ""; gw = ""; m = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") dev = $(i + 1)
        if ($i == "via") gw = $(i + 1)
        if ($i == "metric") m = $(i + 1)
      }
      if (dev != "" && index(t, " " dev " ") == 0 && dev !~ /^(tun|tap|ppp|wg)/) print m, (gw == "" ? "-" : gw), dev
    }' | sort -n | head -n 1)"
  [ -n "$ERL" ] || return 1
  # shellcheck disable=SC2086  # three words: metric, gateway or -, device
  set -- "$1" $ERL
  if [ "$3" = '-' ]; then
    ip route replace "$1/32" dev "$4" 2>/dev/null
  else
    ip route replace "$1/32" via "$3" dev "$4" 2>/dev/null
  fi
  ERD="$(ip route get "$1" 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ "$ERD" != "$PIAWG_IF" ]
}

start_wgpia() {
  stop_wgpia
  # a new key pair for each connection, as the official apps do
  NEWKEY=1
  set_netconf || {
    echo "Could not start PIA!" >&3
    return 1
  }
  NEWKEY=''
  echo "Starting PIA ($(uci get "network.$PIAWG_PEER.description"))" >&3
  # Before the tunnel exists, so that there is no moment without it
  endpoint_route "$(uci -q get "network.$PIAWG_PEER.endpoint_host")" pin
  ifup "$PIAWG_IF"
  sleep 1
  # The handshake can take a few seconds; check quietly before reporting
  N=0
  while [ $N -lt 5 ] && ! check_wg >/dev/null 2>&1 3>/dev/null; do
    N=$((N + 1))
    sleep 2
  done
  check_wg
  RET=$?
  [ $RET -eq 0 ] && echo "PIA started successfully ..." >&3 || echo "Could not start PIA!" >&3
  return $RET
}

stop_wgpia() {
  DESC=" ($(uci -q get "network.$PIAWG_PEER.description"))" || DESC=""
  echo "Stopping PIA$DESC" >&3
  ifdown "$PIAWG_IF" >/dev/null 2>&1
  # the host route pinned by endpoint_route
  SEP="$(uci -q get "network.$PIAWG_PEER.endpoint_host")" && [ -n "$SEP" ] && ip route del "$SEP/32" 2>/dev/null
  return 0
}

check_wg() {
  if wg show "$PIAWG_IF" >/dev/null 2>&1; then
    PIAWG_EP="$(wg show "$PIAWG_IF" endpoints | awk -F'[[:space:]:]' '{print $2; exit;}')"
    PIAWG_MK="$(wg show "$PIAWG_IF" fwmark)"
    [ "$PIAWG_MK" = "off" ] && PIAWG_MK=''
    # never leave the endpoint routed through the tunnel (routing loop)
    if ! endpoint_route "$PIAWG_EP" check; then
      echo "Routing loop: the endpoint $PIAWG_EP is routed through the tunnel; bringing it down!" >&3
      ifdown "$PIAWG_IF" >/dev/null 2>&1
      return 1
    fi
    WAN_IF="$(ip route get "$PIAWG_EP" ${PIAWG_MK:+mark "$PIAWG_MK"} | awk '{for(i=0;i<NF;i++){if($i=="dev"){print $++i; exit;}}}')"
    echo "WireGuard PIA interface: UP"
  else
    echo "WireGuard PIA interface: DOWN!" >&3
    return 1
  fi

  echo "Region is: $(uci get "network.$PIAWG_PEER.description")"
  # Probe PIA's own in-tunnel DNS address (handed out by addKey): the probe is
  # an ICMP packet that never leaves the tunnel and names no third party.
  # The first hop does not always answer TTL expiry, so also try a plain ping
  CHK="$(uci -q get "network.$PIAWG_IF.dns" | awk '{print $1}')"
  [ -n "$CHK" ] || CHK='10.0.0.243'
  if traceroute -i "$PIAWG_IF" -q1 -m1 "$CHK" | grep -q ' ms' ||
    ping -q -c1 -n -W 3 -I "$PIAWG_IF" "$CHK" >/dev/null 2>&1; then
    echo "Connectivity through PIA: OK"
  elif ping -q -c1 -n -I "$WAN_IF" "$PIAWG_EP" >/dev/null; then
    echo "Connectivity through PIA: NOK" >&3
    return 1
  elif WAN_GW="$(ip route show default dev "$WAN_IF" | awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}')" &&
    [ -n "$WAN_GW" ] && ping -q -c1 -n -W 3 -I "$WAN_IF" "$WAN_GW" >/dev/null 2>&1; then
    echo "Access to PIA Endpoint through WAN: NOK!" >&3
    return 1
  else
    echo "Connectivity through PIA: NOK (WAN gateway unreachable)" >&3
    return 1
  fi
}

# ---- Watchdog back-off (cron runs only): after repeated failed restarts wait
# longer, so that a dead server is not hammered and the config not rewritten.
watchdog_skip() {
  [ -s "$WDFAIL" ] || return 1
  read -r WN WT <"$WDFAIL"
  case "${WN:-0}" in
  0 | 1) WD=0 ;;
  2) WD=60 ;;
  3) WD=120 ;;
  4) WD=300 ;;
  *) WD=600 ;;
  esac
  [ $(($(date +%s) - ${WT:-0})) -lt $WD ]
}

watchdog_failed() {
  read -r WN _ <"$WDFAIL" 2>/dev/null
  echo "$((${WN:-0} + 1)) $(date +%s)" >"$WDFAIL"
}

# ---- renew: keep the key registered, nothing else ----
# It never starts or stops the tunnel: that is left to ifup/ifdown (LuCI).

# Seconds since the tunnel's last handshake (nothing if none)
handshake_age() {
  HSEC="$(wg show "$PIAWG_IF" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
  [ -n "$HSEC" ] && [ "$HSEC" -gt 0 ] || return 1
  echo $(($(date +%s) - HSEC))
}

# Is there a default route that is not the tunnel (a WAN)?
wan_present() {
  ip -4 route show default | awk -v t="$PIAIFS" '{for(i=1;i<NF;i++) if($i=="dev" && index(t, " " $(i+1) " ")==0 && $(i+1) !~ /^(tun|tap|ppp|wg)/) f=1} END{exit !f}'
}

# renew [--force] [--new-key] [--apply] [--if-missing]
renew_cmd() {
  RFORCE='' RNEWKEY='' RAPPLY='' RIFMISS=''
  for RA in "$@"; do
    case "$RA" in
    '--force') RFORCE=1 ;;
    '--new-key') RNEWKEY=1 ;;
    '--apply') RAPPLY=1 ;;
    '--if-missing') RIFMISS=1 ;;
    *)
      echo "Unknown renew option '$RA'!" >&2
      return 1
      ;;
    esac
  done
  if [ -n "$RIFMISS" ]; then
    # from the hotplug hook: quiet unless the session has to be made
    session_staged && return 0
    wan_present || return 0
    if [ -f "$RENEWFAIL" ] && [ $(($(date +%s) - $(cat "$RENEWFAIL" 2>/dev/null || echo 0))) -lt 30 ]; then
      return 0
    fi
  fi
  if [ -z "$RFORCE" ] && [ -z "$RNEWKEY" ] && HSECGE="$(handshake_age)" && [ "$HSECGE" -lt "$RENEW_SKIP" ]; then
    echo "The tunnel is up (handshake ${HSECGE}s ago): nothing to renew (use --force)"
    return 0
  fi
  if [ -n "$RNEWKEY" ] && [ -z "$RAPPLY" ] && wg show "$PIAWG_IF" >/dev/null 2>&1; then
    echo "The interface is up: a new key needs a restart of it; add --apply" >&2
    return 1
  fi
  echo "Renewing the registration (leaving via the WAN; the tunnel is not touched)"
  [ -n "$RNEWKEY" ] && NEWKEY=1
  APPLY="$RAPPLY"
  if ! set_netconf; then
    date +%s >"$RENEWFAIL"
    echo "Renew failed" >&2
    return 1
  fi
  rm -f "$RENEWFAIL"
  echo "Registered: $(session_get server_ip) as $(session_get peer_ip)"
  # the interface may have just been restarted by netifd (--apply)
  if [ -n "$RAPPLY" ]; then
    sleep 1
    endpoint_route "$(session_get server_ip)" pin
  fi
  return 0
}

renew_installed() { grep -qF "$CRON_TAG_RENEW" /etc/crontabs/root 2>/dev/null; }

hook_content() {
  cat <<EOF
#!/bin/sh
# Installed by pia_wg.sh ('renew install'): keeps the PIA session ready and
# pins the endpoint route when the PIA interface goes up
[ "\$ACTION" = ifup ] || [ "\$ACTION" = ifdown ] || exit 0
/bin/sh "$SCRIPTPATH" hook "\$ACTION" "\$INTERFACE" >/dev/null 2>&1 &
EOF
}

hook_install() {
  [ "$(hook_content)" = "$(cat "$HOOKFILE" 2>/dev/null)" ] && return 0
  hook_content >"$HOOKFILE.new" && chmod 755 "$HOOKFILE.new" && mv "$HOOKFILE.new" "$HOOKFILE"
}

renew_install() {
  hook_install
  watchdog_remove
  grep -qF "/bin/sh $SCRIPTPATH renew $CRON_TAG_RENEW" /etc/crontabs/root 2>/dev/null && return 0
  {
    crontab -l 2>/dev/null | grep -vF "$CRON_TAG_RENEW"
    echo "47 */6 * * * /bin/sh $SCRIPTPATH renew $CRON_TAG_RENEW"
  } | crontab -
  echo "[$(date)] Renew installed" >>"$PIALOG"
}

renew_remove() {
  rm -f "$HOOKFILE"
  renew_installed || return 0
  crontab -l | grep -vF "$CRON_TAG_RENEW" | crontab -
  echo "[$(date)] Renew removed" >>"$PIALOG"
}

# Called by the hotplug hook: hook ifup|ifdown <interface that changed>
# (the endpoint route is deliberately left in place when the interface goes
# down, so that the next ifup finds it)
hook_cmd() {
  case "$1" in
  ifup) ;;
  *) return 0 ;;
  esac
  if iface_exists "$2"; then
    PIAWG_IF="$2"
    set_ifvars
    HEP="$(uci -q get "network.$PIAWG_PEER.endpoint_host")"
    [ -n "$HEP" ] && endpoint_route "$HEP" pin
    # up with nothing registered: make the session, which restarts it
    session_staged || /bin/sh "$SCRIPTPATH" -i "$PIAWG_IF" renew --if-missing --apply
  else
    # another interface: a WAN that came back may need our session and a new gateway
    for HX in $(iface_list); do
      /bin/sh "$SCRIPTPATH" -i "$HX" renew --if-missing
      PIAWG_IF="$HX"
      set_ifvars
      HEP="$(uci -q get "network.$PIAWG_PEER.endpoint_host")"
      [ -n "$HEP" ] && endpoint_route "$HEP" pin
    done
  fi
  return 0
}

watchdog_installed() {
  grep -qF "$CRON_TAG_WD" /etc/crontabs/root 2>/dev/null
  return $?
}

watchdog_lastrun() {
  [ -f "$PIALOG" ] && date -r "$PIALOG" || return 1
}

watchdog_install() {
  grep -qF "/bin/sh $SCRIPTPATH -i $PIAWG_IF start --cron $CRON_TAG_WD" /etc/crontabs/root 2>/dev/null && return
  {
    crontab -l 2>/dev/null | grep -vF "$CRON_TAG_WD"
    echo "* * * * * /bin/sh $SCRIPTPATH -i $PIAWG_IF start --cron $CRON_TAG_WD"
  } | crontab -
  echo "[$(date)] Watchdog installed" >>"$PIALOG"
}

watchdog_remove() {
  watchdog_installed || return
  crontab -l | grep -vF "$CRON_TAG_WD" | crontab -
  echo "[$(date)] Watchdog removed" >>"$PIALOG"
}

log_show() {
  [ -s "$PIALOG" ] && cat "$PIALOG" || echo "Log is empty!"
  watchdog_installed && WLR="$(watchdog_lastrun)" && echo "[$WLR] Watchdog last check"
}

log_clear() {
  echo "[$(date)] Log cleared" >"$PIALOG"
}

script_update() {
  TMPDL="$RUNDIR/update.$$.tmp"
  curl -sfL --max-time 30 -o "$TMPDL" "$SCRIPTDL" || {
    echo "Failed to check/download latest version!" >&2
    rm -f "$TMPDL"
    exit 1
  }
  # Never install anything that is not a pia_wg.sh script (error page, partial
  # download, wrong file)
  if [ "$(head -n 1 "$TMPDL")" != '#!/bin/sh' ] ||
    ! grep -q '^# Version: ' "$TMPDL" ||
    ! grep -q 'pia_wg' "$TMPDL" ||
    ! sh -n "$TMPDL" 2>/dev/null; then
    echo "The downloaded file is not a valid pia_wg.sh script; update aborted!" >&2
    rm -f "$TMPDL"
    exit 1
  fi
  MD5D="$(md5sum "$TMPDL" | cut -d' ' -f1)"
  MD5C="$(md5sum "$SCRIPTPATH" | cut -d' ' -f1)"
  [ "$MD5D" = "$MD5C" ] && {
    echo "This is already latest version ($CURVERS)"
    rm "$TMPDL"
    exit
  }
  NEWVERS="$(awk '(index($0,"# Version: ")==1){print $3; exit}' "$TMPDL")"
  read_yn "Version $NEWVERS is available (current: $CURVERS); install" n || {
    rm "$TMPDL"
    exit
  }
  echo "Upgrading from version $CURVERS to version $NEWVERS"
  mv "$TMPDL" "$SCRIPTPATH"
  chmod +x "$SCRIPTPATH"
  echo "Done"
}

# Install the cron jobs requested with --watchdog and/or --cache
install_jobs() {
  shift
  for A in "$@"; do
    case "$A" in
    '--watchdog') watchdog_install ;;
    '--cache') cache_install ;;
    esac
  done
}

print_usage() {
  echo "Usage: $0 [ -i <interface|all> ] { configure <section> | start [ --watchdog ] [ --cache ] | restart [ --watchdog ] [ --cache ] | stop | status | renew [ --force | --new-key | --apply ] | renew { install | remove } | watchdog { install | remove } | cache { refresh | install | remove | show | probe } | log { show | clear | path } | update | version}"
  echo "  The interfaces are the sections of /etc/config/pia, named like the network interface."
  echo "  With several, -i NAME selects one (-i all or nothing: every one, for start, restart, stop, status, renew)."
  echo "  Details:"
  echo "    - configure          : same as configure all"
  echo "    - configure all      : configure all settings (of the interface, created if needed)"
  echo "    - configure user     : set PIA user ID and password (shared by the interfaces)"
  echo "    - configure dip      : set PIA dedicated IP"
  echo "    - configure region   : set/choose PIA region"
  echo "    - configure keys     : (the keys are kept in RAM only; nothing to configure)"
  echo "    - configure interface [name] : create an interface (a section of /etc/config/pia)"
  echo "    - configure rename <name>    : rename the interface (-i old)"
  echo "    - configure remove <name>    : forget an interface (config, network sections, cron)"
  echo "    - configure cache    : set offline cache directory and options"
  echo "    - configure network  : generate default network settings"
  echo "    - init-network       : setup PIA WireGuard network (no start)"
  echo "    - start              : start PIA WireGuard (if not already up)"
  echo "    - start --watchdog   : same as start and install the watchdog"
  echo "    - restart            : start or restart PIA WireGuard"
  echo "    - restart --watchdog : same as restart and install the watchdog"
  echo "    - start|restart --cache : same and install the cache refresh"
  echo "    - stop               : stop PIA WireGuard (and remove the watchdog)"
  echo "    - status             : show PIA WireGuard status"
  echo "    - renew              : register the session key again (never starts or stops the tunnel; skipped while it is up)"
  echo "    - renew --force      : register even if the tunnel is up (the key is re-added on the server)"
  echo "    - renew --new-key    : register a new key (needs --apply if the interface is up: it is restarted)"
  echo "    - renew install      : install the renew cron (every 6 hours, all interfaces) and the ifup hook; removes the watchdogs"
  echo "    - renew remove       : remove the renew cron and the hook"
  echo "    - watchdog install   : install the watchdog (legacy, always on; per interface)"
  echo "    - watchdog remove    : remove the watchdog"
  echo "    - cache refresh      : refresh the offline cache (servers list, meta servers, tokens)"
  echo "    - cache install      : install the cache refresh (cron, every 6 hours)"
  echo "    - cache remove       : remove the cache refresh"
  echo "    - cache show         : show the offline cache"
  echo "    - cache probe        : check which regions need the legacy token"
  echo "    - log show           : display the log"
  echo "    - log clear          : clear the log"
  echo "    - log path           : set a custom Directory Path for the log"
  echo "    - update             : update the script to latest version"
  echo "    - version            : print the version and exit"
}

# ---- Main ->

# -i NAME selects the interface (-i all: every one); with a single interface
# configured it is implicit
SELIF=''
if [ "$1" = '-i' ]; then
  SELIF="$2"
  [ -n "$SELIF" ] || {
    echo "-i needs an interface name (or all)" >&2
    exit 1
  }
  shift 2
fi

[ -t 0 ] && unset AUTO || AUTO=1
rundir_init
trap cleanup EXIT
trap 'exit 1' 1 2 3 6 15

# Names of older versions (config, cron tags, hook, cache dir), once
if [ -s /etc/config/pia_wg ] || [ -e /etc/hotplug.d/iface/80-pia_wg ] || grep -qF '# pia_wg ' /etc/crontabs/root 2>/dev/null; then
  MIGWAIT=0
  while ! mkdir "$RUNDIR/migrate.lock" 2>/dev/null && [ $MIGWAIT -lt 30 ]; do
    MIGWAIT=$((MIGWAIT + 1))
    sleep 1
  done
  [ -e "$PIACONF" ] || touch "$PIACONF"
  migrate_names
  rmdir "$RUNDIR/migrate.lock" 2>/dev/null
fi
[ -e "$PIACONF" ] || touch "$PIACONF"

# Which interface
IFLIST="$(iface_list)"
IFCOUNT="$(echo "$IFLIST" | grep -c .)"
MULTI=''
if [ -n "$SELIF" ] && [ "$SELIF" != 'all' ]; then
  PIAWG_IF="$SELIF"
  valid_ifname "$PIAWG_IF" || {
    echo "Invalid interface name '$PIAWG_IF'!" >&2
    exit 1
  }
elif [ "$IFCOUNT" -eq 1 ]; then
  PIAWG_IF="$IFLIST"
elif [ "$IFCOUNT" -gt 1 ]; then
  MULTI=1
  PIAWG_IF="$(echo "$IFLIST" | head -n 1)"
fi
set_ifvars
PIALOG="$(logfile)"

# Logging (only if not in interactive mode)
if [ "$AUTO" ]; then
  FIFO="$RUNDIR/log.$$.fifo"
  export FIFO
  [ -f "$PIALOG" ] && touch "$PIALOG" || echo "[$(date)] Log created" >"$PIALOG"
  mkfifo "$FIFO"
  # Open both ends before starting the reader, which gets its own read-only
  # descriptor: a short command may exit (and remove the pipe) before a
  # reader that opens it by name has started, and the reader must not hold
  # the write end or it would never see the end of the input.
  exec 3<>"$FIFO"
  exec 4<"$FIFO"
  awk -v lf="$PIALOG" -v date="$(date)" '{print; printf("[%s] %s\n",date,$0) >> lf}' <&4 3>&- 4<&- >&2 &
  exec 4<&-
else
  exec 3>&2
fi

# Several interfaces and none named (or -i all): run the command for each
if [ -n "$MULTI" ] || [ "$SELIF" = 'all' ]; then
  case "$1" in
  'start' | 'restart' | 'stop' | 'status' | 'renew' | 'init-network')
    case "$1 $2" in
    'renew install' | 'renew remove') ;;
    *)
      MR=0
      for MX in $IFLIST; do
        [ "$1" = 'status' ] && echo "== $MX =="
        /bin/sh "$SCRIPTPATH" -i "$MX" "$@" || MR=1
      done
      exit $MR
      ;;
    esac
    ;;
  'configure' | 'watchdog')
    case "$1 $2" in
    'configure ' | 'configure all' | 'configure region' | 'configure dip' | 'configure network' | 'configure rename' | 'watchdog install' | 'watchdog remove')
      if [ -z "$SELIF" ] || [ "$SELIF" = 'all' ]; then
        echo "Several interfaces are configured ($(echo "$IFLIST" | tr '\n' ' ')): use -i NAME" >&2
        exit 1
      fi
      ;;
    esac
    ;;
  esac
fi

# Serialise the runs that act on the tunnel, the tokens or the cache
case "$1" in
'start' | 'restart' | 'stop' | 'init-network') lock_take "$1" ;;
'renew') case "$2" in
  'install' | 'remove') ;;
  *) lock_take "$1" ;;
  esac ;;
'cache') case "$2" in
  'refresh' | 'probe') lock_take "$1 $2" ;;
  esac ;;
esac

case "$1" in
'configure') case "$2" in
  '' | 'all')
    keep_conf_section 'user' || set_piauser
    iface_exists "$PIAWG_IF" || set_iface "$SELIF" || exit 1
    keep_conf_section 'net_interface' || set_defnetiface
    keep_conf_section 'net_peer' || set_defnetpeer
    if read_yn "Do you have a dedicated IP" n; then
      keep_conf_section 'dip' || set_dip
      validate_dip
    else
      clear_group dip_
      uci -q commit pia
    fi
    # if no DIP ask for region
    uci -q get "pia.$PIAWG_IF.dip_token" >/dev/null || keep_conf_section 'region' || select_region
    keep_conf_section 'cache' || set_cache
    ;;
  'user') keep_conf_section 'user' || set_piauser ;;
  'dip')
    iface_exists "$PIAWG_IF" || set_iface "$SELIF" || exit 1
    keep_conf_section 'dip' || set_dip
    ;;
  'region')
    iface_exists "$PIAWG_IF" || set_iface "$SELIF" || exit 1
    keep_conf_section 'region' || select_region
    ;;
  'network')
    iface_exists "$PIAWG_IF" || set_iface "$SELIF" || exit 1
    keep_conf_section 'net_interface' || set_defnetiface
    keep_conf_section 'net_peer' || set_defnetpeer
    ;;
  'keys') echo "The WireGuard keys are not saved: a new pair is generated in RAM at each start (as the official apps do) or with 'renew --new-key'" ;;
  'cache') keep_conf_section 'cache' || set_cache ;;
  'interface') set_iface "$3" ;;
  'rename') rename_iface "$3" ;;
  'remove') remove_iface "${3:-$SELIF}" ;;
  *)
    echo "Unknown configure subcommand '$2'!"
    print_usage
    exit 1
    ;;
  esac ;;
'watchdog') case "$2" in
  'install') watchdog_install ;;
  'remove') watchdog_remove ;;
  *)
    echo "Unknown watchdog subcommand '$2'!"
    print_usage
    exit 1
    ;;
  esac ;;
'cache') case "$2" in
  'refresh') cache_refresh ;;
  'install') cache_install ;;
  'remove') cache_remove ;;
  'show') cache_show ;;
  'probe') legacy_probe && echo "Regions needing the legacy token: $(legacy_ids)" ;;
  *)
    echo "Unknown cache subcommand '$2'!"
    print_usage
    exit 1
    ;;
  esac ;;
'init-network') set_netconf ;;
'renew') case "$2" in
  'install') renew_install ;;
  'remove') renew_remove ;;
  *)
    shift
    renew_cmd "$@"
    exit $?
    ;;
  esac ;;
'hook') shift && hook_cmd "$@" ;;
'restart')
  start_wgpia
  R=$?
  [ $R -eq 0 ] && install_jobs "$@"
  exit $R
  ;;
'start')
  check_wg
  case $? in
  0)
    rm -f "$WDFAIL"
    echo "PIA is already up!"
    ;;
  1)
    if [ "$2" = '--cron' ] && watchdog_skip; then
      echo "Backing off after failed restarts; not trying again yet"
      exit 0
    fi
    if start_wgpia; then
      rm -f "$WDFAIL"
    else
      [ "$2" = '--cron' ] && watchdog_failed
      false
    fi
    ;;
  2) echo "Could not start PIA!" >&2 ;;
  esac
  R=$?
  [ $R -eq 0 ] && install_jobs "$@"
  exit $R
  ;;
'stop')
  watchdog_remove
  stop_wgpia
  ;;
'status')
  check_wg
  R=$?
  if session_valid; then
    echo "Session key: RAM only, registered $(($(date +%s) - $(session_get time)))s ago on $(session_get server_ip)"
  else
    echo "Session key: none (made at the next start, renew or ifup)"
  fi
  if renew_installed; then
    echo "Renew (cron) installed: YES"
  else
    echo "Renew (cron) installed: NO"
  fi
  if watchdog_installed; then
    echo "Watchdog (cron) installed: YES"
    if WLR="$(watchdog_lastrun)"; then
      echo "Watchdog last check: $WLR"
    fi
  else
    echo "Watchdog (cron) installed: NO"
  fi
  exit $R
  ;;
'log') case "$2" in
  'show') log_show ;;
  'clear') log_clear ;;
  'path') set_logpath ;;
  *)
    echo "Unknown log subcommand '$2'!"
    print_usage
    exit 1
    ;;
  esac ;;
'update') script_update ;;
'version') echo "Version is ${CURVERS}" ;;
'') print_usage ;;
*)
  echo "Unknown command '$*'!" >&2
  print_usage
  exit 1
  ;;
esac

exit
