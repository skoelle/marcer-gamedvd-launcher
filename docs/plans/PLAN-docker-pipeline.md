# Plan: Docker-Pipeline für Archiv-Sync und Katalogdaten

- **Status:** Entwurf
- **Stand:** 2026-10-26
- **Ziel:** Ein dauerhaft laufender Docker-Container auf dem Server übernimmt
  FTP-Sync, Änderungserfassung, `gameinfo-gen`, `crew-analysis`,
  `screenshot-gen index`, Paketierung, FTP-Upload und `latest.json`.
  Die eigentliche Screenshot-Generierung bleibt auf dem Dev-Server.

---

## 1. Zielbild

Ein Container (`amd64`) läuft auf dem Server und bietet:

- monatlichen Voll-Lauf am **1. des Monats, 03:00 Europe/Berlin**
- manuellen Voll-Lauf per HTTP (`POST /run`)
- Screenshot-Hook per HTTP (`POST /hook/screenshots`) nach dem Dev-Lauf
- Sync nach `PatchDirectory`
- Änderungsprotokoll als JSON und Text
- `gameinfo-gen`, `full-index-gen` und `crew-analysis` (ohne Screenshot-Index)
- ZIP-Erstellung für `screenshots` und `gameinfo`
- FTP-Upload nur bei inhaltlicher Änderung
- `latest.json` nur nach einem tatsächlichen Upload

### Nicht-Ziele

- Kein Hatari, kein Xvfb und kein `shotgen run` im Container.
- Keine automatischen `crew-analysis images`/`crew-images.json` (später).
- Kein Löschen lokaler Dateien und kein Mirror-Pruning per Default.
- Kein Upload von ZIPs durch `asset-manifest`; das macht `asset-publish`.
- Keine Authentifizierung des HTTP-Endpoints (nur internes Netz).

---

## 2. Architektur

```text
Dev-Server (Hatari/Xvfb)
  shotgen run ...
        |
        | POST /hook/screenshots
        v
+--------------------------------------------------------------+
| Docker-Container: catalog-pipeline                          |
|                                                              |
|  Scheduler (1. des Monats 03:00) ----+                       |
|  POST /run --------------------------+--> Monatslauf         |
|  POST /hook/screenshots -----------------> Screenshot-Hook   |
|                                                              |
|  archive-sync -> gameinfo-gen -> full-index-gen -> crew-analysis |
|               -> asset-publish (gameinfo, nur bei Änderung)  |
|               -> asset-manifest (latest.json, nur nach Upload)|
+--------------------------------------------------------------+
        |                |                  |
        v                v                  v
  PatchDirectory   ScreenshotDir/Data   FTP + GitHub Release
```

Gemeinsame Bind-Mounts vom Host:

- `MARCER_ROOT_DIR` (nur lesen)
- `MARCER_PATCH_DIR` (schreiben; Sync-Ziel)
- `MARCER_OUT_DIR` (Screenshots + `index*.json`)
- `MARCER_DATA_DIR` (Gameinfo/Data)
- `/state` (persistenter Zustand, Reports, Locks)

---

## 3. Komponenten

### 3.1 `tools/archive-sync/`

Eigenes Python-Sync-Tool als ftp-sync-Ersatz.

- Dateien: `archive_sync.py`, `run.sh`, `README.md`, Tests.
- Befehle: `plan` (read-only), `sync`, `status`.
- Remote: `MARCER_FTP_REMOTE` (neu; Default `/GameDVD/`).
- Lokal: Union aus `MARCER_ROOT_DIR` und `MARCER_PATCH_DIR`, Patch gewinnt.
- Ziel: immer `MARCER_PATCH_DIR`.
- Verzeichnislisten laufen parallel über mehrere FTP-Verbindungen
  (`MARCER_SYNC_WORKERS`, Default 4); der Marcer-Server ist pro Verzeichnis
  langsam (~3-4 Verzeichnisse/s pro Verbindung).
