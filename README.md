# pia_wg.sh
A script to setup and run PIA through WireGuard on OpenWrt
<br />https://github.com/bolemo/pia_wg/

__This is a fork__ (branch `release`) of [bolemo/pia_wg](https://github.com/bolemo/pia_wg/), kept in sync with it, with the changes listed under *Version* below. The changes are also offered upstream, one commit each, in the branch `official-api-offline-cache`.

## Inspired from:
  - This thread: https://forum.openwrt.org/t/private-internet-access-pia-wireguard-vpn-on-openwrt/155475
  - And @Lazerdog's script: https://github.com/jimhall718/piawg/blob/main/piawgx.sh

## Version
1.12.3 (upstream 1.0.16)

Changes compared to upstream 1.0.16:
  - Logs in to PIA the way the official PIA apps do (API v5 tokens that last weeks, through PIA's own servers by IP address), so it works where the PIA domain names are blocked; the legacy token is used for the servers that still require it
  - Offline cache (servers list, verified meta servers, tokens) kept on external storage and refreshed by cron: `cache refresh|install|remove|show|probe`; all PIA calls leave through the WAN device, so the PIA tunnel is never disconnected for it
  - `configure region`: regions needing the legacy token are marked `(L)`, a streaming optimised filter, default answers on every yes/no question
  - Configurable interface name, a run lock, temporary files in `/var/run/pia`, log in `/var/log/pia`
  - Fixes: server list error check, connectivity check on tunnels whose first hop does not answer, `jq` without regex support, `update` refusing anything that is not a valid script
  - The WireGuard key pair and the server settings are kept in RAM only (like the official apps), as deltas in `/var/state/network` that netifd's protocol scripts read and LuCI does not (no *unsaved changes*, nothing committed by a Save & Apply); the persistent network config is written only when it changes; `renew` (cron, ifup hook) and the guard (cron) replace the retired watchdog for an ordinary `ifup`/`ifdown` managed interface
  - One config, `/etc/config/pia` (was `pia_wg`), with a section per interface named like it: several PIA interfaces on one router (`-i NAME`), sharing the account, tokens and cache; the script, cron tags, hook, log and cache directory use `pia` names (older names are converted on the first run)
  - AmneziaWG (PIA's obfuscated WireGuard, as in the Android app) is the default protocol of a new interface: `iface_proto`, asked right after the name, `configure protocol`; the servers list is the v7 one; also at interface creation: automatic protocol (AmneziaWG, then WireGuard), MACE DNS, small packets, fastest region of the country; a 401 is retried after 5/15/30 s before the VPN token is renewed
  - A LuCI web interface (Services > PIA VPN, `luci install`): account and interfaces, added and edited in the same dialog; the script gets JSON `api` commands for it (see *Web interface*); a new region triggers a background check of its country's regions that need the legacy token (`cache probe CC`), and the interface is written the way LuCI saves it, so a save in the Network pages lists no changes

## Install
  - Connect to your OpenWrt router with SSH
  - Go to (and create if needed) the location you want to install the script
<br /> For example: `mkdir /opt/scripts; cd /opt/scripts`
  - Download the script: `wget https://raw.githubusercontent.com/Blip9575/pia_wg/release/pia_wg.sh`
  - Give execution permission to the script: `chmod +x pia_wg.sh`
  - Install packages which the script depends on: `opkg update && opkg install jq-full curl wireguard-tools luci-proto-wireguard coreutils-stty coreutils-nl`
  - Configure and run:
    - To configure and run PIA, use `./pia_wg.sh start` (or `./pia_wg.sh start --watchdog` if you want the guard installed) and answer the questions
    - To just configure, use `./pia_wg.sh configure` and answer the questions
<br /> Then you can setup network advanced/expert settings (see below) and then to run, use `./pia_wg.sh start` (or `./pia_wg.sh start --watchdog`)

## Setup firewall

__The firewall setup depends on your needs and your personal configuration.__

For a typical setup (direct all LAN traffic to/from internet through the newly created wireguard interface), you'll need to update your firewall this way:

- Navigate to Network > Firewall
- Create a new Zone, name it PIA or whatever you want
- In the General Settings tab, enable **Masquerading** and **MSS Clamping**, then add **LAN** to **Allow forward from source zones**
- In the Advanced Settings tab, set **Covered Devices** to **pia** (or the name of the interface)
- Save the zone
- Now edit your zone starting with **LAN**
- Set **Allow forward to destination zones** to **PIA** or whatever you named the previously created zone
- Traffic should now only be allowed through the wireguard connection

### Fail closed
**IPv6.** PIA does not support IPv6 (the add-key reply holds one IPv4 address), and like the official apps the tunnel is IPv4 only: the peer's allowed IPs are `0.0.0.0/0` and no IPv6 route is given to netifd. The official apps then block IPv6 in their own firewall; this script manages no IPv6 rule, so blocking IPv6 out of the WAN is yours to do, or IPv6 from the LAN leaves through the WAN and bypasses the VPN. For example, in `/etc/config/firewall`:

```
config rule
	option name 'Block-IPv6-Forward-WAN'
	option src '*'
	option dest 'wan'
	option family 'ipv6'
	option proto 'all'
	option target 'REJECT'
```

(`REJECT` makes the devices fall back to IPv4 at once; `DROP` makes them wait for a timeout.) An interface made by an older version has `::/0` in its allowed IPs: it is removed the next time the interface is started or saved.

**Kill switch.** The safe layout is the one where every zone is input DROP, output ACCEPT, forward DROP, and the LAN zones forward only to VPN zones (no `LAN > WAN` forwarding): with the tunnel down the LAN then has no internet. The router's own traffic fails open on purpose (output is ACCEPT and the WAN default route remains), which the cold start needs. The interface option **Kill switch** (off by default; LuCI, or `pia.sh api iface-save NAME killswitch=yes ks_wan="eth_wan"`) makes that layout for you: it needs the firewall zone, at least one zone under **Allow forwarding from** and at least one under **WAN zones**, and it removes the `forwarding` entries from the first to the second. The WAN zones offered are the zones attached to `br-wan` (read from the network config, so a down interface is found too) that masquerade and use no VPN protocol, the `br-wan` zone being ticked by default; **Allow forwarding from** does not offer any zone attached to `br-wan` (masquerading or not), the VPN zones (`wireguard`, `amneziawg`, `openvpn` networks) or any zone that masquerades (a zone already forwarding keeps showing). It does not change any zone policy. What it removed is remembered (`ks_removed`) and put back when the switch is turned off, the zones change, or the interface is removed. It is applied when the interface is saved, never by the hook or the guard, so a forwarding added by hand later is not removed until the next save; `pia.sh status` and the Interfaces table warn (`LAN can reach eth_wan without the VPN`) whenever a zone that forwards into the interface can still reach a WAN zone, whether the switch is on or not.

Neither the guard nor `renew` is a kill switch: when the tunnel is down, the default route into it disappears and traffic follows the next default route. If the LAN must never reach the internet except through PIA, make that a firewall rule rather than a routing one: the LAN zone must have **no** forwarding to the WAN zone (only to the PIA zone), as in the steps above. With no tunnel the LAN then simply has no internet. The router's own traffic (this script's calls to PIA, the cache refresh) leaves through the WAN as output, which the zone rules above do not block.

## Update
The script can be updated to the latest version using: `pia_wg.sh update` (it is downloaded from the `release` branch of this fork, and installed only if it is a valid script)

## Advanced/Expert WireGuard network settings (not required for basic/common usage)
You can setup the script to set any OpenWrt WireGuard network interface or peer settings this way (after running the initial configuration):
  - for the network WireGuard PIA interface: `uci set pia.<interface>.iface_<option>=<value>` then `uci commit pia`
  - for the network WireGuard PIA peer: `uci set pia.<interface>.peer_<option>=<value>` then `uci commit pia`

(`<interface>` is the name of the interface and of its section in `/etc/config/pia`; the options keep their OpenWrt names, prefixed with `iface_` or `peer_`.)

For example, to prevent OpenWrt to route all the traffic through the VPN:
```
uci set pia.vpn_pia.peer_route_allowed_ips='0'
uci commit pia
```

Or to put a fwmark on the outgoing VPN traffic:
```
uci set pia.vpn_pia.iface_fwmark='0x1'
uci commit pia
```

Then, next time you use `./pia_wg.sh start` (if not already started, otherwise you need to restart or do stop then start to enable the new configuration) or `./pia_wg.sh restart`, it will use these extra settings when OpenWrt WireGuard will create the PIA interface and the PIA peer.

## Choosing a region
`configure region` also asks `Pick the fastest region of that country at each start? (y/N)`. With yes (`region_fast`), each `start` pings (ICMP, through the WAN, in parallel) the online regions of the same country and kind (same streaming/geo/port-forward flags) and uses the fastest; the region is written to the config only when it changes. `renew` keeps the current one.

`./pia_wg.sh configure region` lets you type a region ID, or pick from a numbered list that can be narrowed with yes/no questions. Pressing enter gives the default, which is shown in capitals, e.g. `(y/N)`:
  - `Port forward only servers? (y/N)`: only regions supporting port forwarding
  - `Physical VPN locations only (no geo-located regions)? (Y/n)`: leave out the regions whose servers are geo-located (the default; n shows them too)
  - `Stream optimised only servers? (y/N)`: only the streaming optimised regions (those with "Streaming" in their name; their ids do not all end in `-so`, e.g. `uk_2`)

The answers are combined; if no region matches, the questions are asked again. The same convention applies to the other yes/no questions of the script (for example, answering the "Keep this configuration" question with enter keeps it).

## Interfaces
`/etc/config/pia` has one section per PIA interface, named like the network interface (`vpn_pia` below); the account, the tokens, the cache and the log are shared by all of them, so all the interfaces use one PIA account:
```
config account 'account'
	option id 'p1234567'
	option password '...'

config interface 'vpn_pia'
	option region_id 'uk_manchester'
	option region_name 'UK Manchester'
	option region_dns 'uk-manchester.pvt.site'
	option iface_proto 'wireguard'     # iface_* : the network interface options
	option iface_mtu '1440'
	option peer_persistent_keepalive '25'   # peer_* : the network peer options
	list peer_allowed_ips '0.0.0.0/0'
```
  - `./pia_wg.sh configure interface NAME` creates one (letters, digits and underscore, 15 characters at most); `configure rename NEW` (with `-i OLD`) renames it, `configure remove NAME` forgets it (and its network sections).
  - With a single interface it is implicit. With several, `-i NAME` selects one (for example `./pia_wg.sh -i vpn_pia2 start`); `start`, `restart`, `stop`, `status`, `renew` and `init-network` without `-i` (or with `-i all`) act on each. `renew` and the ifup hook cover every interface.
  - Each interface has its own region (or dedicated IP), session key and guard check. One PIA token can hold only one peer per server, so an interface does not pick a server another interface is using; give them different regions when you can.
  - Only one interface should have the default route if they are used for the same traffic: set `peer_route_allowed_ips '0'` (or narrower allowed IPs) on the others, and adapt the firewall zones.

### When an interface is created
`configure interface NAME` (and `configure all`) asks, with the answer in capitals taken by enter:
  - **Protocol**, right after the name: `1) AmneziaWG` (the default) or `2) WireGuard`. AmneziaWG is WireGuard with obfuscated handshakes, the option the official apps use on networks that block WireGuard (`vpninfo/servers/v7` lists its servers in the `awg` group, port 1338). The key is registered with `add-awg-key` (same VPN token, same one-peer-per-token-and-server rule; an AmneziaWG and a WireGuard peer of the same token do not evict each other) and the obfuscation parameters the server returns (`jc, jmin, jmax, s1, s2, h1..h4`) are kept in RAM with the key. It needs `amneziawg-tools`, `kmod-amneziawg` and `luci-proto-amneziawg`; without them the interface is created as WireGuard. A dedicated IP is WireGuard only. **3) Automatic** (`proto_mode 'auto'`) uses the interface's protocol first and, when `start`/`restart` gets no handshake within 12 s, a second server of the region and then the other protocol; the one that works is kept (`iface_proto` is rewritten only then). There is no TCP fallback: PIA has no WireGuard over TCP (the apps' TCP is OpenVPN TCP). An `ifup` from LuCI does not switch protocol, only `start`/`restart` do. `configure protocol` changes it later (the interface's network sections and session are dropped; start it again, with a region that has servers of that protocol). The interface's `iface_proto` option holds it (`amneziawg` or `wireguard`).
  - **DNS servers**: `1) PIA` (default), `2) PIA with MACE` (also blocks ads, trackers and malware; `iface_mace`) or `3) Custom` (a DNS server of your own, IPv4, kept in `iface_dns` and reached through the tunnel). The address follows from that and the region, as in [PIA's article on its DNS](https://helpdesk.privateinternetaccess.com/hc/en-us/articles/46777085837339-Using-PIA-DNS-in-Custom-Configurations): 10.0.0.242 (DNS), 10.0.0.243 (DNS + streaming, regions with `-so.` in their DNS name), 10.0.0.244 (DNS + MACE) and 10.0.0.241 (DNS + streaming + MACE); it is kept in `iface_dns` and follows a change of region. A custom `iface_dns` is left alone until PIA or MACE is chosen again. An older MACE choice (`iface_dns 10.0.0.241` without `iface_mace`) is migrated. `configure dns` asks again.
  - **Packet size**: `1) Default` (the WAN's MTU minus 80, 1420 on a 1500 WAN: PIA's number), `2) Small` (1280, the Android app's small packets) or `3) Custom` (digits only, 1280 to 1420: PIA's servers use 1420 on their side and fragment larger replies, so more gains nothing; an `Optimal (1440)` choice was removed in 1.9.1). Existing `iface_mtu` values are never changed. `configure mtu` asks again.
  - **Default route**: `Route all traffic through NAME (default route)? (Y/n)`. With several PIA interfaces none may have it (a second default route would make one VPN run inside the other, and routing then has to be done by policy routing, firewall marks or per-device routes, which the script does not set up): creating a second interface asks `Remove the default route from all PIA interfaces?` (Y removes it from all, n only keeps it off the new one); the interfaces without it route just the two PIA DNS hosts, so that they can still be tested. Running tunnels change at their next restart. When one interface is left, `configure remove` offers the default route back. `configure route` asks again.
  - **Firewall**: `Create firewall zone 'NAME' with NAT and MSS clamping? (Y/n)` creates a zone named like the interface (input and forward DROP, masquerading, MSS clamping, marked `pia_managed`) and then asks which zones may forward to it (enter for the LAN zone, `-` for none). An existing zone with that name is adopted after asking, never removed. The firewall is checked (`fw4 check`) and reloaded only when something changed; only `configure` touches it, never start, renew or the hook. `configure firewall` asks again, `configure remove` removes the zone and forwardings the script made.
  - **DNS**: the interface carries PIA's DNS server for its region (see above; `iface_dns`) with `dns_metric 1`, so they come first in `resolv.conf.auto`. dnsmasq only keeps that order with `strictorder`: strict-order follows the default route: it is set on the dnsmasq instances that use the interfaces' servers (not those with `noresolv`, such as an instance with its own upstream: its clients do not use PIA's DNS at all) while a PIA interface has the default route, and removed again, only from the instances the script set (`pia.account.strict_set`), when none has it. A strict-order you had set yourself is never removed.
  - **Keepalive**: `1) Default` is PIA's, 25 seconds (as the official apps), `2) Disabled` is 0 and `3) Custom` is 1 to 65535 seconds (`peer_persistent_keepalive`; `configure keepalive` asks again). The interface route metric is distinct for each PIA interface (the first keeps the default one), so a destination routed by several of them (the DNS hosts) is resolved by metric.

## Web interface (LuCI)
`pia_wg.sh luci install` adds **Services > PIA VPN** to LuCI (the files are in the `luci/` directory of the repository: a view, a menu entry, an ACL and an rpcd plugin that calls the script's `api` commands; `luci remove` removes them; log in to LuCI again afterwards). It uses LuCI's own widgets, so it follows the theme, including its dark mode.
  - **Account**: *User ID*, *Password* (write-only) and *Cache Path* (default `/mnt/usb/pia`, the cache files are copied when it changes), then *Login Status*, *Save and log in*, *VPN Token valid till*, *Cache Renewed* (when it was last checked, regions, meta servers; warnings if it is old, kept in RAM or has no refresh cron) and *Refresh server list & VPN token*. *Save and log in* writes to flash only when the ID, password or path changed, logs in again, refreshes the servers and tokens, and opens *Add interface* when no interface exists yet. Times are shown in UTC as year/month/day (the token expiry as a date: PIA's tokens expire at 00:00 UTC).
  - **Interfaces**: one row per interface with its region, protocol, settings and state (handshake age, endpoint), and Start, Stop, Restart, Edit and Remove. **Add interface…** (below the table) opens the same dialog as Edit: name, protocol (AmneziaWG, WireGuard or automatic), region (physical VPN locations only, streaming/port forwarding filters, VPN location (nothing chosen until you pick one), fastest region, region), packet size (default, small or custom: digits only, 1280 to 1420), keepalive (default 25, disabled or custom: 1 to 65535), DNS servers (PIA, PIA with MACE or custom: an IPv4 address; the PIA address follows the region), default route, firewall zone and forwardings, all on one page; the region list follows the chosen protocol. Saving keeps dnsmasq's strict order in step with the default route (set while a PIA interface has it, removed when none does). It offers to start the new interface.
  - Start, restart, stop and logins run in the background (the page follows the output); a change of settings applies at the next start or restart.
  - What it cannot do (use `configure` on the command line): a dedicated IP, renaming.

## Keeping the key registered with `renew`
`./pia_wg.sh renew install` makes the VPN behave like an ordinary WireGuard interface, started and stopped with `ifup`/`ifdown` (or from LuCI), and removes the retired watchdog:
  - `renew` (cron, every 6 hours) registers the session key again with the PIA server and renews the tokens when due. It never starts or stops the tunnel, leaves through the WAN, and does nothing while the tunnel has had a handshake in the last 3 minutes (`--force` overrides).
  - A hotplug hook (`/etc/hotplug.d/iface/80-pia`) keeps the host route of the endpoint in place (without it the first packets of an `ifup` loop through the tunnel), and prepares the session when the WAN comes up or when the PIA interface is brought up with none (after a reboot).
  - `renew --new-key` registers a new key; if the interface is up, add `--apply` to restart it with the new key.
  - To uninstall: `./pia_wg.sh renew remove`.

The interface is not started at boot unless you want it: set `uci set pia.vpn_pia.iface_auto=1; uci commit pia` then `./pia_wg.sh restart` (persistent `auto='1'` on the interface), or leave it at `0` and start it from LuCI.

### What is stored where
Like the official apps, the script does not store the WireGuard key pair. A new pair is generated for each connection (`start`, `restart`, `renew --new-key`, or after a reboot), registered with `addKey`, and kept only in RAM together with the address and server settings that `addKey` returned (`/var/run/pia/session`). The script manages only its own options of the interface and peer sections (the others, such as `ip4table` or `ip6assign` set in LuCI, are left alone). The network config on flash only holds what never changes (interface name, protocol, MTU, DNS, allowed IPs, keepalive, a fixed placeholder key, the region description); the key, address and server are RAM-only uci deltas in `/var/state/network` (tmpfs), which the protocol handlers of netifd (`wireguard.sh`, `amneziawg.sh`) read through `config_load`. uci, rpcd and LuCI do not read that directory, so these settings are neither listed as unsaved changes nor committed by a *Save & Apply*; netifd itself does not see them either, so the script restarts a running interface (`ifdown`/`ifup`) to apply a new session. Before 1.4.0 they were staged in `/tmp/.uci`, which LuCI shows as unsaved changes; they are moved at the next renew or start. As a result:
  - the flash is not written by `renew`, `start`, `restart` or a recovery of the guard, only when what is persistent actually changes (region, interface name, DNS); every write to `/etc/config/network` and `/etc/config/pia` is preceded by a comparison;
  - LuCI's Network pages show the interface and its peer with the placeholder settings (no key, address or endpoint); the PIA page and the interface status show the live ones;
  - the legacy 24h token is also kept in RAM only (`/var/run/pia/legacy.token`); the v5 tokens, which last weeks, stay in `/etc/config/pia`;
  - a reboot loses the key: the hook registers a new one when the WAN is up (through the cache and the PIA servers by IP, so it also works where PIA names are blocked).

## Watchdog (retired since 1.9.0)
The watchdog (a cron entry per interface that restarted the VPN when it was down or did not answer, so that stopping it from LuCI was undone within a minute) is retired. The [guard](#guard-since-180) mends a stale tunnel, and ifup/ifdown stays yours (LuCI, `ifup`, travelmate).
<br/> The commands remain as aliases: `watchdog install`, `start --watchdog` and `restart --watchdog` install the guard, `watchdog remove` removes it, and `start --cron` (an old cron entry) runs the guard check. Old `# pia watchdog` cron entries are removed whenever the script sees them (`renew install`, `luci install`, `stop`, `configure remove`).

## Offline cache (networks blocking PIA)
Like the official PIA apps, the script talks to PIA through PIA servers by IP address (meta servers for the API, WireGuard servers for `addKey`), verifying their certificate against the PIA CA, and only falls back to the PIA domain names (`privateinternetaccess.com`, `piaproxy.net`, `serverlist.piaservers.net`, `<region>.pvt.site`) when that fails. This keeps it working on networks that block the PIA domains through DNS or SNI filtering.

It also uses the PIA API v5 login of the official apps: the username/password is exchanged for a long lived API token, then a VPN token used to authenticate on the WireGuard servers. The legacy 24h token is still used as a fallback.

The offline cache holds:
  - `servers.json`: the PIA servers list
  - `meta.list`: meta servers (IP and name) whose certificate is signed by the PIA CA
  - `ca.rsa.4096.crt`: the PIA CA
  - the v5 tokens are stored in `/etc/config/pia` with their expiry (the legacy token is RAM-only)

Commands:
  - `./pia_wg.sh configure cache` sets the cache directory (default `/mnt/usb/pia`, on external storage to spare the router flash; if a directory under `/mnt` or `/media` is not on a mounted filesystem, `/tmp/pia_wg` in RAM is used instead), extra regions to take meta servers from, and whether meta servers with a certificate not signed by the PIA CA may be used (insecure, off by default)
  - `./pia_wg.sh cache refresh` refreshes the servers list, the meta servers and renews the tokens ahead of expiry
  - `./pia_wg.sh cache install` (or `--cache` with `start`/`restart`) installs a cron job running `cache refresh` every 6 hours; `./pia_wg.sh cache remove` removes it
  - `./pia_wg.sh cache show` shows the cache
  - `./pia_wg.sh cache probe` checks which regions need the legacy token (see below)

### Regions needing the legacy token
Some PIA WireGuard servers refuse the long lived VPN token and only accept the legacy 24h token, which has to be renewed more often. In `configure region`, the regions for which every server refused the VPN token are marked `(L)`. The script uses the legacy token for them automatically, so they work, but they depend on the 24h token being renewable (the cache refresh job does it).

The first time (and when the result is older than a week), `configure region` offers to check the regions; this takes a few minutes. It can also be run with `./pia_wg.sh cache probe`. The check calls `addKey` with a deliberately invalid public key, so no key is registered on the servers, and leaves through the WAN, because PIA does not accept it from inside its own tunnel. A PIA server removes the existing peer of a token before it validates a new key, even when the request then fails, so the check never asks the server the tunnel is connected to (a region is judged on its other servers, or keeps its previous result). Some servers answer differently from one request to the next; a region is marked only if its servers refuse every time. The result is a snapshot, kept with its date in `legacy.list` in the cache directory. When the configured region is in that list, connecting goes straight to the legacy token instead of first trying the VPN token and being refused.

`./pia_wg.sh cache probe GB` checks only the regions of one country and merges the result into the list (a `#c GB <epoch>` line records when). The web interface starts this in the background when an interface is saved with a region of a country whose result is older than a week, so the next start goes straight to the right token; a start meanwhile waits for it (a few seconds to a minute).

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
To also check that tokens can be obtained through meta servers, delete the stored VPN token first: `uci delete pia.vpntoken; uci commit pia`.
<br/> Remove these entries (`uci del_list ...` with the same values) when done.

## Temporary files and locking
Temporary files (the API responses, which hold tokens, the logging pipe and downloads) are created in `/var/run/pia/`, in RAM, with mode 0700; the directory is created on demand (`/tmp/pia` is used if `/var/run` is not writable). Leftovers of runs that died are removed at the next run. The only temporary files elsewhere are the short-lived `*.tmp` files used to replace cache files atomically, which sit next to them in the cache directory.

The commands that act on the tunnel, the tokens or the cache (`start`, `restart`, `stop`, `init-network`, `cache refresh`, `cache probe`) take a lock, `/var/run/pia/pia_wg.lock`, so that two runs cannot step on each other. `start` just skips when another run is in progress; the other commands wait up to 2 minutes and then give up with exit status 75. A lock left by a run that died is removed, and a run still holding it after 15 minutes is considered stuck and terminated. `configure` does not take the lock, so that waiting at a prompt cannot stop the unattended jobs.

## Tunnel confirmation (since 1.7.0)

A tunnel gets the default route and its DNS server only when it works, so that a key PIA does not know, or a server that does not answer, can no longer leave a default route that goes nowhere:

1. **Stage 1 (confirm):** the interface comes up with its key but without routes or DNS (the network config has no `dns` and no `route_allowed_ips`; the allowed IPs are always everything). The script waits for the handshake (up to 15 s) and sends a DNS query to the PIA DNS server through the tunnel, over a host route made first so that it cannot leave through the WAN.
2. **Stage 2 (apply):** the default route (or, for an interface without it, only the DNS route) and the DNS server are given to netifd as an update of the interface, the way the protocol script would. Nothing of it is written to the flash, and an interface that is restarted starts again from stage 1 (the ifup hook confirms it again).

When stage 1 fails the script recovers up to three times: it registers the key again, then refreshes the servers list and chooses another server, then renews the VPN token (a list refresh or a token renewal at most once in 10 minutes). When it still fails the tunnel stays up and unconfirmed, the WAN keeps the default route, and the next hook or cron run tries again. A confirmed tunnel whose handshake is lost has its default route and DNS server withdrawn at the next hook or renew. Every stage is logged (`Stage 1/2 (confirm)`, `Stage 2/2 (apply)`, `Stage 2/2 (withdraw)`), to the PIA log and to the system log. `pia.sh confirm [--force]` runs it by hand.

## Guard (since 1.8.0)

A cron job (`# pia guard`, every minute, installed with the renew job and removed with it) looks at each interface that is up. When its handshake is older than 180 seconds (a working tunnel renews it at least every 2 minutes with the keepalive on) it runs the ifup hook, which registers the key when it is missing and confirms the tunnel: a default route and DNS server that point into a dead tunnel are withdrawn first, then the recovery of the tunnel confirmation runs. The guard itself changes nothing and leaves no trace while all is well (no log file is touched). An interface whose keepalive is 0 is skipped, since an idle tunnel has no handshake then, and so is an interface that is down.

## Logging
When it runs unattended, the script's log is located in `/var/log/pia/pia.log` (RAM on OpenWrt, so it does not wear the flash; use `./pia_wg.sh log path` to choose another directory)
The log can be displayed using `pia_wg.sh log show` and cleared using `pia_wg_sh log clear`

What unattended runs print (cron, the ifup hook, LuCI jobs) also goes to the system log (`logread | grep pia`), like other daemons do: tag `pia[PID]`, facility `daemon`, lines starting `PIA: ` and, for an interface, `PIA: [name] `; failures are warnings.

The first run after each boot adds one line, `Boot: up Ns, clock … , version …; NAME: session key yes|no, bring up on boot yes|no` (RAM only, once per boot). The router has no battery clock, so lines logged before the clock is synchronised carry the last saved time and the next lines jump forward; the `up Ns` tells how long the boot had run. A VPN token refusal names the answer: `PIA refused the VPN token (HTTP 401 from SERVER: message); trying again in 1s` (then 5, 15 and 30 s: a refusal is often random per request, as with uk_manchester, so the first retry is quick).

A confirm run that does nothing says why, in one line: `Command skipped (ifup wlan_wan): The interface is down | The interface is up | In back-off after a failed attempt, Ns left | There is no session key` (the brackets name what was trying to run; `The interface is up`, the normal case, stays in the log file and is not sent to the syslog).

Firmware upgrades and LuCI backups: `renew install` and `luci install` add the hook and the LuCI app files to `/etc/sysupgrade.conf` under `## PIA VPN (kept by pia.sh)` (only the lines that are missing; `luci remove` and `renew remove` take theirs out). `/etc/config/pia`, the network and firewall configuration and the cron entries are kept by OpenWrt already; the session key (RAM), the cache and the log are not meant to be kept.

## Port forwarding

PIA shares each server's address between its users and blocks incoming connections; port forwarding opens one inbound port on your session, which PIA picks. It is for a service behind the router that must be reached from outside (a torrent client accepting peers, a game or media server). The port is the same for TCP and UDP, only some regions offer it (the region list shows them), and anyone who learns the server address and port can connect to what you forward: leave it off unless you need it.

The script does it the way the official apps do. Once the tunnel is confirmed it asks the server (`https://<server address inside the tunnel>:19999`, the PIA CA, the server's name) for a signature with the API token (`getSignature`) and opens the port with it (`bindPort`), and the guard repeats the bind every 15 minutes. A new signature means a new port, so the token (payload and signature) is kept in the Cache Path, `portfwd.NAME.json`, and reused while a week of it is left (about two months in all); the port stays the same across restarts until the token expires, the region's server changes, or a bind is refused (then one new token is tried). Nothing is written to the flash. A failed attempt is repeated every 5 minutes.

Set it in LuCI (Edit interface: **Port forwarding**, then **Destination IP address** and **Destination Port**) or with `pia.sh api iface-save NAME portfwd=yes pf_ip=192.168.1.50 pf_port=8080` (`pf_port` empty: the forwarded port). With a destination the script keeps a firewall redirect (`PIA port forward NAME`, marked `pia_managed_pf`, TCP and UDP, DNAT to the destination, which fw4 also accepts inbound) for the port; it is changed only when the port changes (a firewall check and reload then) and removed when the option is turned off or the interface is removed. The destination's zone is the one of the zones forwarding into the interface whose network holds the address. It needs the firewall zone; it is not available with a dedicated IP. Without a destination the port is held and shown but not forwarded. `pia.sh status` and the Interfaces table show the port. UCI: `pf_enable`, `pf_ip`, `pf_port`.

## History
`history.json` in the cache path records what happened with the servers: key registrations (server, HTTP code, time taken, accepted or refused), the pings of the fastest-region choice, tunnel confirmations and guard actions, each with country, region, server IP, latency and status (never tokens or keys). Entries are collected in RAM and written once when a run ends, to the cache path only (RAM if the USB drive is not mounted), and the file keeps the latest 200. `pia.sh api history` prints it with a per-region summary; LuCI shows both under *History* on the PIA VPN page. `pia.sh history probe [--rounds N] [--delay S] REGION|COUNTRY…` (for example `history probe GB`) asks the servers of the regions whether they accept the VPN token, N times (default 8, 3 s apart), with an invalid public key: nothing is registered, and the servers in use by an interface are skipped (a request removes the key the token has on that server). Each answer is recorded as a *Token probe* and counted in the region summary. A region whose servers refuse a share of the registrations at random (uk_manchester refused about 60% of the requests in a 2026-10-16 measurement) is easy to see there.

`luci install` and the first interface made from LuCI install the cache refresh and renew cron entries when they are missing (and the guard; a retired watchdog's entries are removed).

## Usage
Usage: `pia_wg.sh [ -i <interface|all> ] { configure <section> | start [ --watchdog ] [ --cache ] | restart [ --watchdog ] [ --cache ] | stop | status | renew [ --force | --new-key | --apply ] | renew { install | remove } | watchdog { install | remove } | cache { refresh | install | remove | show } | log { show | clear | path } | update | version}`
<br/>  Details:
  - `configure`          : same as configure all
  - `configure all`      : configure all settings
  - `configure user`     : set PIA user ID and password
  - `configure dip`      : set PIA dedicated IP
  - `configure region`   : set/choose PIA region
  - `configure keys`     : (nothing to configure: the keys live in RAM, see above)
  - `configure interface NAME`: create an interface (a section of `/etc/config/pia`)
  - `configure rename NEW` : rename the interface (`-i OLD`)
  - `configure remove NAME`: forget an interface
  - `configure cache`    : set offline cache directory and options
  - `configure network`  : generate default network settings (and ask about the default route)
  - `configure route`    : default route through the interface
  - `configure firewall` : firewall zone, NAT and the zones forwarded to the interface
  - `init-network`       : setup PIA WireGuard network (no start)
  - `start`              : start PIA WireGuard (if not already up)
  - `start --watchdog`   : same as start and install the guard (the watchdog is retired)
  - `restart`            : start or restart PIA WireGuard
  - `restart --watchdog` : same as restart and install the guard
  - `start|restart --cache` : same and install the cache refresh
  - `stop`               : stop PIA WireGuard
  - `status`             : show PIA WireGuard status
  - `renew`              : register the session key again (never starts or stops the tunnel; skipped while it is up; `--force`, `--new-key [--apply]`)
  - `renew install`      : install the renew cron, the guard cron and the ifup hook, and remove the retired watchdog
  - `renew remove`       : remove the renew cron and the hook
  - `watchdog install`   : alias of the guard install
  - `watchdog remove`    : remove the guard (and any old watchdog entry)
  - `cache refresh`      : refresh the offline cache (servers list, meta servers, tokens)
  - `cache install`      : install the cache refresh (cron, every 6 hours)
  - `cache remove`       : remove the cache refresh
  - `cache show`         : show the offline cache
  - `cache probe [CC]`  : check which regions (of the country CC only) need the legacy token
  - `log show`           : display the watchdog log
  - `log clear`          : clear the watchdog log
  - `log path`           : set a custom Directory Path for the log
  - `luci install`       : install the LuCI web interface (`luci remove` removes it)
  - `api …`              : JSON commands used by the web interface (status, regions, iface-save, …)
  - `update`             : update the script to latest version
  - `version`            : print the version and exit

## Notes
Please, take into account that the script is only creating and setting up the WireGuard interface. It is up to the user to set up/adapt his firewall zones (either including the interface in the WAN zone, or creating a specific zone for it named VPN, PIA or whichever name you want).

A user reported an issue not directly linked to this script but that others users might experience : on his OpenWrt setup, when his router restarts, the time is not properly set and it prevents the interface to go up.
He proposed a solution here: https://github.com/bolemo/pia_wg/issues/5

## Copyright
©2026 bOLEMO
