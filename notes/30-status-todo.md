# Status & offene Punkte

## Erledigt
- [x] Repo analysiert (Upstream = MT3000/aarch64/21.02-spezifisch)
- [x] Zielarchitektur geklärt **und auf dem Gerät bestätigt**: `linux_mipsle_softfloat`
- [x] NetBird v0.81.4 mipsle_softfloat probeweise geladen und geprüft (46 MB Binary)
- [x] `notes/` + `CLAUDE.md` angelegt
- [x] SSH-Key-Zugang (`ssh root@192.168.8.1` bzw. `ssh opal`, Key `~/.ssh/id_rsa_glinet`)
- [x] Read-only Diagnose auf dem Router (siehe 10-ziel-gl-sft1200.md)

## Entscheidungen, die vom Nutzer kommen müssen (Stand 2026-10-24, Code pausiert)
- [ ] RAM-Strategie: nur ~35 MB verfügbar. Optionen: USB-Swap (empfohlen), nginx `worker_processes 2→1` (~15 MB, GL-Datei, reversibel), erst messen
- [x] **Nutzer-Wunsch 2026-10-24:** keine extra Web-UI, NetBird direkt in die GL-Oberfläche; so weit wie möglich GL-interne Systeme nutzen ⇒ Plan: Lua-RPC-Objekt `netbird` + native View (siehe 10-ziel, Abschnitt oui). nginx-Location/uhttpd-CGI/iframe aus dem Upstream entfallen.
- [x] **DNS (Nutzer 2026-10-24): alle NetBird-DNS-Funktionen nutzen** — Peer-Namen, DNS-Routen/Nameserver-Gruppen für bestimmte Domains, später evtl. alle Anfragen über NetBird. Referenz des Nutzers: auf pfSense läuft NetBird problemlos.
  Plan (GL-konform):
  1. NetBird-DNS bleibt **an**. Für den Router selbst verwaltet NetBird `/etc/resolv.conf` wie vorgesehen; Resolver-Adresse fest auf `127.0.0.153` pinnen (`--dns-resolver-address`), damit kein Konflikt mit dnsmasq auf 127.0.0.1/192.168.8.1 entsteht.
  2. OpenWrt-Besonderheit abfangen: `/etc/resolv.conf -> /tmp/resolv.conf` (tmpfs, von netifd bei WAN/Repeater-Wechseln neu geschrieben, nach Reboot leer). Auf dem Gerät testen, was NetBird daraus macht; Watchdog prüft, dass der Router-Resolver weiter funktioniert (Lookup-Test), und repariert/neu startet DNS bei Bedarf.
  3. LAN-Clients fragen dnsmasq, nicht NetBird ⇒ Watchdog liest `netbird status --json` (`dnsServers[].domains`, Peer-Domain) und schreibt `server=/<domain>/127.0.0.153` nach `/tmp/dnsmasq.d/netbird.conf` (GLs `confdir`), reload dnsmasq bei Änderung. So bekommen LAN-Clients Peer-Namen und DNS-Routen.
  4. UCI-Schalter `lan_dns_via_netbird` (später): dnsmasq-Upstream komplett auf NetBird-Resolver (Schleifenrisiko 127.0.0.1 ↔ 127.0.0.153 beachten).
- [x] Management-Server: self-hosted `https://vpn.schlichte.cloud:443`
- [x] Exit-Node/Routen: Firewall-Zone + Forwardings stehen, fw3-Reload überlebt; Opal nutzt Heimnetz-Route 172.16.10.0/24 als Client (disable_client_routes=0)
- [x] Repo-Umbau: ein Workstation-Installer `install.sh`, `files/`-Baum; Nutzer hat den Umbau mitgetragen (Nachfrage zu CONTRIBUTING beantwortet, Datei lesbar umgeschrieben)
- [x] Firmware-Datei: nicht nötig, Gerät liefert alles (GL-Lua ist auch im Image nur Bytecode)

