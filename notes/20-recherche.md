# Recherche-Log (belegt)

## Endianness / passender NetBird-Build — ENTSCHIEDEN & AUF DEM GERÄT BESTÄTIGT: `linux_mipsle_softfloat`
- **Gerät (2026-10-24):** `hexdump -n 8 -C /bin/busybox` → `7f 45 4c 46 01 01 01 00`, Byte 5 = `01` = LSB. `/proc/cpuinfo`: `FPU V0.0` ⇒ softfloat.
- OpenWrt-Mainline-Target `target/linux/siflower/Makefile`: `ARCH:=mipsel`; Subtarget `sf19a2890/target.mk`: `CPU_TYPE:=24kc`, `CPU_SUBTYPE:=24kf`, `FEATURES+=fpu`.
  → little-endian, FPU vorhanden. (Quelle: raw.githubusercontent.com/openwrt/openwrt/main/target/linux/siflower/)
- GL.iNet-Forum-Tutorial „Tailscale on GL-SFT1200“ baut `GOOS=linux GOARCH=mipsle GOMIPS=hardfloat` und das läuft auf dem Gerät.
  https://forum.gl-inet.com/t/tutorial-tailscale-on-gl-sf1200-gl-sft1200-opal/31376
- Der opkg-Arch-Name `mips_siflower` ist eine GL.iNet-Eigenbenennung und sagt **nichts** über die Byte-Order (normales OpenWrt würde `mipsel_…` schreiben).
- Softfloat gewählt, weil es unabhängig von FPU/Kernel-Emulation immer läuft; Krypto ist Integer-lastig, FP spielt für NetBird kaum eine Rolle.
- Installer prüft die Endianness zur Laufzeit über das ELF-Header-Byte 5 von `/bin/busybox` (1 = LSB, 2 = MSB) — mit `hexdump`, nicht `od` (`od` fehlt auf dem Opal).

## NetBird-Releases (Stand 2026-10-24, v0.81.4)
- Offizielle Tarballs: `netbird_<ver>_linux_{mips,mipsle,mips64,mips64le}_{softfloat,hardfloat}.tar.gz`, je ~14 MB komprimiert.
- Build-Konfig `.goreleaser.yaml`, Build-ID `netbird-static`: `CGO_ENABLED=0`, `gomips: [hardfloat, softfloat]`, `-s -w` (statisch, gestrippt).
- Getestet heruntergeladen: `netbird_0.81.4_linux_mipsle_softfloat.tar.gz`
  - sha256 `818c7d06fde18d3b088d803d59f3f04f8a1d0acae12f79a6dd133e55cd9ba94e`
  - Binary **46 MB** unkomprimiert, `ELF 32-bit LSB executable, MIPS, MIPS32 version 1 (SYSV), statically linked, stripped`
  - ⇒ auf dem Router **niemals** nach `/tmp` (= RAM!) entpacken; Binary auf dem Mac entpacken und per SSH direkt nach `/usr/bin/netbird.new` streamen.
  - ⇒ ~36 MB Overlay bleiben nach Installation übrig.

## RAM-Problematik (Erfahrungen mit Tailscale, ebenfalls Go, auf exakt diesem Gerät)
- `tailscaled` stürzte nach 1–2 h ab (OOM-Kill); Swap-Datei auf USB-Stick machte es „so much better“.
  https://forum.gl-inet.com/t/tailscale-1-76-1-on-gl-inet-sft1200-opal/49848
- GL.iNet selbst: Tailscale offiziell nicht auf dem Opal, „not enough power and resources“.
- Gegenmaßnahmen für NetBird (im Fork umgesetzt / vorgesehen):
  1. Kernel-WireGuard nutzen statt wireguard-go (GL-Firmware bringt WireGuard mit) — NetBird nimmt das Kernelmodul automatisch.
  2. `GOGC`/`GOMEMLIMIT` per procd-`env` setzen (UCI-Optionen).
  3. `--disable-dns` auf dem Router (dnsmasq bedient das LAN; NetBird-DNS-Proxy brächte nur das resolv.conf-Problem aus dem Upstream-README).
  4. procd-`respawn` mit unbegrenzten Retries, damit ein OOM-Kill nicht in „gave up“ endet.
  5. Optional Swap auf USB (`scripts/setup-swap.sh`).
  6. Watchdog loggt RSS, damit man den Verbrauch über die Zeit sieht.

