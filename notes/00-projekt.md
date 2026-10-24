# Projektüberblick

Fork von <https://github.com/devNalyx/netbird-openwrt> (Upstream-Referenzgerät: GL-MT3000, aarch64, OpenWrt 21.02).
Ziel dieses Forks: NetBird auf dem **GL.iNet Opal GL-SFT1200** lauffähig machen, mit Original-GL.iNet-Firmware 4.8.3 (OpenWrt-18.06-Basis).

## Was das Repo liefert
- NetBird-Client-Binary als procd-Dienst (`/etc/init.d/netbird`, START=90, respawn)
- Persistente Config in `/etc/netbird/` (Overlay), `/var/lib/netbird` ist Symlink dorthin (`/var` = tmpfs)
- UCI-Config `/etc/config/netbird` (anonyme Sections: `netbird.@connection[0].*`)
- Web-UI (SPA `index.html`) + Shell-CGI JSON-API, per nginx unter `/netbird/` in das GL-Panel eingebettet (iframe-View `#/netbirdview`)
- Watchdog-Cron (5 min): Reconnect, TCP-Keepalive-Sysctls, ipset-Regeln für Exit-Node, Log-Rotation, Doppel-Daemon-Selbstheilung
- Exit-Node-Toggle über NetBird-Management-API (optionaler API-Token)

## Dateien → Zweck
| Datei | Zweck |
|---|---|
| `gl-sdk4-netbird/root/etc/init.d/netbird` | **kanonisches** procd-Init-Skript (einziger Weg, den Daemon zu starten) |
| `gl-sdk4-netbird/root/etc/config/netbird` | UCI-Template |
| `gl-sdk4-netbird/root/usr/share/oui/menu.d/netbirdview.json` | Sidebar-Eintrag im GL-Panel (SDK4) |
| `gl-sdk4-netbird/root/www/views/*.common.js.gz` | GL-Panel-View: nur ein iframe auf `/netbird/` |
| `gl-sdk4-netbird/deploy.sh` | SSH-Push: Init, UCI, Panel-Dateien |
| `nginx-app-netbird/index.html` | Web-UI (SPA), ruft `/netbird/api` |
| `nginx-app-netbird/netbird-api.cgi` | JSON-API (GET Status / POST Aktionen), landet in `/www/cgi-bin/netbird-api` |
| `nginx-app-netbird/netbird.conf` | nginx-Location-Block → `/etc/nginx/gl-conf.d/netbird.conf`; `/netbird/api` wird an uhttpd `127.0.0.1:8080/cgi-bin/netbird-api` proxied |
| `nginx-app-netbird/deploy.sh` | SSH-Push: UI, CGI, Watchdog, Cleanup, Init; aktiviert procd; Cron; Sysctls |
| `nginx-app-netbird/netbird-ui.cgi` | alte server-side-rendered UI (Legacy, nicht deployed) |
| `nginx-app-netbird/netbird-setup-api.sh`, `setup-api.sh`, `netbird-toggle-exit.sh` | Management-API-Helfer (peer_id/route_id finden, Exit-Route togglen) |
| `scripts/install.sh` | Upstream-Skript, läuft **auf dem Router**, hart auf arm64/MT3000; Watchdog-Schritt ist ein kaputter Platzhalter; schreibt rc.local → in diesem Fork ersetzt |
| `scripts/netbird-watchdog.sh` | Cron-Watchdog |
| `scripts/netbird-cleanup.sh` | kompletter Teardown (Prozesse + alle NETBIRD-* iptables-Chains) |
| `scripts/status.sh`, `start-daemon.sh`, `setup-exit-node.sh` | Debug-/Einmal-Helfer |

## Architektur-Invarianten (aus CONTRIBUTING.md)
- Daemon wird **nur** über procd gestartet, kein rc.local-Start
- Config in `/etc/netbird/`, Symlink wird in `start_service()` angelegt
- `--disable-client-routes` ist auf einem Router Pflicht (sonst überschreibt ein fremder Exit-Node die WAN-Default-Route)
- `pkill` fehlt auf GL-BusyBox → immer `killall -q netbird` / `pgrep -x netbird`
- Management-URL **mit explizitem Port** (`https://host:443`), sonst `missing port in address`