## Geplante Code-Änderungen (nach Freigabe)
- [ ] `install.sh` (Workstation): SSH-Multiplexing, Probe (hexdump-ELF, RAM, Flash, Module), Arch-Mapping, Download+SHA256 auf dem Mac, Binary per SSH nach `/usr/bin/netbird.new` streamen (nie über `/tmp`), Dateien pushen, procd enable, nginx reload, Bericht
- [ ] `/usr/libexec/netbird-common.sh`: gemeinsame Helfer (`nb_up_args`, Env, `nb_timeout`), UCI-gesteuert
- [ ] Init: UCI-Optionen (gogc, gomemlimit, disable_dns, …), `respawn` unbegrenzt, **Watchdog als zweite procd-Instanz** (kein Cron — GL nutzt `/tmp/gl_crontabs`)
- [ ] Watchdog: Doppel-Daemon-Erkennung nur auf `netbird service run` (nicht `pgrep -x netbird`, das zählt auch CLI-Aufrufe), RSS-Logging, kein `netbird up` bei `NeedsLogin`
- [ ] rc.local unangetastet lassen (nur alte NetBird-Blöcke entfernen, falls vorhanden)
- [ ] sysctl nach `/etc/sysctl.d/90-netbird.conf`
- [ ] nginx-Location mit optionalem `access_by_lua_file` (GL-Login)
- [ ] UI: native GL-View (kein iframe), Felder RAM/RSS/WG-Modus; **i18n für alle 7 Panel-Sprachen** (en, zh-cn, zh-tw, de, es, it, ja)
- [ ] `scripts/setup-swap.sh` (USB unter `/mnt/*`, block-mount `config swap`)
- [ ] `uninstall.sh`
- [ ] README/CONTRIBUTING für SFT1200

## opkg-Feed (2026-10-25)
- [x] `packaging/build.sh` + `check.sh`, Paket `netbird-glinet` (all), `setup-router.sh` als einzige Router-Logik,
      `netbird-fetch-binary`, Workflow `feed.yml`, README-Abschnitt „Install via opkg feed“. Lokal gebaut und validiert;
      `install.sh --probe` läuft mit dem Umbau; Skripte mit der BusyBox-ash des Routers `sh -n`-geprüft.
- [x] **Feed veröffentlicht (2026-10-25 ~01:00):** PR #1 gemerged, Pages auf „GitHub Actions“, Tag `v0.1.0`. Erster
      Deploy-Job abgelehnt („Tag v0.1.0 is not allowed to deploy to github-pages“) — die Umgebung `github-pages` erlaubt
      standardmäßig nur `main`; Tag-Regel `v*` per API angelegt, Job neu gestartet, erfolgreich. Geprüft:
      `https://schlichtercode.github.io/netbird-glinet-openwrt/Packages.gz` → `netbird-glinet 0.1.0-1`, .ipk abrufbar,
      SHA256 stimmt mit Index überein; Release `v0.1.0` hat .ipk + Packages + Packages.gz.
      Push-Hinweis: der HTTPS-Token im Schlüsselbund hatte keinen `workflow`-Scope (Push mit Workflow-Datei abgelehnt);
      Push per SSH-Key funktioniert, Nutzer hat den Token per `gh auth refresh -s workflow` erweitert.
- [x] **2026-10-25 00:15 auf dem Opal getestet:** `opkg install /root/netbird-glinet_0.0.0+git16b0ebf-1_all.ipk`
      über die bestehende install.sh-Installation (MemAvailable vorher 31,7 MB). Ergebnis: 41 s, rc=0, 29 Dateien
      verwaltet, `/etc/config/netbird` byteidentisch (md5 8490dc44…), Binary 0.81.4 erkannt ⇒ kein Download, Dienst
      gestartet (`mgmt=Connected`, `wg=kernel`, RSS 27 MB, MemAvailable danach 24 MB), nginx verzögert neu gestartet
      (3 Prozesse, keine Waisen), Panel HTTP 200. opkg hat die unverwaltete Config selbst geschont und das Template als
      `/etc/config/netbird-opkg` abgelegt ⇒ `postinst` löscht diese Datei jetzt (auf dem Router manuell entfernt).
