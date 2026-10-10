#!/bin/sh
#
# pia_wg.sh
# Script to setup and run PIA through WireGuard on OpenWrt
#
# Inspired from:
# - This thread: https://forum.openwrt.org/t/private-internet-access-pia-wireguard-vpn-on-openwrt/155475
# - And @Lazerdog's script: https://github.com/jimhall718/piawg/blob/main/piawgx.sh
#
# Version: 1.0.16
#
# ©2026 bOLEMO
# https://github.com/bolemo/pia_wg/
#
#########

SCRIPTDL="https://raw.githubusercontent.com/bolemo/pia_wg/main/pia_wg.sh"
SCRIPTPATH="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)/${0##*/}"
RUNDIR='/var/run/pia' # temporary files (RAM); created on demand, mode 0700
LOCKDIR="$RUNDIR/pia_wg.lock"
LOCK_WAIT=120  # seconds a manual command waits for another run
LOCK_STEAL=900 # seconds after which a run still holding the lock is considered stuck
LOGDEFPATH='/var/log/pia'
LOGNAME='pia_wg_watchdog.log'
PIACONF='/etc/config/pia_wg'
PIAWG_IF="$(uci -q get pia_wg.@iface[0].name)" || PIAWG_IF='wg_pia'
case "$PIAWG_IF" in
'' | *[!A-Za-z0-9_]*) PIAWG_IF='wg_pia' ;;
esac
[ ${#PIAWG_IF} -le 15 ] || PIAWG_IF='wg_pia'
PIAWG_PEER='wgpeer_pia'
CACHEDEFDIR='/mnt/usb/pia_wg' # external storage, to spare the router flash
CACHERAMDIR="$RUNDIR/cache"   # used when the external storage is not mounted
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
  LOCKDIR="$RUNDIR/pia_wg.lock"
  CACHERAMDIR="$RUNDIR/cache"
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

# Is this pid a live pia_wg.sh run (and not a reused pid)?
pid_is_pia() {
  kill -0 "$1" 2>/dev/null && grep -q pia_wg "/proc/$1/cmdline" 2>/dev/null
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
        echo "Another pia_wg.sh run is in progress (pid $LPID: $LCMD); skipping" >&3
        exit 0
      fi
      if [ $LW -ge "$LOCK_WAIT" ]; then
        echo "Another pia_wg.sh run (pid $LPID: $LCMD) is still in progress after ${LOCK_WAIT}s; giving up" >&3
        exit 75
      fi
      [ $LW -eq 0 ] && echo "Waiting for another pia_wg.sh run (pid $LPID: $LCMD)…" >&3
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
    LOGPATH="$(uci -q get pia_wg.@log[0].path)"
    echo "Current Directory Path is: $LOGPATH"
    printf "Enter the Directory Path for the log (press enter to keep current one): "
    read -r NEWLOGPATH
    [ -z "$NEWLOGPATH" ] || LOGPATH="$NEWLOGPATH"
  fi
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@log[0]
    add pia_wg log
    set pia_wg.@log[0].path="$LOGPATH"
    commit pia_wg.@log[0]
EOI
}

logfile() {
  if LOGPATH=$(uci -q get pia_wg.@log[0].path); then
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
  wg show "$PIAWG_IF" >/dev/null 2>&1 || return 0
  WEP="$(wg show "$PIAWG_IF" endpoints | awk -F'[[:space:]:]' '{print $2; exit}')"
  [ -n "$WEP" ] || return 0
  WMK="$(wg show "$PIAWG_IF" fwmark)"
  [ "$WMK" = 'off' ] && WMK=''
  WANDEV="$(ip route get "$WEP" ${WMK:+mark "$WMK"} 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ "$WANDEV" = "$PIAWG_IF" ] && WANDEV=''
  return 0
}

cache_dir() {
  CACHEDIR="$(uci -q get pia_wg.@cache[0].dir)" || CACHEDIR="$CACHEDEFDIR"
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
  jq -r --arg regs "$(uci -q get pia_wg.@region[0].id) $(uci -q get pia_wg.@cache[0].regions)" '
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

# Days of validity left for the token stored in pia_wg.@<section>[0]
token_days() {
  TDE="$(uci -q get "pia_wg.@$1[0].expires")"
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
  if uci -q get pia_wg.@user[0] >/dev/null; then
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
  grep -qF 'pia_wg.sh cache refresh' /etc/crontabs/root 2>/dev/null
}

cache_install() {
  cache_installed && return
  {
    crontab -l
    echo "17 */6 * * * /bin/sh $SCRIPTPATH cache refresh # pia_wg cache"
  } | crontab -
  echo "[$(date)] Cache refresh installed" >>"$PIALOG"
}

cache_remove() {
  cache_installed || return
  crontab -l | grep -vF 'pia_wg.sh cache refresh' | crontab -
  echo "[$(date)] Cache refresh removed" >>"$PIALOG"
}

cache_show() {
  CD="$(cache_dir)"
  echo "Cache directory: $CD"
  [ "$CD" = "$CACHERAMDIR" ] && echo "  (RAM: configured directory not mounted)"
  cache_installed && echo "Cache refresh (cron) installed: YES" || echo "Cache refresh (cron) installed: NO"
  if [ -s "$CD/servers.json" ]; then
    echo "Servers list: $(jq '.regions | length' "$CD/servers.json") regions, updated $(date -r "$CD/servers.json")"
    PIAREGIONID="$(uci -q get pia_wg.@region[0].id)" &&
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
  CACHEDIR="$(uci -q get pia_wg.@cache[0].dir)" || CACHEDIR="$CACHEDEFDIR"
  printf "Directory for the offline cache (press enter for %s): " "$CACHEDIR"
  read -r NEWCACHEDIR
  [ -z "$NEWCACHEDIR" ] || CACHEDIR="$NEWCACHEDIR"
  printf "Extra region IDs to take meta servers from, space separated (press enter for none): "
  read -r CACHEREGIONS
  read_yn "Allow meta servers whose certificate is not signed by the PIA CA (insecure)" n && CACHEINSECURE=1 || CACHEINSECURE=0
  {
    echo "delete pia_wg.@cache[0]"
    echo "add pia_wg cache"
    echo "set pia_wg.@cache[0].dir=\"$CACHEDIR\""
    echo "set pia_wg.@cache[0].insecure_meta=\"$CACHEINSECURE\""
    for R in $CACHEREGIONS; do echo "add_list pia_wg.@cache[0].regions=\"$R\""; done
    echo "commit pia_wg"
  } | uci -q batch >/dev/null
}

# Regions whose WireGuard servers refuse the VPN token (HTTP 401 on addKey) and
# only accept the legacy 24h token. addKey is called with a deliberately invalid
# public key: a server that accepts the token answers 409 (invalid key) and
# registers nothing, one that refuses it answers 401. The first server of each
# online region is asked, then the others if it refuses; a region is listed (in
# $CACHE/legacy.list, after a '# <epoch>' line) only if all the servers that
# answered refused.
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
  echo "Checking the regions (leaving via ${WANDEV:-the default route}); this takes a few minutes" >&3
  CA="$(pia_ca)"
  LU="$(uci -q get pia_wg.@vpntoken[0].user)"
  LP="$(uci -q get pia_wg.@vpntoken[0].pass)"
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
        for SRV in $SRVS; do
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
        [ $TRY -gt 0 ] && [ $REF -eq $TRY ] && echo "$RID" >>"$CD/legacy.list.tmp"
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
    delete pia_wg.@region[0]
    add pia_wg region
    set pia_wg.@region[0].id="$PIAREGIONID"
    set pia_wg.@region[0].name="$PIAREGIONNAME"
    set pia_wg.@region[0].dns="$PIAREGIONDNS"
    commit pia_wg.@region[0]
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
    delete pia_wg.@user[0]
    add pia_wg user
    set pia_wg.@user[0].id="$PIAUSER"
    set pia_wg.@user[0].password="$PIAPASS"
    commit pia_wg.@user[0]
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
# if pia_wg.@cache[0].insecure_meta is set, then privateinternetaccess.com and
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
  [ "$(uci -q get pia_wg.@cache[0].insecure_meta)" = '1' ] &&
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

# token_ok <section> [renew]: is the stored token in pia_wg.@<section>[0]
# still usable (default) or still fresh (renew: before half of its life, at
# most 21 days before expiry, as the official apps do)
token_ok() {
  uci -q get "pia_wg.@$1[0]" >/dev/null || return 1
  EXP="$(uci -q get "pia_wg.@$1[0].expires")"
  TS="$(uci -q get "pia_wg.@$1[0].timestamp")"
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
    delete pia_wg.@apitoken[0]
    add pia_wg apitoken
    set pia_wg.@apitoken[0].token="$APITOK"
    set pia_wg.@apitoken[0].expires="$(iso2epoch "$(jq -r '.expires_at // empty' "$PIARESP")")"
    set pia_wg.@apitoken[0].timestamp="$(date +%s)"
    commit pia_wg
EOI
}

# PIA API v5 login (username/password -> long lived API token)
api_login() {
  echo "Logging in to PIA" >&3
  uci -q get pia_wg.@user[0] >/dev/null || {
    [ "$AUTO" ] && return 1 || set_piauser
  }
  pia_api /api/client/v5/api_token apiv5 /api/client/v5/api_token \
    --data-urlencode "username=$(uci -q get pia_wg.@user[0].id)" \
    --data-urlencode "password=$(uci -q get pia_wg.@user[0].password)"
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
    --header "Authorization: Token $(uci -q get pia_wg.@apitoken[0].token)" &&
    store_apitoken
}

# PIA API v5: API token -> VPN token (used to authenticate on VPN servers)
vpn_token_get() {
  echo "Renewing PIA VPN token" >&3
  pia_api /api/client/v5/vpn_token apiv5 /api/client/v5/vpn_token -d "" \
    --header "Authorization: Token $(uci -q get pia_wg.@apitoken[0].token)" || return
  VPNS1="$(jq -r '.vpn_secret1 // empty' "$PIARESP" 2>/dev/null)"
  VPNS2="$(jq -r '.vpn_secret2 // empty' "$PIARESP" 2>/dev/null)"
  [ "$VPNS1" ] && [ "$VPNS2" ] || return 2
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@vpntoken[0]
    add pia_wg vpntoken
    set pia_wg.@vpntoken[0].user="vpn_token_$VPNS1"
    set pia_wg.@vpntoken[0].pass="$VPNS2"
    set pia_wg.@vpntoken[0].expires="$(iso2epoch "$(jq -r '.expires_at // empty' "$PIARESP")")"
    set pia_wg.@vpntoken[0].timestamp="$(date +%s)"
    commit pia_wg
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
  uci -q delete pia_wg.@vpntoken[0]
  uci -q commit pia_wg
}

# Register our WireGuard key on a server of the configured region, as the
# official apps do: by IP (certificate verified against the PIA CA) using the
# cached servers list, then through the region hostname (legacy behaviour).
# Response in $PIAADDKEY; $ADDKEYAUTHFAIL is set if a server refused the token.
pia_addkey() {
  piaresp_init
  pia_wan
  CA="$(pia_ca)"
  PUB="$(uci -q get pia_wg.@keys[0].pub)"
  if [ "$PIAAUTH" = 'vpn' ]; then
    set -- --user "$(uci -q get pia_wg.@vpntoken[0].user):$(uci -q get pia_wg.@vpntoken[0].pass)"
  else
    set -- --data-urlencode "pt=$(uci -q get pia_wg.@token[0].hash)"
  fi
  SERVERS="$(jq -r --arg r "$(uci -q get pia_wg.@region[0].id)" \
    '.regions[] | select(.id == $r) | .servers.wg[]? | "\(.ip) \(.cn) ip"' "$(cache_dir)/servers.json" 2>/dev/null)
$(uci -q get pia_wg.@region[0].dns) - dns"
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
  LRID="$(uci -q get pia_wg.@region[0].id)" || return 1
  [ -n "$LRID" ] || return 1
  case " $(legacy_ids) " in
  *" $LRID "*) return 0 ;;
  esac
  return 1
}

# Legacy (v2) tokens are valid for 24h
legacy_token_ensure() {
  LTS="$(uci -q get pia_wg.@token[0].timestamp)"
  [ $(($(date +%s) - ${LTS:-0})) -lt 82800 ] || renew_piatoken
}

# Register our key with the VPN token. Some PIA servers still refuse the VPN
# token (HTTP 401) and only accept the legacy one: renew the VPN token once
# if it is not brand new, then fall back to the legacy token.
pia_addkey_any() {
  if [ "$PIAAUTH" = 'vpn' ]; then
    pia_addkey && return 0
    [ "$ADDKEYAUTHFAIL" ] || return 1
    VTS="$(uci -q get pia_wg.@vpntoken[0].timestamp)"
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
  DIPTOK="$(uci -q get pia_wg.@dip[0].token)" || return
  token_ok apitoken || pia_tokens >/dev/null 2>&1
  # Try to fetch DIP info from API
  if uci -q get pia_wg.@apitoken[0].token >/dev/null; then
    pia_api /api/client/v5/dedicated_ip apiv5 /api/client/v5/dedicated_ip -X POST \
      --header 'Content-Type: application/json' \
      --header "Authorization: Token $(uci -q get pia_wg.@apitoken[0].token)" \
      -d '{ "tokens":["'"$DIPTOK"'"] }'
  else
    pia_api /apiv2/dedicated_ip apiv2 /api/client/v2/dedicated_ip -X POST \
      --header 'Content-Type: application/json' \
      --header "Authorization: Token $(uci -q get pia_wg.@token[0].hash)" \
      -d '{ "tokens":["'"$DIPTOK"'"] }'
  fi
  DIPR="$(jq 'select(.[0]) | .[0]' "$PIARESP" 2>/dev/null)"
  # Extract status - if empty, API call failed (likely network down during restart)
  DIP_STATUS_NEW="$(echo "$DIPR" | jq -r 'select(.status) | .status')"
  if [ -z "$DIP_STATUS_NEW" ]; then
    # API call failed - preserve existing config if it exists
    DIP_STATUS_EXISTING="$(uci -q get pia_wg.@dip[0].status)"
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
  uci -q batch <<EOI >/dev/null
  set pia_wg.@dip[0].status="$DIP_STATUS_NEW"
  set pia_wg.@dip[0].ip="$(echo "$DIPR" | jq -r 'select(.ip) | .ip')"
  set pia_wg.@dip[0].cn="$(echo "$DIPR" | jq -r 'select(.cn) | .cn')"
  set pia_wg.@dip[0].expire="$(echo "$DIPR" | jq -r 'select(.dip_expire) | .dip_expire')"
  set pia_wg.@dip[0].id="$(echo "$DIPR" | jq -r 'select(.ip) | .id')"
  commit pia_wg.@dip[0]
EOI
}

set_dip() {
  while {
    printf "Dedicated IP token (press enter for none): "
    read -r DIPTOK
  }; do
    [ -z "$DIPTOK" ] && {
      uci -q delete pia_wg.@dip[0]
      uci -q commit pia_wg
      return
    }
    [ ${#DIPTOK} -eq 32 ] && [ "$(printf '%.3s' "$DIPTOK")" = "DIP" ] && break
    echo "Token starts with DIP and is 32 characters long!"
  done
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@dip[0]
    add pia_wg dip
    set pia_wg.@dip[0].token="$DIPTOK"
    commit pia_wg.@dip[0]
EOI
}

set_iface() {
  printf "Name of the WireGuard network interface (press enter to keep %s): " "$PIAWG_IF"
  read -r NEWIF
  [ -z "$NEWIF" ] && NEWIF="$PIAWG_IF"
  case "$NEWIF" in
  '' | *[!A-Za-z0-9_]*)
    echo "Invalid name: use letters, digits and underscore only!" >&3
    return 1
    ;;
  esac
  [ ${#NEWIF} -le 15 ] || {
    echo "Invalid name: 15 characters at most!" >&3
    return 1
  }
  if [ "$NEWIF" != "$PIAWG_IF" ] && uci -q get "network.$PIAWG_IF" >/dev/null; then
    # Remove the interface created under the previous name
    ifdown "$PIAWG_IF" >/dev/null 2>&1
    uci -q delete "network.$PIAWG_IF"
    uci -q delete "network.$PIAWG_PEER"
    uci -q commit network
  fi
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@iface[0]
    add pia_wg iface
    set pia_wg.@iface[0].name="$NEWIF"
    commit pia_wg.@iface[0]
EOI
  PIAWG_IF="$NEWIF"
}

set_defnetpeer() {
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@net_peer[0]
    add pia_wg net_peer
    set pia_wg.@net_peer[0].route_allowed_ips='1'
    set pia_wg.@net_peer[0].persistent_keepalive="25"
    add_list pia_wg.@net_peer[0].allowed_ips="::/0"
    add_list pia_wg.@net_peer[0].allowed_ips="0.0.0.0/0"
    commit pia_wg.@net_peer[0]
EOI
}

set_defnetiface() {
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@net_interface[0]
    add pia_wg net_interface
    set pia_wg.@net_interface[0].proto="wireguard"
    set pia_wg.@net_interface[0].defaultroute='1'
    set pia_wg.@net_interface[0].delegate='0' # No IPv6 with PIA
    commit pia_wg.@net_interface[0]
EOI
}

generate_wgkeys() {
  WGPRIVKEY="$(wg genkey)"
  WGPUBKEY="$(echo "$WGPRIVKEY" | wg pubkey)"
  uci -q batch <<EOI >/dev/null
    delete pia_wg.@keys[0]
    add pia_wg keys
    set pia_wg.@keys[0].priv="$WGPRIVKEY"
    set pia_wg.@keys[0].pub="$WGPUBKEY"
    commit pia_wg.@keys[0]
EOI
}

# Legacy PIA API v2 token (24h), used if the v5 API fails
renew_piatoken() {
  echo "Renewing PIA legacy token" >&3
  uci -q get pia_wg.@user[0] >/dev/null || set_piauser

  pia_api /apiv2/token apiv2 /api/client/v2/token \
    --data-urlencode "username=$(uci -q get pia_wg.@user[0].id)" \
    --data-urlencode "password=$(uci -q get pia_wg.@user[0].password)"
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

  uci -q batch <<EOI >/dev/null
    delete pia_wg.@token[0]
    add pia_wg token
    set pia_wg.@token[0].hash="$PIATOKEN"
    set pia_wg.@token[0].timestamp="$(date +%s)"
    commit pia_wg.@token[0]
EOI
}

keep_conf_section() {
  case "$1" in
  user) DESC='PIA user' ;;
  keys) DESC='WireGuard local keys' ;;
  net_interface) DESC='WireGuard network interface options' ;;
  net_peer) DESC='WireGuard network PIA peer options' ;;
  region) DESC='PIA region' ;;
  dip) DESC="Dedicated IP token" ;;
  cache) DESC="Offline cache" ;;
  esac
  if uci -q get "pia_wg.@$1[0]" >/dev/null; then
    echo "A configuration already exists for '$DESC':"
    uci show "pia_wg.@$1[0]" | awk 'sub(/^[^.]*\.[^.]*\./,"")==1{print "  "$0}'
    read_yn "Keep this configuration" y
    return $?
  fi
  return 1
}