- Änderungserkennung im MVP: **Größenvergleich**.
  - fehlt lokal oder Größe weicht ab → Download
  - Remote-mtime wird gespeichert und berichtet, aber nicht als Trigger benutzt
  - keine 60-Sekunden-„Safety“-Re-Downloads wie bei ftp-sync
- Download atomar: `<rel>.part` → Größenprüfung → `os.replace` → mtime setzen.
- Retry/Reconnect, passive Verbindung, binärer Modus.
- Keine lokalen Löschungen; lokale Dateien ohne Remote-Gegenstück nur als
  `local_only` im Report.
- Schutz gegen Path-Traversal und Case-Kollisionen.
- Reports: `changes.json` + `changes.txt` mit `new`, `changed`, `in_sync`,
  `local_only`, `downloads`.
- Kein `state.json`; jeder Lauf vergleicht direkt Remote gegen den lokalen
  Union-Baum.
- Optionen: `--dry-run`, `--force`, `--only`, `--exclude`, `--workers`.
- Kann ein Verzeichnis nicht gelistet werden, werden lokale Dateien dieses
  Teilbaums nicht als `local_only` gemeldet (keine falsche Remote-Löschung);
  der Lauf endet mit Exit-Code 1 und meldet die unvollständigen Verzeichnisse.

### 3.2 `tools/asset-publish/`

Neues Uploader-Tool, bewusst getrennt von `asset-manifest`.

- Dateien: `asset_publish.py`, `run.sh`, `README.md`, Tests.
- Befehl: `publish --only screenshots|gameinfo|all [--dry-run] [--force]`.
- Screenshots-Quelle: `MARCER_OUT_DIR`.
  - Excludes wie `archive-screenshots.sh`: `logs/`, alte
    `screenshots-*.zip`/`.7z`, Sidecar-`*.json`, `@eaDir`, `.DS_Store`,
    `.marcer-assets.json`, `archive-screenshots.sh`.
  - Root-Indizes `index.json`, `index-*.json` werden wieder aufgenommen.
- Gameinfo-Quelle: `MARCER_DATA_DIR/gameinfo`.
  - Enthalten: `games-*.json`, `manifest.json`, `crews.json`,
    `crew-images.json` (falls vorhanden), `full-index.json.gz`,
    `unmatched-report.txt`.
  - Ausgeschlossen: `.marcer-assets.json`, `*.bak-*`, Temp-Dateien und
    sonstige Dateien.
- Python-Packer statt `7zz`: deterministisch (sortierte Einträge, feste
  ZIP-Zeitstempel, POSIX-Namen).
- Signatur: SHA-256 über sortierte `(relpath, size, sha256)`-Liste.
  - unverändert → kein neues ZIP, kein Upload
  - geändert → neues `<kind>-<yyyyMMdd-HHmmss>.zip`
- Ablage:
  - Screenshots-ZIP im Screenshot-Ordner
  - Gameinfo-ZIP in `MARCER_ASSET_OUT_DIR` (Default: `MARCER_DATA_DIR`,
    neben dem `gameinfo/`-Ordner — wie die bisherigen Archive)
- Upload per FTP nach `MARCER_FTP_ASSETS_REMOTE`, binär, direkt unter dem
  finalen Namen (`STOR` + `SIZE`-Prüfung; nur mit `--upload`; ohne Flag rein
  lokal). Der Marcer-FTP erlaubt weder `RNFR`/`RNTO` noch `DELE`: eine
  vollständige Datei gleicher Größe wird wiederverwendet, ein Teil-Upload wird
  beim nächsten Lauf überschrieben und kann nicht remote gelöscht werden.
- Nach erfolgreichem Upload automatisch `asset-manifest` (ohne `--only`, damit
  Screenshots- und Gameinfo-Eintrag gemeinsam in `latest.json` bleiben).
- State: `/state/asset-publish/state.json` (Signatur, `uploaded`, `remote`,
  `manifest_dirty`); fehlgeschlagene Uploads werden ohne Neupacken wiederholt,
  fehlgeschlagene Pointer-Updates über `manifest_dirty`.
