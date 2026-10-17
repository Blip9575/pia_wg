#!/bin/sh
#
# pia_wg.sh
# Script to setup and run PIA through WireGuard on OpenWrt
#
# Inspired from:
# - This thread: https://forum.openwrt.org/t/private-internet-access-pia-wireguard-vpn-on-openwrt/155475
# - And @Lazerdog's script: https://github.com/jimhall718/piawg/blob/main/piawgx.sh
#
# Version: 1.14.12
#
# ©2026 bOLEMO
# https://github.com/bolemo/pia_wg/
# Fork with offline cache and official PIA app login: https://github.com/Blip9575/pia_wg/
#
#########

# shellcheck disable=SC2329  # persist_run calls some functions indirectly
SCRIPTDL="https://raw.githubusercontent.com/Blip9575/pia_wg/release/pia_wg.sh"
SCRIPTPATH="$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)/${0##*/}"
SCRIPTNAME="${SCRIPTPATH##*/}"
CRON_TAG_WD='# pia watchdog' # (retired: the guard does it; entries "# pia watchdog [name]" are removed when seen); cron entries are recognised by these tags, not by the file name
CRON_TAG_CACHE='# pia cache'
CRON_TAG_RENEW='# pia renew'
CRON_TAG_GUARD='# pia guard'
HOOKFILE='/etc/hotplug.d/iface/80-pia'
RENEW_SKIP=180        # seconds: a handshake this recent means the registration is alive
RUNDIR='/var/run/pia' # temporary files (RAM); created on demand, mode 0700
LOCKDIR="$RUNDIR/lock"
LEGACYTOK="$RUNDIR/legacy.token"                             # legacy 24h token (RAM only; one per account)
WGPLACEHOLDER='Hy+p7zrRBZWl5uBqhcFvnvMrRWb7Glhq6P5xe2ZkyHw=' # fixed, never registered: keeps wireguard.sh from generating (and saving) a key
LOCK_WAIT=120                                                # seconds a manual command waits for another run
LOCK_STEAL=900                                               # seconds after which a run still holding the lock is considered stuck
LOGDEFPATH='/var/log/pia'
LOGNAME='pia.log'
PIACONF='/etc/config/pia' # one section per interface, named like it; the account, tokens, cache and log are shared
RESERVED_NAMES=' account apitoken vpntoken cache log '
# PIA's DNS servers (private addresses, reachable through the tunnel): DNS,
# DNS + streaming (streaming optimised regions, '-so.' in their DNS name),
# DNS + MACE (also blocks ads, trackers and malware) and both
PIA_DNS='10.0.0.242'
PIA_DNS_SO='10.0.0.243'
PIA_DNS_MACE='10.0.0.244'
PIA_DNS_SO_MACE='10.0.0.241'
PIA_MTU_SMALL=1280   # the Android app's 'small packets' WireGuard MTU
PIA_MTU_MAX=1420     # the largest custom packet size: PIA's servers use 1420 on their side (measured 2026-10-15: they fragment larger replies), so more gains nothing
PIA_MTU_OVERHEAD=60  # WireGuard over IPv4: 20 (IP) + 8 (UDP) + 32 (WireGuard); the WAN's MTU minus this, at most PIA_MTU_MAX, is the default (1420 on 1500)
PIA_KEEPALIVE=25     # the official apps' PersistentKeepalive
PIA_MTU_MIN=1280     # custom packet size: the smallest the apps offer
# AmneziaWG obfuscation used when the server sends none (as the official app)
PIA_AWG_DEFAULTS='jc=5 jmin=25 jmax=100 s1=5 s2=3 h1=1234567891 h2=1234567892 h3=1234567893 h4=1234567894'
UCISTAGEDIR='/tmp/.uci'               # where uci keeps the RAM-staged (uncommitted) changes
SESSSTATE='/var/state'                # RAM deltas of the session (key, address, server): read by netifd's protocol scripts, not by LuCI
PIAWG_IF='pia'                        # the interface being handled (-i NAME, or the only one configured)
CACHEDEFDIR='/mnt/usb/pia'            # external storage, to spare the router flash
CACHERAMDIR="$RUNDIR/cache"           # used when the external storage is not mounted
SERVERLIST_PATH='/vpninfo/servers/v7' # the Android app's list: it also has the AmneziaWG servers
SERVERLIST_URL="https://serverlist.piaservers.net$SERVERLIST_PATH"
PIA_WG_PORT=1337     # WireGuard: addKey
PIA_AWG_PORT=1338    # AmneziaWG: add-awg-key
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
  mkdir -p "$RUNDIR/ucid" "$RUNDIR/ucid.t" 2>/dev/null
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
    wgt "$LX" show "$LX" endpoints 2>/dev/null | awk -F'[[:space:]:]' '{print $2}'
    sget "network.wgpeer_$LX.endpoint_host"
  done | sort -u | tr '\n' ' '
}

# Servers in use by the other interfaces (live, staged or registered)
sibling_endpoints() {
  for LX in $(iface_list); do
    [ "$LX" = "$PIAWG_IF" ] && continue
    wgt "$LX" show "$LX" endpoints 2>/dev/null | awk -F'[[:space:]:]' '{print $2}'
    sget "network.wgpeer_$LX.endpoint_host"
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

# The protocol of an interface: amneziawg or wireguard
iface_proto() {
  case "$(uci -q get "pia.$1.iface_proto")" in
  amneziawg) echo amneziawg ;;
  *) echo wireguard ;;
  esac
}

# Run the WireGuard tool of an interface ($1) with the other arguments: awg for
# AmneziaWG ones
wgt() {
  WGTI="$1"
  shift
  if [ "$(iface_proto "$WGTI")" = 'amneziawg' ]; then awg "$@"; else wg "$@"; fi
}

# Is AmneziaWG installed (netifd protocol handler and tool)?
awg_available() {
  [ -f /lib/netifd/proto/amneziawg.sh ] && command -v awg >/dev/null 2>&1
}

# Names and files that depend on the interface being handled
set_ifvars() {
  PIAWG_PEER="wgpeer_$PIAWG_IF"
  PIAPROTO="$(iface_proto "$PIAWG_IF")"
  SRVGRP='wg' # which group of the servers list holds its servers
  [ "$PIAPROTO" = 'amneziawg' ] && SRVGRP='awg'
  SESSION="$RUNDIR/session.$PIAWG_IF"
  RENEWFAIL="$RUNDIR/renew.$PIAWG_IF.fail"
  # tunnels (ours, any other WireGuard interface): never "the WAN"
  PIAIFS=" $(iface_list | tr '\n' ' ') $PIAWG_IF $( (
    wg show interfaces
    awg show interfaces
  ) 2>/dev/null | tr '\t' ' ') "
}

# Is this pid a live pia.sh run (and not a reused pid)?
pid_is_pia() {
  kill -0 "$1" 2>/dev/null &&
    { grep -qF "$SCRIPTNAME" "/proc/$1/cmdline" 2>/dev/null || grep -qE 'pia(_wg)?\.sh' "/proc/$1/cmdline" 2>/dev/null; }
}

# lock_take <command...>: serialise the runs that act on the tunnel and tokens.
# The 'start' skips when busy (it is run again by whatever called it); the other
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
# History of what happened with the servers (history.json in the cache path):
# key registrations, fastest-region pings, tunnel confirmations, guard actions.
# Entries wait in a RAM list and are written once when the run ends (one small
# write to the cache path, kept to the latest HISTMAX entries); no secrets.
HISTMAX=200
history_file() { echo "$(cache_dir)/history.json"; }
# history_add EVENT STATUS IP NAME MS NOTE [REGION_ID]
history_add() {
  jq -nc --argjson t "$(date +%s)" --arg ifn "$PIAWG_IF" --arg ev "$1" --arg st "$2" --arg ip "$3" --arg cn "$4" \
    --arg ms "$5" --arg note "$6" --arg rid "${7:-$(uci -q get "pia.$PIAWG_IF.region_id")}" --arg proto "$PIAPROTO" \
    '{t: $t, if: $ifn, ev: $ev, status: $st, region_id: $rid, proto: $proto, ip: $ip, cn: $cn,
      ms: (try ($ms | tonumber) catch null), note: $note}' >>"$RUNDIR/history.$$.pending" 2>/dev/null
  return 0
}
history_flush() {
  HFP="$RUNDIR/history.$$.pending"
  [ -s "$HFP" ] || return 0
  HFW=0
  while ! mkdir "$RUNDIR/history.lock" 2>/dev/null; do
    HFW=$((HFW + 1))
    if [ $HFW -gt 50 ]; then rmdir "$RUNDIR/history.lock" 2>/dev/null; break; fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  HFF="$(history_file)"
  HFR="$(jq -c '[.regions[] | {key: .id, value: {country: .country, name: .name}}] | from_entries' "$(cache_dir)/servers.json" 2>/dev/null)"
  [ -n "$HFR" ] || HFR='{}'
  jq -e 'type == "array"' "$HFF" >/dev/null 2>&1 || echo '[]' >"$HFF.old"
  [ -e "$HFF.old" ] || cp "$HFF" "$HFF.old"
  if jq -cs --argjson rm "$HFR" --argjson max "$HISTMAX" \
    '(.[0] + (.[1:] | map(. + {country: ($rm[.region_id].country // ""), region: ($rm[.region_id].name // .region_id)}))) | .[-$max:]' \
    "$HFF.old" "$HFP" >"$HFF.new" 2>/dev/null && [ -s "$HFF.new" ]; then
    mv "$HFF.new" "$HFF"
  fi
  rm -f "$HFF.old" "$HFF.new" "$HFP"
  rmdir "$RUNDIR/history.lock" 2>/dev/null
  return 0
}
# Server addresses the interfaces use now: a request to one of them would remove the live key
probe_live_ips() {
  PLSAVE="$PIAWG_IF"
  for PLX in $(iface_list); do
    PIAWG_IF="$PLX"
    set_ifvars
    sget "network.$PIAWG_PEER.endpoint_host"
  done
  PIAWG_IF="$PLSAVE"
  set_ifvars
}

# history probe [--rounds N] [--delay S] REGION|CC ...: ask the servers of the regions (or of every
# region of a country: GB) whether they accept the VPN token, N times, with an invalid public
# key: 409 = accepted, 401 = refused, nothing is registered. Each answer goes to the history.
history_probe() {
  HPR=8
  HPD=3
  HPREG=''
  while [ $# -gt 0 ]; do
    case "$1" in
    --rounds) HPR="$2" && shift 2 ;;
    --delay) HPD="$2" && shift 2 ;;
    *) HPREG="$HPREG $1" && shift ;;
    esac
  done
  case "$HPR$HPD" in '' | *[!0-9]*) echo "--rounds and --delay take whole numbers" >&2 && return 1 ;; esac
  if [ "$HPR" -lt 1 ] || [ "$HPR" -gt 50 ] || [ "$HPD" -gt 60 ]; then
    echo "--rounds 1 to 50, --delay 0 to 60" >&2
    return 1
  fi
  [ -n "$HPREG" ] || {
    echo "Usage: history probe [--rounds N] [--delay S] REGION|COUNTRY ... (e.g. GB or uk_manchester)" >&2
    return 1
  }
  pia_wan
  HPCA="$(pia_ca)"
  token_ok vpntoken || pia_tokens >/dev/null 2>&1
  HPU="$(uci -q get pia.vpntoken.user)"
  HPP="$(uci -q get pia.vpntoken.pass)"
  [ -n "$HPU" ] || {
    echo "No VPN token: log in first" >&2
    return 1
  }
  HPPORT="$PIA_WG_PORT"
  [ "$PIAPROTO" = 'amneziawg' ] && HPPORT="$PIA_AWG_PORT"
  HPKP='addKey'
  [ "$PIAPROTO" = 'amneziawg' ] && HPKP='add-awg-key'
  HPLIVE="$(probe_live_ips | tr '\n' ' ')"
  : >"$RUNDIR/probe.$$.list"
  for HPX in $HPREG; do
    case "$HPX" in
    [A-Z][A-Z]) HPIDS="$(jq -r --arg c "$HPX" --arg g "$SRVGRP" '.regions[] | select(.country == $c and .offline == false and .servers[$g]) | .id' "$(cache_dir)/servers.json")" ;;
    *) HPIDS="$HPX" ;;
    esac
    for HPID in $HPIDS; do
      jq -r --arg r "$HPID" --arg g "$SRVGRP" --arg p "$HPPORT" \
        '.regions[] | select(.id == $r) | .servers[$g][]? | "\($r) \(.ip) \(.cn) \(.port // $p)"' "$(cache_dir)/servers.json" 2>/dev/null |
        awk -v u="$HPLIVE" 'BEGIN {n = split(u, a, " "); for (i = 1; i <= n; i++) x[a[i]] = 1} !($2 in x)' >>"$RUNDIR/probe.$$.list"
    done
  done
  HPN="$(grep -c . "$RUNDIR/probe.$$.list")"
  [ "$HPN" -gt 0 ] || {
    rm -f "$RUNDIR/probe.$$.list"
    echo "No servers found for:$HPREG (the live servers are skipped)" >&2
    return 1
  }
  echo "Probing $HPN servers, $HPR rounds, ${HPD}s apart (the servers in use are skipped: $HPLIVE)"
  HPI=0
  while [ "$HPI" -lt "$HPR" ]; do
    HPI=$((HPI + 1))
    while read -r HPRID HPIP HPCN HPPT; do
      HPC="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout 5 --max-time 12 ${WANDEV:+--interface "if!$WANDEV"} --cacert "$HPCA" --connect-to "$HPCN::$HPIP:$HPPT" -G --user "$HPU:$HPP" --data-urlencode "pubkey=x" "https://$HPCN:$HPPT/$HPKP")"
      HPCODE="${HPC%% *}"
      HPMS="$(echo "${HPC#* }" | awk '{printf "%d", $1 * 1000}')"
      case "$HPCODE" in 409 | 200) HPST='ok' ;; 401) HPST='refused' ;; 000) HPST='timeout' ;; *) HPST='failed' ;; esac
      history_add probe "$HPST" "$HPIP" "$HPCN" "$HPMS" "HTTP $HPCODE, round $HPI" "$HPRID"
    done <"$RUNDIR/probe.$$.list"
    [ "$HPI" -lt "$HPR" ] && sleep "$HPD"
  done
  rm -f "$RUNDIR/probe.$$.list"
  history_flush
  echo "Done: $((HPN * HPR)) requests recorded (see History in LuCI, or 'api history')"
}

api_history() {
  HFF="$(history_file)"
  if [ -s "$HFF" ] && jq -e 'type == "array"' "$HFF" >/dev/null 2>&1; then
    jq -c '{ok: true, entries: (reverse | .[0:200]),
      summary: ([.[] | select(.ev == "register" or .ev == "probe")] | group_by(.region_id) | map(
        (map(select(.status == "ok" and .ms != null) | .ms)) as $m
        | {region_id: .[0].region_id, region: .[0].region, country: .[0].country, total: length,
           refused: (map(select(.status == "refused")) | length), ok: (map(select(.status == "ok")) | length),
           ms: (if ($m | length) > 0 then (($m | add) / ($m | length) | floor) else null end)}))}' "$HFF"
  else
    echo '{"ok":true,"entries":[],"summary":[]}'
  fi
}

cleanup() {
  history_flush
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
  if wgt "$PIAWG_IF" show "$PIAWG_IF" >/dev/null 2>&1; then
    WEP="$(wgt "$PIAWG_IF" show "$PIAWG_IF" endpoints 2>/dev/null | awk -F'[[:space:]:]' '{print $2; exit}')"
    if [ -n "$WEP" ]; then
      WMK="$(wgt "$PIAWG_IF" show "$PIAWG_IF" fwmark 2>/dev/null)"
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
    | .[].servers.meta[]? | "\(.ip) \(.cn)"' "$SL" 2>/dev/null # the reader may stop early (head)
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
    curl -sf --max-time 15 ${WANDEV:+--interface "if!$WANDEV"} --cacert "$CA" --connect-to "$CN::$IP:443" "https://$CN$SERVERLIST_PATH" | head -1 >"$TMP"
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
    : >"$CD/servers.checked" # when the list was last checked (servers.json only changes with the list)
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
      jq -r --arg r "$PIAREGIONID" --arg g "$SRVGRP" '.regions[] | select(.id == $r) | .servers[$g][]? | "  \($g)  \(.ip) \(.cn)"' "$CD/servers.json"
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
#
# legacy_probe [CC] checks only the regions of the country CC and merges the
# result into the list (a '#c CC <epoch>' line records when).
legacy_probe() {
  PCC="$1"
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
  if [ -z "$PCC" ]; then
    echo "# $(date +%s)" >"$PROBETMP"
  else
    PCIDS="$(jq -r --arg c "$PCC" '.regions[] | select(.country == $c) | .id' "$CD/servers.json" 2>/dev/null)"
    {
      echo "# $(legacy_stamp)"
      grep "^#c " "$CD/legacy.list" 2>/dev/null | grep -v "^#c $PCC "
      echo "#c $PCC $(date +%s)"
      grep -v '^#' "$CD/legacy.list" 2>/dev/null | grep -vxF "$PCIDS"
    } >"$PROBETMP"
  fi
  # Run in the background and wait for it, so that a signal is handled at once
  # (a trap only runs after the foreground command ends); the loop stops by
  # itself when this run is gone
  MAINPID=$$
  {
    jq -r --arg c "$PCC" '.regions[] | select(.offline == false) | select($c == "" or .country == $c)
    | select((.servers.wg // []) | length > 0)
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

# Epoch of the last full legacy_probe, empty if never
legacy_stamp() {
  sed -n '1s/^# //p' "$(cache_dir)/legacy.list" 2>/dev/null
}

# Is the result for the country $1 recent (a full or a per country check)?
legacy_country_fresh() {
  LCF="$(legacy_stamp)"
  [ -n "$LCF" ] && [ $(($(date +%s) - LCF)) -lt "$LEGACY_MAXAGE" ] && return 0
  LCF="$(sed -n "s/^#c $1 //p" "$(cache_dir)/legacy.list" 2>/dev/null | head -n 1)"
  [ -n "$LCF" ] && [ $(($(date +%s) - LCF)) -lt "$LEGACY_MAXAGE" ]
}

# Numbered list of the online WireGuard regions, (L) marking those needing the
# legacy token. Uses $PIAREGIONS, $PIASERVPF, $PIASERVGEO, $PIASERVSO and $LEGACYIDS.
region_names() {
  echo "$PIAREGIONS" | jq -r --arg l "$LEGACYIDS" ".[] | select(.offline==false) | select(.servers.$SRVGRP) $PIASERVPF $PIASERVGEO $PIASERVSO |
    .id as \$id | .name + (if (\$l | split(\" \") | any(.[]; . == \$id)) then \" (L)\" else \"\" end)" | nl -v0
}

# Store the region $PIAREGIONID of the list $PIAREGIONS in the interface
store_region() {
  PIAREGIONNAME="$(echo "$PIAREGIONS" | jq -r ".[] | select(.id==\"$PIAREGIONID\") | .name")"
  PIAREGIONDNS="$(echo "$PIAREGIONS" | jq -r ".[] | select(.id==\"$PIAREGIONID\") | .dns")"
  uci -q batch <<EOI >/dev/null
    set pia.$PIAWG_IF=interface
    set pia.$PIAWG_IF.region_id="$PIAREGIONID"
    set pia.$PIAWG_IF.region_name="$PIAREGIONNAME"
    set pia.$PIAWG_IF.region_dns="$PIAREGIONDNS"
    set pia.$PIAWG_IF.region_country="$(echo "$PIAREGIONS" | jq -r ".[] | select(.id==\"$PIAREGIONID\") | .country")"
    commit pia
EOI
  dns_apply
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
    [ "$PIAPROTO" = 'amneziawg' ] && LEGACYIDS='' && LSTAMP=''
    echo "Eliminating offline servers…"
    echo "Eliminating servers without ${PIAPROTO}…"
    while :; do
      read_yn "Port forward only servers" n && PIASERVPF='| select(.port_forward==true) ' || PIASERVPF=''
      read_yn "Physical VPN locations only (no geo-located regions)" y && PIASERVGEO='| select(.geo==false) ' || PIASERVGEO=''
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
      *) PIAREGIONID="$(echo "$PIAREGIONS" | jq -r "[.[] | select(.offline==false) | select(.servers.$SRVGRP) $PIASERVPF $PIASERVGEO $PIASERVSO ][$AND].id // empty")" ;;
      esac
      [ -n "$PIAREGIONID" ] && break
      echo "Invalid region number: '$AND'"
    done
  fi
  store_region
  echo "Region selected: $PIAREGIONNAME"
  # the fastest region of the country, picked at each start
  uci -q delete "pia.$PIAWG_IF.region_fast"
  if [ -z "$AUTO" ] && read_yn "Pick the fastest region of that country at each start" n; then
    uci -q set "pia.$PIAWG_IF.region_fast=1"
  fi
  uci -q commit pia
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
  KEYPORT="$PIA_WG_PORT"
  [ "$PIAPROTO" = 'amneziawg' ] && KEYPORT="$PIA_AWG_PORT"
  SERVERS="$(jq -r --arg r "$(uci -q get "pia.$PIAWG_IF.region_id")" --arg g "$SRVGRP" --arg p "$KEYPORT" \
    '.regions[] | select(.id == $r) | .servers[$g][]? | "\(.ip) \(.cn) ip \(.port // $p)"' "$(cache_dir)/servers.json" 2>/dev/null)"
  # the region host name (legacy) only serves WireGuard
  [ "$PIAPROTO" = 'amneziawg' ] || SERVERS="$SERVERS
$(uci -q get "pia.$PIAWG_IF.region_dns") - dns $PIA_WG_PORT"
  KEYPATH='addKey'
  [ "$PIAPROTO" = 'amneziawg' ] && KEYPATH='add-awg-key'
  # one peer per token and server: keep off the servers of the other interfaces
  SIBIPS="$(sibling_endpoints) $PIAEXCL"
  SERVERS="$(echo "$SERVERS" | awk -v u="$SIBIPS" 'BEGIN{n=split(u,a," ");for(i=1;i<=n;i++)x[a[i]]=1} !($1 in x)')"
  unset ADDKEYAUTHFAIL
  ADDKEYWHY='no server to ask'
  while read -r HOST CN MODE KPORT; do
    case "$MODE" in
    'ip') CODE="$(curl -s -o "$PIARESP" -w '%{http_code} %{time_total}' --connect-timeout 5 --max-time 15 ${WANDEV:+--interface "if!$WANDEV"} --cacert "$CA" --connect-to "$CN::$HOST:$KPORT" -G "$@" --data-urlencode "pubkey=$PUB" "https://$CN:$KPORT/$KEYPATH")" ;;
    'dns') CODE="$(curl -s -k -o "$PIARESP" -w '%{http_code} %{time_total}' --connect-timeout 5 --max-time 15 ${WANDEV:+--interface "if!$WANDEV"} -G "$@" --data-urlencode "pubkey=$PUB" "https://$HOST:$KPORT/$KEYPATH")" ;;
    *) continue ;;
    esac
    AKSEC="${CODE#* }"
    CODE="${CODE%% *}"
    [ "$CODE" = '401' ] && ADDKEYAUTHFAIL=1
    PIAADDKEY="$(cat "$PIARESP")"
    AKN=$((${AKN:-0} + 1))
    if [ "$(echo "$PIAADDKEY" | jq -r '.status' 2>/dev/null)" = 'OK' ]; then
      AKST='ok'
    else
      case "$CODE" in 401) AKST='refused' ;; 000) AKST='timeout' ;; *) AKST='failed' ;; esac
    fi
    history_add register "$AKST" "$HOST" "$CN" "$(echo "$AKSEC" | awk '{printf "%d", $1 * 1000}')" "HTTP ${CODE:-000}, try $AKN"
    # why the last server said no (shown by the retry lines)
    ADDKEYWHY="HTTP ${CODE:-000} from $CN"
    AKMSG="$(echo "$PIAADDKEY" | jq -r '.message // .status // empty' 2>/dev/null | tr -cd ' -~' | cut -c1-80)"
    [ -z "$AKMSG" ] || ADDKEYWHY="$ADDKEYWHY: $AKMSG"
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
    # A refusal is often random per request (measured on uk_manchester: about 60%
    # of the requests, cold or not), so the first retry is quick; renewing the
    # token does not help then
    for AKW in 1 5 15 30; do
      echo "PIA refused the VPN token ($ADDKEYWHY); trying again in ${AKW}s" >&3
      sleep "$AKW"
      pia_addkey && return 0
      [ "$ADDKEYAUTHFAIL" ] || return 1
    done
    VTS="$(uci -q get pia.vpntoken.timestamp)"
    if [ $(($(date +%s) - ${VTS:-0})) -gt 600 ]; then
      echo "PIA server refused the VPN token ($ADDKEYWHY); renewing it" >&3
      pia_token_forget
      pia_tokens && pia_addkey && return 0
    fi
    echo "PIA servers refused the VPN token ($ADDKEYWHY); trying the legacy token" >&3
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

# ---- Default route, firewall zone and DNS priority of an interface ----

# The other PIA interfaces
others_list() { iface_list | grep -vx "$PIAWG_IF"; }

# set_default_route yes|no: all traffic through the interface, or only the
# PIA DNS hosts (so that it can still be tested and used for DNS)
# The DNS server of the interface (iface_dns)
dns_hosts() {
  DHL="$(uci -q get "pia.$PIAWG_IF.iface_dns")"
  echo "${DHL:-$(dns_wanted)}"
}

# Has the interface MACE (iface_mace; an old MACE choice was iface_dns 10.0.0.241)?
dns_mace() {
  [ "$(uci -q get "pia.$PIAWG_IF.iface_mace")" = '1' ] && return 0
  [ -z "$(uci -q get "pia.$PIAWG_IF.iface_mace")" ] &&
    [ "$(uci -q get "pia.$PIAWG_IF.iface_dns")" = "$PIA_DNS_SO_MACE" ]
}

# Does the interface use a DNS server of its own (iface_dns, not one of PIA's)?
dns_custom() {
  DCC="$(uci -q get "pia.$PIAWG_IF.iface_dns")"
  case "$DCC" in
  '' | "$PIA_DNS" | "$PIA_DNS_SO" | "$PIA_DNS_MACE" | "$PIA_DNS_SO_MACE") return 1 ;;
  esac
  return 0
}

# The PIA DNS server the interface should use: by its region (streaming
# optimised: '-so.' in its DNS name) and by MACE
dns_wanted() {
  DWSO=0
  case "$(uci -q get "pia.$PIAWG_IF.region_dns")" in
  *-so.*) DWSO=1 ;;
  esac
  DWM=0
  dns_mace && DWM=1
  case "$DWSO$DWM" in
  11) echo "$PIA_DNS_SO_MACE" ;;
  10) echo "$PIA_DNS_SO" ;;
  01) echo "$PIA_DNS_MACE" ;;
  *) echo "$PIA_DNS" ;;
  esac
}

