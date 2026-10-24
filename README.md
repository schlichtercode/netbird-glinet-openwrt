# netbird-glinet-openwrt

> NetBird (WireGuard overlay network) on GL.iNet routers — native page in the GL.iNet admin panel, procd service, watchdog, LAN DNS forwarding, exit-node support. Built for the 128 MB **GL-SFT1200 (Opal)**, works on other GL.iNet SDK4 routers too.

Fork of [devNalyx/netbird-openwrt](https://github.com/devNalyx/netbird-openwrt), reworked for small MIPS routers and for a native GL.iNet integration (no extra web UI, no nginx/CGI hacks).

## What you get

- **NetBird page inside the GL.iNet admin panel** (VPN → NetBird), in all seven panel languages (en, de, es, it, ja, zh-cn, zh-tw). Enrol with a setup key, see peers, memory and DNS state, restart, toggle the exit node, edit every setting. Protected by the panel login like every other GL page.
- **procd service** with auto-restart and a **watchdog instance**: reconnects, repairs the router's resolver, keeps the firewall zone, logs memory use, and a **memory guard** that stops the daemon before the router starts thrashing and brings it back after a cooldown. No cron (GL.iNet's crond ignores `/etc/crontabs`).
- **Hardware switch**: set it to "VPN client" in the GL panel and it turns NetBird (or the preferred exit node) on and off.
- **Shows up like a GL VPN**: the VPN indicator on the Internet page lights up while NetBird is connected, and the VPN Dashboard gets a "NetBird" card (type, server, virtual IP, traffic, ON/OFF switch).
- **NetBird DNS fully usable**: peer names and DNS routes work on the router *and* for every LAN client — the watchdog publishes NetBird's domains to GL's dnsmasq as forwarders.
- **GL-native firewall zone** `netbird` for `wt0` (masquerade, lan→netbird, netbird→wan) so LAN clients can use NetBird routes / exit nodes and the router can be an exit node itself.
- **Two ways to install**: an **opkg feed** you add in the GL.iNet panel (Applications → Software packages → Sources) and then install/upgrade `netbird-glinet` like any other package — or the **one-command installer** `install.sh` from your computer, which also prints a compatibility report. Both stream the NetBird binary straight onto flash (never through RAM-backed `/tmp`); `uninstall.sh` / `opkg remove` take everything out again.
- Tuned for 128 MB routers: `GOGC`/`GOMEMLIMIT`, kernel WireGuard, no CLI forks from the web path, optional USB swap helper.

## Supported hardware

| Device | SoC / arch | Firmware | Status |
|---|---|---|---|
| GL.iNet **GL-SFT1200 Opal** | SiFlower SF19A28, MIPS32r2 LE (`mipsle_softfloat`) | 4.8.3 (OpenWrt 18.06, kernel 4.14) | ✅ reference device, tested |
| GL.iNet GL-MT3000 / MT6000 / AXT1800 … | aarch64 / ipq | 4.x | ⚠️ should work (same SDK4 panel, same scripts), untested here |
| Other OpenWrt (no GL panel) | any | 21.02+ | ⚠️ service + CLI tools work, no panel page |

Requirements on the router: `kmod-wireguard` (bundled in GL firmware), `kmod-tun`, `iptables` + `ipset`, `curl`, `lua` (all present on GL.iNet 4.x). Free flash: ~50 MB for the binary.

## Install via opkg feed

The feed is published to GitHub Pages by the release workflow: **`https://schlichtercode.github.io/netbird-glinet-openwrt`**. The package `netbird-glinet` is `Architecture: all` (~55 KB of shell, Lua and panel files); its `postinst` downloads the matching NetBird binary (~46 MB) from GitHub straight onto flash and verifies the SHA256 — it never passes through `/tmp` (RAM).

**In the GL.iNet panel:** Applications → *Software packages* (Plug-ins) → *Sources* → add

```
src/gz netbird_glinet https://schlichtercode.github.io/netbird-glinet-openwrt
```

then *Update*, search for `netbird-glinet`, *Install*. The first install takes a few minutes on a MIPS router (binary download + write to flash); if the panel gives up waiting, the install still finishes in the background — check with `logread -e netbird` or run `netbird-fetch-binary` over SSH.

**Over SSH:**

```bash
echo 'src/gz netbird_glinet https://schlichtercode.github.io/netbird-glinet-openwrt' >> /etc/opkg/customfeeds.conf
opkg update && opkg install netbird-glinet
```