check_conf() {
  uci -q get pia_wg.@user[0] >/dev/null &&
    echo "User is configured" ||
    {
      echo "User is not configured!" >&3
      sleep 1
      [ "$AUTO" ] && return 1 || set_piauser
    }
  uci -q get pia_wg.@keys[0] >/dev/null &&
    echo "Local keys are configured" ||
    {
      echo "Local keys are not configured!" >&3
      sleep 1
      generate_wgkeys
    }
  uci -q get pia_wg.@net_interface[0] >/dev/null &&
    echo "Network interface options are configured" ||
    {
      echo "Network interface options are not configured!" >&3
      sleep 1
      [ "$AUTO" ] && return 1 || set_defnetiface
    }
  uci -q get pia_wg.@net_peer[0] >/dev/null &&
    echo "Network peer options are configured" ||
    {
      echo "Network peer options are not configured!" >&3
      sleep 1
      [ "$AUTO" ] && return 1 || set_defnetpeer
    }
  if uci -q get pia_wg.@dip[0] >/dev/null; then
    echo "Dedicated IP is configured"
    validate_dip
    DIP_STATUS="$(uci -q get pia_wg.@dip[0].status)"
    [ "$DIP_STATUS" = 'active' ] &&
      echo "Dedicated IP is active" ||
      {
        echo "Dedicated IP status is $DIP_STATUS!" >&3
        sleep 1
        return 1
      }
  fi
  uci -q get pia_wg.@region[0] >/dev/null &&
    echo "PIA region is configured" ||
    {
      echo "PIA region is not configured!" >&3
      sleep 1
      [ "$AUTO" ] && return 1 || select_region
    }
}

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
  echo "Initializing network"

  if [ -z "$DIP_STATUS" ]; then
    pia_addkey_any
  else
    pia_wan
    PIAADDKEY="$(curl -s -k -G ${WANDEV:+--interface "if!$WANDEV"} --connect-to "$(uci -q get pia_wg.@dip[0].cn)::$(uci -q get pia_wg.@dip[0].ip)" --user "dedicated_ip_$(uci -q get pia_wg.@dip[0].token):$(uci -q get pia_wg.@dip[0].ip)" --data-urlencode "pubkey=$(uci -q get pia_wg.@keys[0].pub)" "https://$(uci -q get pia_wg.@dip[0].cn):1337/addKey")"
  fi
  #  echo "$PIAADDKEY"

  WGSERVSTATUS="$(echo "$PIAADDKEY" | jq -r '.status')"
  [ "$WGSERVSTATUS" = "OK" ] || {
    echo "PIA server status: $WGSERVSTATUS; Aborting!" >&3
    exit 1
  }

  WGSERVIP="$(echo "$PIAADDKEY" | jq -r '.server_ip')"
  WGSERVPT="$(echo "$PIAADDKEY" | jq -r '.server_port')"
  WGSERVKEY="$(echo "$PIAADDKEY" | jq -r '.server_key')"
  WGDNS1="$(echo "$PIAADDKEY" | jq -r '.dns_servers[0]')"
  WGDNS2="$(echo "$PIAADDKEY" | jq -r '.dns_servers[1]')"
  WGPEERIP="$(echo "$PIAADDKEY" | jq -r '.peer_ip')"

  uci -q batch <<EOI >/dev/null
  delete network.$PIAWG_IF
  delete network.$PIAWG_PEER
  set network.$PIAWG_IF=interface
  set network.$PIAWG_IF.addresses="$WGPEERIP"
  set network.$PIAWG_IF.private_key="$(uci -q get pia_wg.@keys[0].priv)"
  add_list network.$PIAWG_IF.dns="$WGDNS1"
  add_list network.$PIAWG_IF.dns="$WGDNS2"
  set network.$PIAWG_PEER="wireguard_${PIAWG_IF}"
  set network.$PIAWG_PEER.description="PIA $(uci -q get pia_wg.@region[0].name)"
  set network.$PIAWG_PEER.endpoint_host="$WGSERVIP"
  set network.$PIAWG_PEER.endpoint_port="$WGSERVPT"
  set network.$PIAWG_PEER.public_key="$WGSERVKEY"
