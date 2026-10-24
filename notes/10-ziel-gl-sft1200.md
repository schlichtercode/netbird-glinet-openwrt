# Zielgerät: GL.iNet Opal GL-SFT1200 — verifizierte Fakten

Quelle: read-only SSH-Diagnose am 2026-10-24 (`ssh root@192.168.8.1`, Key-Login eingerichtet, Alias `opal`).
Nutzer-Entscheidung: Original-GL.iNet-Firmware bleibt, GL-Weboberfläche bleibt, keine Custom-Images.

## Plattform
| Komponente | Wert |
|---|---|
| Firmware | GL.iNet **4.8.3**, `DISTRIB_TARGET='siflower/sf19a28-fullmask'`, OpenWrt 18.06 (LEDE), GCC 7.4 |
| Kernel | 4.14.90 SMP, kein `/proc/config.gz` |
| CPU | `MIPS interAptiv (multi) V2.8`, **`FPU V0.0`** (⇒ softfloat), isa mips32r2, 4 logische CPUs, BogoMIPS 531 |
| Endianness | **little-endian** — ELF-Header von `/bin/busybox` Byte 5 = `01` (LSB). ⇒ NetBird-Build `linux_mipsle_softfloat` |
| RAM | MemTotal **118.700 kB**, MemAvailable **~35.000 kB** (MemFree ~21 MB) — Hauptrisiko |
| Größte RSS-Verbraucher | nginx 15,3 + 15,2 + 11,4 MB (lua-nginx, `worker_processes 2`), lua 3,7, uhttpd 2,8, eco ×3 ~6,5 MB |
| Flash | `/overlay` ubifs **84 MB frei** (ubi0_1), `/rom` squashfs 18,5 MB; `/tmp` tmpfs 59 MB (= RAM!) |
| Swap | keiner; `mkswap`/`swapon`/`swapoff`/`dd` vorhanden, `block-mount` installiert (`auto_swap 1`, `auto_mount 1`) |
| USB | kein `/tmp/mountd`; block-mount mountet nach `/mnt/<dev>` (aktuell leer) |

## Netzwerk-Stack
- `/dev/net/tun` vorhanden, Module **geladen**: `tun`, `wireguard` (kmod-wireguard 1.0.20211208), `ip_set` + alle hash/bitmap-Typen, `xt_set`, `xt_connmark`; auf Disk zusätzlich `xt_owner`
- Binaries: `iptables 1.8.2` (legacy), `ipset 7.1`, `wg`, `curl 7.63` + ca-bundle (259 Certs), `uclient-fetch`, `wget` (busybox), `timeout`, `pgrep`, `killall`, `hexdump`, `logger`, `ubus`, `uci`, `netstat`
- **Fehlt**: `pkill`, `nft`, `od`, `xxd`, `file`, `ss`, `lsof`, `busybox`-Applet-Aufruf (`busybox --help` → applet not found)
- Firewall: **fw3/iptables** (107 Regeln), `flow_offloading 1` + `flow_offloading_hw 1`, `fullconenat`; Zonen `lan`, `wan` (eth0.2 + wwan), `guest`; mehrere `config include` (firewall.user, gl_block.sh, …)
- WAN aktuell über **`sta0`** (Repeater-Modus, 172.16.80.0/24), Default-Route `via 172.16.80.1 dev sta0`; `eth0.2` ist der WAN-Port (udhcpc läuft)
- `ip rule`: GL hat `1: from all iif lo lookup 16800`; `ip_forward = 1` bereits aktiv; `tcp_keepalive_time = 120`
- DNS: dnsmasq lauscht auf 127.0.0.1:53, 192.168.8.1:53, sta0-IP:53; `/etc/resolv.conf -> /tmp/resolv.conf` (`nameserver 127.0.0.1`)
- GL-eigene WireGuard-Client/-Server-Configs vorhanden (`/etc/config/wireguard`, `route_policy` mit fwmark `0x8000`), Policy aktuell `enabled 0`

