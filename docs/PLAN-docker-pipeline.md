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
- `gameinfo-gen`, `crew-analysis` und `screenshot-gen index` (nur Index)
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
|  archive-sync -> gameinfo-gen -> crew-analysis               |
|               -> shotgen index (nur betroffene Scopes)       |
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
    `crew-images.json` (falls vorhanden).
  - Ausgeschlossen: `.marcer-assets.json`, `*.bak-*`, Temp-Dateien und
    sonstige Dateien.
- Python-Packer statt `7zz`: deterministisch (sortierte Einträge, feste
  ZIP-Zeitstempel, POSIX-Namen).
- Signatur: SHA-256 über sortierte `(relpath, size, sha256)`-Liste.
  - unverändert → kein neues ZIP, kein Upload
  - geändert → neues `<kind>-<yyyyMMdd-HHmmss>.zip`
- Ablage:
  - Screenshots-ZIP im Screenshot-Ordner
  - Gameinfo-ZIP in `MARCER_ASSET_OUT_DIR` (Default: Parent von
    `MARCER_DATA_DIR`)
- Upload per FTP nach `MARCER_FTP_ASSETS_REMOTE`, binär, Temp-Name +
  `RNFR`/`RNTO`, Größenprüfung.
- State: `/state/asset-publish/state.json`.
- Exit-Resultat signalisiert `uploaded`, `skipped` oder `error`.

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
- Prüft vor `shotgen index`, ob ein `shotgen.lock` eines Dev-Runs existiert →
  sauberer Busy-Fehler statt Konflikt.
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
4. Wenn `gameinfo` lief oder der Cracked-Bereich Änderungen hat →
   `crew-analysis` (nur Ranking).
5. Für **jeden betroffenen Scope**:
   `shotgen index --scope <name>`.
6. `asset-publish --only gameinfo`.
   - unverändert → Skip
   - geändert → ZIP erstellen und hochladen
7. Nur wenn ein Upload erfolgte oder der Pointer „dirty“ ist:
   `asset-manifest` → `latest.json`.
8. Run-Report schreiben.

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
- **index:** mindestens ein `new`/`changed`-Pfad im jeweiligen Scope-Baum oder
  Indexdatei fehlt.
- **No-Op:** keine `new`/`changed`-Pfade und alle Indexdateien vorhanden →
  Lauf endet erfolgreich mit „nothing changed“.

### 4.4 Paketierungs- und Upload-Regeln

- Screenshots werden **nur** im Screenshot-Hook gepackt/hochgeladen.
- Gameinfo wird im Monatslauf gepackt/hochgeladen, wenn sich die Quelle
  inhaltlich geändert hat.
- Inhaltliche Signatur entscheidet, nicht der Dateiname und nicht das Datum.
- Unveränderte Daten erzeugen weder neues ZIP noch Upload.
- `latest.json` wird nur nach einem erfolgreichen Upload aktualisiert.
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
| `MARCER_ASSET_OUT_DIR` | Ablage der Gameinfo-ZIPs (Default: Parent von `MARCER_DATA_DIR`) |
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

## 6. Umsetzungsschritte

### Phase 0 – Vorbereitung

- [x] Plan als Markdown in `docs/PLAN-docker-pipeline.md` ablegen.
- [ ] Diesen Plan freigeben.
- [ ] Env-Variablen-Namen und State-Layout finalisieren.
- [ ] FTP-Schreibrecht auf `/Uploads/MarcerGameDVDLauncher-assets/` prüfen.
- [ ] GitHub-PAT mit Release-/Asset-Schreibrecht prüfen.
- [ ] Server-Mounts und UID/GID für die Bind-Mounts dokumentieren.
- [ ] Entscheiden, ob der Container `MARCER_OUT_DIR` und `MARCER_DATA_DIR`
      schreibend mounten darf (benötigt für Index/Assets).

### Phase 1 – `archive-sync`

- [x] `tools/archive-sync/` anlegen (MIT-Header, `run.sh`, README).
- [x] Env-/Pfad-Loader inkl. `MARCER_FTP_REMOTE` implementieren.
- [x] FTP-Client: Connect, passive Mode, MLSD mit LIST/SIZE-Fallback,
      Retry/Reconnect.
- [x] Remote-Baum rekursiv lesen, Excludes und Path-Traversal-Schutz.
- [x] Lokalen Union-Baum (Root/Patch, Patch gewinnt) und Case-Behandlung
      implementieren.
- [x] `plan`/`sync`: `new`, `changed`, `in_sync`, `local_only`, `downloads`
      auf Basis des Größenvergleichs.
- [x] Atomaren Download (`.part`, Größenprüfung, `os.replace`, mtime setzen)
      implementieren.