- [x] **Upgrade über den echten Feed getestet (2026-10-25 01:00, per SSH):** Feed-Zeile in `/etc/opkg/customfeeds.conf`,
      `opkg update` → Liste `netbird_glinet` (569 B), `opkg upgrade netbird-glinet` 0.0.0+git16b0ebf-1 → 0.1.0-1 in 26 s:
      prerm `upgrade` (nur stop), postinst → setup-router (Binary erkannt, nginx unangetastet). Danach: Config byteidentisch,
      `netbird-opkg` entfernt, Hook intakt, 29 Dateien, beide Instanzen mit `respawn`.
      **Beobachtung:** `opkg update` (Entpacken der GL-Listen nach `/var/opkg-lists` = RAM, ~450 KB + opkg selbst) drückte
      MemAvailable unter 9 MB ⇒ Memory Guard stoppte den Daemon zweimal (00:57, 00:58), dabei flackerte die DNS-Auflösung
      (zwei Feed-Downloads „Failed to establish connection“, auch ein GL-Feed). Zweiter `opkg update` bei gestopptem
      Daemon (30 MB frei) lief sauber. ⇒ Auf dem Opal Paketaktionen am besten bei gestopptem NetBird; procd + Cooldown
      holten den Daemon danach automatisch zurück (Respawn-Fix bestätigt). Nach dem Neustart blieb der Status mehrere
      Minuten auf `Connecting` (Management-Stream laut client.log verbunden, Peer-ICE „not initialized yet“, nur Relay) —
      beobachten, ggf. unabhängig vom Paket.
- [x] **Deinstallation über die GL-Weboberfläche getestet (2026-10-25 01:14, Nutzer):** Paketseite zeigt `netbird-glinet 0.1.0-1`
      mit Paketinformationen (Conffiles, Description), Knopf „Deinstallieren“ → prerm `remove` → `setup-router.sh uninstall
      --keep-files`. Ergebnis read-only geprüft: Paket weg, alle 29 Dateien weg, Binary weg, Hook raus, `vpn-client` und
      Dashboard-Bundle wieder GL-Original, Firewall-Zone weg, kein wt0, keine NETBIRD-Chains, resolv.conf normal, nginx mit
      3 Prozessen, `/etc/netbird` + `/etc/config/netbird` erhalten. Einziger Rest: die leeren Verzeichnisse
      `/usr/libexec/netbird` und `/usr/share/netbird-glinet` (opkg löscht nur Dateien) ⇒ `postrm` räumt sie jetzt weg.
- [x] **Erstinstallation über die GL-Paketseite getestet (2026-10-25 01:18, Nutzer):** Feed → „Installieren“ → opkg holt das
      55-KB-.ipk, postinst → `setup-router.sh install` → `netbird-fetch-binary` lädt das 46-MB-Release von GitHub auf den
      Flash (Binary-mtime = Release-Build-Zeit, also frisch entpackt), Dienst gestartet, nginx neu gestartet (md5-Datei war
      durch die Deinstallation weg). Zustand danach: Paket `0.1.0-1` mit 29 Dateien, Config byteidentisch (preinst/postinst),
      kein `netbird-opkg`, Wrapper + `.gl`, Dashboard-Patch, Hook (2 Zeilen, kein Backup), beide Instanzen mit `respawn`,
      `mgmt=Connected`, Kernel-WG, wt0 100.78.14.175, RSS 22,5 MB, MemAvailable 22,7 MB, nginx 3 Prozesse. Enrollment
      aus `/etc/netbird` wurde ohne neuen Setup-Key weiterverwendet. ⇒ Beide Panel-Wege (Install, Uninstall) und der
      Upgrade-Weg per opkg sind auf dem Opal verifiziert.