## NetBird-Client: relevante Flags/Env (Quelle: docs.netbird.io/get-started/cli, /client/environment-variables, client/cmd/*.go)
- `netbird up`: `--disable-client-routes`, `--disable-server-routes`, `--disable-dns`, `--disable-firewall`, `--block-lan-access`, `--block-inbound`, `--interface-name` (default `wt0`), `--wireguard-port` (51820), `--mtu` (1280), `--extra-dns-labels`
- global: `--management-url` (Port zwingend!), `--setup-key`, `--hostname`, `--log-file`, `--log-level`, `--daemon-addr`
- Env (gehört auf den **Daemon**, also in procd `env`): `NB_WG_KERNEL_DISABLED=true` (wireguard-go erzwingen), `NB_SKIP_NFTABLES_CHECK=true` (direkt iptables-Backend; auf 18.06 sinnvoll, spart die nf_tables-Probe), `NB_DISABLE_EBPF_WG_PROXY=true` (Kernel 4.14 → klassischer UDP-Proxy), `NB_USE_LEGACY_ROUTING`, `NB_FWMARK_BASE`, `NB_STATE_DIR`, `NB_LOG_MAX_SIZE_MB`
- Firewall-Backend-Wahl (`client/firewall/create_linux.go`): zuerst nftables-Probe (außer `NB_SKIP_NFTABLES_CHECK=true`), sonst iptables via `coreos/go-iptables` (ruft das `iptables`-Binary). Für Routen nutzt der iptables-Manager ipsets (`nb*`) ⇒ Kernel braucht `ip_set*` + `xt_set`.

## GL.iNet 4.x Web-Stack — auf dem SFT1200 verifiziert, Details in 10-ziel-gl-sft1200.md
- Forum: nginx-Konfig der GL-UI liegt in `/etc/nginx/conf.d/gl.conf`; `nginx.conf` inkludiert `conf.d/*.conf`. Ob `gl-conf.d/` (wie beim MT3000 im Upstream) existiert, ist unbekannt → Installer prüft das und fällt sonst auf eine Warnung zurück.
- LuCI läuft auf uhttpd; `uhttpd -x /cgi-bin` ist auf 4.x-Geräten gesehen worden.

## GL.iNet-Forum: „How to install NetBird on GL.iNet routers …“ (gefunden vom Nutzer, 2026-10-24)
https://forum.gl-inet.com/t/how-to-install-netbird-on-gl-inet-routers-and-route-traffic-through-an-exit-node/72161
- Getestet auf Brume 3 (4.9.0, 21.02) und Slate 7 (4.10.1, 23.05) mit NetBird 0.81.2; Binary über `pkgs.netbird.io/install.sh` (gibt es für mips_siflower nicht — wir laden das Release-Tarball selbst).
- Eigenes procd-Skript `gl-netbird`, Daemon-Env: `NB_CONFIG=/etc/netbird/config.json`, `NB_DISABLE_SSH_CONFIG=1`, `NB_DNS_STATE_FILE=/var/lib/netbird/state.json` (Profil ging sonst nach Reboot verloren, weil /var im RAM liegt — bei uns per Symlink + `NB_DISABLE_SSH_CONFIG=1` gelöst).
- **Firewall GL-nativ per UCI**: Zone `netbird` (device `wt0`, input REJECT, output/forward ACCEPT, masq 1), Forwarding `lan→netbird` (optional `guest→netbird`); für Exit-Node-Betrieb des Routers zusätzlich Forwarding Richtung `wan`. ⇒ übernommen als UCI-Option `firewall_zone` (`nb_firewall_zone_ensure`).
- Exit-Node als Client wählen: `netbird networks list` / `netbird networks select -a <ID>` / `deselect`; Status zeigt dann `0.0.0.0/0`. Kandidat für die View (später).
- DNS: nur `--disable-dns` erwähnt; Hinweis, dass bei deaktiviertem DNS Anfragen nicht über den Exit-Node laufen.
- Keine Panel-Integration, kein RAM-Thema (Geräte mit ≥512 MB).