# Make iface_dns what dns_wanted says (a DNS server of our own is left alone);
# the old MACE choice is migrated to iface_mace
dns_apply() {
  DAC="$(uci -q get "pia.$PIAWG_IF.iface_dns")"
  case "$DAC" in
  '' | "$PIA_DNS" | "$PIA_DNS_SO" | "$PIA_DNS_MACE" | "$PIA_DNS_SO_MACE") ;;
  *) return 0 ;;
  esac
  DAM=''
  if [ -z "$(uci -q get "pia.$PIAWG_IF.iface_mace")" ] && dns_mace; then
    uci -q set "pia.$PIAWG_IF.iface_mace=1"
    DAM=1
  fi
  DAW="$(dns_wanted)"
  if [ "$DAC" = "$DAW" ]; then
    [ -z "$DAM" ] || uci -q commit pia
    return 0
  fi
  uci -q set "pia.$PIAWG_IF.iface_dns=$DAW"
  uci -q commit pia
  # without the default route only the DNS host is routed to the tunnel
  has_default_route "$PIAWG_IF" || set_default_route no
  return 0
}

set_default_route() {
  uci -q delete "pia.$PIAWG_IF.peer_allowed_ips"
  if [ "$1" = 'yes' ]; then
    uci -q add_list "pia.$PIAWG_IF.peer_allowed_ips=0.0.0.0/0"
    uci -q set "pia.$PIAWG_IF.iface_defaultroute=1"
  else
    for SDH in $(dns_hosts); do
      uci -q add_list "pia.$PIAWG_IF.peer_allowed_ips=$SDH/32"
    done
    uci -q set "pia.$PIAWG_IF.iface_defaultroute=0"
  fi
  uci -q set "pia.$PIAWG_IF.peer_route_allowed_ips=1"
  uci -q commit pia
}

# Does this interface hold the default route?
has_default_route() { uci -q get "pia.$1.peer_allowed_ips" | grep -q '0\.0\.0\.0/0'; }

# Default route of the interface being handled (asked when it is created):
# with several PIA interfaces none may have it, or one VPN would run inside
# another.
ask_default_route() {
  ADROTHERS="$(others_list)"
  if [ -z "$ADROTHERS" ]; then
    if read_yn "Route all traffic through $PIAWG_IF (default route)" y; then
      set_default_route yes
    else
      set_default_route no
    fi
    return 0
  fi
  echo "Other PIA interfaces: $(echo "$ADROTHERS" | tr '\n' ' ')"
  echo "Two default routes cannot work together (one VPN would run inside the other)."
  echo "Traffic then has to be sent to the VPNs by policy routing, firewall marks or"
  echo "per-device routes, which this script does not set up."
  if read_yn "Remove the default route from all PIA interfaces (including $PIAWG_IF)" y; then
    ADRKEEP="$PIAWG_IF"
    for ADRX in $ADROTHERS $ADRKEEP; do
      PIAWG_IF="$ADRX"
      set_default_route no
    done
    PIAWG_IF="$ADRKEEP"
    set_ifvars
    echo "Default routes removed; running tunnels change at their next restart"
  else
    set_default_route no
  fi
}

# Fill in what an interface section lacks (written only if missing)
iface_defaults() {
  IDCH=''
  if [ -z "$(uci -q get "pia.$PIAWG_IF.iface_dns_metric")" ]; then
    uci -q set "pia.$PIAWG_IF.iface_dns_metric=1" # its DNS servers come first in resolv.conf.auto
    IDCH=1
  fi
  if [ -z "$(uci -q get "pia.$PIAWG_IF.peer_persistent_keepalive")" ]; then
    uci -q set "pia.$PIAWG_IF.peer_persistent_keepalive=$PIA_KEEPALIVE"
    IDCH=1
  fi
  if [ -z "$(uci -q get "pia.$PIAWG_IF.iface_metric")" ] && [ -n "$(others_list)" ]; then
    # a distinct route metric: the first interface keeps the default one, the
    # PIA DNS hosts routed by several interfaces are then resolved by metric
    IDMAX=0
    for IDX in $(others_list); do
      IDM="$(uci -q get "pia.$IDX.iface_metric")"
      [ "${IDM:-0}" -gt "$IDMAX" ] && IDMAX="$IDM"
    done
    uci -q set "pia.$PIAWG_IF.iface_metric=$((IDMAX + 10))"
    IDCH=1
  fi
  [ -z "$IDCH" ] || uci -q commit pia
  return 0
}

# ---- firewall: zone, NAT and forwardings (only touched by configure)

fw_zone_id() { uci -q show firewall | sed -n "s/^firewall\\.\\([^.]*\\)\\.name='$1'\$/\\1/p" | head -n 1; }

# The devices of the networks of a zone: from the network config (an interface that is
# down has no running device), else what netifd reports
fw_zone_devs() {
  FZZ="$(fw_zone_id "$1")"
  for FZN in $(uci -q get "firewall.$FZZ.network"); do
    FZD="$(uci -q get "network.$FZN.device")"
    [ -n "$FZD" ] || FZD="$(uci -q get "network.$FZN.ifname")"
    [ -n "$FZD" ] || FZD="$(ubus call "network.interface.$FZN" status 2>/dev/null | jsonfilter -e '@.l3_device')"
    echo "$FZD"
  done
}

# Every zone, one name per line
fw_zone_names() {
  FNN=0
  while uci -q get "firewall.@zone[$FNN]" >/dev/null; do
    uci -q get "firewall.@zone[$FNN].name"
    FNN=$((FNN + 1))
  done
}

# Does a network of the zone use a VPN protocol?
fw_zone_is_vpn() {
  FVZ="$(fw_zone_id "$1")"
  for FVN in $(uci -q get "firewall.$FVZ.network"); do
    case "$(uci -q get "network.$FVN.proto")" in
    wireguard | amneziawg | openvpn | vpn) return 0 ;;
    esac
  done
  return 1
}

fw_zone_masq() { [ "$(uci -q get "firewall.$(fw_zone_id "$1").masq")" = '1' ]; }

# The zones with a network on the device $1 (br-lan, br-wan)
fw_zone_of_dev() {
  for FDZ in $(fw_zone_names); do
    fw_zone_devs "$FDZ" | grep -qxF "$1" && echo "$FDZ"
  done
}

# The zone the LAN is in: the one attached to br-lan, else 'lan', or the first one named like it
fw_lan_zone() {
  FWL="$(fw_zone_of_dev br-lan | head -n 1)"
  if [ -n "$FWL" ]; then
    echo "$FWL"
    return
  fi
  FWZ="$(uci -q show firewall | sed -n "s/^firewall\\.[^.]*\\.name='\\([^']*\\)'\$/\\1/p")"
  for FWN in $FWZ; do
    [ "$FWN" = 'lan' ] && {
      echo lan
      return
    }
  done
  for FWN in $FWZ; do
    case "$FWN" in
    *wan* | *vpn* | *pia*) ;;
    *lan*)
      echo "$FWN"
      return
      ;;
    esac
  done
}

# The WAN zones: attached to br-wan or masquerading, no VPN protocol (and not br-lan)
fw_wan_zones() {
  for FWZ2 in $(fw_zone_names); do
    fw_zone_is_vpn "$FWZ2" && continue
    fw_zone_devs "$FWZ2" | grep -qxF br-lan && continue
    if fw_zone_masq "$FWZ2" || fw_zone_devs "$FWZ2" | grep -qxF br-wan; then echo "$FWZ2"; fi
  done
}

# The WAN zones the kill switch starts with: the ones attached to br-wan
fw_wan_default() {
  for FWZ2 in $(fw_wan_zones); do
    fw_zone_devs "$FWZ2" | grep -qxF br-wan && echo "$FWZ2"
  done
}

fw_vpn_zones() {
  for FWZ2 in $(fw_zone_names); do fw_zone_is_vpn "$FWZ2" && echo "$FWZ2"; done
}

fw_masq_zones() {
  for FWZ2 in $(fw_zone_names); do fw_zone_masq "$FWZ2" && echo "$FWZ2"; done
}

# The firewall zone the interface is in (any zone: not only the one this script made)
fw_iface_zone() {
  for FIZ in $(fw_zone_names); do
    case " $(uci -q get "firewall.$(fw_zone_id "$FIZ").network") " in
    *" $PIAWG_IF "*)
      echo "$FIZ"
      return
      ;;
    esac
  done
}

# Is TCP MSS clamping on for the interface (its zone has mtu_fix)? Prints the zone name
# and returns 0, or returns 1
mss_clamp() {
  MCZ="$(fw_iface_zone)"
  [ -n "$MCZ" ] || return 1
  echo "$MCZ"
  [ "$(uci -q get "firewall.$(fw_zone_id "$MCZ").mtu_fix")" = '1' ]
}

# The forwardings from the zones that forward into the interface to the zones that
# lead to the internet: "src>dest" each (the way out if the VPN is down)
ks_leaks() {
  KLW=" $(fw_wan_zones | tr '\n' ' ')"
  KLS=" $(uci -q get "pia.$PIAWG_IF.fw_forward") "
  [ "$(uci -q get "pia.$PIAWG_IF.fw_zone")" = '1' ] || return 0
  KLN=0
  while uci -q get "firewall.@forwarding[$KLN]" >/dev/null; do
    KLSRC="$(uci -q get "firewall.@forwarding[$KLN].src")"
    KLDST="$(uci -q get "firewall.@forwarding[$KLN].dest")"
    case "$KLS" in *" $KLSRC "*) case "$KLW" in *" $KLDST "*) echo "$KLSRC>$KLDST" ;; esac ;; esac
    KLN=$((KLN + 1))
  done
}

# Kill switch: the forwardings from the zones that forward into the interface to the
# chosen WAN zones (ks_wan) are removed (remembered in ks_removed, put back when the switch is
# turned off or the zones change). $1 off: as if turned off.
ks_sync_inner() {
  FWCHANGED=''
  KSWANT=' '
  if [ "$1" != 'off' ] && [ "$(uci -q get "pia.$PIAWG_IF.ks_enable")" = '1' ] && [ "$(uci -q get "pia.$PIAWG_IF.fw_zone")" = '1' ]; then
    for KSS in $(uci -q get "pia.$PIAWG_IF.fw_forward"); do
      for KSD in $(uci -q get "pia.$PIAWG_IF.ks_wan"); do
        [ "$KSS" = "$KSD" ] || KSWANT="$KSWANT$KSS>$KSD "
      done
    done
  fi
  KSREM=" $(uci -q get "pia.$PIAWG_IF.ks_removed") "
  KSN=0
  while uci -q get "firewall.@forwarding[$KSN]" >/dev/null; do KSN=$((KSN + 1)); done
  KSI=$((KSN - 1))
  while [ "$KSI" -ge 0 ]; do
    KSK="$(uci -q get "firewall.@forwarding[$KSI].src")>$(uci -q get "firewall.@forwarding[$KSI].dest")"
    case "$KSWANT" in
    *" $KSK "*)
      uci -q delete "firewall.@forwarding[$KSI]"
      FWCHANGED=1
      case "$KSREM" in
      *" $KSK "*) ;;
      *)
        uci -q add_list "pia.$PIAWG_IF.ks_removed=$KSK"
        KSREM="$KSREM$KSK "
        ;;
      esac
      ;;
    esac
    KSI=$((KSI - 1))
  done
  # put back what is not removed any more
  for KSK in $KSREM; do
    case "$KSWANT" in *" $KSK "*) continue ;; esac
    KSF="$(uci -q add firewall forwarding)"
    uci -q set "firewall.$KSF.src=${KSK%%>*}"
    uci -q set "firewall.$KSF.dest=${KSK#*>}"
    uci -q del_list "pia.$PIAWG_IF.ks_removed=$KSK"
    FWCHANGED=1
  done
  [ -z "$FWCHANGED" ] || uci -q commit firewall
  uci -q commit pia
  return 0
}

ks_sync() {
  persist_run ks_sync_inner "$1"
  fw_reload
}

# Make firewall.* what pia.<if>.fw_zone / fw_forward say (compare, then write).
# Run through persist_run: sets FWCHANGED.
fw_apply_inner() {
  FWCHANGED=''
  FWID="$(fw_zone_id "$PIAWG_IF")"
  if [ -z "$FWID" ]; then
    FWID="$(uci -q add firewall zone)"
    uci -q set "firewall.$FWID.name=$PIAWG_IF"
    uci -q add_list "firewall.$FWID.network=$PIAWG_IF"
    uci -q set "firewall.$FWID.input=DROP"
    uci -q set "firewall.$FWID.output=ACCEPT"
    uci -q set "firewall.$FWID.forward=DROP"
    uci -q set "firewall.$FWID.masq=1"
    uci -q set "firewall.$FWID.mtu_fix=1"
    uci -q set "firewall.$FWID.pia_managed=1"
    FWCHANGED=1
  else
    case " $(uci -q get "firewall.$FWID.network") " in
    *" $PIAWG_IF "*) ;;
    *)
      uci -q add_list "firewall.$FWID.network=$PIAWG_IF"
      FWCHANGED=1
      ;;
    esac
    for FWO in masq mtu_fix; do
      [ "$(uci -q get "firewall.$FWID.$FWO")" = '1' ] && continue
      uci -q set "firewall.$FWID.$FWO=1"
      FWCHANGED=1
    done
  fi
  # forwardings to it: the wanted ones, and none we made that are not
  FWWANT=" $(uci -q get "pia.$PIAWG_IF.fw_forward") "
  FWN=0
  FWHAVE=' '
  while uci -q get "firewall.@forwarding[$FWN]" >/dev/null; do FWN=$((FWN + 1)); done
  FWI=$((FWN - 1))
  while [ "$FWI" -ge 0 ]; do
    if [ "$(uci -q get "firewall.@forwarding[$FWI].dest")" = "$PIAWG_IF" ]; then
      FWS="$(uci -q get "firewall.@forwarding[$FWI].src")"
      case "$FWWANT" in
      *" $FWS "*) FWHAVE="$FWHAVE$FWS " ;;
      *)
        if [ "$(uci -q get "firewall.@forwarding[$FWI].pia_managed")" = '1' ]; then
          uci -q delete "firewall.@forwarding[$FWI]"
          FWCHANGED=1
        fi
        ;;
      esac
    fi
    FWI=$((FWI - 1))
  done
  for FWS in $FWWANT; do
    case "$FWHAVE" in
    *" $FWS "*) continue ;;
    esac
    FWF="$(uci -q add firewall forwarding)"
    uci -q set "firewall.$FWF.src=$FWS"
    uci -q set "firewall.$FWF.dest=$PIAWG_IF"
    uci -q set "firewall.$FWF.pia_managed=1"
    FWCHANGED=1
  done
  [ -z "$FWCHANGED" ] || uci -q commit firewall
  return 0
}

# Remove the zone and the forwardings we made for the interface being handled
fw_remove_inner() {
  pf_fw_inner ''
  PFRM="$FWCHANGED"
  ks_sync_inner off
  PFRM="$PFRM$FWCHANGED"
  FWCHANGED=''
  FWN=0
  while uci -q get "firewall.@forwarding[$FWN]" >/dev/null; do FWN=$((FWN + 1)); done
  FWI=$((FWN - 1))
  while [ "$FWI" -ge 0 ]; do
    if [ "$(uci -q get "firewall.@forwarding[$FWI].dest")" = "$PIAWG_IF" ] &&
      [ "$(uci -q get "firewall.@forwarding[$FWI].pia_managed")" = '1' ]; then
      uci -q delete "firewall.@forwarding[$FWI]"
      FWCHANGED=1
    fi
    FWI=$((FWI - 1))
  done
  FWID="$(fw_zone_id "$PIAWG_IF")"
  if [ -n "$FWID" ] && [ "$(uci -q get "firewall.$FWID.pia_managed")" = '1' ]; then
    uci -q delete "firewall.$FWID"
    FWCHANGED=1
  fi
  [ -z "$PFRM" ] || FWCHANGED=1
  [ -z "$FWCHANGED" ] || uci -q commit firewall
  return 0
}