- [x] **Nebenbefund analysiert (2026-10-25):** Daemon 25 min down, weil procd 2018-11-23 das `respawn`-Flag beim
      Wiederverwenden einer Instanz verliert (Upstream-Fix a30a8fd, 2019-04-17, nicht in GL 4.8.3). Details in
      `20-recherche.md`, „Vorfall 4“. **Fix umgesetzt + getestet (00:40):** `stop_service` via ubus-Instanz-Delete + Warten,
      Watchdog `nb_ensure_daemon` alle 10 s. Externer Kill ⇒ procd-Respawn nach 25 s, `respawn`-Flag bleibt erhalten.
- [x] Schalter-Dropdown zeigte `vpn.sh.pre-netbird` (GL listet alles in `/etc/gl-switch.d/`): Backup entfällt,
      `setup-router.sh` räumt alte Backups weg; auf dem Router gelöscht (2026-10-25).
- [ ] Offen: Verhalten der GL-Paketseite bei mehrminütigem `postinst` (Timeout?) — ggf. Download in den Hintergrund
      (procd-Instanz) verlagern.
- [ ] `install.sh --skip-binary` gegen den Router laufen lassen (nutzt jetzt `setup-router.sh`), danach Panel neu laden.

## Nach der Installation auf dem Gerät zu testen
- [ ] `netbird version` läuft (beweist Endianness)
- [ ] RSS nach 10 min / 1 h (`grep VmRSS /proc/$(pgrep -f "netbird service run")/status`), `MemAvailable`
- [ ] Kernel-WG aktiv? (`[ -e /sys/class/net/wt0/tun_flags ]` ⇒ userspace)
- [ ] `fw3 reload` → bleiben `NETBIRD-*`-Chains erhalten? (`iptables-save | grep NETBIRD`)
- [ ] Peer-Ping in beide Richtungen, LAN-Zugriff über NetBird, ggf. Exit-Node
- [ ] Reboot → kommt der Daemon via procd hoch und verbindet ohne Setup-Key?

## Exit-Node fehlt in der Panel-Karte (2026-10-25 01:30) — Verteilung im Dashboard, kein Panel-Fehler
- Dashboard des Nutzers: Netzwerk „Exit Node – Deutschland (IONOS)“, Routing-Peer `ionos-exit-node`, Metric 9999, Route
  ACTIVE, Distribution Groups „All“, Access Control Groups „-“, Auto Apply aus; im Kopf der Netzwerk-Zeile steht ein
  ausgegrautes „Disabled“.
- Opal: `ListNetworks` am Daemon-Gateway liefert nur `MGMT Network 172.16.10.0/24` (selected). Kein `0.0.0.0/0`, auch nicht
  als nicht-selektiertes Netzwerk ⇒ der Management-Server verteilt die Exit-Node-Route nicht an den Opal-Peer. Die
  Panel-Karte „Netzwerke & Exit-Nodes“ zeigt 1:1 das Gateway-Ergebnis (RPC `get_networks` → `nb_networks_json`).
- `disable_client_routes=0`, kein `api_token` in UCI (Management-API daher nicht abfragbar), Dashboard-Login nicht möglich.
- **Gelöst (01:38): Fehlkonfiguration im Dashboard (Nutzer).** Danach: `ListNetworks` liefert „Exit Node – Deutschland
  (IONOS)“ `0.0.0.0/0` selected=true; Daemon setzt `0.0.0.0/1` + `128.0.0.0/1` via wt0; Peer `ionos-exit-node` Connected
  (Relay); Router-Public-IP = 82.165.153.21 = Public IP des Exit-Nodes; Panel-Karte zeigt den Eintrag aktiv mit Badge
  „Exit-Node“ und Link „Für Schalter nutzen“. LAN-Clients folgen über Zone `netbird` (masq, lan→netbird).
