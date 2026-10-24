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
- [ ] GitHub: Repo-Settings → Pages → Source „GitHub Actions“ aktivieren, dann ersten Tag `v0.1.0` pushen und den
      Workflow-Lauf prüfen (Pages-URL, Release-Asset).
- [x] **2026-10-25 00:15 auf dem Opal getestet:** `opkg install /root/netbird-glinet_0.0.0+git16b0ebf-1_all.ipk`
      über die bestehende install.sh-Installation (MemAvailable vorher 31,7 MB). Ergebnis: 41 s, rc=0, 29 Dateien
      verwaltet, `/etc/config/netbird` byteidentisch (md5 8490dc44…), Binary 0.81.4 erkannt ⇒ kein Download, Dienst
      gestartet (`mgmt=Connected`, `wg=kernel`, RSS 27 MB, MemAvailable danach 24 MB), nginx verzögert neu gestartet
      (3 Prozesse, keine Waisen), Panel HTTP 200. opkg hat die unverwaltete Config selbst geschont und das Template als
      `/etc/config/netbird-opkg` abgelegt ⇒ `postinst` löscht diese Datei jetzt (auf dem Router manuell entfernt).
- [ ] Noch nicht getestet: `opkg remove netbird-glinet` (prerm → `setup-router.sh uninstall --keep-files`), Upgrade auf eine
      neuere Paketversion (prerm `upgrade`), Installation über die GL-Paketseite mit echtem Feed.
- [ ] **Nebenbefund:** Vor der Installation war der Daemon seit 23:48 down (`hold-until` 23:48:34 längst abgelaufen),
      der Watchdog loggte 25 min lang nur „daemon socket missing (procd will respawn)“ ohne Neustart. Watchdog sollte
      nach N Intervallen ohne Socket `/etc/init.d/netbird restart` auslösen; Ursache (procd respawn erschöpft? run-daemon
      hängt?) per `ubus call service list '{"name":"netbird"}'` prüfen.
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
