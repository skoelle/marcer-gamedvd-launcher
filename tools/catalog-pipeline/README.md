# catalog-pipeline

Read-only status web service for the Marcer catalog pipeline.

Phase 1 of the server automation described in
[`docs/plans/PLAN-docker-pipeline.md`](../../docs/plans/PLAN-docker-pipeline.md).
It aggregates the existing sync reports, gameinfo files, full index, crew data,
asset-publish state, screenshot indices, storage and recent run reports into a
small dashboard. It never writes to the catalog, the game trees or the pipeline
state.

Manual runs, the scheduler, Docker/GHCR and screenshot publishing are later
phases.

## Requirements

- Python 3.12 (the repo `.venv`; standard library only)
- `local/paths.env` (git-ignored) with the usual path variables:
  `MARCER_ROOT_DIR`, `MARCER_PATCH_DIR`, `MARCER_OUT_DIR`,
  `MARCER_DATA_DIR` and optionally `MARCER_STATE_DIR`,
  `MARCER_SYNC_REPORT_DIR`, `MARCER_PIPELINE_REPORT_DIR`
- No FTP or GitHub connection is made in this phase; credentials only affect
  the configuration indicator

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
| `MARCER_SYNC_REPORT_DIR` | `$MARCER_STATE_DIR/archive-sync` or `local/archive-sync` | `archive-sync` reports |
| `MARCER_PIPELINE_REPORT_DIR` | `$MARCER_STATE_DIR/catalog-update` or `local/catalog-update` | `catalog-update` run reports |
| `PIPELINE_VERBOSE` | – | log every HTTP request |

The UI binds to `0.0.0.0` by default. It has no authentication; expose it only
on a trusted network or behind a reverse proxy with TLS and Basic Auth.

## HTTP API

| Method | Path | Meaning |
|---|---|---|
| `GET` | `/healthz` | process/config health (`ok` or `degraded`) |
| `GET` | `/api/status` | aggregated status |
| `GET` | `/api/runs?limit=10` | recent `catalog-update` run reports |

All endpoints are read-only and return JSON except `/` and `/static/*`.

## Status sources

| Area | Source |
|---|---|
| Sync | `archive-sync/changes.json` |
| Gameinfo | `gameinfo/manifest.json`, `games-*.json`, file metadata |
| Full index | `gameinfo/full-index.json.gz` |
| Crews | `gameinfo/crews.json` |
| Publish | `asset-publish/state.json` (or `<MARCER_DATA_DIR>/.asset-publish-state.json`) |
| Screenshots | `MARCER_OUT_DIR/index*.json` and referenced PNGs |
| Run history | `<report dir>/runs/*.json` |
| Storage | `shutil.disk_usage` for root, patch, out, data and state |
| Configuration | presence of the `MARCER_*` variables, never their values |

Missing or malformed files are reported as `present: false` plus an error
string. The service does not return HTTP 500 for broken catalog data. Large
JSON files are cached in memory by `(mtime, size)`.

Screenshot status is read-only in this phase: per scope it counts
`done`/`desktop`/`no_usable_shots`/`pending`/`error`/… entries, entries without
a preview and the referenced image bytes. No screenshot is packaged or uploaded.
Image sizes are sampled within a small time budget because stat'ing tens of
thousands of PNGs on a network share is slow; `bytes_partial` marks a sampled
value (the UI prefixes it with `≥`). The index file size is always included.

## Tests

```sh
.venv/bin/python -m unittest discover -s tools/catalog-pipeline/tests -v
```

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