- Exit-Resultat signalisiert `created`, `uploaded`, `skipped` oder `error`
  (inkl. `stage` `upload`/`manifest`).

### 3.3 `tools/catalog-pipeline/`

Orchestrator, HTTP-Service und Scheduler in einem Prozess.

- Dateien: `pipeline.py`, `run.sh`, `README.md`, Tests.
- Ein Worker, globaler Lock (`/state/pipeline.lock`), keine parallelen Läufe.
- HTTP (stdlib, ohne Auth, nur internes Netz):
  - `GET /healthz`
  - `GET /status`
  - `POST /run` → Monatslauf, `202` + Job-ID, `409` wenn beschäftigt
  - `POST /hook/screenshots` → Screenshot-Hook, `202`/`409`
- Scheduler: 1. des Monats, 03:00 Europe/Berlin, konfigurierbar.
- Persistenter Scheduler-State verhindert Doppelläufe nach Restart.
- Run-Reports: `/state/runs/<timestamp>.json` + stdout für `docker logs`.
- Prüft im Screenshot-Hook, ob ein `shotgen.lock` eines Dev-Runs existiert →
  sauberer Busy-Fehler statt Konflikt. Der Monatslauf fasst den Screenshot-Index
  nicht an.
- Merkt fehlgeschlagene `latest.json`-Updates als „dirty“ und wiederholt sie
  beim nächsten Lauf.
- CLI: `serve`, `run --once`, `status`.

### 3.4 `tools/asset-manifest/` erweitern

- Neue Token-Variante über die GitHub-API (`MARCER_GITHUB_TOKEN`), kein
  `gh`-CLI im Container nötig.
- Release per Tag finden/erstellen, `latest.json` als Asset ersetzen.
- Lokaler `gh`-Fallback bleibt für Dev erhalten.
- Optional `--skip-unchanged`: Pointer nur schreiben, wenn sich der Inhalt
  geändert hat.

### 3.5 Docker + CI

- `docker/Dockerfile`
  - `python:3.12-slim`
  - venv + nur `olefile` (kein Pillow/numpy/scipy für `index` nötig)
  - `COPY tools/` + Lizenz; kein Hatari/Xvfb/7zz
- `docker/compose.yml`
  - `env_file: .env`
  - Bind-Mounts für Root, Patch, Screenshots, Data und `/state`
  - Port `8080`, `restart: unless-stopped`, `init: true`, Healthcheck
  - `user: "${PUID}:${PGID}"`
- `docker/.env.example`
- `.github/workflows/pipeline-image.yml`
  - Push auf `main` bei Änderungen an `tools/**`/`docker/**`
  - Build amd64, Push nach
    `ghcr.io/skoelle/marcer-gamedvd-launcher/pipeline:latest` + `:sha-…`
  - `workflow_dispatch`

---

## 4. Abläufe

### 4.1 Monatslauf (`POST /run` oder Scheduler)

1. Lock prüfen.
2. `archive-sync sync` → `changes.json`.
3. Änderungen auswerten:
   - XLS geändert, Ordner neu/entfernt, `gameinfo-gen check` fehlgeschlagen
     oder Erstlauf → `gameinfo-gen extract`.
   - sonst überspringen.
4. Wenn `gameinfo` lief oder neue/geänderte ZIPs im Cracked-Bereich sind →
   `full-index-gen run` (inkrementell, schreibt `gameinfo/full-index.json.gz`).
5. Wenn `gameinfo` lief oder der Cracked-Bereich Änderungen hat →
   `crew-analysis` (nur Ranking, liest den Full-Index).
6. `asset-publish --only gameinfo` (enthält `full-index.json.gz`).
   - unverändert → Skip
   - geändert → ZIP erstellen und hochladen
7. Nur wenn ein Upload erfolgte oder der Pointer „dirty“ ist:
   `asset-manifest` → `latest.json`.
8. Run-Report schreiben.

