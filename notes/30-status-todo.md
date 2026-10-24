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