- [x] Reports `changes.json`/`changes.txt` schreiben (kein `state.json`).
- [x] CLI `plan|sync|status`, `--dry-run`, `--force`, `--only`, `--exclude`.
- [x] Parallele FTP-Listing-Worker (`--workers`, `MARCER_SYNC_WORKERS`).
- [x] Unvollständige Verzeichnisse im Report sicher behandeln.
- [x] Unit-Tests (Vergleich, Patch-Vorrang, kein Löschen, Traversal, Report).
- [x] README mit Beispielen und Sicherheitsregeln.
- [x] Read-only-Test gegen echten FTP (`plan`, Scope `pd` und `A`).

### Phase 2 – `asset-publish`

- [ ] `tools/asset-publish/` anlegen (MIT-Header, `run.sh`, README).
- [ ] Screenshot- und Gameinfo-Quellen inklusive Excludes implementieren.
- [ ] Signatur über sortierte `(relpath, size, sha256)`-Liste implementieren.
- [ ] Deterministischen Python-ZIP-Packer implementieren.
- [ ] Ausgabepfade für Screenshots- und Gameinfo-ZIPs implementieren.
- [ ] FTP-Upload mit Temp-Name, `RNFR`/`RNTO` und Größenprüfung.
- [ ] Skip-Logik bei unveränderter Signatur, `--force`, `--dry-run`.
- [ ] Maschinenlesbares Ergebnis (`uploaded`, `skipped`, `archive`, `error`).
- [ ] State `/state/asset-publish/state.json` atomar schreiben.
- [ ] Unit-Tests (Determinismus, Excludes, Skip, Force, Upload-Reihenfolge).
- [ ] README mit Publish-Regeln.
- [ ] `--dry-run` gegen die echten Ordner prüfen.

### Phase 3 – `asset-manifest` Token-API

- [ ] `MARCER_GITHUB_TOKEN` und Repo/Tag-Konfiguration ergänzen.
- [ ] GitHub-API: Release per Tag finden/erstellen.
- [ ] GitHub-API: `latest.json` als Asset ersetzen.
- [ ] `--skip-unchanged` für identischen Pointer-Inhalt.
- [ ] `gh`-Fallback für lokale Dev-Läufe erhalten.
- [ ] Unit-Tests mit gemockter GitHub-API.
- [ ] README aktualisieren.

### Phase 4 – `catalog-pipeline`

- [ ] `tools/catalog-pipeline/` anlegen (MIT-Header, `run.sh`, README).
- [ ] Step-Runner mit Timeout, Logging und Fehlerbehandlung.
- [ ] Änderungsabbildung auf `gameinfo`, `crews` und betroffene Scopes.
- [ ] Monatslauf implementieren (ohne Screenshot-Paketierung).
- [ ] Screenshot-Hook implementieren.
- [ ] Globalen Lock und `shotgen.lock`-Prüfung implementieren.
- [ ] HTTP-Endpoints `/healthz`, `/status`, `/run`, `/hook/screenshots`.
- [ ] Busy-Antwort `409` und Job-Status.
- [ ] Scheduler 1. des Monats 03:00 Europe/Berlin.
- [ ] Scheduler-State gegen Doppelläufe nach Restart.
- [ ] „dirty pointer“-Retry implementieren.
- [ ] Run-Reports unter `/state/runs/` schreiben.
- [ ] CLI `serve`, `run --once`, `status`.
- [ ] Unit-Tests (Mapping, No-Op, HTTP, Scheduler, Retry).
- [ ] README mit Betrieb und Triggern.
- [ ] Lokaler `run --once --dry-run` gegen die Shared-Ordner.

### Phase 5 – Docker und CI

- [ ] `docker/Dockerfile` erstellen (Python-venv + `olefile`).
- [ ] Non-root-Betrieb über `PUID`/`PGID` vorbereiten.
- [ ] `docker/compose.yml` mit Mounts, Healthcheck und Port `8080`.
- [ ] `docker/.env.example` ohne echte Secrets.
- [ ] `.dockerignore` für einen kleinen Build-Kontext.
- [ ] `.github/workflows/pipeline-image.yml` für GHCR (amd64).
- [ ] Image lokal bauen und `docker compose config` prüfen.
- [ ] `docker/README.md` für Deployment schreiben.

### Phase 6 – Dokumentation

- [ ] Root-`README.md`: neue Tools in der Tool-Tabelle ergänzen.
- [ ] `AGENTS.md`: Module-Overview um die neuen Tools und den Container
      erweitern.
- [x] Plan in `docs/README.md` verlinken.
- [ ] Tool-READMEs in `docs/README.md` ergänzen.
- [ ] `docs/GETTING-STARTED.md`: kurzen Abschnitt „Server-Automatisierung“
      ergänzen.
- [ ] Tool-READMEs für `archive-sync`, `asset-publish`, `catalog-pipeline`.
- [ ] Keine Secrets, Host-Pfade oder Tokens im Repo dokumentieren.