## Absturz-Analyse: offizielle NetBird-Builds ab 0.78 segfaulten auf dem Opal (2026-10-24)
Symptom: `/usr/bin/netbird version` → sofort `Segmentation fault` (rc=139), keine Go-Panic-Ausgabe, kein Kernel-Log
(auch mit `/proc/sys/debug/exception-trace=1`), `GODEBUG=inittrace=1` zeigt keine einzige Package-Init ⇒ Absturz
im Runtime-Bootstrap vor den Signal-Handlern. Transfer korrekt (md5 identisch).

| Binary | Go-Version | Ergebnis |
|---|---|---|
| netbird 0.81.4 mipsle_softfloat (offiziell) | go1.26.10 | **SIGSEGV** |
| netbird 0.78.0 mipsle_softfloat (offiziell) | go1.26.7 | **SIGSEGV** |
| netbird 0.74.7 mipsle_softfloat (offiziell) | go1.25.12 | läuft (`0.74.7`) |
| Hello-World mipsle soft+hard, lokal gebaut | go1.25.12 / go1.26.10 / go1.27.3 | alle laufen (Goroutine, time.Now/vDSO ok) |

Go-Versionen der Releases (aus den mipsle_softfloat-Tarballs): 0.74.7–0.77.1 = go1.25.12, **ab 0.78.0 = go1.26.x**.
⇒ Das Go-1.26-Runtime startet auf dem Kernel 4.14.90 grundsätzlich, aber die großen NetBird-Binaries (~46 MB) aus
Go 1.26 nicht. Verdacht: Linker/Layout-Problem großer MIPS32-Binaries in Go 1.26 (z. B. Trampolines/Sprungweiten)
oder etwas, das mit Binary-Größe skaliert. Test läuft: eigener Build von 0.81.4 mit go1.25.12 vs go1.26.10.

Weitere Geräte-Fakten aus der Analyse: Userspace-Layout normal (Stack 0x7f…, vDSO vorhanden), kein THP-Sysfs,
`randomize_va_space=1`, `ulimit -s 8192`, `overcommit_memory=0`.

### Ergebnis der Bisektion (2026-10-24, ~21:10)
| Build (alle: linux/mipsle, GOMIPS=softfloat, CGO_ENABLED=0, -trimpath -s -w) | Ergebnis |
|---|---|
| NetBird 0.77.1 Quellcode, **go1.25.12** | läuft |
| NetBird 0.77.1 Quellcode, **go1.26.10** | **SIGSEGV** |
| NetBird 0.81.4, go1.26.10 (eigener Build, identisch zum offiziellen Verhalten) | SIGSEGV |
| NetBird 0.81.4, go1.26.10 + `GOEXPERIMENT=nogreenteagc` | SIGSEGV (Green-Tea-GC ist es nicht) |
| NetBird 0.81.4 mit go1.25.12 | nicht baubar: `golang.org/x/sync@v0.23.0` verlangt go ≥ 1.26 |
| „fat hello“ (8,5 MB, 18 Stdlib-Pakete), go1.26.10 | läuft |

⇒ **Go-1.26-Regression für das große NetBird-Binary (~45 MB) auf Kernel 4.14.90 / interAptiv**, unabhängig vom
NetBird-Code. Go-1.26-Release-Notes nennen Linker-Änderungen am ELF-Layout (`moduledata` in eigener Section
`.go.module`, Sections nach Adresse sortiert) — Verdacht, noch nicht bewiesen. Offene Eingrenzung: go1.26.0 / go1.26.5.

**Projekt-Entscheidung:** Installer pinnt für `mips*`-Architekturen NetBird **0.77.1** (letztes offizielles
Release mit Go 1.25, Juli 2026); andere Architekturen bekommen 0.81.4. Sobald Go/NetBird gefixt sind:
`--version` bzw. `NETBIRD_VERSION_MIPS32` in `install.sh` anheben. Bug-Report an Go (golang/go) ist sinnvoll
(Reproduzierer: NetBird 0.77.1 mit go1.26.10 vs go1.25.12 auf GL-SFT1200) — nur mit Zustimmung des Nutzers posten.

