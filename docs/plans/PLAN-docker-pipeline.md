# Plan: Katalog-Pipeline, Web-Interface und Docker-Betrieb

- **Status:** umgesetzt
- **Stand:** 2026-11-03
- **Ziel:** Ein dauerhaft laufender Docker-Container übernimmt FTP-Sync,
  Katalogaufbereitung und Veröffentlichung. Ein Web-Interface zeigt den
  aktuellen Zustand und löst Läufe manuell aus. Ein Scheduler startet den
  Sync wöchentlich am **Donnerstagabend**. Die Gallery läuft als eigener
  Service aus demselben Image. Screenshots werden separat über Button/Hook
  veröffentlicht.

Die vorhandenen Bausteine `tools/archive-sync`, `tools/catalog-update`,
`tools/gameinfo-gen`, `tools/full-index-gen`, `tools/crew-analysis`,
`tools/asset-publish` und `tools/asset-manifest` bilden die Grundlage.
Dieses Dokument beschreibt die umgesetzte Architektur, Konfiguration und
Betriebsregeln der Pipeline.

---

## 1. Bestätigte Entscheidungen

| Thema | Entscheidung |
|---|---|
| Reihenfolge | Zuerst das lesende Web-Interface, danach Aktionen, Docker, Scheduler, Screenshots |
| Status-Umfang (read-only UI) | Auch Screenshot-Index **nur lesend** anzeigen (Counts, pending, Alter, Größe) |
| Screenshot-Aktionen | Eigener Button/Hook; nicht Teil des automatischen Syncs |
| Screenshot-Auslöser | Nach einem automatischen Sync bzw. separat über den Dev-Hook |
| `MARCER_OUT_DIR` | Ist im Docker-Container gemountet und lesbar |
| Scheduler | Wöchentlich Donnerstag, Default `20:00`, Zeitzone `Europe/Berlin` |
| Lokaler Bind | `0.0.0.0` |
| Docker-Layout | Getrennte Container für Pipeline und Gallery; gemeinsames Image ist zulässig |
| Gallery im Compose | Ja, als eigener `gallery`-Service im selben Compose-Stack |
| Auth | Keine Auth im UI v1; extern nur über Reverse Proxy mit TLS/Basic Auth |

### Nicht-Ziele

- Keine Screenshot-Erzeugung (Hatari/Xvfb) im Container.
- Screenshot-Paketierung/Upload nur über den separaten Button/Hook, nicht im automatischen Sync.
- Kein Löschen, Pruning oder Rename-Erkennung in Root/Patch.
- Kein öffentlicher Betrieb des Pipeline-UI ohne Reverse Proxy.

---

## 2. Architektur

```text
Dev-Server (Hatari/Xvfb)
  shotgen run ...
        |
        | spaeter: POST /api/hook/screenshots
        v
+--------------------------------------------------------------+
| Docker-Host                                                  |
|                                                              |
|  +---------------------------+   +------------------------+  |
|  | pipeline                  |   | gallery                |  |
|  | catalog-pipeline serve    |   | gallery.py             |  |
|  |                           |   |                        |  |
|  |  Web-UI + API             |   |  Screenshot-Gallery    |  |
|  |  Scheduler                |   |  read-only             |  |
|  |  Job-Runner               |   |                        |  |
|  +-------------+-------------+   +-----------+------------+  |
|                |                             |               |
|        archive-sync -> gameinfo -> full-index -> crews       |
|                -> asset-publish -> asset-manifest            |
+----------------+-----------------------------+---------------+
                 |                             |
                 v                             v
           PatchDirectory                Out/Data (ro)
```

### Container und Mounts

| Service | Image | Port | Schreibzugriff |
|---|---|---|---|
| `pipeline` | gemeinsames Pipeline-Image | `8080` (intern/Proxy) | `MARCER_PATCH_DIR`, `MARCER_DATA_DIR` (inkl. `state/`), `MARCER_OUT_DIR` |
| `gallery` | dasselbe Image, anderes Kommando | `8764` (Proxy) | keiner; alle Mounts `:ro` |

Die Gallery erhält **keine** FTP- oder GitHub-Secrets. Das Pipeline-UI bleibt
im internen Netz; nach außen wird nur die Gallery bzw. ein bewusst
freigegebener Pfad über einen Reverse Proxy veröffentlicht.

### Bind-Mounts

| Host-Variable | Container-Pfad | Pipeline | Gallery |
|---|---|---|---|
| `HOST_ROOT_DIR` | `/data/root` | `ro` | `ro` |
| `HOST_PATCH_DIR` | `/data/patch` | `rw` | `ro` |
| `HOST_OUT_DIR` | `/data/out` | `rw` (Screenshot-Publish) | `ro` |
| `HOST_DATA_DIR` | `/data/data` | `rw` | `ro` |
| `${HOST_DATA_DIR}/state` | `/state` | `rw` | – |

---

## 3. Phasen

Alle geplanten Phasen sind umgesetzt:

- Status-Web-Interface, manuelle Jobs und Locking
  ([`tools/catalog-pipeline`](../../tools/catalog-pipeline/README.md))
