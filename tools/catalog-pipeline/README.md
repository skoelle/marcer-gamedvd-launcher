# catalog-pipeline

Status dashboard and manual job control for the Marcer catalog pipeline.

Phase 1 (read-only status), Phase 2 (manual runs, job runner, locking and
cancellation) and Phase 3 (Docker/Compose/GHCR) of the server automation
described in [`docs/plans/PLAN-docker-pipeline.md`](../../docs/plans/PLAN-docker-pipeline.md)
are implemented. The dashboard aggregates sync reports, gameinfo files, full
index, crew data, asset-publish state, screenshot indices, storage, recent run
reports and pipeline jobs.

The weekly scheduler and screenshot publishing are included. During a running
job the panel shows the current stage and tails the live job log, so long
steps (screenshot hashing, packing, FTP upload) stay visible.

## Requirements

- Python 3.12 (the repo `.venv`; standard library only)
- `local/paths.env` (git-ignored) with the usual path variables:
  `MARCER_ROOT_DIR`, `MARCER_PATCH_DIR`, `MARCER_OUT_DIR`,
  `MARCER_DATA_DIR` and optionally `MARCER_STATE_DIR`,
  `MARCER_SYNC_REPORT_DIR`, `MARCER_PIPELINE_REPORT_DIR`.
  Pipeline state lives in `$MARCER_DATA_DIR/state` by default; an explicit
  `MARCER_STATE_DIR` overrides it (the Docker container uses `/state`).
- Status polling makes no FTP or GitHub connection. A full run needs the FTP
  credentials and either `gh` authentication or `MARCER_GITHUB_TOKEN` for the
  `latest.json` update; a dry run needs FTP read access.

## Usage

```sh
# status web UI (default: 0.0.0.0:8080)
tools/catalog-pipeline/run.sh serve
tools/catalog-pipeline/run.sh serve --host 127.0.0.1 --port 8080

# print the aggregated status JSON
tools/catalog-pipeline/run.sh status
```

Environment overrides:

| Variable | Default | Meaning |
|---|---|---|
| `MARCER_PIPELINE_HOST` | `0.0.0.0` | bind address |
| `MARCER_PIPELINE_PORT` | `8080` | bind port |
| `MARCER_STATE_DIR` | `$MARCER_DATA_DIR/state` | state root (Docker: `/state`) |
| `MARCER_SYNC_REPORT_DIR` | `$MARCER_STATE_DIR/archive-sync` | `archive-sync` reports |
| `MARCER_PIPELINE_REPORT_DIR` | `$MARCER_STATE_DIR/catalog-update` | `catalog-update` run reports |
| `MARCER_PIPELINE_TOKEN` | – | optional bearer token for `POST` requests |
| `MARCER_SCHEDULE_CRON` | `0 20 * * 4` | five-field cron schedule |
| `MARCER_TZ` | `Europe/Berlin` | IANA timezone for the schedule |
| `MARCER_SCHEDULE_CATCH_UP_HOURS` | `24` | missed-run catch-up window; `0` skips |
| `PIPELINE_VERBOSE` | – | log every HTTP request |

The UI binds to `0.0.0.0` by default. `GET` endpoints are read-only and
unauthenticated. If `MARCER_PIPELINE_TOKEN` is set, every `POST` requires
`Authorization: Bearer <token>`. The UI shows the token field only when the
server has `MARCER_PIPELINE_TOKEN` configured and stores the value in
`localStorage`; without a token the field stays hidden. Expose the UI only on a
trusted network or behind a reverse proxy with TLS and Basic Auth.

## HTTP API

| Method | Path | Meaning |
|---|---|---|
| `GET` | `/healthz` | process/config health (`ok` or `degraded`) |
| `GET` | `/api/status` | aggregated status |
| `GET` | `/api/runs?limit=10` | recent `catalog-update` run reports |
| `GET` | `/api/jobs?limit=10` | current and recent pipeline jobs |
| `GET` | `/api/jobs/{id}` | job detail |
| `GET` | `/api/jobs/{id}/log?tail=200` | job log tail |
| `POST` | `/api/run` | start a `full` or `dry-run` job |
| `POST` | `/api/cancel` | cancel the running job |
| `POST` | `/api/hook/screenshots` | package/upload screenshots (409 while `shotgen.lock` exists) |

`POST /api/run` accepts `mode` (`full`/`dry-run`) and the optional
`only`/`exclude`/`skip_publish`/`no_crew` options. A second start returns
`409` while a job is running. `POST /api/cancel` returns `202` and terminates
the process group (SIGTERM, then SIGKILL after 10 seconds).

## Docker

The pipeline and the gallery run as separate services from one image:

```sh
cd docker
cp .env.example .env        # fill in HOST_* paths, FTP, GitHub token, mail
# create <HOST_DATA_DIR>/state on the host, e.g.
# mkdir -p /path/to/MarcersGamesDVD-Update/Data/state
docker compose build
docker compose up -d
```

- `pipeline` exposes `8080`; `gallery` exposes `8764`.
- Both mount `HOST_DATA_DIR`; the pipeline additionally mounts
  `${HOST_DATA_DIR}/state` as `/state` (`MARCER_STATE_DIR=/state`).
- The gallery only gets the four catalog path variables, never FTP/GitHub/mail
  secrets.