`shotgen index` läuft **nicht** in diesem Lauf. Screenshots und ihr Index
werden auf dem Dev-Rechner erzeugt und über den Screenshot-Hook veröffentlicht.

**Wichtig:** Der Monatslauf packt/uploadet **keine** Screenshots, auch wenn
sich nur `index*.json` geändert hat.

### 4.2 Screenshot-Hook (`POST /hook/screenshots`)

1. Lock prüfen.
2. `asset-publish --only screenshots`.
   - Inhalt inklusive PNGs und aktueller `index*.json` unverändert → Skip.
   - geändert → ZIP erstellen und hochladen.
3. Nur nach Upload oder bei „dirty“ Pointer:
   `asset-manifest` → `latest.json`.
4. Run-Report schreiben.

Dev-Seite:

```bash
curl -X POST http://<server>:8080/hook/screenshots
```

### 4.3 Änderungsabbildung

- **XLS:** `Title Sorted/Games.xls`, `PD Games.xls`, `Utils_.xls`.
- **Scopes:** `cracked`, `pd`, `utils`, `magazine`, `falcon` (aus der
  `shotgen`-Config).
- **gameinfo:** XLS-Änderung, neue Ordner (als `new` im Sync-Report),
  fehlendes/inkonsistentes `manifest.json` oder Erstlauf.
- **crews:** `gameinfo` lief oder Cracked-Bereich geändert.
- **full-index:** mindestens ein `new`/`changed` ZIP, `full-index.json.gz`
  fehlt oder `full-index-gen check` meldet eine Abweichung.
- **index:** nur noch dev-seitig für die Screenshot-Erzeugung.
- **No-Op:** keine `new`/`changed`-Pfade und alle Indexdateien vorhanden →
  Lauf endet erfolgreich mit „nothing changed“.

### 4.4 Paketierungs- und Upload-Regeln

- Screenshots werden **nur** im Screenshot-Hook gepackt/hochgeladen.
- Gameinfo wird im Monatslauf gepackt/hochgeladen, wenn sich die Quelle
  inhaltlich geändert hat.
- Inhaltliche Signatur entscheidet, nicht der Dateiname und nicht das Datum.
- Unveränderte Daten erzeugen weder neues ZIP noch Upload.
- `latest.json` wird nur nach einem erfolgreichen Upload aktualisiert.
  `asset-publish` ruft dafür automatisch `asset-manifest` auf.
- Ein fehlgeschlagener Pointer-Upload bleibt als „dirty“ gespeichert und wird
  beim nächsten Lauf wiederholt.
- Alte Archive werden auf dem FTP nicht gelöscht.

---

## 5. Konfiguration

### Pfade

| Variable | Bedeutung |
|---|---|
| `MARCER_ROOT_DIR` | Haupt-Game-Tree (read-only) |
| `MARCER_PATCH_DIR` | Patch-Tree (Sync-Ziel, schreibbar) |
| `MARCER_OUT_DIR` | Screenshots + `index*.json` |
| `MARCER_DATA_DIR` | Data-Verzeichnis (`gameinfo/`, `atarilegend/`, `piratefinder/`) |
| `MARCER_ASSET_OUT_DIR` | Ablage der Gameinfo-ZIPs (Default: `MARCER_DATA_DIR`) |
| `MARCER_STATE_DIR` | Persistenter Container-State (`/state`) |

### FTP

| Variable | Bedeutung |
|---|---|
| `MARCER_FTP_HOST` | `host` oder `host:port` |
| `MARCER_FTP_USER` / `MARCER_FTP_PASS` | Zugangsdaten |
| `MARCER_FTP_REMOTE` | Remote-Basis der Game-Trees (Default `/GameDVD/`) |
| `MARCER_FTP_ASSETS_REMOTE` | Zielordner der Asset-ZIPs (Default `/Uploads/MarcerGameDVDLauncher-assets/`) |

### GitHub