- Docker/Compose/GHCR ([`docker/`](../../docker/README.md))
- E-Mail-Benachrichtigung (`tools/catalog-pipeline/notify.py`)
- Wöchentlicher Scheduler (`tools/catalog-pipeline/scheduler.py`)
- Screenshot-Paketierung/Upload (`tools/asset-publish --only screenshots`)
  und `POST /api/hook/screenshots` bzw. der UI-Button

Es sind keine Pipeline-Entwicklungsphasen mehr offen. Offene Betriebs- und
Verifikationspunkte stehen in Abschnitt 5.

---

## 4. Konfiguration

### Pfade

| Variable | Bedeutung |
|---|---|
| `MARCER_ROOT_DIR` | Haupt-Game-Tree (read-only) |
| `MARCER_PATCH_DIR` | Patch-Tree (Sync-Ziel, schreibbar) |
| `MARCER_OUT_DIR` | Screenshots + `index*.json` |
| `MARCER_DATA_DIR` | Data-Verzeichnis (`gameinfo/`, `state/`) |
| `MARCER_ASSET_OUT_DIR` | Ablage der Gameinfo-ZIPs (Default: `MARCER_DATA_DIR`) |
| `MARCER_STATE_DIR` | State-Root; Default `$MARCER_DATA_DIR/state`, im Container fest `/state` (gemountet von `${HOST_DATA_DIR}/state`) |
| `MARCER_SYNC_REPORT_DIR` | `archive-sync`-Reports |
| `MARCER_PIPELINE_REPORT_DIR` | Run-Reports der Pipeline |

### FTP

| Variable | Bedeutung |
|---|---|
| `MARCER_FTP_HOST` | `host` oder `host:port` |
| `MARCER_FTP_USER` / `MARCER_FTP_PASS` | Zugangsdaten |
| `MARCER_FTP_REMOTE` | Remote-Basis der Game-Trees |
| `MARCER_FTP_ASSETS_REMOTE` | Zielordner der Asset-ZIPs |
| `MARCER_FTP_ENCODING` | `latin-1` für Listenings mit Umlauten |

### GitHub

| Variable | Bedeutung |
|---|---|
| `MARCER_GITHUB_TOKEN` | PAT mit Release-/Asset-Schreibrecht |
| `MARCER_REPO` | `owner/repo` |
| `MARCER_RELEASE_TAG` | `catalog-latest` |

### Web und Scheduler

| Variable | Default |
|---|---|
| `MARCER_PIPELINE_HOST` | `0.0.0.0` |
| `MARCER_PIPELINE_PORT` | `8080` |
| `MARCER_PIPELINE_TOKEN` | – (POSTs ohne Token) |
| `MARCER_SCHEDULE_CRON` | `0 20 * * 4` |
| `MARCER_TZ` | `Europe/Berlin` |
| `MARCER_SCHEDULE_CATCH_UP_HOURS` | `24` |

### E-Mail

| Variable | Default |
|---|---|
| `MARCER_SMTP_HOST` | – (Benachrichtigung aus, wenn leer) |
| `MARCER_SMTP_PORT` | `587` |
| `MARCER_SMTP_USER` / `MARCER_SMTP_PASS` | – |
| `MARCER_SMTP_STARTTLS` | `1` |
| `MARCER_SMTP_SSL` | `0` |
| `MARCER_MAIL_FROM` | `MARCER_SMTP_USER` |
| `MARCER_MAIL_TO` | – |

Secrets ausschließlich über `env_file`/Docker-Secrets, niemals im Image oder
im Repository.

---

## 5. Risiken und offene Punkte

- **FTP-mtime:** im MVP nur diagnostisch; gleiche Größe + geänderter Inhalt
  wird nicht erkannt. Optionaler Hash-Modus für XLS prüfen.
- **Löschungen/Renames:** werden nur reported, nicht übernommen.
- **NAS-Dateisperren:** `flock` ist unzuverlässig; PID-/Heartbeat-Marker
  zusätzlich prüfen.
- **Dropbox/NAS-Sync:** `MARCER_DATA_DIR` liegt aktuell unter Dropbox. Locks,
  Job-Logs und Scheduler-State erzeugen dort Sync-Traffic/Konflikte;
  `Data/state/` vom Sync ausnehmen oder beobachten.
- **Große Screenshot-ZIPs:** Upload kann lange dauern; Status und Cancel
  müssen weiter reagieren. `asset-publish` meldet dafür seit dem 2026-11-04
  Stage-Marker (`==> collect|pack|upload|manifest`) und gedrosselte
  Fortschrittszeilen nach stderr, die der Job-Runner live ins `job.log` und
  in die Job-Stage übernimmt.
- **Screenshot-Index während Dev-Lauf:** Hook muss `shotgen.lock` respektieren.
- **GitHub-PAT:** Ablauf und minimale Rechte einplanen.
- **Alte Archive:** können auf dem FTP nicht gelöscht werden; lokale
  Retention separat regeln.
- **Externe Erreichbarkeit:** Pipeline-UI ohne Auth nie direkt ins Internet.
- **AtariLegend:** Wochendump ist derzeit nicht Teil der Pipeline; eine
  spätere Aufnahme ist möglich, aber nicht Bestandteil dieses Plans.

---

## 6. Definition of Done

- Screenshot-Veröffentlichung läuft separat über Button/Hook, ohne den
  automatischen Sync zu verändern.
- Tests und Dokumentation sind je Phase aktualisiert; keine Secrets im Repo.
