# pia_wg.sh
A script to setup and run PIA through WireGuard on OpenWrt
<br />https://github.com/bolemo/pia_wg/

## Inspired from:
  - This thread: https://forum.openwrt.org/t/private-internet-access-pia-wireguard-vpn-on-openwrt/155475
  - And @Lazerdog's script: https://github.com/jimhall718/piawg/blob/main/piawgx.sh

## Version
1.0.17

## Install
  - Connect to your OpenWrt router with SSH
  - Go to (and create if needed) the location you want to install the script
<br /> For example: `mkdir /opt/scripts; cd /opt/scripts`
  - Download the script: `wget https://raw.githubusercontent.com/bolemo/pia_wg/main/pia_wg.sh`
  - Give execution permission to the script: `chmod +x pia_wg.sh`
  - Install packages which the script depends on: `opkg update && opkg install jq-full curl wireguard-tools luci-proto-wireguard coreutils-stty coreutils-nl`
  - Configure and run:
    - To configure and run PIA, use `./pia_wg.sh start` (or `./pia_wg.sh start --watchdog` if you want the watchdog installed) and answer the questions
    - To just configure, use `./pia_wg.sh configure` and answer the questions
<br /> Then you can setup network advanced/expert settings (see below) and then to run, use `./pia_wg.sh start` (or `./pia_wg.sh start --watchdog`)

## Setup firewall

__The firewall setup depends on your needs and your personal configuration.__

For a typical setup (direct all LAN traffic to/from internet through the newly created wireguard interface), you'll need to update your firewall this way:

- Navigate to Network > Firewall
- Create a new Zone, name it PIA or whatever you want
- In the General Settings tab, enable **Masquerading** and **MSS Clamping**, then add **LAN** to **Allow forward from source zones**
- In the Advanced Settings tab, set **Covered Devices** to **wg_pia**
- Save the zone
- Now edit your zone starting with **LAN**
- Set **Allow forward to destination zones** to **PIA** or whatever you named the previously created zone
- Traffic should now only be allowed through the wireguard connection

## Update
The script can be updated to the latest version using: `pia_wg.sh update`

## Advanced/Expert WireGuard network settings (not required for basic/common usage)
You can setup the script to set any OpenWrt WireGuard network interface or peer settings this way (after running the initial configuration):
  - for network WireGuard PIA interface: `uci set pia_wg.@net_interface[0].<option>=<value>` then `uci commit pia_wg.@net_interface[0]`
  - for network WireGuard PIA peer: `uci set pia_wg.@net_peer[0].<option>=<value>` then `uci commit pia_wg.@net_peer[0]`

For example, to prevent OpenWrt to route all the traffic through the VPN:
```
uci set pia_wg.@net_peer[0].route_allowed_ips='0'
uci commit pia_wg.@net_peer[0]
```

Or to put a fwmark on the outgoing VPN traffic:
```
uci set pia_wg.@net_interface[0].fwmark='0x1'
uci commit pia_wg.@net_interface[0]
```

Then, next time you use `./pia_wg.sh start` (if not already started, otherwise you need to restart or do stop then start to enable the new configuration) or `./pia_wg.sh restart`, it will use these extra settings when OpenWrt WireGuard will create the PIA interface and the PIA peer.

## Choosing a region
`./pia_wg.sh configure region` lets you type a region ID, or pick from a numbered list that can be narrowed with yes/no questions. Pressing enter gives the default, which is shown in capitals, e.g. `(y/N)`:
  - `Port forward only servers? (y/N)`: only regions supporting port forwarding
  - `Geo only servers? (y/N)`: only regions with geo-located servers
  - `Stream optimised only servers? (y/N)`: only the streaming optimised regions (those with "Streaming" in their name; their ids do not all end in `-so`, e.g. `uk_2`)

The answers are combined; if no region matches, the questions are asked again. The same convention applies to the other yes/no questions of the script (for example, answering the "Keep this configuration" question with enter keeps it).

## Interface name
The network interface is named `wg_pia` by default. To use another name (letters, digits and underscore, 15 characters at most), run `./pia_wg.sh configure interface`, or set it directly: `uci set pia_wg.@iface[0].name=vpn_pia` (after `uci add pia_wg iface`). Adapt your firewall zone's covered network accordingly. When the name is changed with `configure interface`, the interface created under the previous name is removed.