- GeoIP-Nebenfrage: wieistmeineip.de und das NetBird-Dashboard („Region: France“) zeigen Frankreich, ipinfo.io zeigt
  Frankfurt/DE. RIPE-Registrierung des Blocks 82.165.153.0/24: netname `fr-nbz-ionos-cloud-nbz`, country **FR** —
  IONOS hat das Netz unter der französischen Allokation eingetragen, obwohl der Server in Deutschland steht; die
  GeoIP-Datenbanken folgen teils der Registrierung. Nicht beeinflussbar von unserer Seite.

## Durchsatz über den Exit-Node (2026-10-25 01:45, Analyse läuft)
- Speedtest des Nutzers über den Exit-Node: 36 Mbit/s down, 72 up, Ping 30 ms (Ookla, Server Paris). „Deutlich langsamer
  als ohne VPN“ (Zahl ohne VPN noch offen).
- Befund: **beide Peers nur „Relayed“**, 0 ICE/P2P-Verbindungen im client.log, 13× „ICE Agent is not initialized yet“,
  44 STUN-Probes (alle 20 s). Verkehr läuft Opal → Relay `rels://vpn.schlichte.cloud:443` (TLS/QUIC, userspace) → Exit-Node.
- Upstream des Opal: 2,4-GHz-Repeater-Link (sta0, HT20, Kanal 1, −33 dBm) hinter 172.16.80.1 (Telekom-Anschluss,
  öffentlich 84.136.219.81) ⇒ doppeltes NAT. STUN vom Mac hinter dem Opal funktioniert (Google + eigener Server 3478),
  ausgehendes UDP ist also offen; `stun.netbird.io` antwortet nicht (irrelevant bei self-hosted).
- CPU: MIPS 24K-Klasse, 531 BogoMIPS; Relay-Pfad = userspace Go + TLS zusätzlich zu WireGuard ⇒ CPU-limitiert.
- Verdacht für fehlendes P2P: IONOS-Cloud-Firewall-Policy am Exit-Node lässt eingehendes UDP 51820 nicht durch (Default:
  nur explizit geöffnete Ports) und/oder Host-Firewall (Debian 13). Prüfen: IONOS-Panel → Firewall-Policy → UDP 51820;
  auf dem Server `ss -lun | grep 51820`, `nft list ruleset` / `ufw status`. Danach sollte das Panel „P2P“ statt
  „Relayed“ zeigen.
- Erwartungswert nach P2P: Kernel-WireGuard auf dem Opal + 2,4-GHz-HT20-Uplink ⇒ realistisch 50–80 Mbit/s, nicht mehr.

### Ergebnis (01:55): Ursache ist eine Candidate-Race in NetBird auf langsamer Hardware, Relay-Pfad ist CPU-limitiert
- IONOS-Firewall: UDP 51820 ist **offen** (Screenshot „My firewall policy“). Verdacht Firewall erledigt.
- Live-Status: beide Peers `relayed=true`, WG-Endpoint `127.0.0.1:46831` (NetBirds Relay-Proxy), **keine** lokalen
  ICE-Kandidatentypen (`localIceCandidateType` leer). State-Dump: `RemoteCandidate: 20`, dazu **19×** „ICE Agent is not
  initialized yet“. Quelle `client/internal/peer/worker_ice.go@v0.81.4` Z. 160–167: `OnRemoteCandidate` verwirft den
  Kandidaten, wenn `w.agent == nil` — **kein Puffer**. Der Agent entsteht erst in `OnNewOffer`; Offer/Answer und die
  Kandidaten der Gegenseite kommen quasi gleichzeitig, der Opal (531 BogoMIPS, GC-Druck) ist mit der Agent-Erzeugung
  noch nicht fertig ⇒ fast alle Remote-Kandidaten gehen verloren ⇒ ICE kann nie ein Paar bilden ⇒ dauerhaft Relay.
  Lazy Connection ist aktiv (Gegenseite initiiert, „activate peer … by remote signal message“), was die Race verschärft.
  Keine Fehlerzeile im Log; `env_linux.go: failed to dial with fwmark … falling back to legacy routing` ist separat
  (Kernel 4.14) und harmlos. Bug-Report an netbirdio/netbird sinnvoll (Remote-Kandidaten puffern bis Agent existiert).