- Needs ~50 MB free flash and internet access on the router; dependencies `curl` and `lua` are part of GL.iNet firmware.
- **Upgrade:** *Upgrade* in the panel or `opkg update && opkg upgrade netbird-glinet`. `/etc/config/netbird` is a conffile — your settings survive (opkg's `netbird-opkg` copy of the template is removed by `postinst`), and so does the enrollment in `/etc/netbird/`.
- **Already installed with `install.sh`?** Installing the package on top is safe: files are identical, the config is kept, and the binary is only downloaded when the version differs (tested on the Opal: 41 s, no download).
- **Remove:** `opkg remove netbird-glinet` (keeps `/etc/netbird` and `/etc/config/netbird`; delete those by hand for a full purge). `uninstall.sh` notices an opkg install and hands over to `opkg remove`.
- **After a GL firmware update** that kept your settings, GL's original `vpn-client` object and dashboard bundle are back: run `/usr/libexec/netbird/setup-router.sh install --no-fetch` (or reinstall the package).
- **Change the pinned NetBird version:** `netbird-fetch-binary --version 0.77.1` (the package default is in `/usr/share/netbird-glinet/netbird-release`).

## Install with install.sh

On your computer (macOS/Linux), with SSH access to the router:

```bash
git clone https://github.com/schlichtercode/netbird-glinet-openwrt.git
cd netbird-glinet-openwrt
./install.sh root@192.168.8.1
```

Optional second argument: your management URL **with port**, e.g. `./install.sh root@192.168.8.1 https://netbird.example.com:443`. Use `./install.sh root@192.168.8.1 --probe` to only print the compatibility report.

Then open the GL.iNet panel → **VPN → NetBird**, enter the management URL (default `https://api.netbird.io:443`) and a **reusable setup key** (NetBird dashboard → Setup Keys), click *Connect*. Enrollment survives reboots.

Tip for GL.iNet 18.06-based firmware (Opal): its dropbear only speaks `ssh-rsa`; the installer passes the right options, and a key-based login avoids repeated password prompts:
```bash
ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa_glinet -N ""
cat ~/.ssh/id_rsa_glinet.pub | ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.8.1 'cat >> /etc/dropbear/authorized_keys'
```

## How it works

```
/etc/init.d/netbird (procd, START=90)
 ├─ instance "daemon":   netbird service run --enable-json-socket --json-socket tcp://127.0.0.1:18090
 │      env: GOGC=50 GOMEMLIMIT=48MiB NB_SKIP_NFTABLES_CHECK NB_DISABLE_EBPF_WG_PROXY …   (from UCI)
 └─ instance "watchdog": /usr/libexec/netbird/watchdog.sh loop   (every 5 min)
        reconnect · duplicate-daemon self-heal · firewall zone · chains check
        resolv.conf repair · dnsmasq forwarding of NetBird domains · memory log (logread -e netbird)

GL.iNet panel  ──$rpcRequest("netbird", …)──►  /usr/lib/oui-httpd/rpc/netbird  (Lua)
                                                 ├─ get_status: curl → daemon JSON gateway (loopback), /proc, ubus
                                                 ├─ set_config: validated → UCI /etc/config/netbird
                                                 └─ action:     /usr/libexec/netbird/action.sh (background, lock)
/www/views/gl-sdk4-ui-netbird.common.js  (Vue view, GL components)   /www/i18n/gl-sdk4-ui-netbird.<lang>.json
```

State lives in `/etc/netbird/` (overlay flash); `/var/lib/netbird` is a symlink to it because `/var` is RAM on OpenWrt.

### Configuration (`/etc/config/netbird`)

Everything is editable in the panel's *Advanced settings*; the UCI file is the source of truth.

| Section.option | Default | Meaning |
|---|---|---|
| `settings.enabled` | 1 | service on/off |
| `settings.gogc` / `gomemlimit` | 50 / `48MiB` on <256 MB RAM | Go GC tuning for the daemon |
| `settings.json_socket` | 1 | daemon JSON API on 127.0.0.1:18090 (status without forking the CLI) |
| `settings.wg_userspace` | 0 | force wireguard-go instead of the kernel module |
| `settings.disable_ebpf_proxy` | 1 (kernel < 5) | classic UDP proxy |
| `connection.management_url` | `https://api.netbird.io:443` | **must include the port** |
| `connection.disable_client_routes` | 1 | ignore other peers' routes (keeps the WAN default route safe) |
| `connection.disable_server_routes` | 0 | 1 = never forward for peers (no LAN access / exit node) |
| `connection.disable_dns` | 0 | NetBird DNS on; proxy at `dns_resolver_address` (127.0.0.153) |
| `connection.lan_dns_forward` | 1 | dnsmasq forwards NetBird domains → LAN clients resolve peers + DNS routes |
| `connection.firewall_zone` | 1 | maintain zone `netbird` (wt0) + forwardings |
| `connection.block_lan_access` | 0 | peers may not reach this router's LAN |
| `connection.exit_node` | — | preferred exit node (network ID) for the hardware switch |
| `settings.hw_switch` / `hw_switch_mode` | 1 / `service` | hardware switch coupling, see below |
| `settings.mem_min_kb` / `mem_cooldown` | 9216 / 120 | memory guard: stop the daemon below this MemAvailable, restart after the cooldown |
| `connection.api_token` | — | NetBird API token: enables the exit-node switch in the panel |

Apply changes with `/etc/init.d/netbird restart` (the panel does this for you).

### DNS

NetBird's resolver listens on `127.0.0.153:53` (dnsmasq owns `127.0.0.1`). NetBird points the **router's own** `/etc/resolv.conf` at it and forwards everything else to its previous upstream (dnsmasq). On OpenWrt that file lives in RAM and gets rewritten by dnsmasq restarts, so the watchdog re-points it whenever NetBird is connected. For **LAN clients** the watchdog reads the domains NetBird serves (peer domain + every DNS route from your management server) and writes `server=/<domain>/127.0.0.153` lines to `/tmp/dnsmasq.d/netbird.conf`, reloading dnsmasq only when the list changes.

### Networks and exit nodes (this router as a client)

The *Networks & exit nodes* card lists every route and exit node your management server offers this router, with a switch per entry. Switching one on selects it in the daemon (the same as `netbird networks select`); LAN clients use it automatically thanks to the firewall zone. Mark one exit node as *preferred* to tie it to the hardware switch (below). Requires *Ignore routes from other peers* to be off.

### VPN indicator and VPN Dashboard

GL's Internet page and VPN Dashboard take their VPN state from the panel's `vpn-client` RPC object. The installer puts a small Lua wrapper in its place (the original is kept as `vpn-client.gl`) that passes everything through and adds a "NetBird" entry: the indicator lights up when NetBird is connected, and the dashboard shows a NetBird card whose ON/OFF switch starts and stops the service. In GL's *global mode* the dashboard shows only the first tunnel, so NetBird is listed first while GL's own tunnel has no configuration. Two strings in the dashboard bundle are patched to label the type (backup `*.pre-netbird`). A GL firmware update restores the originals — re-run `install.sh`; `uninstall.sh` restores them too.

### Hardware toggle switch

Set the router's slide switch to **VPN client** under *System → Toggle Button Settings*. The installer appends a two-line hook to GL.iNet's switch handler (`/etc/gl-switch.d/vpn.sh`), so the switch also drives NetBird:

| `settings.hw_switch_mode` | Switch on | Switch off |
|---|---|---|
| `service` (default) | start NetBird | stop NetBird (wt0, rules and DNS are cleaned up) |
| `exitnode` | select the preferred exit node (`connection.exit_node`) | deselect it, NetBird stays connected |

Turn the coupling off with `settings.hw_switch = 0`. `uninstall.sh` removes the hook; after a GL.iNet firmware update re-run `install.sh` to restore it.

### Exit node (this router as exit node for peers)

*This router as exit node for peers:* enable server routes (default), create the exit-node route in the NetBird dashboard. The firewall zone provides masquerading. With an API token stored in the panel, the page shows a toggle for that route.

*LAN clients through a remote exit node:* `netbird networks select -a <id>` over SSH (see `netbird networks list`); the firewall zone's lan→netbird forwarding does the rest. Keep *ignore routes from other peers* on unless you want that.

## Memory on 128 MB routers

Measured on the Opal: daemon ≈ 17 MB RSS idle, GL's own nginx ≈ 45 MB, ~30 MB left. Check with `netbird-status` or `logread -e netbird` (`rss=… mem_avail=…` every 5 min). If it gets tight: plug in a USB stick and run `netbird-setup-swap` (creates a 256 MB swap file there and persists it in `/etc/config/fstab`). Swap on the router's own NAND is impossible (UBIFS) and would wear it out.

## Troubleshooting

**`netbird version` dies with a bare `Segmentation fault` on a MIPS router.** NetBird ≥ 0.78 is built with Go 1.26, whose binaries carry a ~35 MB zero-filled BSS segment. With the kernel's default overcommit heuristic a 128 MB router refuses that mapping at `exec()` and kills the process before `main()`. The installer sets `vm.overcommit_memory=1` in `/etc/sysctl.d/90-netbird.conf`; verify with `sysctl vm.overcommit_memory`. (Bisected with identical NetBird source: Go 1.25 → runs, Go 1.26 → SIGSEGV; details in `notes/20-recherche.md`.) Alternative: `./install.sh --version 0.77.1` (last Go-1.25 release).

**Installed from the feed, but the service does not start / `netbird: not found`.** The binary download in `postinst` failed (no internet on the router, not enough flash, GitHub unreachable). Run `netbird-fetch-binary` over SSH — it prints the reason — then `/etc/init.d/netbird restart`.

**Panel shows "Setup key required".** Enter a reusable setup key. Without one, `netbird up` would start an interactive SSO device flow — the watchdog deliberately never does that.

**"missing port in address" / connection cycling.** The management URL needs an explicit port (`https://host:443`).

**NETBIRD-* iptables chains disappeared after a WAN change.** fw3 reloads flush them; the watchdog notices within 5 min and re-applies via `netbird down/up`. Run `/usr/libexec/netbird/watchdog.sh once` to do it now.

**Two daemons / "Chain already exists".** `pkill` is missing on GL BusyBox; all scripts use `killall`. The watchdog kills duplicates and restarts. Manual full teardown: `/usr/libexec/netbird/cleanup.sh`.

**Useful commands on the router**
```bash
netbird-status                         # overview incl. memory, DNS, chains
logread -e netbird                     # watchdog + memory log
/etc/init.d/netbird restart            # restart daemon + watchdog
/usr/libexec/netbird/watchdog.sh once  # run all checks now
curl -s -X POST -d '{}' http://127.0.0.1:18090/daemon.DaemonService/Status   # raw daemon status
```

## Uninstall

```bash
./uninstall.sh root@192.168.8.1          # keeps /etc/netbird (enrollment) and /etc/config/netbird
./uninstall.sh root@192.168.8.1 --purge  # removes those too
```

Installed from the opkg feed? `opkg remove netbird-glinet` does the same (its `prerm` runs `setup-router.sh uninstall`); `uninstall.sh` detects that case and calls opkg for you.

## Repository layout

```
install.sh / uninstall.sh      run on your computer, talk to the router over SSH
packaging/build.sh             builds the opkg package netbird-glinet_<ver>_all.ipk + Packages index (no SDK)
packaging/check.sh             validates a built feed directory (unpacks the .ipk, checks the index)
packaging/ipkg/                preinst / postinst / prerm of the package (thin wrappers around setup-router.sh)
.github/workflows/feed.yml     on tag v*: build, publish the feed to GitHub Pages, attach the .ipk to the release
files/                         1:1 image of what lands on the router
  etc/init.d/netbird           procd service (daemon + watchdog instances)
  etc/config/netbird           UCI template (only installed if absent; conffile in the package)
  etc/sysctl.d/90-netbird.conf keepalive, ip_forward, vm.overcommit_memory=1
  usr/libexec/netbird/setup-router.sh   router-side setup/uninstall shared by install.sh and the package scripts
  usr/sbin/netbird-fetch-binary        downloads + verifies the NetBird release binary on the router
  usr/share/netbird-glinet/netbird-release   pinned NetBird version (read by install.sh and netbird-fetch-binary)
  usr/libexec/netbird/         common.sh, watchdog.sh, action.sh, cleanup.sh, exitnode.sh, dnsdomains.lua
  usr/lib/oui-httpd/rpc/netbird   GL panel RPC object (Lua)
  usr/share/gl-validator.d/netbird.lua
  usr/share/oui/menu.d/netbird.json
  www/views/gl-sdk4-ui-netbird.common.js   panel page (gzipped on install)
  www/i18n/gl-sdk4-ui-netbird.*.json       7 languages
  usr/sbin/netbird-status, netbird-setup-swap
notes/                         working notes: device facts, research, decisions (German)
```

## License

MIT — see [LICENSE](LICENSE). NetBird itself is BSD-3-Clause.