# Reload the firewall if something changed (after fw4's own check)
fw_reload() {
  [ -n "$FWCHANGED" ] || return 0
  if command -v fw4 >/dev/null 2>&1 && ! fw4 check >/dev/null 2>&1; then
    echo "fw4 check failed: the firewall was not reloaded (see: fw4 check)" >&3
    return 1
  fi
  /etc/init.d/firewall reload >/dev/null 2>&1
  echo "Firewall updated and reloaded"
}

fw_apply() {
  [ "$(uci -q get "pia.$PIAWG_IF.fw_zone")" = '1' ] || return 0
  persist_run fw_apply_inner
  fw_reload
}

# Ask about the zone, NAT and forwardings, store the answers, apply them
ask_firewall() {
  AFID="$(fw_zone_id "$PIAWG_IF")"
  if [ -n "$AFID" ] && [ "$(uci -q get "firewall.$AFID.pia_managed")" != '1' ]; then
    echo "A firewall zone named '$PIAWG_IF' already exists."
    read_yn "Use it (associate the interface, enable NAT and MSS clamping)" y || return 0
  else
    read_yn "Create firewall zone '$PIAWG_IF' with NAT and MSS clamping" y || {
      uci -q delete "pia.$PIAWG_IF.fw_zone"
      uci -q delete "pia.$PIAWG_IF.fw_forward"
      uci -q commit pia
      return 0
    }
  fi
  AFDEF="$(uci -q get "pia.$PIAWG_IF.fw_forward")"
  [ -n "$AFDEF" ] || AFDEF="$(fw_lan_zone)"
  printf "Zones allowed to forward to it, space separated (enter for '%s', '-' for none): " "${AFDEF:-none}"
  read -r AFANS || AFANS=''
  case "$AFANS" in
  '') AFANS="$AFDEF" ;;
  '-') AFANS='' ;;
  esac
  uci -q set "pia.$PIAWG_IF=interface"
  uci -q set "pia.$PIAWG_IF.fw_zone=1"
  uci -q delete "pia.$PIAWG_IF.fw_forward"
  for AFZ in $AFANS; do uci -q add_list "pia.$PIAWG_IF.fw_forward=$AFZ"; done
  uci -q commit pia
  fw_apply
}

# dnsmasq only keeps the order of the servers of resolv.conf.auto (PIA's first,
# by dns_metric) with strict-order. It follows the default route: set on the
# instances that use the interfaces' DNS servers while a PIA interface has the
# default route, removed (only from the instances set here, listed in
# pia.account.strict_set) when none has it
strict_sync() {
  SSANY=''
  for SSI in $(iface_list); do
    if has_default_route "$SSI"; then
      SSANY=1
      break
    fi
  done
  DSLIST=''
  if [ -n "$SSANY" ]; then
    for DSX in $(uci -q show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p'); do
      [ "$(uci -q get "dhcp.$DSX.noresolv")" = '1' ] && continue
      [ "$(uci -q get "dhcp.$DSX.strictorder")" = '1' ] && continue
      DSLIST="$DSLIST $DSX"
    done
    [ -n "$DSLIST" ] || return 0
    persist_run dns_strict_set
    if uci -q get pia.account >/dev/null; then
      SSOLD="$(uci -q get pia.account.strict_set)"
      uci -q set "pia.account.strict_set=${SSOLD}${DSLIST}"
      uci -q commit pia
    fi
    echo "Strict-order set on:$DSLIST (it follows the default route)"
  else
    for DSX in $(uci -q get pia.account.strict_set); do
      [ "$(uci -q get "dhcp.$DSX.strictorder")" = '1' ] && DSLIST="$DSLIST $DSX"
    done
    if [ -n "$DSLIST" ]; then
      persist_run dns_strict_clear
      echo "Strict-order removed from:$DSLIST (no interface has the default route)"
    fi
    [ -z "$(uci -q get pia.account.strict_set)" ] || {
      uci -q delete pia.account.strict_set
      uci -q commit pia
    }
    [ -n "$DSLIST" ] || return 0
  fi
  /etc/init.d/dnsmasq reload >/dev/null 2>&1
  return 0
}

dns_strict_set() {
  for DSX in $DSLIST; do uci -q set "dhcp.$DSX.strictorder=1"; done
  uci -q commit dhcp
}

dns_strict_clear() {
  for DSX in $DSLIST; do uci -q delete "dhcp.$DSX.strictorder"; done
  uci -q commit dhcp
}

# What is asked when an interface is created (only what is not set yet)
iface_wizard() {
  WZNEW=''
  uci -q get "pia.$PIAWG_IF.peer_allowed_ips" >/dev/null || WZNEW=1
  WZPROTO=''
  # a new interface: which protocol (AmneziaWG by default)
  WZMODE=''
  [ -z "$WZNEW" ] || uci -q get "pia.$PIAWG_IF.iface_proto" >/dev/null || ask_protocol
  keep_conf_section 'net_interface' || set_defnetiface
  if [ "$WZMODE" = 'auto' ]; then
    uci -q set "pia.$PIAWG_IF.proto_mode=auto"
    uci -q commit pia
  fi
  keep_conf_section 'net_peer' || set_defnetpeer
  iface_defaults
  [ -z "$AUTO" ] || return 0
  [ -z "$WZNEW" ] || ask_dns
  [ -z "$WZNEW" ] || ask_mtu
  [ -z "$WZNEW" ] || ask_keepalive
  [ -z "$WZNEW" ] || ask_default_route
  if [ "$(uci -q get "pia.$PIAWG_IF.fw_asked")" != '1' ]; then
    ask_firewall
    uci -q set "pia.$PIAWG_IF.fw_asked=1"
    uci -q commit pia
  fi
  strict_sync
}

# Create an interface section ($1: the name; asked if missing)
set_iface() {
  NEWIF="$1"
  if [ -z "$NEWIF" ]; then
    printf "Name of the network interface (press enter for %s): " "$PIAWG_IF"
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

drop_net_sections() {
  uci -q delete "network.$PIAWG_IF"
  uci -q delete "network.$PIAWG_PEER"
  uci -q commit network
}

# The network sections of the interface: persistent and RAM-staged, and the
# endpoint host route
forget_net() {
  DNEP="$(sget "network.$PIAWG_PEER.endpoint_host")"
  persist_run drop_net_sections
  uci -q revert "network.$PIAWG_IF"
  uci -q revert "network.$PIAWG_PEER"
  uci -q -P "$SESSSTATE" revert "network.$PIAWG_IF"
  uci -q -P "$SESSSTATE" revert "network.$PIAWG_PEER"
  if [ -n "$DNEP" ]; then
    while ip route del "$DNEP/32" 2>/dev/null; do :; done
  fi
  # netifd keeps the interface object of a deleted section (LuCI shows it as
  # 'marked for deletion') until it rereads the config
  if ubus list "network.interface.$PIAWG_IF" >/dev/null 2>&1; then
    ubus call network reload >/dev/null 2>&1
  fi
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
  forget_net
  uci -q rename "pia.$PIAWG_IF=$1"
  uci -q commit pia
  watchdog_strip
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
  watchdog_strip
  ifdown "$PIAWG_IF" >/dev/null 2>&1
  forget_net
  persist_run fw_remove_inner
  fw_reload
  uci -q delete "pia.$PIAWG_IF"
  uci -q commit pia
  rm -f "$SESSION"
  echo "Interface $PIAWG_IF removed"
  strict_sync
  # one left without the default route: offer it back
  RMLEFT="$(iface_list)"
  if [ -n "$RMLEFT" ] && [ "$(echo "$RMLEFT" | wc -l)" -eq 1 ] && [ -z "$AUTO" ] && ! has_default_route "$RMLEFT"; then
    PIAWG_IF="$RMLEFT"
    set_ifvars
    if read_yn "Make $PIAWG_IF the default route again" y; then
      set_default_route yes
      strict_sync
      echo "Applies at the next restart of $PIAWG_IF"
    fi
  fi
}

set_defnetpeer() {
  clear_group peer_
  uci -q batch <<EOI >/dev/null
    set pia.$PIAWG_IF=interface
    set pia.$PIAWG_IF.peer_route_allowed_ips='1'
    set pia.$PIAWG_IF.peer_persistent_keepalive="$PIA_KEEPALIVE"
    add_list pia.$PIAWG_IF.peer_allowed_ips="0.0.0.0/0"
    commit pia
EOI
}

set_defnetiface() {
  # AmneziaWG unless asked otherwise (or not installed)
  if [ -z "$WZPROTO" ]; then
    if awg_available; then WZPROTO='amneziawg'; else WZPROTO='wireguard'; fi
  fi
  clear_group iface_
  uci -q batch <<EOI >/dev/null
    set pia.$PIAWG_IF=interface
    set pia.$PIAWG_IF.iface_proto="$WZPROTO"
    set pia.$PIAWG_IF.iface_defaultroute='1'
    set pia.$PIAWG_IF.iface_delegate='0' # No IPv6 with PIA
    commit pia
EOI
  set_ifvars
}

# Ask which protocol the interface uses ($1: the preselected one), result in
# $WZPROTO. AmneziaWG is the PIA apps' option for networks that block WireGuard.
ask_protocol() {
  WZPROTO=''
  WZMODE=''
  if ! awg_available; then
    echo "AmneziaWG is not installed (packages amneziawg-tools, kmod-amneziawg, luci-proto-amneziawg): using WireGuard" >&3
    WZPROTO='wireguard'
    return 0
  fi
  [ -z "$AUTO" ] || {
    WZPROTO="${1:-amneziawg}"
    return 0
  }
  APDEF=1
  [ "$1" = 'wireguard' ] && APDEF=2
  [ "$2" = 'auto' ] && APDEF=3
  echo "Protocol:"
  echo "  1) AmneziaWG   (obfuscated WireGuard, PIA's option for networks that block it)"
  echo "  2) WireGuard"
  echo "  3) Automatic   (the one that works: the other is tried when there is no handshake)"
  while :; do
    printf "Select the protocol (press enter for %s): " "$APDEF"
    read -r APR || APR=''
    [ -n "$APR" ] || APR="$APDEF"
    case "$APR" in
    1) WZPROTO='amneziawg' ;;
    2) WZPROTO='wireguard' ;;
    3)
      WZPROTO="${1:-amneziawg}"
      WZMODE='auto'
      ;;
    *)
      echo "Invalid choice: '$APR'"
      continue
      ;;
    esac
    return 0
  done
}

# Switch the interface being handled to protocol $1: its network sections and
# session are dropped (made again at the next start)
switch_proto() {
  ifdown "$PIAWG_IF" >/dev/null 2>&1
  forget_net
  rm -f "$SESSION"
  uci -q set "pia.$PIAWG_IF.iface_proto=$1"
  uci -q commit pia
  set_ifvars
}

# The protocol mode: automatic (proto_mode 'auto') or the fixed iface_proto
proto_is_auto() { [ "$(uci -q get "pia.$1.proto_mode")" = 'auto' ]; }

# Change the protocol of the interface being handled
set_protocol() {
  iface_exists "$PIAWG_IF" || {
    echo "No interface named '$PIAWG_IF' is configured!" >&2
    return 1
  }
  SPMODE=''
  proto_is_auto "$PIAWG_IF" && SPMODE='auto'
  ask_protocol "$PIAPROTO" "$SPMODE"
  if [ "$WZPROTO" = 'amneziawg' ] && uci -q get "pia.$PIAWG_IF.dip_token" >/dev/null; then
    echo "A dedicated IP needs WireGuard; remove its token first" >&2
    return 1
  fi
  if [ "$WZMODE" = 'auto' ]; then
    uci -q set "pia.$PIAWG_IF.proto_mode=auto"
  else
    uci -q delete "pia.$PIAWG_IF.proto_mode"
  fi
  uci -q commit pia
  if [ "$WZPROTO" = "$PIAPROTO" ]; then
    echo "$PIAWG_IF uses ${WZMODE:+automatic selection, now }$PIAPROTO"
    return 0
  fi
  switch_proto "$WZPROTO"
  echo "Interface $PIAWG_IF now uses ${WZMODE:+automatic selection, now }$PIAPROTO: start it again (its region needs $PIAPROTO servers)"
}

# DNS servers: PIA's, PIA with MACE (also blocks ads, trackers and malware) or
# one of your own. The PIA address follows from that and the region
# (streaming optimised or not).
ask_dns() {
  [ -z "$AUTO" ] || return 0
  ADDEF=1
  dns_mace && ADDEF=2
  dns_custom && ADDEF=3
  echo "DNS servers (the streaming optimised regions have their own: $PIA_DNS_SO, $PIA_DNS_SO_MACE with MACE):"
  echo "  1) PIA ($PIA_DNS): recommended for PIA"
  echo "  2) PIA with MACE ($PIA_DNS_MACE; blocks ads, trackers and malware)"
  echo "  3) Custom: a DNS server of your own (reached through the tunnel)"
  while :; do
    printf "Select the DNS servers (press enter for %s): " "$ADDEF"
    read -r ADR || ADR=''
    [ -n "$ADR" ] || ADR="$ADDEF"
    case "$ADR" in
    1 | 2)
      dns_custom && uci -q delete "pia.$PIAWG_IF.iface_dns"
      uci -q set "pia.$PIAWG_IF.iface_mace=$((ADR - 1))"
      break
      ;;
    3)
      printf "DNS server address (IPv4): "
      read -r ADC || ADC=''
      if valid_ipv4 "$ADC"; then
        uci -q set "pia.$PIAWG_IF.iface_dns=$ADC"
        break
      fi
      echo "Invalid address: '$ADC'"
      ;;
    *) echo "Invalid choice: '$ADR'" ;;
    esac
  done
  uci -q commit pia
  dns_apply
  # without the default route only the DNS host is routed to the tunnel
  has_default_route "$PIAWG_IF" || set_default_route no
  echo "DNS server: $(uci -q get "pia.$PIAWG_IF.iface_dns")"
}

# The default tunnel MTU: the WAN's minus 60 (WireGuard over IPv4), at most 1420 (what PIA's
# servers use), at least 1280
std_mtu() {
  std_mtu_calc
  echo "$STDMTU"
}

# (sets STDMTU and SMD, the WAN device it came from)
std_mtu_calc() {
  pia_wan
  SMD="$WANDEV"
  [ -n "$SMD" ] || SMD="$(ip -4 route show default | awk -v t="$PIAIFS" '{for(i=1;i<NF;i++) if($i=="dev" && index(t, " " $(i+1) " ") == 0){print $(i+1); exit}}')"
  SMM="$(cat "/sys/class/net/$SMD/mtu" 2>/dev/null)"
  case "$SMM" in
  '' | *[!0-9]*) SMM=1500 ;;
  esac
  [ "$SMM" -le 1500 ] || SMM=1500
  SMM=$((SMM - PIA_MTU_OVERHEAD))
  [ "$SMM" -le "$PIA_MTU_MAX" ] || SMM=$PIA_MTU_MAX
  [ "$SMM" -ge "$PIA_MTU_MIN" ] || SMM=$PIA_MTU_MIN
  STDMTU="$SMM"
}

# Is $1 a custom packet size (digits only, 1280 to 1420)?
valid_mtu() {
  case "$1" in
  '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge "$PIA_MTU_MIN" ] && [ "$1" -le "$PIA_MTU_MAX" ]
}

# Is $1 a keepalive in seconds (digits only, 1 to 65535)?
valid_keepalive() {
  case "$1" in
  '' | *[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Is $1 an IPv4 address?
valid_ipv4() {
  case "$1" in
  '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
  esac
  VIOLD="$IFS"
  IFS=.
  # shellcheck disable=SC2086
  set -- $1
  IFS="$VIOLD"
  [ $# -eq 4 ] || return 1
  for VIX in "$@"; do
    [ "${#VIX}" -le 3 ] && [ "$VIX" -le 255 ] || return 1
  done
}

# Keepalive of the peer: PIA's 25 seconds, none (0) or a number of seconds
ask_keepalive() {
  [ -z "$AUTO" ] || return 0
  AKCUR="$(uci -q get "pia.$PIAWG_IF.peer_persistent_keepalive")"
  AKDEF=1
  [ "$AKCUR" = 0 ] && AKDEF=2
  [ -n "$AKCUR" ] && [ "$AKCUR" != 0 ] && [ "$AKCUR" != "$PIA_KEEPALIVE" ] && AKDEF=3
  echo "Keepalive:"
  echo "  1) Default ($PIA_KEEPALIVE seconds): the official apps' value"
  echo "  2) Disabled (0)"
  echo "  3) Custom (1 to 65535 seconds)"
  [ -z "$AKCUR" ] || echo "  (now $AKCUR)"
  while :; do
    printf "Select the keepalive (press enter for %s): " "$AKDEF"
    read -r AKR || AKR=''
    [ -n "$AKR" ] || AKR="$AKDEF"
    case "$AKR" in
    1)
      uci -q set "pia.$PIAWG_IF.peer_persistent_keepalive=$PIA_KEEPALIVE"
      break
      ;;
    2)
      uci -q set "pia.$PIAWG_IF.peer_persistent_keepalive=0"
      break
      ;;
    3)
      printf "Keepalive in seconds (1 to 65535): "
      read -r AKC || AKC=''
      if valid_keepalive "$AKC"; then
        uci -q set "pia.$PIAWG_IF.peer_persistent_keepalive=$AKC"
        break
      fi
      echo "Invalid keepalive: '$AKC'"
      ;;
    *) echo "Invalid choice: '$AKR'" ;;
    esac
  done
  uci -q commit pia
}

# Does the interface use the default packet size (follows the WAN)? Chosen with mtu_auto 1; an
# interface from before that flag (none) with the 1420 PIA's servers use counts as default too
mtu_is_auto() {
  MAV="$(uci -q get "pia.$PIAWG_IF.mtu_auto")"
  [ "$MAV" = '1' ] && return 0
  [ -z "$MAV" ] && [ "$(uci -q get "pia.$PIAWG_IF.iface_mtu")" = "$PIA_MTU_MAX" ]
}

# The default packet size follows the WAN: when the WAN's MTU changed (a different network),
# the running tunnel gets the new value at once (not written to the flash; a restart
# starts from the stored value and this corrects it)
mtu_sync() {
  mtu_is_auto || return 0
  [ -d "/sys/class/net/$PIAWG_IF" ] || return 0
  std_mtu_calc
  MSW="$STDMTU"
  MSC="$(cat "/sys/class/net/$PIAWG_IF/mtu" 2>/dev/null)"
  [ -n "$MSC" ] && [ "$MSW" != "$MSC" ] || return 0
  if ip link set dev "$PIAWG_IF" mtu "$MSW" 2>/dev/null; then
    echo "MTU: tunnel $MSC -> $MSW (the WAN $SMD has $(cat "/sys/class/net/$SMD/mtu" 2>/dev/null))" >&3
  fi
}

# Packet size: PIA's standard one, small or a custom one
ask_mtu() {
  [ -z "$AUTO" ] || return 0
  AMSTD="$(std_mtu)"
  AMCUR="$(uci -q get "pia.$PIAWG_IF.iface_mtu")"
  AMDEF=1
  [ -n "$AMCUR" ] && [ "$AMCUR" -eq "$PIA_MTU_SMALL" ] && AMDEF=2
  [ -n "$AMCUR" ] && [ "$AMCUR" -ne "$AMSTD" ] && [ "$AMCUR" -ne "$PIA_MTU_SMALL" ] && AMDEF=3
  echo "Packet size (MTU):"
  echo "  1) Default ($AMSTD): recommended (PIA's standard)"
  echo "  2) Small ($PIA_MTU_SMALL): improve compatibility for mobile networks"
  echo "  3) Custom ($PIA_MTU_MIN to $PIA_MTU_MAX)"
  [ -z "$AMCUR" ] || echo "  (now $AMCUR)"
  while :; do
    printf "Select the packet size (press enter for %s): " "$AMDEF"
    read -r AMR || AMR=''
    [ -n "$AMR" ] || AMR="$AMDEF"
    case "$AMR" in
    1)
      uci -q set "pia.$PIAWG_IF.iface_mtu=$AMSTD"
      uci -q set "pia.$PIAWG_IF.mtu_auto=1"
      break
      ;;
    2)
      uci -q set "pia.$PIAWG_IF.iface_mtu=$PIA_MTU_SMALL"
      uci -q set "pia.$PIAWG_IF.mtu_auto=0"
      break
      ;;
    3)
      printf "Packet size (%s to %s): " "$PIA_MTU_MIN" "$PIA_MTU_MAX"
      read -r AMC || AMC=''
      if valid_mtu "$AMC"; then
        uci -q set "pia.$PIAWG_IF.iface_mtu=$AMC"
        uci -q set "pia.$PIAWG_IF.mtu_auto=0"
        break
      fi
      echo "Invalid packet size: '$AMC'"
      ;;
    *) echo "Invalid choice: '$AMR'" ;;
    esac
  done
  uci -q commit pia
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
  elif [ "$PIAPROTO" = 'amneziawg' ]; then
    echo "region:$(uci -q get "pia.$PIAWG_IF.region_id"):amneziawg"
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
      echo "vip=$WGVIP"
      echo "cn=$WGCN"
      echo "server_ip=$WGSERVIP"
      echo "server_port=$WGSERVPT"
      echo "server_key=$WGSERVKEY"
      echo "dns1=$WGDNS1"
      echo "dns2=$WGDNS2"
      echo "obf=$WGOBF"
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