- Durchsatzmessung vom Router durch den Tunnel (curl 20 MB von speed.cloudflare.com über Exit-Node): **5,2 Mbit/s**;
  CPU dabei 82 % aller 4 logischen Kerne ausgelastet, der NetBird-Daemon allein 48 % der Gesamtkapazität (≈1,8 Kerne).
  Speedtest des Nutzers mit VPN: 6,9/5,9 Mbit/s, Ping 51 ms, Jitter 307 ms; ohne VPN 36/72 Mbit/s.
  ⇒ Relay-Pfad (userspace Go: QUIC/TLS zum Relay + UDP-Proxy zu Kernel-WG) ist auf dem Opal CPU-limitiert.
- Hebel: 1) P2P erreichen (Kernel-WG direkt, kaum Userspace-CPU) — braucht den NetBird-Fix oder einen eigenen Build mit
  Kandidaten-Puffer (Build-Umgebung aus der Go-Bisektion vorhanden); 2) Lazy Connection im Dashboard abschalten (hilft nur
  teilweise, die Race bleibt); 3) weniger CPU-Konkurrenz (nginx-Worker). Ohne P2P bleibt es bei ~5–7 Mbit/s.

### Eigener NetBird-Build mit Patches (2026-10-25 02:20–02:40) — Stand
- `packaging/build-netbird.sh` + `packaging/patches/`: klont v<ver>, wendet die Patches an, baut `linux/mipsle softfloat`
  (CGO_ENABLED=0, -trimpath -s -w, version=0.81.4), legt das Binary nach `.cache/<ver>-mipsle_softfloat/` ⇒
  `./install.sh <router> --force` lädt es hoch. Go 1.27.3 + Toolchain 1.26.10 auf dem Mac, Build ~4 s (Cache warm).
- Patch 1 `buffer-remote-candidates`: `OnRemoteCandidate` puffert bis `OnNewOffer` den Agenten erzeugt hat. **Wirkt**
  (Log: „adding N remote candidate(s) buffered before the ICE agent existed“), reicht aber nicht: ICE geht Checking → Failed
  nach ~12 s. Debug-Log: lokale Kandidaten `host 172.16.80.155:51820` + `srflx 84.136.219.81:2033`; remote vom Exit-Node
  `host/srflx 82.165.153.21:51820`, von netbird-mgmt `host 172.16.10.17:51820` + `srflx 84.136.219.81:16288` (gleicher
  Telekom-Anschluss wie der Opal ⇒ Hairpin-NAT nötig, separates Thema).
- Patch 2 `fwmark-probe-timeout`: `CheckFwmarkSupport()` dialt UDP 127.0.0.1:9 mit **100 ms** Timeout; auf dem Opal
  „failed to dial with fwmark: i/o timeout“ ⇒ „legacy routing“. In legacy routing fehlt die fwmark-Umgehung des Tunnels,
  d. h. mit gewähltem Exit-Node (0.0.0.0/1 + 128.0.0.0/1 via wt0) laufen NetBirds eigene ICE-Prüfpakete zum Exit-Node in
  den Tunnel ⇒ ICE kann nicht klappen. Timeout auf 3 s erhöht. Build 2 (md5 4069bc3c…) hochgeladen; Dienst war vom Nutzer
  deaktiviert (enabled=0), Test steht aus: nach Einschalten im Log „system supports advanced routing“ erwarten, dann
  `ip rule` mit fwmark-Regeln und Peer `relayed=false`.
- Nebenbefund Debug-Log: `udpmux: No decoder for layer type DNS` (Raw-Socket-Mux sieht DNS-Pakete) und
  `ice_monitor: wait for gathering timed out` — beobachten.