### Phase 7 – Verifikation

- [ ] Alle neuen Unit-Tests laufen mit dem Repo-`.venv`.
- [ ] `archive-sync plan` gegen echten FTP (read-only).
- [ ] `asset-publish --dry-run` für Screenshots und Gameinfo.
- [ ] `asset-publish --force --dry-run` prüft ZIP-Erstellung.
- [ ] `pipeline run --once --dry-run` prüft die Schrittfolge.
- [ ] No-Op-Test: zweiter Lauf ohne Änderungen erzeugt keinen Upload.
- [ ] Docker-Image baut und startet.
- [ ] `GET /healthz` und `GET /status` liefern plausible Antworten.
- [ ] `POST /run` und `POST /hook/screenshots` liefern `202`; paralleler
      Aufruf liefert `409`.
- [ ] Screenshot-Hook erzeugt/uploadet nur bei geändertem Inhalt.
- [ ] `latest.json` wird nur nach erfolgreichem Upload aktualisiert.
- [ ] Fehlerfall: FTP-Abbruch lässt keinen halben `.part`-Müll zurück.

### Phase 8 – Rollout

- [ ] `docker compose up -d` auf dem Server.
- [ ] Ersten manuellen `/run` ausführen und Log/Report prüfen.
- [ ] Prüfen, dass `gameinfo`/`crews`/`index` aktualisiert wurden.
- [ ] Prüfen, dass unveränderte Assets nicht erneut hochgeladen wurden.
- [ ] Screenshot-Lauf auf dem Dev-Server starten.
- [ ] `POST /hook/screenshots` ausführen und Upload/Pointer prüfen.
- [ ] Monatlichen Scheduler aktivieren und den nächsten Termin prüfen.
- [ ] Alten manuellen ftp-sync-Workflow deaktivieren.
- [ ] State-Verzeichnis in die Server-Backups aufnehmen.

---

## 7. Testmatrix

| Bereich | Fälle |
|---|---|
| Sync | neu, geändert, in sync, local only, Patch-Vorrang, Case-Kollision, Path-Traversal, parallele Listing-Worker, unvollständige Verzeichnisse, Abbruch/Neustart (kein Resume) |
| Publish | gleiche Signatur, geänderte Signatur, `--force`, Excludes, deterministisches ZIP, Upload-Fehler |
| Pipeline | XLS-Änderung, neue ZIPs, neuer Ordner, Scope-Mapping, No-Op, parallele Requests, Scheduler, Pointer-Retry |
| GitHub | Release vorhanden/fehlt, Asset vorhanden/fehlt, identischer Pointer, API-Fehler |
| Docker | Build, Compose-Config, Healthcheck, non-root-Schreibrechte |
| Integration | Monatslauf, Screenshot-Hook, echter FTP-Lesezugriff, echter Upload im Testordner |

---

## 8. Offene Punkte und Risiken

- **FTP-mtime:** Verlässlichkeit der Server-Zeiten ist unklar. Im MVP nur
  diagnostisch; später `--use-mtime` prüfen.
- **Gleich große, geänderte Dateien:** werden im MVP nicht erkannt. Später
  optionaler Hash-Modus (z. B. für XLS).
- **500-MB-Uploads:** werden durch die Regel „Screenshots nur im Hook“
  vermieden; der Monatslauf lädt keine Screenshots hoch.
- **Schreibrechte:** FTP-User und NAS-Mounts müssen Schreiben erlauben.
- **Parallele Dev-/Server-Läufe:** `shotgen index` und `shotgen run` dürfen
  nicht gleichzeitig auf denselben Index schreiben; Lock-Prüfung nötig.
- **Dateisperren auf NAS:** `flock` kann je nach NAS unzuverlässig sein;
  zusätzlich PID-/Heartbeat-Marker im State prüfen.
- **GitHub-PAT:** muss Releases/Assets im Zielrepo schreiben dürfen.
- **Crew-Images:** bleiben vorerst manuell; später eigener Pipeline-Schritt.
- **Lokale Löschungen:** werden nicht automatisch nachgezogen; optionales
  `--prune` nur mit ausdrücklicher Freigabe.

---

## 9. Definition of Done

- [ ] Monatslauf läuft unbeaufsichtigt und ist per HTTP manuell auslösbar.
- [ ] Screenshot-Hook verpackt und veröffentlicht nur nach dem Dev-Lauf.
- [ ] Unveränderte Daten erzeugen keinen Upload.
- [ ] `latest.json` wird nur nach erfolgreichem Upload aktualisiert.
- [ ] `screenshot-gen index` läuft nur für betroffene Scopes.
- [ ] Kein `shotgen run`, Hatari oder Xvfb im Container.
- [ ] State, Reports und Locks überleben Container-Neustarts.
- [ ] Tests und Doku sind aktualisiert; keine Secrets im Repo.