## Web-Stack (GL SDK4)
- nginx 1.26 (nginx-ssl, lua), `nginx.conf` → `conf.d/gl.conf` → server { … `include /etc/nginx/gl-conf.d/*.conf;` } ⇒ **`/etc/nginx/gl-conf.d/netbird.conf` funktioniert wie beim MT3000**
- `location /cgi-bin/` in gl.conf geht an **fcgiwrap** (nicht uhttpd) und ist durch `oui-access.lua` (GL-Login) geschützt
- uhttpd lauscht **127.0.0.1:8080** (+8443) mit `-x /cgi-bin -h /www` ⇒ Upstream-Ansatz `proxy_pass http://127.0.0.1:8080/cgi-bin/netbird-api` funktioniert
- GL-Login für eigene Locations erzwingbar mit `access_by_lua_file /usr/share/gl-ngx/oui-access.lua;` (siehe `gl-conf.d/access.conf`)
- Panel: `/usr/share/oui/menu.d/*.json`, `/www/views/gl-sdk4-ui-<view>.common.js.gz`, `/www/i18n/gl-sdk4-ui-<view>.<lang>.json` (de, en, es, it, ja, zh-cn, zh-tw) ⇒ Upstream-Integration passt
- `/www/cgi-bin/` existiert (enthält `glc`)

## Cron ist anders als Standard-OpenWrt
- `crond` läuft mit `-c /tmp/gl_crontabs` (gestartet von `/etc/init.d/gl_timer`), `/etc/crontabs/` ist **leer**, `crontab -l` schlägt fehl
- `/tmp/gl_crontabs/root` liegt auf tmpfs und wird von GL-Skripten (gl_timer, auto_timezone, gl_modem, …) verwaltet ⇒ **kein Cron für den Watchdog**; stattdessen Watchdog als zweite procd-Instanz (Schleife) im NetBird-Init

## rc.local / sysctl
- `/etc/rc.local`: `. /lib/functions/gl_util.sh; remount_ubifs` (nur für a1300 relevant) + `echo 3 > drop_caches`. **Nicht überschreiben**, nur ggf. eigene Zeilen anhängen/entfernen
- `/etc/sysctl.conf` vorhanden (leer bis auf Kommentar), `/etc/sysctl.d/10-default.conf` … `99-disable-ipv6.conf` ⇒ eigene Werte nach `/etc/sysctl.d/90-netbird.conf`

## Sonstiges
- Log: `logread` funktioniert; hostapd spammt „Failed to set beacon parameters“ (unabhängig von uns)
- Prozesse mit viel Eigenleben: gl-cloud, rtty, modem_*-Skripte (Cron jede Minute), ksmbd, sms_manager, carrier-monitor

## GL-Panel intern (oui) — Basis für eine native Integration (verifiziert 2026-10-24)
- Backend: RPC-Objekte liegen als Lua-Dateien unter `/usr/lib/oui-httpd/rpc/<objekt>` (GLs eigene sind Lua-5.1-Bytecode `LuaQ`, einige `.so`). Ein Objekt ist eine Tabelle `M` mit Methoden `M.<name> = function(params) … end`, `require "oui.rpc"`, `oui.fs`, `uci`, `oui.ubus` verfügbar.
- Dispatcher: `/usr/share/gl-ngx/oui-rpc.lua` → `/usr/lib/lua/oui/rpc.lua`; Session via ubus `gl-session`; ACL: `rpc.access(scope, entry, need)`, Gruppe `root` darf alles; `no-auth-methods` in UCI `oui-httpd`.
- Frontend: Views werden per `GET /views/gl-sdk4-ui-<view>.common.js` geladen und mit `eval` als `module.exports` (Vue-Komponente) registriert. Aufruf des Backends: `window.$rpcRequest("call", ["sid", "<objekt>", "<methode>", params])`.
- Global registrierte Komponenten: `el-dialog`, `el-input`, `el-table`, `el-tag`, `gl-button`, `gl-card`, `gl-switch`, `gl-table` ⇒ handgeschriebene `render(h)`-View kann im GL-Look gebaut werden.
- i18n: `/www/i18n/gl-sdk4-ui-<view>.<lang>.json` mit `"menu_<view>"` für den Sidebar-Titel (de, en, …).
- Konsequenz: NetBird kann als **natives GL-Objekt + native View** laufen — ohne nginx-Sonder-Location, ohne uhttpd-CGI, ohne iframe, Login durch GL.