## Watchdog
The script can install a watchdog that will check regularly the status and restart the VPN if needed.
<br/> For that, just use `--watchdog` when using `start`or `restart`, or run the command `./pia_wg.sh watchdog install`
<br/> The health check pings PIA's own in-tunnel DNS address (the one `addKey` hands out, normally 10.0.0.243) through the tunnel; it never contacts a third-party address, and it sends no DNS query.
<br/> The cron entries are recognised by their `# pia_wg …` tags and written with the path the script is run from, so the script can have any name and location; after moving it, run `watchdog install` (and `cache install`) from the new location and the old entries are replaced.
<br/> To unsinstall/remove the watchdog, use `./pia_wg.sh watchdog remove`; when `./pia_wg.sh stop` is used, the watchdog is automatically removed

## Offline cache (networks blocking PIA)
Like the official PIA apps, the script talks to PIA through PIA servers by IP address (meta servers for the API, WireGuard servers for `addKey`), verifying their certificate against the PIA CA, and only falls back to the PIA domain names (`privateinternetaccess.com`, `piaproxy.net`, `serverlist.piaservers.net`, `<region>.pvt.site`) when that fails. This keeps it working on networks that block the PIA domains through DNS or SNI filtering.

It also uses the PIA API v5 login of the official apps: the username/password is exchanged for a long lived API token, then a VPN token used to authenticate on the WireGuard servers. The legacy 24h token is still used as a fallback.

The offline cache holds:
  - `servers.json`: the PIA servers list
  - `meta.list`: meta servers (IP and name) whose certificate is signed by the PIA CA
  - `ca.rsa.4096.crt`: the PIA CA
  - the tokens are stored in `/etc/config/pia_wg` with their expiry

Commands:
  - `./pia_wg.sh configure cache` sets the cache directory (default `/mnt/usb/pia_wg`, on external storage to spare the router flash; if a directory under `/mnt` or `/media` is not on a mounted filesystem, `/tmp/pia_wg` in RAM is used instead), extra regions to take meta servers from, and whether meta servers with a certificate not signed by the PIA CA may be used (insecure, off by default)
  - `./pia_wg.sh cache refresh` refreshes the servers list, the meta servers and renews the tokens ahead of expiry
  - `./pia_wg.sh cache install` (or `--cache` with `start`/`restart`) installs a cron job running `cache refresh` every 6 hours; `./pia_wg.sh cache remove` removes it
  - `./pia_wg.sh cache show` shows the cache
  - `./pia_wg.sh cache probe` checks which regions need the legacy token (see below)

### Regions needing the legacy token
Some PIA WireGuard servers refuse the long lived VPN token and only accept the legacy 24h token, which has to be renewed more often. In `configure region`, the regions for which every server refused the VPN token are marked `(L)`. The script uses the legacy token for them automatically, so they work, but they depend on the 24h token being renewable (the cache refresh job does it).

The first time (and when the result is older than a week), `configure region` offers to check the regions; this takes a few minutes. It can also be run with `./pia_wg.sh cache probe`. The check calls `addKey` with a deliberately invalid public key, so no key is registered on the servers, and leaves through the WAN, because PIA does not accept it from inside its own tunnel. A PIA server removes the existing peer of a token before it validates a new key, even when the request then fails, so the check never asks the server the tunnel is connected to (a region is judged on its other servers, or keeps its previous result). Some servers answer differently from one request to the next; a region is marked only if its servers refuse every time. The result is a snapshot, kept with its date in `legacy.list` in the cache directory. When the configured region is in that list, connecting goes straight to the legacy token instead of first trying the VPN token and being refused.

All the script's calls to PIA leave through the WAN device used to reach the tunnel endpoint, not through the tunnel, so the cache and tokens can be refreshed whether the PIA tunnel is up, down or not passing traffic, and without disconnecting it. `cache refresh` shows what it did (and the cron job writes the same lines to the log):
```
Cache update (leaving via br-wan; PIA tunnel unchanged)
  Servers list : 204 regions (updated, via losangeles414)
  Meta servers : 6 verified (unchanged)
  Tokens       : API token valid for 94 days, VPN token for 93 days
Done in 4s
```

Before travelling to a place where PIA is blocked, configure and start the VPN, then run `./pia_wg.sh cache refresh` (and `cache probe`) while PIA is reachable, so that the cache and the tokens are fresh.