### Ergebnis Build 2 (2026-10-25 02:35–02:45): **P2P steht**
- Nach Einschalten: „system supports advanced routing“, `ip rule` 105 (`main suppress_prefixlength 0`) + 110
  (`not fwmark 0x1bd00 lookup netbird`), Routen in Tabelle `netbird` (`default dev wt0`, `172.16.10.0/24`). ICE:
  „connection succeeded“, WG-Endpunkte direkt `82.165.153.21:51820` (Exit-Node) und `172.16.10.17:51820` (netbird-mgmt,
  über das Heimnetz erreichbar), Handshake nach 0,7 s. Panel: Verbunden, Peers 2/2 **P2P**, 53 ms / 86 ms.
- Zwischenfall: Panel blieb auf „Verbinde…“ — verwaiste `/var/run/netbird/status.lock` (procd hatte beim Debug-Neustart
  die Watchdog-Instanz mitten in `nb_status_json` beendet; `rmdir` lief nie) ⇒ jede Abfrage lieferte „stale data“ ohne
  Cache. Fix f9aa171: Sperre älter als 30 s wird gebrochen, `nb_invalidate_status` räumt sie mit. Ohne Neustart eingespielt.
- Fehlschluss korrigiert: der Mac am Opal-LAN ging per WLAN (`en0`, 172.16.11.x) direkt ins Heimnetz, nicht über den Opal;
  Traceroute 1. Hop 172.16.11.254. Routing über den Exit-Node vom Router aus ist korrekt (Public IP 82.165.153.21).
- Daemon-CPU im Leerlauf 39 % eines Kerns (GOMEMLIMIT=32MiB bei 22 MB RSS ⇒ GC-Druck?) — Kandidat für Tuning, RAM ist knapp.
- Beide Patches gehören upstream gemeldet: (1) Remote-Kandidaten puffern, (2) fwmark-Probe-Timeout 100 ms → länger.

## Swap auf USB-Stick eingerichtet (2026-10-25 03:05)
- Anlass: 02:53 **Kernel-OOM-Kill von NetBird** (anon-rss 15 MB) während der Paketaktion im GL-Panel; dmesg zugleich
  `[wdt_error] cpu:1/2 not feed wdt` (CPU stand beim Thrash still). procd + Cooldown brachten den Daemon zurück.
  Panel-Upgrade auf 0.1.1-1 kam dabei nicht durch (opkg status weiterhin 0.1.0-1).
- `netbird-setup-swap` (Default 256 MB) auf dem gesteckten SanDisk Ultra Fit 64 GB (FAT32, `/mnt/sda1`): `dd` brauchte
  **5:38 min**, weil der Stick mit `sync` gemountet ist (block-mount-Default für vfat). Danach `swapon` ok,
  `/proc/swaps`: 262096 kB, 11 Extents, Priority -2; fstab `@swap[0]` device=/mnt/sda1/netbird.swap enabled=1,
  `auto_swap=1` ⇒ kommt nach Reboot wieder (block-mount). Swap-I/O geht am Dateisystem vorbei, `sync` bremst den
  Swap nicht. FAT ignoriert chmod 600 (Datei bleibt 777) — unkritisch.
- MemAvailable ändert sich durch Swap nicht (11–13 MB); Entlastung kommt erst, wenn der Kernel inaktive Seiten (nginx-
  Worker bei geschlossenem Panel) auslagert. `vm.swappiness` = 60 (Default).
- **Offen:** Memory Guard (`nb_mem_guard`, Schwelle `mem_min_kb` 9216) ist nicht swap-bewusst — er stoppt NetBird bei
  MemAvailable < 9 MB, obwohl der Kernel jetzt auslagern könnte. Vorschlag: bei SwapFree > 64 MB Schwelle auf ~4 MB
  senken oder Guard auf `MemAvailable + SwapFree`-Logik umstellen; `swappiness` ggf. auf 80–100.
- Zum Auslagern von nginx: keine cgroups im Kernel, keine Prozess-Zuweisung möglich; LRU erledigt es bei Inaktivität.
  Alternative ohne Stick wäre zram (`kmod-zram`, `zram-swap` im GL-Feed vorhanden), kostet CPU.