$(uci export pia_wg | awk '
    $0==""{d=0;next}
    index($0,"config net_"){
      if($2=="net_interface"){d="network.'"$PIAWG_IF"'"}
      else if($2=="net_peer"){d="network.'$PIAWG_PEER'"}
    }
    d{
      if($1=="option"){c="set"}
      else if($1=="list"){c="add_list"}
      else next
      printf("  %s %s.%s=%s\n",c,d,$2,$3)
    }
')

  commit network.$PIAWG_IF
  commit network.$PIAWG_PEER
EOI
}

start_wgpia() {
  stop_wgpia
  set_netconf
  echo "Starting PIA ($(uci get network.$PIAWG_PEER.description))" >&3
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
  DESC=" ($(uci -q get network.$PIAWG_PEER.description))" || DESC=""
  echo "Stopping PIA$DESC" >&3
  ifdown "$PIAWG_IF" >/dev/null 2>&1
}

check_wg() {
  if wg show "$PIAWG_IF" >/dev/null 2>&1; then
    PIAWG_EP="$(wg show "$PIAWG_IF" endpoints | awk -F'[[:space:]:]' '{print $2; exit;}')"
    PIAWG_MK="$(wg show "$PIAWG_IF" fwmark)"
    [ "$PIAWG_MK" = "off" ] && PIAWG_MK=''
    WAN_IF="$(ip route get "$PIAWG_EP" ${PIAWG_MK:+mark "$PIAWG_MK"} | awk '{for(i=0;i<NF;i++){if($i=="dev"){print $++i; exit;}}}')"
    echo "WireGuard PIA interface: UP"
  else
    echo "WireGuard PIA interface: DOWN!" >&3
    return 1
  fi

  echo "Region is: $(uci get network.$PIAWG_PEER.description)"
  # The first hop does not always answer TTL expiry, so also try a plain ping
  if traceroute -i "$PIAWG_IF" -q1 -m1 1.1.1.1 | grep -q ' ms' ||
    ping -q -c1 -n -W 3 -I "$PIAWG_IF" 1.1.1.1 >/dev/null 2>&1; then
    echo "Connectivity through PIA: OK"
  elif ping -q -c1 -n -I "$WAN_IF" "$PIAWG_EP" >/dev/null; then
    echo "Connectivity through PIA: NOK" >&3
    return 1
  elif traceroute -i "$WAN_IF" -q1 -m1 1.1.1.1 | grep -q ' ms'; then
    echo "Access to PIA Endpoint through WAN: NOK!" >&3
    return 1
  else
    echo "Connectivity through PIA: NOK" >&3
    return 1
  fi
}