drop_old_peer() {
  uci -q delete network.wgpeer_pia
  uci -q commit network
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
      persist_run drop_old_peer
    fi
    echo "Configuration moved from $OLDCONF to $PIACONF (interface $MIGIF)"
  else
    echo "Could not convert $OLDCONF; it was left in place" >&2
    : >"$PIACONF"
    return 1
  fi
}

# The session (key, address, server) is kept as RAM deltas in $SESSSTATE
# (/var/state, tmpfs). The protocol scripts of netifd load their settings with
# config_load, which reads that directory too; uci, rpcd and LuCI do not, so
# the session is neither listed as an unsaved change nor committed by them.
# netifd itself does not see it either: a running interface has to be
# restarted (ifdown/ifup) to take it.
sget() { uci -q -P "$SESSSTATE" get "$1"; }

# Set a session option only if its effective value differs
stage_set() {
  [ "$(sget "$1")" = "$2" ] && return 0
  # (revert first: a changed option must not pile up entries in RAM)
  uci -q -P "$SESSSTATE" revert "$1"
  uci -q -P "$SESSSTATE" set "$1=$2"
  SESSCHANGED=1
}

# Versions before 1.4.0 kept the session as staged changes in /tmp/.uci (shown
# by LuCI as unsaved): drop them
unstage_legacy() {
  [ -f "$UCISTAGEDIR/network" ] || return 0
  for USO in "$PIAWG_IF.private_key" "$PIAWG_IF.addresses" "$PIAWG_PEER.public_key" "$PIAWG_PEER.endpoint_host" \
    "$PIAWG_PEER.endpoint_port" "$PIAWG_IF.awg_jc" "$PIAWG_IF.awg_jmin" "$PIAWG_IF.awg_jmax" "$PIAWG_IF.awg_s1" \
    "$PIAWG_IF.awg_s2" "$PIAWG_IF.awg_h1" "$PIAWG_IF.awg_h2" "$PIAWG_IF.awg_h3" "$PIAWG_IF.awg_h4"; do
    uci -q revert "network.$USO"
  done
}

# The persistent part of the interface and of the peer, as uci batch commands
#
# The options the script manages are replaced one by one: the others of the
# section (set by hand in LuCI, such as ip4table or ip6assign) are left alone.
persist_batch() {
  echo "set network.$PIAWG_IF=interface"
  echo "set network.$PIAWG_PEER=${PIAPROTO}_${PIAWG_IF}"
  # (the session options are RAM only: any left in the file are old)
  for PBK in private_key proto defaultroute delegate dns_metric dns mace mtu metric multipath addresses auto \
    awg_jc awg_jmin awg_jmax awg_s1 awg_s2 awg_h1 awg_h2 awg_h3 awg_h4; do
    echo "delete network.$PIAWG_IF.$PBK"
  done
  for PBK in description allowed_ips route_allowed_ips persistent_keepalive public_key endpoint_host endpoint_port; do
    echo "delete network.$PIAWG_PEER.$PBK"
  done
  echo "set network.$PIAWG_IF.private_key=$WGPLACEHOLDER"
  # (no dns and no route_allowed_ips here: the DNS server and the routes are given
  # to netifd by confirm_tunnel once the tunnel works; the allowed IPs are always
  # everything, which routes nothing by itself)
  echo "add_list network.$PIAWG_PEER.allowed_ips=0.0.0.0/0"
  echo "set network.$PIAWG_PEER.description='PIA $(uci -q get "pia.$PIAWG_IF.region_name" | tr -d "'")'"
  # the form of LuCI's own save (the Network pages): dns is a list, multipath is
  # set and a defaultroute of 1 (the default) is left out, so that saving the
  # interface there does not list changes
  echo "set network.$PIAWG_IF.multipath=off"
  # not started by netifd at boot unless asked (iface_auto=1): something else (travelmate,
  # the hook or the user) decides, and a tunnel started before its session is registered
  # only runs keyless
  # (with a boot delay the hook starts it, once the router has been up for that long)
  { [ "$(uci -q get "pia.$PIAWG_IF.iface_auto")" = '1' ] && [ "$(uci -q get "pia.$PIAWG_IF.boot_delay" || echo 0)" -le 0 ]; } || echo "set network.$PIAWG_IF.auto=0"
  # the interface's iface_* options go to the network interface, peer_* to the peer
  uci export pia | awk -v qn="'$PIAWG_IF'" -v one="'1'" -v ni="network.$PIAWG_IF" -v np="network.$PIAWG_PEER" '
    $1=="config"{d=($2=="interface" && $3==qn); next}
    d && ($1=="option" || $1=="list"){
      k=$2
      if (k ~ /^iface_/) { sub(/^iface_/, "", k); t=ni }
      else if (k ~ /^peer_/) { sub(/^peer_/, "", k); t=np }
      else next
      if (t==ni && k=="defaultroute" && $3==one) next
      if (t==ni && (k=="auto" || k=="dns")) next
      if (t==np && (k=="allowed_ips" || k=="route_allowed_ips")) next
      if (!((t "." k) in seen)) { seen[t "." k]=1; printf("delete %s.%s\n", t, k) }
      printf("%s %s.%s=%s\n", ($1=="option" && !(t==ni && k=="dns") ? "set" : "add_list"), t, k, $3)
    }'
}

# Run a command with the RAM-staged network changes (key, address, server)
# set aside: uci loads them into everything it reads and commits, so reading
# or committing the persistent config with them in place would write the key
# to the flash. They are put back afterwards.
persist_run() {
  PRSAVEDPKGS=''
  for PRP in network firewall dhcp; do
    [ -f "$UCISTAGEDIR/$PRP" ] || continue
    mv "$UCISTAGEDIR/$PRP" "$RUNDIR/staged.$PRP.$$.tmp"
    PRSAVEDPKGS="$PRSAVEDPKGS $PRP"
  done
  "$@"
  PRRC=$?
  for PRP in $PRSAVEDPKGS; do
    if [ -f "$UCISTAGEDIR/$PRP" ]; then
      cat "$RUNDIR/staged.$PRP.$$.tmp" "$UCISTAGEDIR/$PRP" >"$RUNDIR/staged.$PRP.$$.m" &&
        mv "$RUNDIR/staged.$PRP.$$.m" "$UCISTAGEDIR/$PRP" && rm -f "$RUNDIR/staged.$PRP.$$.tmp"
    else
      mv "$RUNDIR/staged.$PRP.$$.tmp" "$UCISTAGEDIR/$PRP"
    fi
  done
  return $PRRC
}

# Create or update the persistent interface and peer, writing the flash only
# if what is there differs from what is wanted.
ensure_iface_inner() {
  rm -f "$RUNDIR/ucid.t"/*
  # a copy of the persistent file: the batch is applied to it first, and the
  # flash is written only if that changes something
  cp /etc/config/network "$RUNDIR/ucid/network" 2>/dev/null || : >"$RUNDIR/ucid/network"
  UCIS="uci -q -c $RUNDIR/ucid -t $RUNDIR/ucid.t"
  HAVE="$($UCIS show network | sort)"
  {
    persist_batch
    echo "commit network"
  } | $UCIS batch >/dev/null
  WANT="$($UCIS show network | sort)"
  [ "$WANT" = "$HAVE" ] && return 0
  {
    persist_batch
    echo "commit network"
  } | uci -q batch >/dev/null
  NETCHANGED=1
}

# PIA gives the tunnel no IPv6 and the official apps allow 0.0.0.0/0 only (and block
# IPv6 in their firewall): an older ::/0 is removed from the settings (written to the
# flash only when it is there); persist_batch then puts the allowed IPs right
drop_ipv6_allowed() {
  uci -q get "pia.$PIAWG_IF.peer_allowed_ips" | grep -q '::/0' || return 0
  uci -q del_list "pia.$PIAWG_IF.peer_allowed_ips=::/0"
  uci -q commit pia
}

ensure_iface() {
  drop_ipv6_allowed
  persist_run ensure_iface_inner
}

# Stage the session key, address and server (RAM only)
stage_session() {
  unstage_legacy
  stage_set "network.$PIAWG_IF.private_key" "$(session_get priv)"
  stage_set "network.$PIAWG_IF.addresses" "$(session_get peer_ip)"
  stage_set "network.$PIAWG_PEER.public_key" "$(session_get server_key)"
  stage_set "network.$PIAWG_PEER.endpoint_host" "$(session_get server_ip)"
  stage_set "network.$PIAWG_PEER.endpoint_port" "$(session_get server_port)"
  if [ "$PIAPROTO" = 'amneziawg' ]; then
    for SOP in $(session_get obf); do
      stage_set "network.$PIAWG_IF.awg_${SOP%%=*}" "${SOP#*=}"
    done
  fi
}

# Is the session what netifd would use?
session_staged() {
  session_valid &&
    [ "$(sget "network.$PIAWG_IF.private_key")" = "$(session_get priv)" ] &&
    [ "$(sget "network.$PIAWG_PEER.public_key")" = "$(session_get server_key)" ] &&
    [ "$(sget "network.$PIAWG_PEER.endpoint_host")" = "$(session_get server_ip)" ]
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
  dns_apply
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
  iface_defaults
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
  elif [ "$PIAPROTO" = 'amneziawg' ]; then
    echo "A dedicated IP needs WireGuard: use 'configure protocol'" >&3
    return 1
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
  # the server's address inside the tunnel and its name: port forwarding talks to them
  WGVIP="$(echo "$PIAADDKEY" | jq -r '.server_vip // empty')"
  if [ -z "$DIP_STATUS" ]; then WGCN="$CN"; else WGCN="$(uci -q get "pia.$PIAWG_IF.dip_cn")"; fi
  # AmneziaWG: the obfuscation parameters of the server (or the official app's)
  WGOBF=''
  if [ "$PIAPROTO" = 'amneziawg' ]; then
    for SOK in jc jmin jmax s1 s2 h1 h2 h3 h4; do
      SOV="$(echo "$PIAADDKEY" | jq -r --arg k "$SOK" '.obfuscation[$k] // empty' 2>/dev/null)"
      [ -n "$SOV" ] || SOV="$(echo " $PIA_AWG_DEFAULTS" | sed -n "s/.* $SOK=\([0-9]*\).*/\1/p")"
      WGOBF="$WGOBF $SOK=$SOV"
    done
    WGOBF="${WGOBF# }"
  fi

  session_save "$WGPRIV"
  NETCHANGED='' SESSCHANGED=''
  OLDEP="$(sget "network.$PIAWG_PEER.endpoint_host")"
  ensure_iface
  stage_session
  # The host route for the endpoint is made before the interface can come up,
  # and kept while it is down: otherwise its first packets loop (see below)
  endpoint_route "$WGSERVIP" pin
  [ -z "$OLDEP" ] || [ "$OLDEP" = "$WGSERVIP" ] || ip route del "$OLDEP/32" 2>/dev/null
  # netifd only rereads the config on a reload (which restarts a running
  # interface whose settings changed); it does not see the session, which the
  # protocol script reads when the interface comes up
  if [ -n "$NETCHANGED" ] || [ -n "$SESSCHANGED" ]; then
    if wgt "$PIAWG_IF" show "$PIAWG_IF" >/dev/null 2>&1; then
      if [ -n "$APPLY" ]; then
        [ -z "$NETCHANGED" ] || net_reload
        ifdown "$PIAWG_IF" >/dev/null 2>&1
        ifup "$PIAWG_IF"
      else
        echo "Network settings changed; they apply at the next ifup (or use 'renew --apply')" >&3
      fi
    elif [ -n "$NETCHANGED" ]; then
      net_reload
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

# Fastest region of the country of the configured one: ICMP echoes from the
# WAN (what PIA's apps measure), in parallel. The region is only written when
# it changes.
fast_region() {
  [ "$(uci -q get "pia.$PIAWG_IF.region_fast")" = '1' ] || return 0
  uci -q get "pia.$PIAWG_IF.dip_token" >/dev/null && return 0
  FRC="$(uci -q get "pia.$PIAWG_IF.region_country")"
  [ -n "$FRC" ] || return 0
  pia_wan
  FRN=0
  FRPIDS=''
  # the same kind of region as the chosen one (streaming optimised, geo, port forward)
  FRL="$(jq -r --arg c "$FRC" --arg g "$SRVGRP" --arg me "$(uci -q get "pia.$PIAWG_IF.region_id")" '
    def kind: [((.name | contains("Streaming")) or (.dns | contains("-so."))), .geo, .port_forward];
    (.regions[] | select(.id == $me) | kind) as $k
    | .regions[] | select(.country == $c and .offline == false and kind == $k) | select(.servers[$g])
    | "\(.id) \(.servers[$g][0].ip)"' "$(cache_dir)/servers.json" 2>/dev/null)"
  [ -n "$FRL" ] || return 0
  while read -r FRID FRIP; do
    FRN=$((FRN + 1))
    (ping -c 2 -W 1 ${WANDEV:+-I "$WANDEV"} "$FRIP" 2>/dev/null | awk -F/ -v id="$FRID" '/^round-trip/{print $4, id}' >"$RUNDIR/fast.$$.$FRN") &
    FRPIDS="$FRPIDS $!"
  done <<EOF
$FRL
EOF
  # (not a plain wait: the log writer is a child too)
  # shellcheck disable=SC2086
  wait $FRPIDS
  FRALL="$(cat "$RUNDIR"/fast.$$.* 2>/dev/null)"
  FRBEST="$(echo "$FRALL" | sort -n | head -n 1)"
  rm -f "$RUNDIR"/fast.$$.*
  while read -r FRID FRIP; do
    [ -n "$FRID" ] || continue
    FRMS="$(echo "$FRALL" | awk -v id="$FRID" '$2 == id {printf "%d", $1 + 0.5}')"
    if [ -n "$FRMS" ]; then FRST='ok'; else FRST='timeout'; fi
    history_add fast "$FRST" "$FRIP" "" "$FRMS" "ping" "$FRID"
  done <<EOF
$FRL
EOF
  [ -n "$FRBEST" ] || {
    echo "Fastest region: no answer to the pings; keeping $(uci -q get "pia.$PIAWG_IF.region_id")" >&3
    return 0
  }
  FRID="${FRBEST#* }"
  echo "Fastest region of $FRC: $FRID (${FRBEST%% *} ms)" >&3
  [ "$FRID" = "$(uci -q get "pia.$PIAWG_IF.region_id")" ] && return 0
  FRNAME="$(jq -r --arg r "$FRID" '.regions[] | select(.id == $r) | .name' "$(cache_dir)/servers.json")"
  FRDNS="$(jq -r --arg r "$FRID" '.regions[] | select(.id == $r) | .dns' "$(cache_dir)/servers.json")"
  uci -q batch <<EOI >/dev/null
    set pia.$PIAWG_IF.region_id="$FRID"
    set pia.$PIAWG_IF.region_name="$FRNAME"
    set pia.$PIAWG_IF.region_dns="$FRDNS"
    commit pia
EOI
  dns_apply
}

# One attempt: register a new key, bring the interface up, wait for the
# handshake (the caller checks the result)
start_try() {
  # a new key pair for each connection, as the official apps do
  NEWKEY=1
  set_netconf || {
    NEWKEY=''
    return 1
  }
  NEWKEY=''
  echo "Starting PIA ($(uci get "network.$PIAWG_PEER.description"))" >&3
  # Before the tunnel exists, so that there is no moment without it
  endpoint_route "$(sget "network.$PIAWG_PEER.endpoint_host")" pin
  ifup "$PIAWG_IF"
  sleep 1
  N=0
  if [ "$1" = 'fast' ]; then
    # (the automatic mode: just the handshake, for up to 12 seconds)
    while [ $N -lt 12 ] && ! handshake_age >/dev/null; do
      N=$((N + 1))
      sleep 1
    done
    return 0
  fi
  # The handshake can take a few seconds; check quietly before reporting
  while [ $N -lt 5 ] && ! check_wg >/dev/null 2>&1 3>/dev/null; do
    N=$((N + 1))
    sleep 2
  done
  return 0
}

# Automatic protocol: the interface's protocol first (the one that worked last,
# it is kept), and on no handshake a second server, then the other protocol
auto_start() {
  APALT='amneziawg'
  [ "$PIAPROTO" = 'wireguard' ] || APALT='wireguard'
  AFIRST="$PIAPROTO"
  PIAEXCL=''
  for AP in "$AFIRST" "$APALT"; do
    [ "$AP" = 'amneziawg' ] && ! awg_available && continue
    if [ "$AP" != "$PIAPROTO" ]; then
      echo "No handshake: trying $AP" >&3
      switch_proto "$AP"
    fi
    # shellcheck disable=SC2034 # twice: the second time on another server
    for AT in 1 2; do
      if start_try fast && handshake_age >/dev/null && check_wg >/dev/null 2>&1 3>/dev/null; then
        PIAEXCL=''
        return 0
      fi
      # a server that registered us but never answered: not that one again
      PIAEXCL="$PIAEXCL $(session_get server_ip)"
      ifdown "$PIAWG_IF" >/dev/null 2>&1
      [ -n "$(session_get server_ip)" ] && ip route del "$(session_get server_ip)/32" 2>/dev/null
    done
    PIAEXCL=''
  done
  return 1
}

start_wgpia() {
  stop_wgpia
  fast_region
  if proto_is_auto "$PIAWG_IF"; then
    auto_start
  else
    start_try || {
      echo "Could not start PIA!" >&3
      return 1
    }
  fi
  check_wg
  RET=$?
  [ $RET -eq 0 ] && echo "PIA started successfully ..." >&3 || echo "Could not start PIA!" >&3
  [ $RET -ne 0 ] || confirm_tunnel || :
  return $RET
}

stop_wgpia() {
  DESC=" ($(uci -q get "network.$PIAWG_PEER.description"))" || DESC=""
  echo "Stopping PIA$DESC" >&3
  ifdown "$PIAWG_IF" >/dev/null 2>&1
  # the host route pinned by endpoint_route
  SEP="$(sget "network.$PIAWG_PEER.endpoint_host")" && [ -n "$SEP" ] && ip route del "$SEP/32" 2>/dev/null
  pf_stop
  return 0
}

check_wg() {
  if wgt "$PIAWG_IF" show "$PIAWG_IF" >/dev/null 2>&1; then
    PIAWG_EP="$(wgt "$PIAWG_IF" show "$PIAWG_IF" endpoints 2>/dev/null | awk -F'[[:space:]:]' '{print $2; exit;}')"
    PIAWG_MK="$(wgt "$PIAWG_IF" show "$PIAWG_IF" fwmark 2>/dev/null)"
    [ "$PIAWG_MK" = "off" ] && PIAWG_MK=''
    # never leave the endpoint routed through the tunnel (routing loop)
    if ! endpoint_route "$PIAWG_EP" check; then
      echo "Routing loop: the endpoint $PIAWG_EP is routed through the tunnel; bringing it down!" >&3
      ifdown "$PIAWG_IF" >/dev/null 2>&1
      return 1
    fi
    WAN_IF="$(ip route get "$PIAWG_EP" ${PIAWG_MK:+mark "$PIAWG_MK"} | awk '{for(i=0;i<NF;i++){if($i=="dev"){print $++i; exit;}}}')"
    echo "PIA interface ($PIAPROTO): UP"
  else
    echo "PIA interface ($PIAPROTO): DOWN!" >&3
    return 1
  fi

  echo "Region is: $(uci get "network.$PIAWG_PEER.description")"
  # Probe PIA's own in-tunnel DNS address (handed out by addKey): the probe is
  # an ICMP packet that never leaves the tunnel and names no third party.
  # The first hop does not always answer TTL expiry, so also try a plain ping
  CHK="$(dns_hosts | awk '{print $1}')"
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
# ---- renew: keep the key registered, nothing else ----
# It never starts or stops the tunnel: that is left to ifup/ifdown (LuCI).

# Seconds since the tunnel's last handshake (nothing if none)
handshake_age() {
  HSEC="$(wgt "$PIAWG_IF" show "$PIAWG_IF" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
  [ -n "$HSEC" ] && [ "$HSEC" -gt 0 ] || return 1
  echo $(($(date +%s) - HSEC))
}

# Is there a default route that is not the tunnel (a WAN)?
wan_present() {
  ip -4 route show default | awk -v t="$PIAIFS" '{for(i=1;i<NF;i++) if($i=="dev" && index(t, " " $(i+1) " ")==0 && $(i+1) !~ /^(tun|tap|ppp|wg)/) f=1} END{exit !f}'
}

# ---- clock: TLS (the PIA CA, the tokens' expiry) needs the right time ----
# A router without a battery clock boots with the time of its last shutdown.
# time_synced: 0 synchronised, 1 not (yet), 2 cannot tell. ntpd (sysntpd) is
# used if system.ntp.enabled is not 0 and it runs; otherwise chrony, judged
# like dqm does: stratum 1-9 (0 and 16 are unsynchronised, 10 is chrony's own
# local orphan reference) and a system time offset under 200 ms.
# One line at the first logged run after a boot: uptime, whether the clock is
# right yet (timestamps before that are not), and the state of each interface
boot_summary() {
  mkdir "$RUNDIR/boot.logged" 2>/dev/null || return 0
  time_synced
  case $? in
  0) BSCLK="clock synchronised ($TSRC)" ;;
  *) BSCLK="clock not yet synchronised${TSRC:+ ($TSRC)}, timestamps before the next sync are unreliable" ;;
  esac
  BSLINE="Boot: up $(cut -d. -f1 /proc/uptime)s, $BSCLK, version $CURVERS"
  BSSAVE="$PIAWG_IF"
  for BSX in $(iface_list); do
    PIAWG_IF="$BSX"
    set_ifvars
    if session_valid; then BSK='yes'; else BSK='no'; fi
    BSB='no'
    [ "$(uci -q get "pia.$BSX.iface_auto")" = '1' ] && BSB='yes'
    [ "$BSB" = 'yes' ] && [ "$(uci -q get "pia.$BSX.boot_delay" || echo 0)" -gt 0 ] && BSB="yes, after $(uci -q get "pia.$BSX.boot_delay")s"
    BSLINE="$BSLINE; $BSX: session key $BSK, bring up on boot $BSB"
  done
  PIAWG_IF="$BSSAVE"
  set_ifvars
  echo "$BSLINE" >&3
}
time_synced() {
  if [ "$(uci -q get system.ntp.enabled)" != '0' ] && pidof ntpd >/dev/null 2>&1; then
    TSRC='ntpd'
    # OpenWrt's ntpd hotplug script leaves this file at the first stratum event
    [ -e /var/state/dnsmasqsec ] && return 0
    [ -e /etc/hotplug.d/ntp/25-dnsmasqsec ] && return 1
    return 2
  fi
  if command -v chronyc >/dev/null 2>&1; then
    TSRC='chrony'
    CHT="$(chronyc tracking 2>/dev/null)"
    [ -n "$CHT" ] || return 2
    echo "$CHT" | awk -F: '
      /^Stratum/ {s = $2 + 0}
      /^System time/ {split($2, a, " "); o = a[1] + 0}
      END {exit !(s >= 1 && s <= 9 && o < 0.2)}' && return 0
    return 1
  fi
  return 2
}