## Vorfall 2026-10-24 ~21:35: Panel-Polling hat den Opal in den Speicher-Thrash getrieben
- Jeder `get_status`-Aufruf aus dem Panel (alle 10 s, zwei Browser) startete `netbird status --json` = zweiter
  46-MB-Go-Prozess. Bei ~7 MB MemAvailable hing die CLI minutenlang im D-State (Paging von Flash), Timeouts
  (rc=124) überlappten sich, nginx hielt 5 Worker (alte Worker konnten wegen blockierender `io.popen`-Lua-Calls
  nicht beenden) ⇒ Router per SSH unerreichbar, Nutzer musste stromlos neu starten.
- **Lösung (umgesetzt in files/):** Daemon startet mit `--enable-json-socket --json-socket unix:///var/run/netbird-http.sock`
  (Flag existiert seit ≥ 0.77); Status kommt per `curl --unix-socket … POST /daemon.DaemonService/Status`
  (grpc-gateway, Antwort = proto `StatusResponse {status, fullStatus{…}, daemonVersion}`), kein CLI-Fork mehr.
  CLI-Fallback nur mit Verzeichnis-Lock (nie zwei gleichzeitig) und 10 s Timeout; Cache 5 s; Panel pollt alle 15 s,
  pausiert bei verstecktem Tab, keine überlappenden Requests. `pid` kommt aus `ubus call service list` statt `ps`.
- Lua-RPC normalisiert beide JSON-Formate (`normalize()`), `dnsdomains.lua`/`exitnode.sh` ebenfalls.
- Lehre: Auf 128-MB-Geräten darf aus dem Web-Pfad **nie** ein Go-Binary gestartet werden; alles über Sockets/ubus.

## Vorfall 2 (2026-10-24 ~22:15): Thrash beim Dienst-Neustart nach Enrollment
- Verbunden: Daemon 22 MB RSS, MemAvailable ~20 MB. `install.sh --skip-binary` → `/etc/init.d/netbird restart`:
  `stop_service` rief `netbird down` (CLI-Fork, 46 MB Binary) auf, während alter Daemon noch lief und neuer startete;
  zusätzlich hatten `nb_mgmt_state`/`nb_status_json` noch CLI-Fallbacks, wenn das Gateway (noch) nicht antwortete,
  und mein Test-Loop rief `nb_mgmt_state` alle 2 s. Ergebnis: `netbird status` im D-State, Load 11, 7 MB frei,
  SSH tot → zweiter Stromlos-Neustart nötig.
- **Fixes:** kein `netbird down` mehr in `stop_service` (SIGTERM reicht, Daemon räumt selbst auf); `restart`-Aktion
  ohne anschließendes `netbird up` (Daemon verbindet mit vorhandenem Enrollment automatisch); Watchdog läuft bei
  `Connecting` kein `up`; Doppel-Daemon-Heilung ohne `cleanup.sh`; **kein CLI-Fallback** in den Status-Helfern,
  solange `json_socket=1`; GOMEMLIMIT auf 32MiB für <256 MB RAM.
- Erkenntnis: Mit ~20 MB Headroom darf es auf dem Opal **nie** zwei NetBird-Prozesse gleichzeitig geben. Verbleibende
  CLI-Forks: nur nutzerinitiiert (`enroll`, `connect`, `disconnect`, `exit_*`) und Watchdog-`up` bei `Disconnected`/`Idle`.
- Ergebnisse vor dem Vorfall: Enrollment ok, Management/Signal verbunden, Kernel-WG, dnsmasq-Forwarding geschrieben
  (vpn.schlicht.tech + DNS-Route schlicht.tech → 127.0.0.153), Router-Resolver via NetBird ok (example.com),
  Firewall-Zone + 7 NETBIRD-Chains vorhanden und **überleben `fw3 reload`**. Peer `netbird-mgmt` blieb `Idle`
  (Lazy Connection / noch keine Verbindung), daher Peer-Namen und DNS-Route noch NXDOMAIN — nach Reboot erneut testen.

## Flags gelten nur beim Enrollment — Profil-Sync im Wrapper (2026-10-24 ~23:00)
- Der Daemon persistiert die `netbird up`-Flags in `/etc/netbird/default.json` (`DisableClientRoutes`, `DisableServerRoutes`,
  `DisableDNS`, `BlockLANAccess`, `CustomDNSAddress`, `WgPort`, …) und verbindet beim Start automatisch damit.
  `netbird up` auf bestehender Verbindung antwortet nur „Already connected“ und übernimmt keine neuen Flags.