- The image is built for `linux/amd64` and published as
  `ghcr.io/skoelle/marcer-gamedvd-launcher/pipeline:latest` plus a
  `sha-…` tag by `.github/workflows/pipeline-image.yml`.

## E-mail notification

After a successful **full** job with at least one `new` or `changed` sync file,
the job runner sends one e-mail. Dry runs, failed runs and no-op runs are
silent. The notification is optional and disabled unless the SMTP settings are
present:

| Variable | Default | Meaning |
|---|---|---|
| `MARCER_SMTP_HOST` | – | SMTP server; notification disabled when empty |
| `MARCER_SMTP_PORT` | `587` | SMTP port |
| `MARCER_SMTP_USER` / `MARCER_SMTP_PASS` | – | optional SMTP login |
| `MARCER_SMTP_STARTTLS` | `1` | use STARTTLS |
| `MARCER_SMTP_SSL` | `0` | use implicit TLS (e.g. port 465) |
| `MARCER_MAIL_FROM` | `MARCER_SMTP_USER` | sender |
| `MARCER_MAIL_TO` | – | recipient(s) |

Notification errors never fail the pipeline job; the result is written to the
job log.

## Status sources

| Area | Source |
|---|---|
| Sync | `archive-sync/changes.json`, `archive-sync/remote-inventory.json.gz` |
| Gameinfo | `gameinfo/manifest.json`, `games-*.json`, file metadata |
| Full index | `gameinfo/full-index.json.gz` |
| Crews | `gameinfo/crews.json` |
| Publish | `$MARCER_STATE_DIR/asset-publish/state.json` (gameinfo + screenshots entries; legacy fallback for gameinfo) |
| Screenshots | `MARCER_OUT_DIR/index*.json` and referenced PNGs |
| Run history | `<report dir>/runs/*.json` |
| Jobs | `$MARCER_STATE_DIR/jobs/<id>/job.json` + `job.log` |
| Scheduler | `$MARCER_STATE_DIR/scheduler.json` |
| Lock | `$MARCER_STATE_DIR/pipeline.lock` |
| Storage | `shutil.disk_usage` for root, patch, out, data and state |
| Configuration | presence of the `MARCER_*` variables, never their values |

Missing or malformed files are reported as `present: false` plus an error
string. The service does not return HTTP 500 for broken catalog data. Large
JSON files are cached in memory by `(mtime, size)`.

The **Sync** card also shows the archive-sync remote inventory
(`remote_inventory` in `changes.json`: file count, complete flag, age) so the
freshness of the FTP badges is visible. The **Full index** card shows the
`full-index.json.gz` FTP counts (`ftp_on`/`ftp_physical_dvd`/`ftp_deleted`,
plus `ftp_unknown`, which raises a warning).

Screenshot status is read-only for the index view: per scope it counts
`done`/`desktop`/`no_usable_shots`/`pending`/`error`/… entries, entries without
a preview and the referenced image bytes. Screenshot **publishing** is a
separate job (button or `POST /api/hook/screenshots`); it packages and uploads
the current `MARCER_OUT_DIR` only when the content changed. Image sizes are
sampled within a small time budget because stat'ing tens of thousands of PNGs
on a network share is slow; `bytes_partial` marks a sampled value (the UI
prefixes it with `≥`). The index file size is always included.

## Job model

- One worker and one global lock (`$MARCER_STATE_DIR/pipeline.lock`).
- Persistent job state under `$MARCER_STATE_DIR/jobs/<id>/` with `job.json`
  and `job.log`.
- Stage updates are parsed from the `==> <step>` lines of `catalog-update`;
  a successful job ends with `stage: "done"`.
- A stale lock is detected by PID/heartbeat; after a service restart a running
  job is marked `interrupted` and an orphaned process group is terminated.
- The job history keeps the newest 50 jobs.
- Besides `full`/`dry-run`, the runner supports the `screenshots` mode
  (`asset-publish --only screenshots --upload`).

## Screenshot publishing

Use the **Publish screenshots** button or:

```sh
curl -X POST http://<host>:8080/api/hook/screenshots
```

The hook:

- refuses with `409` while `MARCER_OUT_DIR/shotgen.lock` exists,
- uses the same global job lock as catalog updates,
- runs `asset-publish --only screenshots --upload`,
- packs only changed content (content signature),
- updates `latest.json` through `asset-manifest`,
- shows up in the normal job panel and history.

The automatic weekly/full catalog update never packages screenshots.

## Scheduler

The service starts one scheduler thread. Its default schedule is
**Thursday 20:00 Europe/Berlin** (`0 20 * * 4`). It starts a normal full
catalog-update job through the shared `JobManager` (`source: "scheduler"`),
so lock handling, cancellation, logs and e-mail notifications are identical
to a manual run.

- Persistent state: `$MARCER_STATE_DIR/scheduler.json` with the next run, last
  attempt and last job id.
- A missed run is caught up when it is no later than
  `MARCER_SCHEDULE_CATCH_UP_HOURS` (default 24). `0` skips missed runs.
- Manual runs do not move the schedule.
- If a manual job is running at the due time, the scheduler retries within the
  catch-up window.
- The next run and last scheduler result are shown in the Configuration card.

## Tests

```sh
.venv/bin/python -m unittest discover -s tools/catalog-pipeline/tests -v
```

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