# time_wait <seconds>: wait for the clock; 0 ok (or unknown), 1 timed out
time_wait() {
  TWLEFT="$1"
  time_synced
  TWR=$?
  [ $TWR -eq 1 ] || return 0
  echo "Waiting for the clock to synchronise (${TSRC}, up to ${1}s)" >&3
  while [ "$TWLEFT" -gt 0 ]; do
    sleep 1
    TWLEFT=$((TWLEFT - 1))
    time_synced
    [ $? -eq 1 ] || {
      echo "The clock is synchronised (${TSRC})" >&3
      return 0
    }
  done
  return 1
}

# Before a command that talks to PIA. An unattended run does not go on with a
# clock that is not synchronised (it is tried again at the next trigger); a
# person at a terminal is warned.
time_gate() {
  if [ "$1" = 'renew' ] && [ "$2" = '--if-missing' ]; then
    TGW=180
  elif [ "$1" = 'start' ] && [ "$2" = '--cron' ]; then
    TGW=10
  elif [ -n "$AUTO" ]; then
    TGW=60
  else
    TGW=30
  fi
  time_wait "$TGW" && return 0
  if [ -n "$AUTO" ]; then
    echo "Error: the clock is not synchronised (waited ${TGW}s): not contacting PIA now" >&3
    exit 1
  fi
  echo "Warning: the clock is not synchronised; certificates may be rejected" >&3
  return 0
}

# ---- confirmation: the default route and the DNS server only for a tunnel that works ----
# Stage 1: the tunnel is up with its key, but netifd has neither a route nor a
#   DNS server for it (the network config has no dns and no route_allowed_ips,
#   and the protocol script sends none): the handshake is awaited and a DNS
#   query is sent through the tunnel (over a host route made first, so that it
#   cannot leave through the WAN).
# Stage 2: the routes and the DNS server are given to netifd as an update of the
#   interface, what the protocol script would have sent: netifd and everything
#   that reads it (dqm's IoT DNS hook, trm...) see them as they always did.
# Nothing of it is written to the flash, and a restarted interface starts again
# from stage 1 (its ifup runs the hook, which confirms again).
# tunnel_update [withdraw]: give netifd the routes and the DNS server, or (withdraw)
# take them back: the tunnel is not trusted any more
tunnel_update() {
  TUADDR="$(session_get peer_ip)"
  [ -n "$TUADDR" ] || return 1
  TUDNS="$(dns_hosts)"
  TUMODE='dns'
  has_default_route "$PIAWG_IF" && TUMODE='full'
  [ "$1" = 'withdraw' ] && TUMODE='none'
  (
    # shellcheck disable=SC1091
    . /lib/functions.sh
    # shellcheck disable=SC1091
    . /lib/netifd/netifd-proto.sh
    proto_init_update "$PIAWG_IF" 1
    proto_add_ipv4_address "$TUADDR" 32
    if [ "$TUMODE" = 'full' ]; then
      proto_add_ipv4_route 0.0.0.0 0
    fi
    for TUD in $TUDNS; do
      [ "$TUMODE" = 'none' ] && break
      [ "$TUMODE" = 'full' ] || proto_add_ipv4_route "$TUD" 32
      proto_add_dns_server "$TUD"
    done
    proto_send_update "$PIAWG_IF"
  ) || return 1
  # what follows the interface's DNS server (dqm's IoT upstream file) is told as
  # at an ifup: netifd's own events for an update are not ifup or ifdown
  if [ -x /etc/hotplug.d/iface/90-dqm-iot-dns ]; then
    ACTION=ifup INTERFACE="$PIAWG_IF" /etc/hotplug.d/iface/90-dqm-iot-dns >/dev/null 2>&1
  fi
  return 0
}

# A handshake that is recent (the keepalive renews it every 25 s)
tunnel_handshake() {
  THA="$(handshake_age)" && [ "$THA" -lt "$RENEW_SKIP" ]
}

# Does the PIA DNS server answer through the tunnel? (host routes first)
tunnel_dns_probe() {
  for TDD in $(dns_hosts); do
    ip route replace "$TDD/32" dev "$PIAWG_IF" 2>/dev/null
    nslookup -timeout=3 privateinternetaccess.com "$TDD" >/dev/null 2>&1 && return 0
  done
  return 1
}

# Has stage 2 been done: handshake, DNS server and (if it has it) the default route
confirm_done() {
  tunnel_handshake || return 1
  CDF="$(dns_hosts | awk '{print $1}')"
  ubus call "network.interface.$PIAWG_IF" status 2>/dev/null | jsonfilter -e '@["dns-server"][*]' | grep -qxF "$CDF" || return 1
  if has_default_route "$PIAWG_IF"; then
    ip -4 route show default dev "$PIAWG_IF" 2>/dev/null | grep -q . || return 1
  fi
  return 0
}

# One look at the tunnel (stage 1); CTWHY says what is wrong
confirm_check() {
  CTWHY=''
  if ! wgt "$PIAWG_IF" show "$PIAWG_IF" >/dev/null 2>&1; then
    CTWHY='the interface is not up'
    return 1
  fi
  CTD0="$(date +%s)"
  while ! tunnel_handshake; do
    if [ $(($(date +%s) - CTD0)) -ge 15 ]; then
      CTWHY='no handshake after 15s'
      return 1
    fi
    # (the query makes the first packets: it starts the handshake)
    tunnel_dns_probe >/dev/null 2>&1
    sleep 1
  done
  echo "Stage 1/2 (confirm): handshake confirmed after $(($(date +%s) - CTD0))s" >&3
  CTD1="$(date +%s)"
  if ! tunnel_dns_probe; then
    CTWHY="DNS server $(dns_hosts | awk '{print $1}') did not answer through the tunnel"
    return 1
  fi
  echo "Stage 1/2 (confirm): DNS server $(dns_hosts | awk '{print $1}') answered through the tunnel ($(($(date +%s) - CTD1))s)" >&3
  return 0
}

# A step of the recovery: 1 register the key again, 2 refresh the servers list
# and choose the server again, 3 renew the VPN token. A list refresh or a token
# renewal at most once in 10 minutes.
confirm_recover() {
  CRN="$1"
  CRNOW="$(date +%s)"
  CROLDEP="$(session_get server_ip)"
  case "$CRN" in
  2)
    CRL="$(cat "$RUNDIR/last.list" 2>/dev/null)"
    if [ $((CRNOW - ${CRL:-0})) -ge 600 ]; then
      echo "Stage 1/2 (confirm): refreshing the servers list (attempt 2/3)" >&3
      pia_wan
      echo "$CRNOW" >"$RUNDIR/last.list"
      cache_refresh_list >/dev/null 2>&1 || echo "Stage 1/2 (confirm): the servers list could not be refreshed" >&3
      PIAREGIONS=''
      fast_region
    else
      echo "Stage 1/2 (confirm): the servers list was refreshed less than 10 minutes ago; another server is chosen (attempt 2/3)" >&3
    fi
    # not the server that did not answer
    PIAEXCL="$CROLDEP"
    ;;
  3)
    CRL="$(cat "$RUNDIR/last.token" 2>/dev/null)"
    if [ $((CRNOW - ${CRL:-0})) -ge 600 ]; then
      echo "Stage 1/2 (confirm): renewing the VPN token (attempt 3/3)" >&3
      echo "$CRNOW" >"$RUNDIR/last.token"
      pia_token_forget
    else
      echo "Stage 1/2 (confirm): the VPN token was renewed less than 10 minutes ago; kept (attempt 3/3)" >&3
    fi
    PIAEXCL="$CROLDEP"
    ;;
  *) echo "Stage 1/2 (confirm): registering the key again (attempt 1/3)" >&3 ;;
  esac
  NEWKEY=1
  APPLY=1
  set_netconf
  CRRC=$?
  NEWKEY=''
  APPLY=''
  PIAEXCL=''
  sleep 2
  return $CRRC
}

# ---- port forwarding, as the official apps do it ----
# getSignature (with the API token) on the server's address inside the tunnel
# (port 19999, the PIA CA, the server's name) returns a payload (the port and its
# expiry) and a signature; bindPort with them opens the port and has to be repeated
# every 15 minutes. A new signature means a new port, so the token is kept (in the
# cache path, not in the flash) and reused while a week of it is left.
PF_BIND_EVERY=900
PF_MIN_LEFT=604800

pf_enabled() { [ "$(uci -q get "pia.$PIAWG_IF.pf_enable")" = '1' ]; }
pf_tokfile() { echo "$(cache_dir)/portfwd.$PIAWG_IF.json"; }
pf_statefile() { echo "$RUNDIR/portfwd.$PIAWG_IF"; }

# $1: getSignature|bindPort, then the curl data arguments
pf_call() {
  PFPATH="$1"
  shift
  curl -s --max-time 10 --cacert "$(pia_ca)" --connect-to "$PFCN::$PFVIP:19999" -G "$@" "https://$PFCN:19999/$PFPATH"
}

# The saved token if it is for this server and has a week left (sets PFPAY, PFSIG, PFPORT)
pf_token_load() {
  PFTF="$(pf_tokfile)"
  [ -s "$PFTF" ] || return 1
  [ "$(jq -r '.server // empty' "$PFTF" 2>/dev/null)" = "$PFSRV" ] || return 1
  PFPAY="$(jq -r '.payload // empty' "$PFTF" 2>/dev/null)"
  PFSIG="$(jq -r '.signature // empty' "$PFTF" 2>/dev/null)"
  [ -n "$PFPAY" ] && [ -n "$PFSIG" ] || return 1
  PFEXP="$(iso2epoch "$(echo "$PFPAY" | jq -Rr '@base64d | fromjson | .expires_at // empty' 2>/dev/null)")"
  [ "${PFEXP:-0}" -gt $(($(date +%s) + PF_MIN_LEFT)) ] || return 1
  PFPORT="$(echo "$PFPAY" | jq -Rr '@base64d | fromjson | .port // empty' 2>/dev/null)"
  [ -n "$PFPORT" ]
}

# A new token from the server; saved
pf_token_new() {
  token_ok apitoken || pia_tokens >/dev/null 2>&1
  PFAT="$(uci -q get pia.apitoken.token)"
  [ -n "$PFAT" ] || { PFWHY='there is no API token'; return 1; }
  PFR="$(pf_call getSignature --data-urlencode "token=$PFAT")"
  if [ "$(echo "$PFR" | jq -r '.status // empty' 2>/dev/null)" != 'OK' ]; then
    PFWHY="getSignature: $(echo "$PFR" | jq -r '.message // .status // empty' 2>/dev/null | tr -cd ' -~' | cut -c1-60)"
    return 1
  fi
  PFPAY="$(echo "$PFR" | jq -r '.payload // empty')"
  PFSIG="$(echo "$PFR" | jq -r '.signature // empty')"
  PFPORT="$(echo "$PFPAY" | jq -Rr '@base64d | fromjson | .port // empty' 2>/dev/null)"
  PFEXP="$(iso2epoch "$(echo "$PFPAY" | jq -Rr '@base64d | fromjson | .expires_at // empty' 2>/dev/null)")"
  [ -n "$PFPAY" ] && [ -n "$PFSIG" ] && [ -n "$PFPORT" ] || { PFWHY='getSignature: incomplete answer'; return 1; }
  PFTF="$(pf_tokfile)"
  (
    umask 077
    jq -nc --arg s "$PFSRV" --arg p "$PFPAY" --arg g "$PFSIG" '{server: $s, payload: $p, signature: $g}' >"$PFTF.tmp" && mv "$PFTF.tmp" "$PFTF"
  )
  PFNEWTOK=1
  return 0
}

# The zone of the destination: the one (of those forwarding into the interface) whose
# network holds the address, else the first of them
pf_dest_zone() {
  PDDEV="$(ip -4 route get "$1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)"
  PDFIRST=''
  for PDZ in $(uci -q get "pia.$PIAWG_IF.fw_forward"); do
    [ -n "$PDFIRST" ] || PDFIRST="$PDZ"
    PDID="$(fw_zone_id "$PDZ")"
    for PDN in $(uci -q get "firewall.$PDID.network"); do
      if [ "$(ubus call "network.interface.$PDN" status 2>/dev/null | jsonfilter -e '@.l3_device')" = "$PDDEV" ]; then
        echo "$PDZ"
        return 0
      fi
    done
  done
  [ -n "$PDFIRST" ] || PDFIRST="$(fw_lan_zone | awk '{print $1}')"
  echo "$PDFIRST"
}

# Make the redirect (NAT and its inbound accept) say what is wanted: $1 is the
# forwarded port, empty for none
pf_fw_inner() {
  FWCHANGED=''
  PFWP="$1"
  PFWIP="$(uci -q get "pia.$PIAWG_IF.pf_ip")"
  PFWDP="$(uci -q get "pia.$PIAWG_IF.pf_port")"
  [ -n "$PFWDP" ] || PFWDP="$PFWP"
  PFWZ=''
  if pf_enabled && [ -n "$PFWP" ] && [ -n "$PFWIP" ] && [ -n "$(fw_zone_id "$PIAWG_IF")" ]; then
    PFWZ="$(pf_dest_zone "$PFWIP")"
  fi
  PFHAVE=''
  PFN=0
  while uci -q get "firewall.@redirect[$PFN]" >/dev/null; do PFN=$((PFN + 1)); done
  PFI=$((PFN - 1))
  while [ "$PFI" -ge 0 ]; do
    if [ "$(uci -q get "firewall.@redirect[$PFI].pia_managed_pf")" = "$PIAWG_IF" ]; then
      if [ -n "$PFWZ" ] && [ -z "$PFHAVE" ] &&
        [ "$(uci -q get "firewall.@redirect[$PFI].src_dport")" = "$PFWP" ] &&
        [ "$(uci -q get "firewall.@redirect[$PFI].dest_ip")" = "$PFWIP" ] &&
        [ "$(uci -q get "firewall.@redirect[$PFI].dest_port")" = "$PFWDP" ] &&
        [ "$(uci -q get "firewall.@redirect[$PFI].dest")" = "$PFWZ" ]; then
        PFHAVE=1
      else
        uci -q delete "firewall.@redirect[$PFI]"
        FWCHANGED=1
      fi
    fi
    PFI=$((PFI - 1))
  done
  if [ -n "$PFWZ" ] && [ -z "$PFHAVE" ]; then
    PFR="$(uci -q add firewall redirect)"
    uci -q set "firewall.$PFR.name=PIA port forward $PIAWG_IF"
    uci -q set "firewall.$PFR.src=$PIAWG_IF"
    uci -q set "firewall.$PFR.src_dport=$PFWP"
    uci -q set "firewall.$PFR.dest=$PFWZ"
    uci -q set "firewall.$PFR.dest_ip=$PFWIP"
    uci -q set "firewall.$PFR.dest_port=$PFWDP"
    uci -q add_list "firewall.$PFR.proto=tcp"
    uci -q add_list "firewall.$PFR.proto=udp"
    uci -q set "firewall.$PFR.target=DNAT"
    uci -q set "firewall.$PFR.family=ipv4"
    uci -q set "firewall.$PFR.pia_managed_pf=$PIAWG_IF"
    FWCHANGED=1
  fi
  [ -z "$FWCHANGED" ] || uci -q commit firewall
  return 0
}

pf_fw_sync() {
  persist_run pf_fw_inner "$1"
  fw_reload
}

# Get (or reuse) the token, bind the port, keep the redirect right. keepalive: only
# when the last bind is 15 minutes old (the guard runs this every minute)
pf_run() {
  pf_enabled || return 0
  PFSF="$(pf_statefile)"
  if [ "$1" = 'keepalive' ]; then
    pf_due || return 0
    tunnel_handshake || return 0
  fi
  if [ -n "$(uci -q get "pia.$PIAWG_IF.dip_ip")" ]; then
    [ "$1" = 'keepalive' ] || echo "Port forwarding: not available with a dedicated IP" >&3
    return 0
  fi
  PFVIP="$(session_get vip)"
  PFCN="$(session_get cn)"
  PFSRV="$(session_get server_ip)"
  if [ -z "$PFVIP" ] || [ -z "$PFCN" ]; then
    [ "$1" = 'keepalive' ] || echo "Port forwarding: the session has no server address yet (made at the next key registration)" >&3
    return 0
  fi
  ip route replace "$PFVIP/32" dev "$PIAWG_IF" 2>/dev/null
  PFNEWTOK=''
  PFWHY=''
  PFTRY=0
  PFOK=''
  while [ $PFTRY -lt 2 ]; do
    if ! pf_token_load; then
      pf_token_new || break
    fi
    PFB="$(pf_call bindPort --data-urlencode "payload=$PFPAY" --data-urlencode "signature=$PFSIG")"
    if [ "$(echo "$PFB" | jq -r '.status // empty' 2>/dev/null)" = 'OK' ]; then
      PFOK=1
      break
    fi
    PFWHY="bindPort: $(echo "$PFB" | jq -r '.message // .status // empty' 2>/dev/null | tr -cd ' -~' | cut -c1-60)"
    rm -f "$(pf_tokfile)"
    PFTRY=$((PFTRY + 1))
  done
  if [ -z "$PFOK" ]; then
    rm -f "$PFSF"
    date +%s >"$RUNDIR/portfwd.try.$PIAWG_IF"
    echo "Error: Port forwarding FAILED (${PFWHY:-no answer from $PFCN}); tried again in 5 minutes" >&3
    return 1
  fi
  PFOLD="$(awk '{print $1; exit}' "$PFSF" 2>/dev/null)"
  echo "$PFPORT $(date +%s)" >"$PFSF"
  rm -f "$RUNDIR/portfwd.try.$PIAWG_IF"
  if [ "$PFOLD" != "$PFPORT" ] || [ -n "$PFNEWTOK" ]; then
    echo "Port forwarding: port $PFPORT bound on $PFCN${PFNEWTOK:+ (new token)}, token valid until $(date -d "@$PFEXP" '+%Y/%m/%d' 2>/dev/null || echo "$PFEXP")" >&3
  fi
  pf_fw_sync "$PFPORT" >&3
  return 0
}

# Is a bind due (the guard looks before it sets up its logging): the last one is 15
# minutes old, or none yet and the last failed attempt is 5 minutes old
pf_due() {
  pf_enabled || return 1
  wgt "$PIAWG_IF" show "$PIAWG_IF" >/dev/null 2>&1 || return 1
  PDNOW="$(date +%s)"
  PDLAST="$(awk '{print $2; exit}' "$(pf_statefile)" 2>/dev/null)"
  if [ -n "$PDLAST" ]; then
    [ $((PDNOW - PDLAST)) -ge $PF_BIND_EVERY ]
  else
    PDTRY="$(cat "$RUNDIR/portfwd.try.$PIAWG_IF" 2>/dev/null)"
    [ -n "$PDTRY" ] && [ $((PDNOW - PDTRY)) -ge 300 ]
  fi
}

# The port is not forwarded any more (option off, interface stopped or removed)
pf_stop() {
  rm -f "$(pf_statefile)"
}