watchdog_installed() {
  grep -qF 'pia_wg.sh start' /etc/crontabs/root 2>/dev/null
  return $?
}

watchdog_lastrun() {
  [ -f "$PIALOG" ] && date -r "$PIALOG" || return 1
}

watchdog_install() {
  watchdog_installed && return
  {
    crontab -l
    echo "* * * * * /bin/sh $SCRIPTPATH start # pia_wg watchdog"
  } | crontab -
  echo "[$(date)] Watchdog installed" >>"$PIALOG"
}

watchdog_remove() {
  watchdog_installed || return
  crontab -l | grep -vF 'pia_wg.sh start' | crontab -
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
  echo "Usage: $0 { configure <section> | start [ --watchdog ] [ --cache ] | restart [ --watchdog ] [ --cache ] | stop | status | watchdog { install | remove } | cache { refresh | install | remove | show | probe } | log { show | clear | path } | update | version}"
  echo "  Details:"
  echo "    - configure          : same as configure all"
  echo "    - configure all      : configure all settings"
  echo "    - configure user     : set PIA user ID and password"
  echo "    - configure dip      : set PIA dedicated IP"
  echo "    - configure region   : set/choose PIA region"
  echo "    - configure keys     : generate local WireGuard keys"
  echo "    - configure interface: set the network interface name (default wg_pia)"
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
  echo "    - watchdog install   : install the watchdog"
  echo "    - watchdog remove    : remove the watchdog"
  echo "    - cache refresh      : refresh the offline cache (servers list, meta servers, tokens)"
  echo "    - cache install      : install the cache refresh (cron, every 6 hours)"
  echo "    - cache remove       : remove the cache refresh"
  echo "    - cache show         : show the offline cache"
  echo "    - cache probe        : check which regions need the legacy token"
  echo "    - log show           : display the watchdog log"
  echo "    - log clear          : clear the watchdog log"
  echo "    - log path           : set a custom Directory Path for the log"
  echo "    - update             : update the script to latest version"
  echo "    - version            : print the version and exit"
}

