# Plan: Katalog-Pipeline, Web-Interface und Docker-Betrieb

- **Status:** Entwurf
- **Stand:** 2026-11-03
- **Ziel:** Ein dauerhaft laufender Docker-Container übernimmt FTP-Sync,
  Katalogaufbereitung und Veröffentlichung. Ein Web-Interface zeigt den
  aktuellen Zustand und löst Läufe manuell aus. Ein Scheduler startet den
  Sync wöchentlich am **Donnerstagabend**. Die Gallery läuft als eigener
  Service aus demselben Image.

Die vorhandenen Bausteine `tools/archive-sync`, `tools/catalog-update`,
`tools/gameinfo-gen`, `tools/full-index-gen`, `tools/crew-analysis`,
`tools/asset-publish` und `tools/asset-manifest` bilden die Grundlage.
Dieser Plan beschreibt, was für Web-Interface, Aktionen, Docker, Scheduler
und die spätere Screenshot-Veröffentlichung noch fehlt.

---

## 1. Bestätigte Entscheidungen

| Thema | Entscheidung |
|---|---|
| Reihenfolge | Zuerst das lesende Web-Interface, danach Aktionen, Docker, Scheduler, Screenshots |
| Status-Umfang (read-only UI) | Auch Screenshot-Index **nur lesend** anzeigen (Counts, pending, Alter, Größe) |
| Screenshot-Aktionen | Erst später als eigener Button; kein Bestandteil des ersten Schritts |
| Screenshot-Auslöser | Nach einem automatischen Sync bzw. separat über den Dev-Hook |
| `MARCER_OUT_DIR` | Ist im Docker-Container gemountet und lesbar |
| Scheduler | Wöchentlich Donnerstag, Default `20:00`, Zeitzone `Europe/Berlin` |
| Lokaler Bind | `0.0.0.0` |
| Docker-Layout | Getrennte Container für Pipeline und Gallery; gemeinsames Image ist zulässig |
| Gallery im Compose | Ja, als eigener `gallery`-Service im selben Compose-Stack |
| Auth | Keine Auth im UI v1; extern nur über Reverse Proxy mit TLS/Basic Auth |

### Nicht-Ziele

- Keine Screenshot-Erzeugung (Hatari/Xvfb) im Container.
- Keine Screenshot-Paketierung oder -Upload vor Phase 5.
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
| `HOST_OUT_DIR` | `/data/out` | `rw` (Phase 5) / `ro` (vorher) | `ro` |
| `HOST_DATA_DIR` | `/data/data` | `rw` | `ro` |
| `${HOST_DATA_DIR}/state` | `/state` | `rw` | – |

---

## 3. Phasen

Phase 1 (read-only Status-Web-Interface), Phase 2 (Aktionen, Job-Runner und
Sperren) und Phase 3 (Docker, Compose und GHCR) sind in
[`tools/catalog-pipeline`](../../tools/catalog-pipeline/README.md) bzw.
[`docker/`](../../docker/README.md) umgesetzt. Die E-Mail-Benachrichtigung bei
Sync-Änderungen ist in `tools/catalog-pipeline/notify.py` umgesetzt.

Offen sind Scheduler und Screenshot-Veröffentlichung.

### Phase 4 – Scheduler

Ziel: Der Sync startet unbeaufsichtigt wöchentlich am Donnerstagabend.

#### Scheduler

- Python-Scheduler im selben Prozess (kein Cron-Daemon)
- Default: `MARCER_SCHEDULE_CRON=0 20 * * 4`
- Zeitzone: `MARCER_TZ=Europe/Berlin` (`zoneinfo`)
- Persistenter State: `$MARCER_STATE_DIR/scheduler.json`
- Kein Doppellauf nach Neustart
- Misfire-Policy konfigurierbar:
  - `catch_up_hours` (Default z. B. 24): verpasster Lauf wird nachgeholt
  - `0`: verpasster Lauf wird übersprungen
- Nächster geplanter Lauf im Status sichtbar
- Manuelle Läufe verschieben den Zeitplan nicht

#### Akzeptanz Phase 4

- Scheduler läuft in der Zeitzone Europe/Berlin, auch über DST-Wechsel
- Neustart am Donnerstagabend erzeugt keinen Doppellauf
- Verpasster Lauf wird gemäß Policy nachgeholt oder übersprungen

---

### Phase 5 – Screenshots veröffentlichen (später)

Ziel: Screenshots werden getrennt vom automatischen Sync veröffentlicht –
über einen eigenen Button bzw. den Dev-Hook nach einem Screenshot-Lauf.

#### Voraussetzungen

- `tools/asset-publish --only screenshots` implementieren:
  - Quelle `MARCER_OUT_DIR`
  - Excludes wie beim bisherigen Screenshot-Archiv (`logs/`, alte ZIPs,
    Sidecar-JSON, `@eaDir`, `.DS_Store`, …)
  - `index*.json` und PNGs aufnehmen
  - deterministisches ZIP, Signatur, Skip bei unverändertem Inhalt
  - FTP-Upload und `latest.json` über `asset-manifest`
- `POST /api/hook/screenshots` im Pipeline-Service
- Prüfung auf einen aktiven `shotgen.lock` eines Dev-Laufs

#### Ablauf

1. Automatischer Sync läuft wie gewohnt ohne Screenshots.
2. Nach dem Sync kann der Screenshot-Button manuell ausgelöst werden.
3. Alternativ ruft der Dev-Rechner nach `shotgen run` den Hook auf.
4. Nur bei inhaltlicher Änderung wird gepackt und hochgeladen.
5. `latest.json` wird nur nach erfolgreichem Upload aktualisiert.

#### Akzeptanz Phase 5

- Unveränderte Screenshots erzeugen weder ZIP noch Upload
- Hook liefert bei laufendem `shotgen.lock` einen sauberen Busy-Fehler
- Screenshot-Lauf ist im Status und in der Run-Historie sichtbar
- Der automatische Sync packt weiterhin keine Screenshots

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
  müssen weiter reagieren.
- **Screenshot-Index während Dev-Lauf:** Hook muss `shotgen.lock` respektieren.
- **GitHub-PAT:** Ablauf und minimale Rechte einplanen.
- **Alte Archive:** können auf dem FTP nicht gelöscht werden; lokale
  Retention separat regeln.
- **Externe Erreichbarkeit:** Pipeline-UI ohne Auth nie direkt ins Internet.
- **AtariLegend:** Wochendump ist derzeit nicht Teil der Pipeline; eine
  spätere Aufnahme ist möglich, aber nicht Bestandteil dieses Plans.

---

## 6. Definition of Done

- Phase 4: Wöchentlicher Donnerstagslauf funktioniert unbeaufsichtigt in
  `Europe/Berlin`, inklusive Misfire-Policy; die E-Mail-Benachrichtigung ist
  bereits implementiert.
- Phase 5: Screenshot-Veröffentlichung läuft separat über Button/Hook, ohne
  den automatischen Sync zu verändern.
- Tests und Dokumentation sind je Phase aktualisiert; keine Secrets im Repo.