# Confirm the tunnel and apply stage 2; recover (up to 3 times) when stage 1 fails
confirm_tunnel() {
  CTA=0
  # routes that were applied for a tunnel that no longer answers are taken back
  # at once (the WAN default route and its DNS serve meanwhile)
  if ! tunnel_handshake && ip -4 route show default dev "$PIAWG_IF" 2>/dev/null | grep -q .; then
    echo "Stage 2/2 (withdraw): no recent handshake: default route and DNS server withdrawn" >&3
    history_add confirm withdrawn "$(sget "network.$PIAWG_PEER.endpoint_host")" "" "" "no recent handshake: routes withdrawn"
    tunnel_update withdraw
  fi
  while :; do
    if confirm_check; then
      if tunnel_update; then
        if has_default_route "$PIAWG_IF"; then
          echo "Stage 2/2 (apply): default route and DNS server $(dns_hosts | awk '{print $1}') applied" >&3
        else
          echo "Stage 2/2 (apply): DNS server $(dns_hosts | awk '{print $1}') and its route applied" >&3
        fi
        rm -f "$RUNDIR/confirm.fail.$PIAWG_IF"
        history_add confirm ok "$(sget "network.$PIAWG_PEER.endpoint_host")" "" "" "handshake and DNS answer confirmed, routes applied"
        pf_run >&3
        return 0
      fi
      CTWHY='the interface could not be updated'
    fi
    CTA=$((CTA + 1))
    if [ $CTA -gt 3 ]; then
      date +%s >"$RUNDIR/confirm.fail.$PIAWG_IF"
      history_add confirm failed "$(sget "network.$PIAWG_PEER.endpoint_host")" "" "" "$CTWHY"
      echo "Error: Stage 1/2 (confirm) FAILED after 3 attempts (last: $CTWHY): the tunnel stays unconfirmed, the WAN keeps the default route; retried at the next hook or cron" >&3
      return 1
    fi
    echo "Stage 1/2 (confirm): FAILED ($CTWHY)" >&3
    case $CTA in 1) sleep 5 ;; 2) sleep 15 ;; *) sleep 30 ;; esac
    confirm_recover "$CTA" || echo "Stage 1/2 (confirm): the key could not be registered" >&3
  done
}

# confirm [--force]: nothing when the interface is down or already confirmed;
# after a failure not again within 2 minutes (unless --force)
confirm_cmd() {
  CCW="Command skipped${CONFIRM_BY:+ ($CONFIRM_BY)}:"
  wgt "$PIAWG_IF" show "$PIAWG_IF" >/dev/null 2>&1 || {
    echo "$CCW The interface is down" >&3
    return 0
  }
  confirm_done && {
    echo "$CCW The interface is up" >&3
    return 0
  }
  if [ "$1" != '--force' ]; then
    CCF="$(cat "$RUNDIR/confirm.fail.$PIAWG_IF" 2>/dev/null)"
    if [ $(($(date +%s) - ${CCF:-0})) -lt 120 ]; then
      echo "$CCW In back-off after a failed attempt, $((120 - $(date +%s) + CCF))s left" >&3
      return 0
    fi
  fi
  session_valid || {
    echo "$CCW There is no session key" >&3
    return 0
  }
  confirm_tunnel
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
  if [ -n "$RNEWKEY" ] && [ -z "$RAPPLY" ] && wgt "$PIAWG_IF" show "$PIAWG_IF" >/dev/null 2>&1; then
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

# ---- guard: a tunnel that is up but whose handshake is stale ----
# Run by cron every minute. It only detects: a handshake older than 180 s (a
# working tunnel renews it at least every 2 minutes, with the keepalive on), and
# then runs the ifup hook, which registers the key if missing and confirms the
# tunnel (withdrawing a stale route first, then recovering). An interface
# whose keepalive is 0 is left alone: an idle tunnel has no handshake then.
GUARD_AGE=180
guard_installed() { grep -qF "$CRON_TAG_GUARD" /etc/crontabs/root 2>/dev/null; }

# Does the interface being handled need the hook? (quiet: no output, no files)
guard_needed() {
  GK="$(uci -q get "pia.$PIAWG_IF.peer_persistent_keepalive")"
  [ "${GK:-$PIA_KEEPALIVE}" = '0' ] && return 1
  wgt "$PIAWG_IF" show "$PIAWG_IF" >/dev/null 2>&1 || return 1
  # a hook run is in progress: it is doing it
  GHP="$(cat "$RUNDIR/hook.lock/pid" 2>/dev/null)"
  [ -n "$GHP" ] && kill -0 "$GHP" 2>/dev/null && return 1
  GA="$(handshake_age)" || GA=''
  [ -z "$GA" ] || [ "$GA" -gt "$GUARD_AGE" ]
}

guard_cmd() {
  pf_run keepalive >&3
  guard_needed || return 0
  GA="$(handshake_age)" || GA=''
  if [ -n "$GA" ]; then
    echo "Guard: handshake ${GA}s old (over ${GUARD_AGE}s): running the ifup hook" >&3
  else
    echo "Guard: the interface is up without a handshake: running the ifup hook" >&3
  fi
  if [ -n "$GA" ]; then GAN="handshake ${GA}s old: ifup hook run"; else GAN="no handshake: ifup hook run"; fi
  history_add guard stale "$(sget "network.$PIAWG_PEER.endpoint_host")" "" "" "$GAN"
  if [ -x "$HOOKFILE" ]; then
    ACTION=ifup INTERFACE="$PIAWG_IF" "$HOOKFILE"
  else
    /bin/sh "$SCRIPTPATH" hook ifup "$PIAWG_IF" >/dev/null 2>&1 &
  fi
  return 0
}

guard_install() {
  grep -qF "/bin/sh $SCRIPTPATH guard $CRON_TAG_GUARD" /etc/crontabs/root 2>/dev/null && return 0
  {
    crontab -l 2>/dev/null | grep -vF "$CRON_TAG_GUARD"
    echo "* * * * * /bin/sh $SCRIPTPATH guard $CRON_TAG_GUARD"
  } | crontab -
  echo "[$(date)] Guard installed" >>"$PIALOG"
}

guard_remove() {
  guard_installed || return 0
  crontab -l | grep -vF "$CRON_TAG_GUARD" | crontab -
  echo "[$(date)] Guard removed" >>"$PIALOG"
}

hook_content() {
  cat <<EOF
#!/bin/sh
# Installed by pia_wg.sh ('renew install'): keeps the PIA session ready and
# pins the endpoint route when the PIA interface goes up.
# One run at a time (lock directory, like the chrony hook): an event that
# arrives meanwhile is queued and handled by the run in progress. The work is
# done by a second process (this file with 'run'), in the background, because
# the hotplug events are handled one at a time.
if [ "\$1" != run ]; then
  [ "\$ACTION" = ifup ] || exit 0
  /bin/sh '$HOOKFILE' run "\$ACTION" "\$INTERFACE" >/dev/null 2>&1 &
  exit 0
fi
EV="\$2 \$3"
RUN='$RUNDIR'
LOCKDIR="\$RUN/hook.lock"
QUEUE="\$RUN/hook.queue"
umask 077
mkdir -p "\$RUN"
trap 'rm -rf "\$LOCKDIR"' EXIT INT TERM HUP
while [ -n "\$EV" ]; do
  if ! mkdir "\$LOCKDIR" 2>/dev/null; then
    HP="\$(cat "\$LOCKDIR/pid" 2>/dev/null)"
    [ -n "\$HP" ] || { sleep 1; HP="\$(cat "\$LOCKDIR/pid" 2>/dev/null)"; }
    if [ -n "\$HP" ] && kill -0 "\$HP" 2>/dev/null; then
      echo "\$EV" >>"\$QUEUE"
      trap - EXIT
      exit 0
    fi
    rm -rf "\$LOCKDIR"
    mkdir "\$LOCKDIR" 2>/dev/null || { trap - EXIT; exit 0; }
  fi
  echo \$\$ >"\$LOCKDIR/pid"
  while [ -n "\$EV" ]; do
    /bin/sh "$SCRIPTPATH" hook \$EV
    EV="\$(sort -u "\$QUEUE" 2>/dev/null | head -n 1)"
    [ -z "\$EV" ] || { grep -vxF "\$EV" "\$QUEUE" >"\$QUEUE.n"; mv "\$QUEUE.n" "\$QUEUE"; }
  done
  rm -rf "\$LOCKDIR"
  # an event queued while the lock was being released
  EV="\$(sort -u "\$QUEUE" 2>/dev/null | head -n 1)"
  [ -z "\$EV" ] || { grep -vxF "\$EV" "\$QUEUE" >"\$QUEUE.n"; mv "\$QUEUE.n" "\$QUEUE"; }
done
EOF
}

# Files kept by a firmware upgrade or a LuCI backup (/etc/sysupgrade.conf). The
# configuration (/etc/config/pia, network, firewall) and the cron entries are
# kept by OpenWrt already; the session key, the cache and the log are not wanted.
SYSUPG='/etc/sysupgrade.conf'
backup_paths() {
  case "$1" in
  core) printf '%s\n' "$SCRIPTPATH" "$HOOKFILE" ;;
  luci) printf '%s\n' /www/luci-static/resources/view/pia/ /usr/share/luci/menu.d/luci-app-pia.json /usr/share/rpcd/acl.d/luci-app-pia.json /usr/share/rpcd/ucode/luci.pia ;;
  esac
}
# Add the missing lines in one write (nothing is written when all are there)
backup_add() {
  BKNEW=''
  for BKP in $(backup_paths "$1"); do
    grep -qxF "$BKP" "$SYSUPG" 2>/dev/null || BKNEW="$BKNEW$BKP
"
  done
  [ -n "$BKNEW" ] || return 0
  {
    grep -qxF '## PIA VPN (kept by pia.sh)' "$SYSUPG" 2>/dev/null || printf '\n## PIA VPN (kept by pia.sh)\n'
    printf '%s' "$BKNEW"
  } >>"$SYSUPG"
}
backup_remove() {
  [ -f "$SYSUPG" ] || return 0
  BKTMP="$RUNDIR/sysupgrade.$$"
  backup_paths "$1" >"$BKTMP.rm"
  # the script's own line stays (it was listed before this version managed it)
  grep -vxFf "$BKTMP.rm" "$SYSUPG" >"$BKTMP"
  cmp -s "$BKTMP" "$SYSUPG" || cat "$BKTMP" >"$SYSUPG"
  rm -f "$BKTMP" "$BKTMP.rm"
}

hook_install() {
  [ "$(hook_content)" = "$(cat "$HOOKFILE" 2>/dev/null)" ] && return 0
  hook_content >"$HOOKFILE.new" && chmod 755 "$HOOKFILE.new" && mv "$HOOKFILE.new" "$HOOKFILE"
}

renew_install() {
  hook_install
  backup_add core
  watchdog_strip
  guard_install
  grep -qF "/bin/sh $SCRIPTPATH renew $CRON_TAG_RENEW" /etc/crontabs/root 2>/dev/null && return 0
  {
    crontab -l 2>/dev/null | grep -vF "$CRON_TAG_RENEW"
    echo "47 */6 * * * /bin/sh $SCRIPTPATH renew $CRON_TAG_RENEW"
  } | crontab -
  echo "[$(date)] Renew installed" >>"$PIALOG"
}

renew_remove() {
  rm -f "$HOOKFILE"
  grep -qxF "$HOOKFILE" "$SYSUPG" 2>/dev/null && grep -vxF "$HOOKFILE" "$SYSUPG" >"$RUNDIR/sysupgrade.$$" && cat "$RUNDIR/sysupgrade.$$" >"$SYSUPG"
  rm -f "$RUNDIR/sysupgrade.$$"
  guard_remove
  renew_installed || return 0
  crontab -l | grep -vF "$CRON_TAG_RENEW" | crontab -
  echo "[$(date)] Renew removed" >>"$PIALOG"
}

# Called by the hotplug hook: hook ifup|ifdown <interface that changed>
# (the endpoint route is deliberately left in place when the interface goes
# down, so that the next ifup finds it)
# Once per boot, at the first interface that comes up: bring up the interfaces that have
# a boot delay when the router has been up for that many seconds (netifd does not
# start them: their network auto is 0)
boot_delay_run() {
  mkdir "$RUNDIR/boot.delay" 2>/dev/null || return 0
  BDUP="$(cut -d. -f1 /proc/uptime)"
  for BDX in $(iface_list); do
    [ "$(uci -q get "pia.$BDX.iface_auto")" = '1' ] || continue
    BDD="$(uci -q get "pia.$BDX.boot_delay")"
    [ "${BDD:-0}" -gt 0 ] 2>/dev/null || continue
    BDW=$((BDD - BDUP))
    [ "$BDW" -gt 0 ] || BDW=0
    echo "Boot: $BDX is brought up in ${BDW}s (${BDD}s after boot)" >&3
    (
      sleep "$BDW"
      [ "$(ubus call "network.interface.$BDX" status 2>/dev/null | jsonfilter -e '@.up')" = 'true' ] || ifup "$BDX"
    ) >/dev/null 2>&1 3>&- &
  done
}

hook_cmd() {
  case "$1" in
  ifup) ;;
  *) return 0 ;;
  esac
  boot_delay_run
  if iface_exists "$2"; then
    PIAWG_IF="$2"
    set_ifvars
    HEP="$(sget "network.$PIAWG_PEER.endpoint_host")"
    [ -n "$HEP" ] && endpoint_route "$HEP" pin
    # up with nothing registered: make the session, which restarts it
    session_staged || /bin/sh "$SCRIPTPATH" -i "$PIAWG_IF" renew --if-missing --apply
    CONFIRM_BY="ifup $2" /bin/sh "$SCRIPTPATH" -i "$PIAWG_IF" confirm
    mtu_sync
  else
    # another interface: a WAN that came back may need our session and a new gateway
    for HX in $(iface_list); do
      # a tunnel that netifd brought up before there was a session (no key,
      # no handshake) has to be restarted to take it: it gets no ifup event
      PIAWG_IF="$HX"
      set_ifvars
      HXA=''
      handshake_age >/dev/null 2>&1 || HXA='--apply'
      /bin/sh "$SCRIPTPATH" -i "$HX" renew --if-missing $HXA
      HEP="$(sget "network.$PIAWG_PEER.endpoint_host")"
      [ -n "$HEP" ] && endpoint_route "$HEP" pin
      CONFIRM_BY="ifup $2" /bin/sh "$SCRIPTPATH" -i "$HX" confirm
      mtu_sync
    done
  fi
  return 0
}

# The watchdog (a cron entry per interface running 'start --cron': it restarted a
# tunnel that was down or did not answer) is retired: the guard replaces it and
# only mends a stale tunnel (it never brings an interface up or down). Its
# entries are removed whenever seen; the commands remain as aliases.
watchdog_strip() {
  grep -qF "$CRON_TAG_WD" /etc/crontabs/root 2>/dev/null || return 0
  crontab -l | grep -vF "$CRON_TAG_WD" | crontab -
  echo "[$(date)] Watchdog entries removed (the guard replaces them)" >>"$PIALOG"
}

watchdog_install() {
  echo "The watchdog is retired: the guard (cron, every minute) replaces it" >&3
  watchdog_strip
  guard_install
}

log_show() {
  [ -s "$PIALOG" ] && cat "$PIALOG" || echo "Log is empty!"
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

# ---- LuCI app (luci/ of the repository): Services > PIA VPN

LUCI_FILES='htdocs/luci-static/resources/view/pia/overview.js:/www/luci-static/resources/view/pia/overview.js
root/usr/share/luci/menu.d/luci-app-pia.json:/usr/share/luci/menu.d/luci-app-pia.json
root/usr/share/rpcd/acl.d/luci-app-pia.json:/usr/share/rpcd/acl.d/luci-app-pia.json
root/usr/share/rpcd/ucode/luci.pia:/usr/share/rpcd/ucode/luci.pia'

luci_reload() {
  rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
  /etc/init.d/rpcd restart >/dev/null 2>&1
}

# Install the web interface: from the luci/ directory next to the script if
# there is one, else downloaded from the repository the script comes from
# The unattended jobs a deployment needs (cache refresh and renew, as cron
# entries, plus the ifup hook and the guard): installed when missing; a retired
# watchdog's entries are removed
jobs_deploy() {
  cache_installed || {
    cache_install && echo "Cache refresh (cron) installed"
  }
  renew_installed || {
    renew_install && echo "Renew (cron, ifup hook, guard) installed"
  }
  # (renew_install makes the guard too; one added to an older deployment)
  watchdog_strip
  guard_installed || guard_install
  return 0
}

luci_install() {
  LIBASE="${SCRIPTDL%/*}/luci"
  LILOCAL="${SCRIPTPATH%/*}/luci"
  LITMP="$RUNDIR/luci.$$"
  mkdir -p "$LITMP"
  LIN=0
  for LIX in $LUCI_FILES; do
    LISRC="${LIX%%:*}"
    LIN=$((LIN + 1))
    if [ -f "$LILOCAL/$LISRC" ]; then
      cp "$LILOCAL/$LISRC" "$LITMP/$LIN"
    else
      curl -sfL --max-time 30 -o "$LITMP/$LIN" "$LIBASE/$LISRC" || {
        echo "Failed to download $LISRC" >&2
        rm -rf "$LITMP"
        exit 1
      }
    fi
    # a page of the web server, an error message or an empty file is no app file
    if [ ! -s "$LITMP/$LIN" ] || head -c 64 "$LITMP/$LIN" | grep -q -i '<html\|<!doctype\|404'; then
      echo "$LISRC is not valid" >&2
      rm -rf "$LITMP"
      exit 1
    fi
  done
  LIN=0
  for LIX in $LUCI_FILES; do
    LIN=$((LIN + 1))
    LIDST="${LIX#*:}"
    mkdir -p "${LIDST%/*}"
    sed "s|/usr/bin/pia.sh|$SCRIPTPATH|g" "$LITMP/$LIN" >"$LIDST"
  done
  rm -rf "$LITMP"
  backup_add luci
  luci_reload
  jobs_deploy
  echo "LuCI app installed: Services > PIA VPN (log in to LuCI again)"
}

luci_remove() {
  for LIX in $LUCI_FILES; do rm -f "${LIX#*:}"; done
  rmdir /www/luci-static/resources/view/pia 2>/dev/null
  backup_remove luci
  luci_reload
  echo "LuCI app removed"
}

# Install the cron jobs requested with --watchdog and/or --cache
install_jobs() {
  shift
  for A in "$@"; do
    case "$A" in
    '--watchdog') guard_install ;;
    '--cache') cache_install ;;
    esac
  done
}

print_usage() {
  echo "Usage: $0 [ -i <interface|all> ] { configure <section> | start [ --watchdog ] [ --cache ] | restart [ --watchdog ] [ --cache ] | stop | status | renew [ --force | --new-key | --apply ] | renew { install | remove } | watchdog { install | remove } (aliases of the guard) | cache { refresh | install | remove | show | probe } | history probe [ --rounds N ] [ --delay S ] REGION|COUNTRY... | log { show | clear | path } | update | version}"
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
  echo "    - configure protocol : AmneziaWG, WireGuard or automatic for the interface (asked when it is created)"
  echo "    - configure dns      : PIA DNS, PIA with MACE or a custom DNS server (asked when the interface is created)"
  echo "    - configure mtu      : default, small or custom packet size (asked when the interface is created)"
  echo "    - configure keepalive: default (25), disabled or custom keepalive (asked when the interface is created)"
  echo "    - configure rename <name>    : rename the interface (-i old)"
  echo "    - configure remove <name>    : forget an interface (config, network sections, cron)"
  echo "    - configure cache    : set offline cache directory and options"
  echo "    - configure network  : generate default network settings (and ask about the default route)"
  echo "    - configure route    : default route through the interface (none with several PIA interfaces)"
  echo "    - configure firewall : firewall zone, NAT and the zones forwarded to the interface"
  echo "    - init-network       : setup PIA WireGuard network (no start)"
  echo "    - start              : start PIA WireGuard (if not already up)"
  echo "    - start --watchdog   : same as start and install the guard (the watchdog is retired)"
  echo "    - restart            : start or restart PIA WireGuard"
  echo "    - restart --watchdog : same as restart and install the guard"
  echo "    - start|restart --cache : same and install the cache refresh"
  echo "    - stop               : stop PIA WireGuard"
  echo "    - status             : show PIA WireGuard status"
  echo "    - renew              : register the session key again (never starts or stops the tunnel; skipped while it is up)"
  echo "    - renew --force      : register even if the tunnel is up (the key is re-added on the server)"
  echo "    - renew --new-key    : register a new key (needs --apply if the interface is up: it is restarted)"
  echo "    - renew install      : install the renew cron (every 6 hours, all interfaces), the guard cron (every minute) and the ifup hook; removes the watchdogs"
  echo "    - renew remove       : remove the renew cron and the hook"
  echo "    - watchdog install   : alias of the guard install (the watchdog is retired)"
  echo "    - watchdog remove    : remove the guard (and any old watchdog entry)"
  echo "    - cache refresh      : refresh the offline cache (servers list, meta servers, tokens)"
  echo "    - cache install      : install the cache refresh (cron, every 6 hours)"
  echo "    - cache remove       : remove the cache refresh"
  echo "    - cache show         : show the offline cache"
  echo "    - cache probe [CC]   : check which regions (of the country CC) need the legacy token"
  echo "    - log show           : display the log"
  echo "    - log clear          : clear the log"
  echo "    - log path           : set a custom Directory Path for the log"
  echo "    - luci install       : install the LuCI web interface (Services > PIA VPN); luci remove removes it"
  echo "    - update             : update the script to latest version"
  echo "    - version            : print the version and exit"
}

# ---- api: machine readable commands (JSON on stdout) for the LuCI app
# (luci-app-pia talks to them through /usr/libexec/rpcd/pia). Nothing is asked.

api_fail() {
  jq -nc --arg e "$1" '{ok: false, error: $e}'
  exit 0
}

api_ok() { echo '{"ok":true}'; }

# The state of the job started by 'api job' ($1: the interface or _global)
api_job_json() {
  AJS="$RUNDIR/job.$1"
  if [ -s "$AJS" ]; then
    read -r AJST AJRC AJTS AJCMD <"$AJS"
    if [ "$AJST" = 'running' ] && [ "$AJRC" -gt 0 ] && ! kill -0 "$AJRC" 2>/dev/null; then
      AJST='died'
    fi
    jq -nc --arg s "$AJST" --arg c "$AJCMD" --arg t "$AJTS" --arg rc "$AJRC" --rawfile o "$AJS.out" \
      '{state: $s, cmd: $c, since: ($t | tonumber? // 0), rc: (if $s == "done" then ($rc | tonumber? // null) else null end),
        output: ($o | split("\n") | map(select(. != "" and (startswith("{\"ok\":") | not))) | .[-12:])}' 2>/dev/null ||
      echo null
  else
    echo null
  fi
}