| Variable | Bedeutung |
|---|---|
| `MARCER_GITHUB_TOKEN` | PAT mit Release-/Asset-Schreibrecht |
| `MARCER_REPO` | `skoelle/marcer-gamedvd-launcher` |
| `MARCER_RELEASE_TAG` | `catalog-latest` |

### Scheduler

| Variable | Default |
|---|---|
| `MARCER_SCHEDULE_DAY` | `1` |
| `MARCER_SCHEDULE_HOUR` | `3` |
| `MARCER_TZ` | `Europe/Berlin` |

### Compose-Hostpfade

`HOST_ROOT_DIR`, `HOST_PATCH_DIR`, `HOST_OUT_DIR`, `HOST_DATA_DIR`,
`HOST_STATE_DIR`.

---

## 6. Offene Umsetzungsschritte

Erledigt sind `tools/archive-sync` (plan/sync/status, Größenvergleich, atomare
Downloads), `tools/asset-publish` für Gameinfo (Signatur, ZIP, FTP-Upload,
State/Retry) sowie die Plan-/README-Verknüpfung.

Offen:

- **asset-publish:** Screenshot-Quelle inkl. Excludes, Ausgabepfad und
  `--dry-run`-Prüfung.
- **asset-manifest:** GitHub-Token-API (Release finden/erstellen,
  `latest.json` ersetzen), `--skip-unchanged`, `gh`-Fallback behalten.
- **catalog-pipeline:** Step-Runner, Änderungsabbildung, Monatslauf,
  Screenshot-Hook, globaler Lock + `shotgen.lock`-Prüfung, HTTP-Endpoints,
  Scheduler-State, Dirty-Pointer-Retry, Run-Reports, CLI, Tests.
- **Docker/CI:** Dockerfile, Compose, `.env.example`, `.dockerignore`,
  GHCR-Workflow, lokaler Build.
- **Dokumentation:** Root-README-Tool-Tabelle, AGENTS-Modulübersicht,
  Tool-READMEs, GETTING-STARTED-Abschnitt.
- **Verifikation/Rollout:** Unit-Tests, echter FTP-Lesezugriff,
  `--dry-run`-Läufe, No-Op-Test, Container-Start, HTTP-Checks, erster
  manueller `/run`, Screenshot-Hook, Scheduler, Backup des State-Verzeichnisses.

## 7. Offene Punkte und Risiken

- **FTP-mtime:** Verlässlichkeit der Server-Zeiten unklar; im MVP nur
  diagnostisch, später `--use-mtime` prüfen.
- **Gleich große, geänderte Dateien:** im MVP nicht erkannt; später optionaler
  Hash-Modus (z. B. für XLS).
- **Schreibrechte:** FTP-User und NAS-Mounts müssen Schreiben erlauben.
- **Parallele Dev-/Server-Läufe:** `shotgen index` und `shotgen run` dürfen
  nicht gleichzeitig auf denselben Index schreiben; der Screenshot-Hook prüft
  deshalb den `shotgen.lock`.
- **Dateisperren auf NAS:** `flock` kann unzuverlässig sein; zusätzlich
  PID-/Heartbeat-Marker im State prüfen.
- **GitHub-PAT:** muss Releases/Assets im Zielrepo schreiben dürfen.
- **Crew-Images:** bleiben vorerst manuell; später eigener Schritt.
- **Lokale Löschungen:** werden nicht automatisch nachgezogen; optionales
  `--prune` nur mit ausdrücklicher Freigabe.

## 8. Definition of Done

- Monatslauf läuft unbeaufsichtigt und ist per HTTP manuell auslösbar.
- Screenshot-Hook verpackt und veröffentlicht nur nach dem Dev-Lauf.
- Unveränderte Daten erzeugen keinen Upload; `latest.json` wird nur nach
  erfolgreichem Upload aktualisiert.
- `screenshot-gen index` läuft nur für betroffene Scopes; kein `shotgen run`,
  Hatari oder Xvfb im Container.
- State, Reports und Locks überleben Container-Neustarts.
- Tests und Doku sind aktualisiert; keine Secrets im Repo.
