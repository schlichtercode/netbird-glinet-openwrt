# netbird-glinet-openwrt — Arbeitskontext für Claude

Lies zuerst `notes/` (kurze Markdown-Dateien), bevor du den Rest des Repos liest:

- `notes/00-projekt.md` — was das Repo tut, welche Datei wofür zuständig ist, Architektur-Invarianten
- `notes/10-ziel-gl-sft1200.md` — Fakten zum Zielgerät (GL.iNet Opal, mips_siflower, 18.06, 128 MB RAM)
- `notes/20-recherche.md` — belegte Erkenntnisse mit Quellen (Endianness, NetBird-Builds, bekannte Probleme)
- `notes/30-status-todo.md` — was erledigt ist, was offen ist, was auf dem Gerät noch zu prüfen ist

Regeln:
- Shell-Skripte: POSIX `#!/bin/sh` (BusyBox ash), kein bash. Siehe `CONTRIBUTING.md`.
- Nach jeder größeren Erkenntnis oder Änderung die passende Notiz aktualisieren, statt sie nur im Chat zu erwähnen.
- Nichts auf den Router schreiben, ohne vorher den Zustand zu lesen (read-only Diagnose zuerst).