# One interface of the config as JSON
api_iface_json() {
  PIAWG_IF="$1"
  set_ifvars
  AIUP=false
  AIHS=''
  AIEP=''
  if wgt "$PIAWG_IF" show "$PIAWG_IF" >/dev/null 2>&1; then
    AIUP=true
    AIHS="$(handshake_age)"
    AIEP="$(wgt "$PIAWG_IF" show "$PIAWG_IF" endpoints 2>/dev/null | awk '{print $2; exit}')"
  fi
  AIDR=0
  has_default_route "$PIAWG_IF" && AIDR=1
  AIAUTO=0
  proto_is_auto "$PIAWG_IF" && AIAUTO=1
  AIMACE=0
  dns_mace && AIMACE=1
  AICUSTOM=0
  dns_custom && AICUSTOM=1
  jq -nc --arg name "$PIAWG_IF" \
    --arg rid "$(uci -q get "pia.$PIAWG_IF.region_id")" \
    --arg rname "$(uci -q get "pia.$PIAWG_IF.region_name")" \
    --arg rdns "$(uci -q get "pia.$PIAWG_IF.region_dns")" \
    --arg rcountry "$(uci -q get "pia.$PIAWG_IF.region_country")" \
    --arg fast "$(uci -q get "pia.$PIAWG_IF.region_fast")" \
    --arg proto "$PIAPROTO" --argjson auto "$AIAUTO" \
    --arg dnsip "$(dns_hosts)" --argjson mace "$AIMACE" \
    --arg mtu "$(uci -q get "pia.$PIAWG_IF.iface_mtu")" \
    --arg mtuauto "$(mtu_is_auto && echo 1)" \
    --arg mturun "$([ "$AIUP" = true ] && cat "/sys/class/net/$PIAWG_IF/mtu" 2>/dev/null)" \
    --arg keep "$(uci -q get "pia.$PIAWG_IF.peer_persistent_keepalive")" \
    --argjson custom "$AICUSTOM" \
    --argjson route "$AIDR" \
    --arg fw "$(uci -q get "pia.$PIAWG_IF.fw_zone")" \
    --arg fwd "$(uci -q get "pia.$PIAWG_IF.fw_forward")" \
    --arg dip "$(uci -q get "pia.$PIAWG_IF.dip_token")" \
    --arg boot "$(uci -q get "pia.$PIAWG_IF.iface_auto")" \
    --arg bdelay "$(uci -q get "pia.$PIAWG_IF.boot_delay")" \
    --arg msszone "$(fw_iface_zone)" --argjson mssok "$(mss_clamp >/dev/null && echo true || echo false)" \
    --arg kse "$(uci -q get "pia.$PIAWG_IF.ks_enable")" \
    --arg ksb "$(uci -q get "pia.$PIAWG_IF.ks_wan")" \
    --arg ksl "$(ks_leaks | tr '\n' ' ')" \
    --arg pfe "$(uci -q get "pia.$PIAWG_IF.pf_enable")" \
    --arg pfip "$(uci -q get "pia.$PIAWG_IF.pf_ip")" \
    --arg pfdp "$(uci -q get "pia.$PIAWG_IF.pf_port")" \
    --arg pfport "$([ "$AIUP" = true ] && awk '{print $1; exit}' "$(pf_statefile)" 2>/dev/null)" \
    --arg pfcap "$(jq -r --arg r "$(uci -q get "pia.$PIAWG_IF.region_id")" '.regions[] | select(.id == $r) | .port_forward' "$(cache_dir)/servers.json" 2>/dev/null)" \
    --argjson up "$AIUP" --arg hs "$AIHS" --arg ep "$AIEP" \
    --argjson job "$(api_job_json "$PIAWG_IF")" \
    '{name: $name,
      region: {id: $rid, name: $rname, country: $rcountry},
      fast: ($fast == "1"), proto: $proto, auto: ($auto == 1),
      dns: (if $custom == 1 then "custom" elif $mace == 1 then "mace" else "standard" end), dns_ip: $dnsip,
      streaming: ($rdns | contains("-so.")),
      mtu: ($mtu | tonumber? // null), mtu_auto: ($mtuauto == "1"), mtu_run: ($mturun | tonumber? // null), keepalive: ($keep | tonumber? // null), default_route: ($route == 1),
      firewall: ($fw == "1"), forward: ($fwd | split(" ") | map(select(. != ""))),
      dip: ($dip != ""), boot: ($boot == "1"), boot_delay: ($bdelay | tonumber? // 0),
      mss: {zone: $msszone, clamp: $mssok},
      killswitch: {enabled: ($kse == "1"), wan: ($ksb | split(" ") | map(select(. != ""))), leaks: ($ksl | split(" ") | map(select(. != "")))},
      portfwd: {enabled: ($pfe == "1"), ip: $pfip, dest_port: ($pfdp | tonumber? // null), port: ($pfport | tonumber? // null), capable: ($pfcap != "false")}, up: $up, handshake: ($hs | tonumber? // null),
      endpoint: ($ep | if . == "" then null else . end), job: $job}'
}

api_status() {
  AZONES="$(uci -q show firewall | sed -n "s/^firewall\\.[^.]*\\.name='\\([^']*\\)'\$/\\1/p" | tr '\n' ' ')"
  ACD="$(cache_dir)"
  ASERV="$ACD/servers.json"
  ASN=0
  ASTS=0
  ASCK=0
  if [ -s "$ASERV" ]; then
    ASN="$(jq '.regions | length' "$ASERV" 2>/dev/null)"
    ASTS="$(date -r "$ASERV" +%s 2>/dev/null)"
    ASCK="$(date -r "$ACD/servers.checked" +%s 2>/dev/null)"
  fi
  ARAM=0
  [ "$ACD" = "$CACHERAMDIR" ] && ARAM=1
  ACRON=0
  cache_installed && ACRON=1
  AMETA="$(grep -c . "$ACD/meta.list" 2>/dev/null)"
  AAWG=0
  awg_available && AAWG=1
  # dnsmasq instances still without strict-order (those using only their own servers are skipped)
  ASTRICT=1
  for DSX in $(uci -q show dhcp | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p'); do
    [ "$(uci -q get "dhcp.$DSX.noresolv")" = '1' ] && continue
    [ "$(uci -q get "dhcp.$DSX.strictorder")" = '1' ] || ASTRICT=0
  done
  {
    for AX in $(iface_list); do api_iface_json "$AX"; done
  } | jq -sc --arg version "$CURVERS" --argjson awg "$AAWG" --argjson strict "$ASTRICT" \
    --arg id "$(uci -q get pia.account.id)" --arg pw "$(uci -q get pia.account.password)" \
    --arg apiexp "$(uci -q get pia.apitoken.expires)" --arg vpnexp "$(uci -q get pia.vpntoken.expires)" \
    --arg zones "$AZONES" --arg lan "$(fw_lan_zone)" --arg wans "$(fw_wan_zones | tr '\n' ' ')" --argjson hook "$([ -x "$HOOKFILE" ] && echo true || echo false)" --arg vpns "$(fw_vpn_zones | tr '\n' ' ')" --arg brwans "$(fw_zone_of_dev br-wan | tr '\n' ' ')" --arg masqs "$(fw_masq_zones | tr '\n' ' ')" --arg stdmtu "$(std_mtu)" \
    --arg small "$PIA_MTU_SMALL" --arg max "$PIA_MTU_MAX" \
    --arg dns "$PIA_DNS" --arg dnsso "$PIA_DNS_SO" --arg dnsmace "$PIA_DNS_MACE" --arg dnssomace "$PIA_DNS_SO_MACE" \
    --argjson regions "${ASN:-0}" --arg listts "${ASTS:-0}" --arg checked "${ASCK:-0}" \
    --arg cdir "$ACD" --arg cpath "$(uci -q get pia.cache.dir || echo "$CACHEDEFDIR")" --argjson cram "$ARAM" --argjson ccron "$ACRON" --arg cmeta "${AMETA:-0}" \
    --argjson job "$(api_job_json _global)" --argjson probe "$(api_job_json _probe)" \
    '{version: $version, awg: ($awg == 1), strict_dns: ($strict == 1),
      account: {id: $id, password_set: ($pw != ""), api_expires: ($apiexp | tonumber? // null), vpn_expires: ($vpnexp | tonumber? // null)},
      zones: ($zones | split(" ") | map(select(. != ""))), lan_zone: $lan, hook: $hook, wan_zones: ($wans | split(" ") | map(select(. != ""))), vpn_zones: ($vpns | split(" ") | map(select(. != ""))), brwan_zones: ($brwans | split(" ") | map(select(. != ""))), masq_zones: ($masqs | split(" ") | map(select(. != ""))),
      std_mtu: ($stdmtu | tonumber), small_mtu: ($small | tonumber), max_mtu: ($max | tonumber),
      dns_servers: {standard: $dns, streaming: $dnsso, mace: $dnsmace, streaming_mace: $dnssomace},
      cache: {regions: $regions, updated: ($listts | tonumber? // 0), checked: ($checked | tonumber? // 0),
              dir: $cdir, path: $cpath, ram: ($cram == 1), cron: ($ccron == 1), meta: ($cmeta | tonumber? // 0)},
      job: $job, probe: $probe, now: (now | floor), interfaces: .}'
}

# api_regions <wireguard|amneziawg>: the regions that have servers of that protocol
api_regions() {
  case "$1" in
  amneziawg) ARG='awg' ;;
  *) ARG='wg' ;;
  esac
  ASERV="$(cache_dir)/servers.json"
  [ -s "$ASERV" ] || api_fail "No servers list: refresh it first"
  jq -c --arg g "$ARG" --arg l "$(legacy_ids)" '
    [.regions[] | select(.offline == false) | select(.servers[$g]) | .id as $i |
     {id, name, country, dns, port_forward, geo,
      streaming: ((.name | contains("Streaming")) or (.dns | contains("-so."))),
      legacy: (($g == "wg") and (($l | split(" ")) | index($i) != null))}] | sort_by(.name)' \
    "$ASERV" 2>/dev/null || api_fail "The servers list is unreadable"
}

# api_account: the user id on the first line of the input, the password on the second
api_account() {
  read -r AAID
  read -r AAPW
  read -r AAPATH || AAPATH=''
  [ -n "$AAID" ] || api_fail "The user ID is needed"
  # no password given: the stored one is kept
  if [ -z "$AAPW" ]; then
    uci -q get pia.account.password >/dev/null || api_fail "User ID and password are both needed"
    [ "$AAID" = "$(uci -q get pia.account.id)" ] || api_fail "Enter the password with the new user ID"
  fi
  if [ -n "$AAPATH" ]; then
    case "$AAPATH" in /*) ;; *) api_fail "The cache path must be absolute" ;; esac
    case "$AAPATH" in *[!A-Za-z0-9_./-]* | *..*) api_fail "The cache path may hold letters, digits and _ . / - only" ;; esac
    AAPATH="$(echo "$AAPATH" | sed 's#//*#/#g; s#\(.\)/$#\1#')"
  fi
  AACH=''
  uci -q get pia.account >/dev/null || uci -q set pia.account=account
  [ "$AAID" = "$(uci -q get pia.account.id)" ] || {
    uci -q set "pia.account.id=$AAID"
    AACH=1
  }
  [ -z "$AAPW" ] || [ "$AAPW" = "$(uci -q get pia.account.password)" ] || {
    uci -q set "pia.account.password=$AAPW"
    AACH=1
  }
  # the cache folder: its files are copied over (the old ones stay where they are)
  AAOLD=''
  if [ -n "$AAPATH" ] && [ "$AAPATH" != "$(uci -q get pia.cache.dir || echo "$CACHEDEFDIR")" ]; then
    AAOLD="$(cache_dir)"
    uci -q get pia.cache >/dev/null || uci -q set pia.cache=cache
    uci -q set "pia.cache.dir=$AAPATH"
    AACH=1
  fi
  [ -z "$AACH" ] || uci -q commit pia
  if [ -n "$AAOLD" ]; then
    AANEW="$(cache_dir)"
    if [ "$AANEW" != "$AAOLD" ]; then
      for AAF in servers.json servers.checked meta.list legacy.list ca.rsa.4096.crt; do
        [ -e "$AAOLD/$AAF" ] && [ ! -e "$AANEW/$AAF" ] && cp -p "$AAOLD/$AAF" "$AANEW/$AAF"
      done
    fi
  fi
  api_ok
}

# api_relogin: log in with the stored account (fresh tokens)
api_relogin() {
  uci -q get pia.account.id >/dev/null || api_fail "No account is configured"
  uci -q delete pia.apitoken
  uci -q delete pia.vpntoken
  uci -q commit pia
  if pia_tokens renew; then api_ok; else api_fail "PIA login failed: check the user id and the password"; fi
}

# api_job <key> <script arguments…>: run the script in the background, state in
# $RUNDIR/job.<key> (running|done <pid|rc> <epoch> <command>), output in .out
api_job() {
  AJK="$1"
  shift
  case "$AJK" in
  _global | _probe) ;;
  *) valid_ifname "$AJK" || api_fail "Invalid interface name" ;;
  esac
  case "$*" in
  "-i $AJK start" | "-i $AJK restart" | "-i $AJK stop" | "-i $AJK renew --force" | 'cache refresh' | 'api refresh-list' | 'api login') ;;
  'cache probe '[A-Z][A-Z]) [ "$AJK" = '_probe' ] || api_fail "Command not allowed" ;;
  *) api_fail "Command not allowed" ;;
  esac
  AJF="$RUNDIR/job.$AJK"
  if [ -s "$AJF" ]; then
    read -r AJST AJPID AJTS _ <"$AJF"
    if [ "$AJST" = 'running' ]; then
      if [ "$AJPID" -gt 0 ] && kill -0 "$AJPID" 2>/dev/null; then api_fail "Busy: a command is still running"; fi
      [ "$AJPID" -gt 0 ] || [ $(($(date +%s) - AJTS)) -gt 10 ] || api_fail "Busy: a command is starting"
    fi
  fi
  echo "running 0 $(date +%s) $*" >"$AJF"
  : >"$AJF.out"
  /bin/sh -c 'f="$1"; shift; c="$*"; echo "running $$ $(date +%s) $c" >"$f"; /bin/sh "$0" "$@" >"$f.out" 2>&1; echo "done $? $(date +%s) $c" >"$f"' \
    "$SCRIPTPATH" "$AJF" "$@" </dev/null >/dev/null 2>&1 &
  api_ok
}

# api_iface_save <name> [key=value…]: create or modify an interface
#   proto=amneziawg|wireguard|auto  region=<id>  fast=0|1  dns=standard|mace|custom
#   dns_ip=<IPv4 of a custom DNS server>  mtu=std|small|<1280-1420>
#   keepalive=default|off|<1-65535>  route=yes|no  firewall=yes|no
#   killswitch=yes|no  ks_wan="<zones>" (the WAN zones: the forwardings from the allowed zones to these are removed; default the br-wan zone)
#   portfwd=yes|no  pf_ip=<IPv4 behind the router>  pf_port=<port there; empty: the forwarded one>
#   boot=yes|no (netifd starts it at boot)  boot_delay=<0-3600 seconds after boot: the hook starts it instead>  forward="<zones>"  strict=no (leave dnsmasq strict-order alone; it otherwise follows the default route)
api_iface_save() {
  AN="$1"
  shift
  valid_ifname "$AN" || api_fail "Invalid name: 1 to 15 letters, digits or underscore, and not one of:$RESERVED_NAMES"
  A_PROTO='' A_REGION='' A_FAST='' A_DNS='' A_DNSIP='' A_MTU='' A_KEEP='' A_ROUTE='' A_FW='' A_FWD='' A_STRICT='' A_FWDSET='' A_BOOT='' A_PF='' A_PFIP='' A_PFPORT='' A_PFSET='' A_KS='' A_KSB='' A_KSSET='' A_BD='' A_BDSET=''
  for AKV in "$@"; do
    AV="${AKV#*=}"
    case "$AKV" in
    proto=*) A_PROTO="$AV" ;;
    region=*) A_REGION="$AV" ;;
    fast=*) A_FAST="$AV" ;;
    dns=*) A_DNS="$AV" ;;
    dns_ip=*) A_DNSIP="$AV" ;;
    mtu=*) A_MTU="$AV" ;;
    keepalive=*) A_KEEP="$AV" ;;
    route=*) A_ROUTE="$AV" ;;
    firewall=*) A_FW="$AV" ;;
    forward=*)
      A_FWD="$AV"
      A_FWDSET=1
      ;;
    strict=*) A_STRICT="$AV" ;;
    boot=*) A_BOOT="$AV" ;;
    boot_delay=*)
      A_BD="$AV"
      A_BDSET=1
      ;;
    portfwd=*) A_PF="$AV" ;;
    killswitch=*) A_KS="$AV" ;;
    ks_wan=*)
      A_KSB="$AV"
      A_KSSET=1
      ;;
    pf_ip=*)
      A_PFIP="$AV"
      A_PFSET=1
      ;;
    pf_port=*)
      A_PFPORT="$AV"
      A_PFSET=1
      ;;
    *) api_fail "Unknown setting '${AKV%%=*}'" ;;
    esac
  done
  case "$A_PROTO" in '' | amneziawg | wireguard | auto) ;; *) api_fail "Invalid protocol" ;; esac
  case "$A_FAST" in '' | 0 | 1) ;; *) api_fail "Invalid fast region value" ;; esac
  case "$A_DNS" in '' | standard | mace | custom) ;; *) api_fail "Invalid DNS choice" ;; esac
  if [ "$A_DNS" = 'custom' ] || [ -n "$A_DNSIP" ]; then
    valid_ipv4 "$A_DNSIP" || api_fail "Invalid DNS server: an IPv4 address"
    [ "$A_DNS" = 'custom' ] || api_fail "A DNS server address needs the custom DNS choice"
  fi
  case "$A_ROUTE" in '' | yes | no) ;; *) api_fail "Invalid route choice" ;; esac
  case "$A_FW" in '' | yes | no) ;; *) api_fail "Invalid firewall choice" ;; esac
  case "$A_STRICT" in '' | yes | no) ;; *) api_fail "Invalid strict-order choice" ;; esac
  case "$A_BOOT" in '' | yes | no) ;; *) api_fail "Invalid boot choice" ;; esac
  case "$A_PF" in '' | yes | no) ;; *) api_fail "Invalid port forwarding choice" ;; esac
  case "$A_BD" in
  '') ;;
  *[!0-9]*) api_fail "Boot delay: digits only, 0 to 3600 seconds" ;;
  *) [ "$A_BD" -le 3600 ] || api_fail "Boot delay: digits only, 0 to 3600 seconds" ;;
  esac
  if [ "${A_BD:-0}" -gt 0 ]; then
    [ "$A_BOOT" != 'no' ] || api_fail "A boot delay needs Bring up on boot"
    [ -x "$HOOKFILE" ] || api_fail "A boot delay needs the ifup hook (pia.sh renew install): it brings the interface up"
  fi
  case "$A_KS" in '' | yes | no) ;; *) api_fail "Invalid kill switch choice" ;; esac
  for AZ in $A_KSB; do
    case "$AZ" in *[!A-Za-z0-9_-]*) api_fail "Invalid zone name" ;; esac
    [ -n "$(fw_zone_id "$AZ")" ] || api_fail "No firewall zone named '$AZ'"
  done
  # turned on (or left on): the firewall zone, a zone to allow forwarding from and a WAN zone are needed
  if [ "$A_KS" = 'yes' ] || { [ -z "$A_KS" ] && [ "$(uci -q get "pia.$AN.ks_enable")" = '1' ]; }; then
    [ "$A_KS" = 'no' ] || {
      AKFW="$(uci -q get "pia.$AN.fw_zone")"
      iface_exists "$AN" || AKFW=1
      [ "$A_FW" = 'yes' ] && AKFW=1
      [ "$A_FW" = 'no' ] && AKFW=0
      if [ -n "$A_FWDSET" ]; then AKSRC="$A_FWD"; else AKSRC="$(uci -q get "pia.$AN.fw_forward")"; fi
      [ -n "$AKSRC" ] || [ -n "$A_FWDSET" ] || iface_exists "$AN" || AKSRC="$(fw_lan_zone)"
      if [ -n "$A_KSSET" ]; then AKZ="$A_KSB"; else AKZ="$(uci -q get "pia.$AN.ks_wan")"; fi
      [ -n "$AKZ" ] || [ -n "$A_KSSET" ] || AKZ="$(fw_wan_default | tr '\n' ' ')"
      if [ "$A_FW" = 'no' ]; then
        [ "$A_KS" = 'yes' ] && api_fail "The kill switch needs the firewall zone"
        A_KS=no
      elif [ "$AKFW" != '1' ]; then
        api_fail "The kill switch needs the firewall zone"
      elif [ -z "$AKSRC" ]; then
        api_fail "The kill switch needs a zone to allow forwarding from"
      elif [ -z "${AKZ# }" ]; then
        api_fail "The kill switch needs a WAN zone"
      fi
    }
  fi
  [ -z "$A_PFIP" ] || valid_ipv4 "$A_PFIP" || api_fail "Destination IP address: an IPv4 address"
  case "$A_PFPORT" in
  '') ;;
  *[!0-9]*) api_fail "Destination port: digits only, 1 to 65535" ;;
  *) [ "$A_PFPORT" -ge 1 ] && [ "$A_PFPORT" -le 65535 ] || api_fail "Destination port: digits only, 1 to 65535" ;;
  esac
  case "$A_MTU" in
  '' | std | small) ;;
  *)
    # (a size set before the limit was lowered stays valid until it is changed)
    valid_mtu "$A_MTU" || [ "$A_MTU" = "$(uci -q get "pia.$AN.iface_mtu")" ] ||
      api_fail "Packet size: digits only, $PIA_MTU_MIN to $PIA_MTU_MAX"
    ;;
  esac
  case "$A_KEEP" in
  '' | default | off) ;;
  *) valid_keepalive "$A_KEEP" || api_fail "Keepalive: digits only, 1 to 65535" ;;
  esac
  for AZ in $A_FWD; do
    case "$AZ" in *[!A-Za-z0-9_-]*) api_fail "Invalid zone name" ;; esac
    [ -n "$(fw_zone_id "$AZ")" ] || api_fail "No firewall zone named '$AZ'"
  done
  if [ "$A_ROUTE" = 'yes' ]; then
    for AOT in $(iface_list | grep -vx "$AN"); do
      has_default_route "$AOT" && api_fail "$AOT already has the default route: remove it there first"
    done
  fi
  lock_take "api iface-save"
  AFIRST=''
  [ -n "$(iface_list)" ] || AFIRST=1
  AWNEW=''
  iface_exists "$AN" || AWNEW=1
  PIAWG_IF="$AN"
  set_ifvars
  # protocol
  AWMODE=''
  AWP=''
  case "$A_PROTO" in
  auto)
    awg_available || api_fail "AmneziaWG is not installed: automatic selection needs both protocols"
    AWMODE=auto
    AWP="$PIAPROTO"
    [ -n "$AWNEW" ] && AWP='amneziawg'
    ;;
  amneziawg)
    awg_available || api_fail "AmneziaWG is not installed (packages amneziawg-tools, kmod-amneziawg, luci-proto-amneziawg)"
    AWP="$A_PROTO"
    ;;
  wireguard) AWP="$A_PROTO" ;;
  *)
    if [ -n "$AWNEW" ]; then
      if awg_available; then AWP='amneziawg'; else AWP='wireguard'; fi
    fi
    ;;
  esac
  if [ "$AWP" = 'amneziawg' ] && uci -q get "pia.$AN.dip_token" >/dev/null; then
    api_fail "A dedicated IP needs WireGuard"
  fi
  # the region: from the servers list, with the servers of the protocol
  ASERV="$(cache_dir)/servers.json"
  if [ -n "$A_REGION" ]; then
    uci -q get "pia.$AN.dip_token" >/dev/null && api_fail "The region comes from the dedicated IP"
    PIAREGIONS="$(jq -e '.regions | sort_by(.name)' "$ASERV" 2>/dev/null)" || api_fail "No servers list: refresh it first"
    PIAREGIONID="$A_REGION"
    ARG='wg'
    [ "${AWP:-$PIAPROTO}" = 'amneziawg' ] && ARG='awg'
    echo "$PIAREGIONS" | jq -e --arg i "$A_REGION" --arg g "$ARG" '.[] | select(.id == $i and .offline == false and .servers[$g])' >/dev/null ||
      api_fail "Region '$A_REGION' has no ${AWP:-$PIAPROTO} servers"
  elif [ -n "$AWNEW" ] && ! uci -q get "pia.$AN.dip_token" >/dev/null; then
    api_fail "A region is needed"
  fi
  if [ -n "$AWNEW" ]; then
    set_iface "$AN" || api_fail "Could not create the interface"
    WZPROTO="$AWP"
    set_defnetiface
    set_defnetpeer
    iface_defaults
    if [ -z "$(others_list)" ]; then set_default_route yes; else set_default_route no; fi
    [ -n "$A_DNS" ] || A_DNS=standard
    [ -n "$A_MTU" ] || A_MTU=std
    [ -n "$A_FW" ] || A_FW=yes
    [ -n "$A_STRICT" ] || A_STRICT=yes
  elif [ -n "$AWP" ] && [ "$AWP" != "$PIAPROTO" ]; then
    switch_proto "$AWP"
  fi
  if [ "$AWMODE" = 'auto' ]; then
    uci -q set "pia.$AN.proto_mode=auto"
  elif [ -n "$A_PROTO" ]; then
    uci -q delete "pia.$AN.proto_mode"
  fi
  uci -q commit pia
  [ -z "$A_REGION" ] || store_region
  case "$A_FAST" in
  1) uci -q set "pia.$AN.region_fast=1" ;;
  0) uci -q delete "pia.$AN.region_fast" ;;
  esac
  case "$A_DNS" in
  standard | mace)
    dns_custom && uci -q delete "pia.$AN.iface_dns"
    uci -q set "pia.$AN.iface_mace=$([ "$A_DNS" = mace ] && echo 1 || echo 0)"
    ;;
  custom) uci -q set "pia.$AN.iface_dns=$A_DNSIP" ;;
  esac
  uci -q commit pia
  dns_apply
  # the PIA DNS host or the custom one is what the tunnel carries without the default route
  if [ -n "$A_DNS" ] && ! has_default_route "$AN"; then set_default_route no; fi
  case "$A_MTU" in
  std)
    uci -q set "pia.$AN.iface_mtu=$(std_mtu)"
    uci -q set "pia.$AN.mtu_auto=1"
    ;;
  small)
    uci -q set "pia.$AN.iface_mtu=$PIA_MTU_SMALL"
    uci -q set "pia.$AN.mtu_auto=0"
    ;;
  '') ;;
  *)
    uci -q set "pia.$AN.iface_mtu=$A_MTU"
    uci -q set "pia.$AN.mtu_auto=0"
    ;;
  esac
  case "$A_KEEP" in
  default) uci -q set "pia.$AN.peer_persistent_keepalive=$PIA_KEEPALIVE" ;;
  off) uci -q set "pia.$AN.peer_persistent_keepalive=0" ;;
  '') ;;
  *) uci -q set "pia.$AN.peer_persistent_keepalive=$A_KEEP" ;;
  esac
  uci -q commit pia
  case "$A_ROUTE" in
  yes) has_default_route "$AN" || set_default_route yes ;;
  no) ! has_default_route "$AN" || set_default_route no ;;
  esac
  # the firewall zone, NAT and forwardings
  case "$A_FW" in
  yes)
    uci -q set "pia.$AN.fw_zone=1"
    if [ -n "$A_FWDSET" ]; then
      uci -q delete "pia.$AN.fw_forward"
      for AZ in $A_FWD; do uci -q add_list "pia.$AN.fw_forward=$AZ"; done
    elif [ -n "$AWNEW" ]; then
      for AZ in $(fw_lan_zone); do uci -q add_list "pia.$AN.fw_forward=$AZ"; done
    fi
    uci -q commit pia
    fw_apply >&3
    ;;
  no)
    uci -q delete "pia.$AN.fw_zone"
    uci -q delete "pia.$AN.fw_forward"
    uci -q commit pia
    ;;
  '')
    if [ -n "$A_FWDSET" ] && [ "$(uci -q get "pia.$AN.fw_zone")" = '1' ]; then
      uci -q delete "pia.$AN.fw_forward"
      for AZ in $A_FWD; do uci -q add_list "pia.$AN.fw_forward=$AZ"; done
      uci -q commit pia
      fw_apply >&3
    fi
    ;;
  esac
  # started by netifd at boot (network auto); written to the flash only if it changes
  case "$A_BOOT" in
  yes) uci -q set "pia.$AN.iface_auto=1" ;;
  no) uci -q set "pia.$AN.iface_auto=0" ;;
  esac
  # the boot delay (off with the boot option)
  if [ "$A_BOOT" = 'no' ]; then
    uci -q delete "pia.$AN.boot_delay"
  elif [ -n "$A_BDSET" ]; then
    if [ "${A_BD:-0}" -gt 0 ] && [ "$(uci -q get "pia.$AN.iface_auto")" != '1' ]; then api_fail "A boot delay needs Bring up on boot"; fi
    if [ "${A_BD:-0}" -gt 0 ]; then uci -q set "pia.$AN.boot_delay=$A_BD"; else uci -q delete "pia.$AN.boot_delay"; fi
  fi
  if [ -n "$A_BOOT" ] || [ -n "$A_BDSET" ] || [ -n "$AWNEW" ]; then
    uci -q commit pia
    NETCHANGED='' SESSCHANGED=''
    ensure_iface
  fi
  # kill switch
  case "$A_KS" in
  yes) uci -q set "pia.$AN.ks_enable=1" ;;
  no) uci -q delete "pia.$AN.ks_enable" ;;
  esac
  if [ "$(uci -q get "pia.$AN.ks_enable")" = '1' ]; then
    if [ -n "$A_KSSET" ] || [ -z "$(uci -q get "pia.$AN.ks_wan")" ]; then
      uci -q delete "pia.$AN.ks_wan"
      for AZ in ${A_KSB:-$(fw_wan_default)}; do uci -q add_list "pia.$AN.ks_wan=$AZ"; done
    fi
  fi
  uci -q commit pia
  if [ -n "$A_KS" ] || [ -n "$A_KSSET" ] || [ -n "$A_FWDSET" ] || [ "$A_FW" = 'no' ] || [ "$(uci -q get "pia.$AN.ks_enable")" = '1' ] || [ -n "$(uci -q get "pia.$AN.ks_removed")" ]; then
    ks_sync >&3
  fi
  # port forwarding: the option, the destination, and the redirect at once if the tunnel is up
  if [ -n "$A_PF" ] || [ -n "$A_PFSET" ]; then
    case "$A_PF" in
    yes) uci -q set "pia.$AN.pf_enable=1" ;;
    no) uci -q delete "pia.$AN.pf_enable" ;;
    esac
    if [ -n "$A_PFSET" ]; then
      if [ -n "$A_PFIP" ]; then uci -q set "pia.$AN.pf_ip=$A_PFIP"; else uci -q delete "pia.$AN.pf_ip"; fi
      if [ -n "$A_PFPORT" ]; then uci -q set "pia.$AN.pf_port=$A_PFPORT"; else uci -q delete "pia.$AN.pf_port"; fi
    fi
    uci -q commit pia
    if pf_enabled; then
      if [ -z "$AWNEW" ] && wgt "$AN" show "$AN" >/dev/null 2>&1 && session_valid; then pf_run >&3; fi
    else
      pf_fw_sync '' >&3
      pf_stop
    fi
  fi
  # dnsmasq: strict order follows the default route
  [ "$A_STRICT" = 'no' ] || strict_sync >/dev/null
  # the first interface of a router that was deployed without the cron jobs
  [ -z "$AFIRST" ] || jobs_deploy >/dev/null 2>&1
  # a new region: check in the background which of its country's regions need
  # the legacy token (the next start waits for it instead of being refused)
  if [ -n "$A_REGION" ]; then
    APC="$(echo "$PIAREGIONS" | jq -r --arg i "$A_REGION" '.[] | select(.id == $i) | .country' | head -n 1)"
    if [ -n "$APC" ] && ! legacy_country_fresh "$APC"; then
      (api_job _probe cache probe "$APC") >/dev/null 2>&1
    fi
  fi
  api_ok
}

api_iface_remove() {
  iface_exists "$1" || api_fail "No interface named '$1'"
  lock_take "api iface-remove"
  AUTO=1 remove_iface "$1" >/dev/null 2>&1
  api_ok
}

api_cmd() {
  case "$1" in
  status) api_status ;;
  regions) api_regions "$2" ;;
  account) api_account ;;
  login) api_relogin ;;
  refresh-list)
    pia_wan
    if cache_refresh_list; then
      jq -nc --arg r "$LISTRES" --argjson n "$LISTN" '{ok: true, result: $r, regions: $n}'
    else
      api_fail "The servers list could not be fetched"
    fi
    ;;
  job) shift && api_job "$@" ;;
  job-status) api_job_json "${2:-_global}" ;;
  iface-save) shift && api_iface_save "$@" ;;
  iface-remove) api_iface_remove "$2" ;;
  log) if [ -s "$PIALOG" ]; then tail -n "${2:-80}" "$PIALOG"; fi ;;
  history) api_history ;;
  *) api_fail "Unknown api command '$1'" ;;
  esac
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

if [ -t 0 ] || [ -n "$PIA_INTERACTIVE" ]; then unset AUTO; else AUTO=1; fi
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

# The guard runs every minute: when nothing is wrong it must leave no trace
# (no log file touched, no pipe made), so it looks before the logging is set up
if [ "$1" = 'guard' ]; then
  GSAVE="$PIAWG_IF"
  GNEED=''
  for GX in $(iface_list); do
    [ -z "$SELIF" ] || [ "$SELIF" = 'all' ] || [ "$SELIF" = "$GX" ] || continue
    PIAWG_IF="$GX"
    set_ifvars
    guard_needed && GNEED=1
    pf_due && GNEED=1
  done
  [ -n "$GNEED" ] || exit 0
  PIAWG_IF="$GSAVE"
  set_ifvars
fi

# Logging (only if not in interactive mode)
if [ "$1" = 'api' ]; then
  AUTO=1
  exec 3>&2
elif [ "$AUTO" ]; then
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
  # also to the system log (logread), like dqm: tag pia[PID], daemon facility,
  # lines prefixed "PIA: [interface] "; a line is sent once per run
  SYSLOGOK=''
  command -v logger >/dev/null 2>&1 && SYSLOGOK=1
  SLIF=''
  case "$1" in
  start | stop | restart | status | renew | init-network | confirm | guard) [ -n "$PIAWG_IF" ] && SLIF="[$PIAWG_IF] " ;;
  esac
  awk -v lf="$PIALOG" -v date="$(date)" -v tag="pia[$$]" -v pre="PIA: $SLIF" -v sl="$SYSLOGOK" '
    {print; printf("[%s] %s\n",date,$0) >> lf}
    sl && NF && !($0 in seen) && $0 !~ /^Command skipped.*: The interface is up$/ {
      seen[$0]
      m = $0
      sub(/^[ \t]+/, "", m)
      lvl = "notice"
      if (m ~ /^(Error|FATAL)/) lvl = "err"
      else if (m ~ /(fail|FAIL|refused|giving up|NOK|NONE|NOT |not updated)/) lvl = "warning"
      print pre m | ("logger -t \"" tag "\" -p daemon." lvl)
    }' <&4 3>&- 4<&- >&2 &
  exec 4<&-
else
  exec 3>&2
fi

if [ "$AUTO" ]; then
  case "$1 $2" in
  'renew install' | 'renew remove') ;;
  'start '* | 'restart '* | 'init-network '* | 'confirm '* | 'renew '* | 'cache refresh' | 'cache probe') boot_summary ;;
  esac
fi

# Several interfaces and none named (or -i all): run the command for each
if [ -n "$MULTI" ] || [ "$SELIF" = 'all' ]; then
  case "$1" in
  'start' | 'restart' | 'stop' | 'status' | 'renew' | 'init-network' | 'confirm' | 'guard')
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
    'configure ' | 'configure all' | 'configure region' | 'configure dip' | 'configure network' | 'configure route' | 'configure firewall' | 'configure rename')
      if [ -z "$SELIF" ] || [ "$SELIF" = 'all' ]; then
        echo "Several interfaces are configured ($(echo "$IFLIST" | tr '\n' ' ')): use -i NAME" >&2
        exit 1
      fi
      ;;
    esac
    ;;
  esac
fi

# The clock first: the certificates and the tokens' expiry depend on it
case "$1" in
'start' | 'restart' | 'init-network' | 'confirm') time_gate "$@" ;;
'renew') case "$2" in
  'install' | 'remove') ;;
  *) time_gate "$@" ;;
  esac ;;
'cache') case "$2" in
  'refresh' | 'probe') time_gate "$@" ;;
  esac ;;
'history') [ "$2" = 'probe' ] && time_gate "$@" ;;
esac

# Serialise the runs that act on the tunnel, the tokens or the cache
case "$1" in
'start' | 'restart' | 'stop' | 'init-network' | 'confirm') lock_take "$1" ;;
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
    iface_wizard
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
    iface_defaults
    [ -n "$AUTO" ] || ask_default_route
    strict_sync
    ;;
  'route')
    iface_exists "$PIAWG_IF" || set_iface "$SELIF" || exit 1
    ask_default_route
    strict_sync
    ;;
  'firewall')
    iface_exists "$PIAWG_IF" || set_iface "$SELIF" || exit 1
    if [ -n "$AUTO" ]; then fw_apply; else ask_firewall; fi
    ;;
  'keys') echo "The WireGuard keys are not saved: a new pair is generated in RAM at each start (as the official apps do) or with 'renew --new-key'" ;;
  'cache') keep_conf_section 'cache' || set_cache ;;
  'interface')
    set_iface "$3" || exit 1
    iface_wizard
    ;;
  'rename') rename_iface "$3" ;;
  'dns')
    iface_exists "$PIAWG_IF" || set_iface "$SELIF" || exit 1
    ask_dns
    ;;
  'mtu')
    iface_exists "$PIAWG_IF" || set_iface "$SELIF" || exit 1
    ask_mtu
    ;;
  'keepalive')
    iface_exists "$PIAWG_IF" || set_iface "$SELIF" || exit 1
    ask_keepalive
    ;;
  'protocol')
    iface_exists "$PIAWG_IF" || set_iface "$SELIF" || exit 1
    set_protocol
    ;;
  'remove') remove_iface "${3:-$SELIF}" ;;
  *)
    echo "Unknown configure subcommand '$2'!"
    print_usage
    exit 1
    ;;
  esac ;;
'api')
  shift
  api_cmd "$@"
  ;;
'watchdog') case "$2" in
  'install') watchdog_install ;;
  'remove') watchdog_strip && guard_remove ;;
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
  'probe')
    case "$3" in
    '' | [A-Z][A-Z]) ;;
    *)
      echo "The country must be a two letter code (GB, US…)"
      exit 1
      ;;
    esac
    legacy_probe "$3" && echo "Regions needing the legacy token: $(legacy_ids)"
    ;;
  *)
    echo "Unknown cache subcommand '$2'!"
    print_usage
    exit 1
    ;;
  esac ;;
'history') case "$2" in
  'probe')
    shift 2
    history_probe "$@"
    exit $?
    ;;
  *)
    echo "Unknown history subcommand '$2'!"
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
'confirm')
  shift
  confirm_cmd "$@"
  exit $?
  ;;
'guard')
  guard_cmd
  exit $?
  ;;
'restart')
  start_wgpia
  R=$?
  [ $R -eq 0 ] && install_jobs "$@"
  exit $R
  ;;
'start')
  if [ "$2" = '--cron' ]; then
    # an entry of the retired watchdog: the guard does what is needed, the entry goes
    watchdog_strip
    guard_cmd
    exit 0
  fi
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
  KSL="$(ks_leaks | tr '\n' ' ')"
  if [ -n "$KSL" ]; then
    echo "Kill switch: $([ "$(uci -q get "pia.$PIAWG_IF.ks_enable")" = '1' ] && echo 'ON, but' || echo OFF): traffic can leave without the VPN through ${KSL}(from>to)"
  elif [ "$(uci -q get "pia.$PIAWG_IF.ks_enable")" = '1' ]; then
    echo "Kill switch: ON (no forwarding to $(uci -q get "pia.$PIAWG_IF.ks_wan"))"
  fi
  if pf_enabled; then
    PFSP="$(awk '{print $1; exit}' "$(pf_statefile)" 2>/dev/null)"
    if [ -n "$PFSP" ]; then
      PFSI="$(uci -q get "pia.$PIAWG_IF.pf_ip")"
      if [ -n "$PFSI" ]; then
        echo "Port forwarding: port $PFSP -> $PFSI:$(uci -q get "pia.$PIAWG_IF.pf_port" || echo "$PFSP")"
      else
        echo "Port forwarding: port $PFSP (no destination IP address: not forwarded)"
      fi
    else
      echo "Port forwarding: enabled, no port bound yet"
    fi
  fi
  if renew_installed; then
    echo "Renew (cron) installed: YES"
  else
    echo "Renew (cron) installed: NO"
  fi
  if guard_installed; then
    echo "Guard (cron) installed: YES"
  else
    echo "Guard (cron) installed: NO"
  fi
  CRL=$(uci -q get system.@system[0].cronloglevel)
  case "$CRL" in
    ''|*[!0-9]*) ;;
    *) [ "$CRL" -lt 8 ] && echo "crond log level: $CRL (logs every job start, about 6 lines a minute with the guard; 9 logs errors only, see the README)" ;;
  esac
  if [ "$(uci -q get "pia.$PIAWG_IF.peer_persistent_keepalive")" = '0' ]; then
    echo "Guard: off for $PIAWG_IF (the keepalive is disabled: the guard needs it to see a stale tunnel)"
  fi
  if MSSZ="$(mss_clamp)"; then
    echo "MSS clamping: ON (zone $MSSZ)"
  elif [ -n "$MSSZ" ]; then
    echo "MSS clamping: OFF (zone $MSSZ has no mtu_fix): large TCP transfers can stall on a smaller path"
  else
    echo "MSS clamping: OFF (the interface is in no firewall zone): large TCP transfers can stall on a smaller path"
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
'luci') case "$2" in
  'install') luci_install ;;
  'remove') luci_remove ;;
  *)
    echo "Unknown luci subcommand '$2'!"
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