- Folge: UCI-Änderungen (z. B. `disable_client_routes 1→0`) kamen nie beim Daemon an.
- Lösung: `run-daemon.sh` synchronisiert vor jedem Start die UCI-Booleans + DNS-Adresse + WG-Port per `sed` in das
  Profil (zeilenbasiert, keine JSON-Neuformatierung). Außerdem gibt `nb_up_args` Booleans immer explizit als
  `--flag=true/false` mit. ⇒ „Speichern → Dienst neu starten“ im Panel wirkt, ohne CLI-Fork.
- Dashboard des Nutzers: Policy „Allowed Travel To MGMT Home“ = Opal → Netzwerk-Ressource 172.16.10.0/24 (Router-Peer
  `netbird-mgmt`). Keine Peer↔Peer-Policy ⇒ ACL-INPUT leer, Ping auf 100.78.190.62 unbeantwortet, kein DNS-Record
  für den Peer — alles erwartbar. Mit `disable_client_routes=0` liegt `172.16.10.0/24 dev wt0` im Routing.

## Vorfall 3 (2026-10-24 ~23:00): verwaiste nginx-Worker fressen 30 MB
- `nginx -s reload` (vom Installer bei jedem Lauf) startet neue Worker; die alten bleiben, solange die
  Panel-WebSocket (`/ws`) des Browsers offen ist ⇒ 5 nginx-Prozesse (75 MB) statt 3 (45 MB), MemAvailable ~8 MB
  **ohne** NetBird-Daemon. Der Speicherwächter stoppte daraufhin (korrekt nach Regel, aber am falschen Täter) NetBird.
- Fix: Installer restartet nginx nur, wenn sich das RPC-Objekt geändert hat (md5-Vergleich), und dann mit
  `/etc/init.d/nginx restart` statt reload. Panel-Seite danach neu laden.
- Hardware-Schalter: Hook in `/etc/gl-switch.d/vpn.sh` → `/usr/libexec/netbird/switch.sh on|off`; getestet (OFF räumt
  wt0/Resolver/dnsmasq auf, ON startet via procd). Menüpunkt jetzt unter VPN.

## GL-Panel: VPN-Anzeige + Dashboard-Karte für NetBird (2026-10-24 ~23:20)
- Internet-Seite: `vpnStatus()` = "is-active", wenn ein Eintrag in `systemStatus.service` (ovpnserver/wgserver) oder in
  `vpnclientStatus` (= `status_list` aus WebSocket-Subscription `vpnclient.status`) `status === 1` hat (2 = connecting).
- `vpnclient.status` kommt aus `/usr/share/gl-ngx/websocket/vpnclient.lua` = `dofile("/usr/lib/oui-httpd/rpc/vpn-client").get_status()`;
  Live-Pushes schickt `gl-ngx-session` (eco) über `/var/run/ngx-ws-proxy.sock` (Format: `<len>\n<json>`, json = {name,data}).
- VPN-Dashboard: Karten aus `vpn-client.get_tunnel().tunnels` (Felder: tunnel_id, name, enabled, via.via, from, to, options, killswitch),
  Status aus `get_status().status_list` (per tunnel_id), Typ-Label aus `d={wireguard,openvpn}` im Bundle; ON/OFF → `set_tunnel`.
- Umsetzung: Lua-Hülle ersetzt `/usr/lib/oui-httpd/rpc/vpn-client` (Original → `vpn-client.gl`), ergänzt NetBird (tunnel_id 900,
  via "netbird") in `get_status`/`get_tunnel`, fängt `set_tunnel`/`remove_tunnel`/… für id 900 ab (→ action.sh start/stop).
  `wspush.lua` (luasocket unix) pusht `vpnclient.status`; Watchdog/Actions/Switch rufen `nb_panel_push`.
  Bundle-Patch: `netbird:"NetBird"` im Typ-Label-Map (Backup `.pre-netbird`). Installer idempotent, Uninstall stellt beides zurück.
- Firmware-Update von GL überschreibt Hülle und Bundle → `install.sh` erneut ausführen.