To simulate DNS based blocking before travelling, make dnsmasq answer `0.0.0.0` for the PIA domains, then stop and start the VPN:
```
uci add_list dhcp.@dnsmasq[0].address='/privateinternetaccess.com/0.0.0.0'
uci add_list dhcp.@dnsmasq[0].address='/piaproxy.net/0.0.0.0'
uci add_list dhcp.@dnsmasq[0].address='/piaservers.net/0.0.0.0'
uci add_list dhcp.@dnsmasq[0].address='/pvt.site/0.0.0.0'
uci commit dhcp && /etc/init.d/dnsmasq restart
```
To also check that tokens can be obtained through meta servers, delete the stored VPN token first: `uci delete pia_wg.@vpntoken[0]; uci commit pia_wg`.
<br/> Remove these entries (`uci del_list ...` with the same values) when done.

## Temporary files and locking
Temporary files (the API responses, which hold tokens, the logging pipe and downloads) are created in `/var/run/pia/`, in RAM, with mode 0700; the directory is created on demand (`/tmp/pia` is used if `/var/run` is not writable). Leftovers of runs that died are removed at the next run. The only temporary files elsewhere are the short-lived `*.tmp` files used to replace cache files atomically, which sit next to them in the cache directory.

The commands that act on the tunnel, the tokens or the cache (`start`, `restart`, `stop`, `init-network`, `cache refresh`, `cache probe`) take a lock, `/var/run/pia/pia_wg.lock`, so that two runs cannot step on each other. The watchdog's `start` just skips when another run is in progress (it runs again a minute later); the other commands wait up to 2 minutes and then give up with exit status 75. A lock left by a run that died is removed, and a run still holding it after 15 minutes is considered stuck and terminated. `configure` does not take the lock, so that waiting at a prompt cannot stop the watchdog.

## Logging
When the watchdog is enabled, the scripts log is located in `/var/log/pia/pia_wg_watchdog.log` (RAM on OpenWrt, so it does not wear the flash; use `./pia_wg.sh log path` to choose another directory)
The log can be displayed using `pia_wg.sh log show` and cleared using `pia_wg_sh log clear`

## Usage
Usage: `pia_wg.sh { configure <section> | start [ --watchdog ] [ --cache ] | restart [ --watchdog ] [ --cache ] | stop | status | watchdog { install | remove } | cache { refresh | install | remove | show } | log { show | clear | path } | update | version}`
<br/>  Details:
  - `configure`          : same as configure all
  - `configure all`      : configure all settings
  - `configure user`     : set PIA user ID and password
  - `configure dip`      : set PIA dedicated IP
  - `configure region`   : set/choose PIA region
  - `configure keys`     : generate local WireGuard keys
  - `configure interface`: set the network interface name (default `wg_pia`)
  - `configure cache`    : set offline cache directory and options
  - `configure network`  : generate default network settings
  - `init-network`       : setup PIA WireGuard network (no start)
  - `start`              : start PIA WireGuard (if not already up)
  - `start --watchdog`   : same as start and install the watchdog
  - `restart`            : start or restart PIA WireGuard
  - `restart --watchdog` : same as restart and install the watchdog
  - `start|restart --cache` : same and install the cache refresh
  - `stop`               : stop PIA WireGuard (and remove the watchdog)
  - `status`             : show PIA WireGuard status
  - `watchdog install`   : install the watchdog
  - `watchdog remove`    : remove the watchdog
  - `cache refresh`      : refresh the offline cache (servers list, meta servers, tokens)
  - `cache install`      : install the cache refresh (cron, every 6 hours)
  - `cache remove`       : remove the cache refresh
  - `cache show`         : show the offline cache
  - `cache probe`        : check which regions need the legacy token
  - `log show`           : display the watchdog log
  - `log clear`          : clear the watchdog log
  - `log path`           : set a custom Directory Path for the log
  - `update`             : update the script to latest version
  - `version`            : print the version and exit

## Notes
Please, take into account that the script is only creating and setting up the WireGuard interface. It is up to the user to set up/adapt his firewall zones (either including the interface in the WAN zone, or creating a specific zone for it named VPN, PIA or whichever name you want).

A user reported an issue not directly linked to this script but that others users might experience : on his OpenWrt setup, when his router restarts, the time is not properly set and it prevents the interface to go up.
He proposed a solution here: https://github.com/bolemo/pia_wg/issues/5

## Copyright
©2026 bOLEMO