# ---- Main ->

[ -e "$PIACONF" ] || touch "$PIACONF"
PIALOG="$(logfile)"
[ -t 0 ] && unset AUTO || AUTO=1
rundir_init
trap cleanup EXIT
trap 'exit 1' 1 2 3 6 15

# Logging (only if not in interactive mode)
if [ "$AUTO" ]; then
  FIFO="$RUNDIR/log.$$.fifo"
  export FIFO
  [ -f "$PIALOG" ] && touch "$PIALOG" || echo "[$(date)] Log created" >"$PIALOG"
  mkfifo "$FIFO"
  awk -v lf="$PIALOG" -v date="$(date)" '{print; printf("[%s] %s\n",date,$0) >> lf}' "$FIFO" >&2 &
  exec 3<>"$FIFO"
else
  exec 3>&2
fi

# Serialise the runs that act on the tunnel, the tokens or the cache
case "$1" in
'start' | 'restart' | 'stop' | 'init-network') lock_take "$1" ;;
'cache') case "$2" in
  'refresh' | 'probe') lock_take "$1 $2" ;;
  esac ;;
esac

case "$1" in
'configure') case "$2" in
  '' | 'all')
    keep_conf_section 'user' || set_piauser
    keep_conf_section 'keys' || generate_wgkeys
    keep_conf_section 'net_interface' || set_defnetiface
    keep_conf_section 'net_peer' || set_defnetpeer
    if read_yn "Do you have a dedicated IP" n; then
      keep_conf_section 'dip' || set_dip
      validate_dip
    else
      uci -q delete pia_wg.@dip[0]
      uci -q commit pia_wg
    fi
    # if no DIP ask for region
    uci -q get pia_wg.@dip[0].token >/dev/null || keep_conf_section 'region' || select_region
    keep_conf_section 'cache' || set_cache
    ;;
  'user') keep_conf_section 'user' || set_piauser ;;
  'dip') keep_conf_section 'dip' || set_dip ;;
  'region') keep_conf_section 'region' || select_region ;;
  'network')
    keep_conf_section 'net_interface' || set_defnetiface
    keep_conf_section 'net_peer' || set_defnetpeer
    ;;
  'keys') keep_conf_section 'keys' || generate_wgkeys ;;
  'cache') keep_conf_section 'cache' || set_cache ;;
  'interface') set_iface ;;
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
'restart')
  start_wgpia
  R=$?
  [ $R -eq 0 ] && install_jobs "$@"
  exit $R
  ;;
'start')
  check_wg
  case $? in
  0) echo "PIA is already up!" ;;
  1) start_wgpia ;;
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
