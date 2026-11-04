# Marcer Pipeline Docker

Docker image and Compose stack for the catalog pipeline and the gallery.

The image is built for **linux/amd64** only. It contains the Python tools from
`tools/`; runtime dependencies are `tzdata` and `olefile` (for `gameinfo-gen`).
No Hatari, Xvfb, 7-Zip or desktop toolchain is included.

## Services

| Service | Port | Access | State |
|---|---|---|---|
| `pipeline` | `8080` | internal / reverse proxy | read/write |
| `gallery` | `8764` | reverse proxy | read-only |

Both services use the same image. The gallery gets only the four catalog path
variables and never receives FTP, GitHub, pipeline-token or mail secrets.

## Setup

```sh
cd docker
cp .env.example .env
# edit .env: HOST_* paths, FTP, MARCER_GITHUB_TOKEN, optional SMTP and token
# create <HOST_DATA_DIR>/state on the host, e.g.
# mkdir -p /path/to/MarcersGamesDVD-Update/Data/state
# ensure HOST_PATCH_DIR, HOST_DATA_DIR and HOST_DATA_DIR/state are writable by PUID:PGID
docker compose build
docker compose up -d
```

The host paths are read from `docker/.env` for the Compose volume mounts. The
pipeline state lives under `${HOST_DATA_DIR}/state` and is mounted as `/state`
(`MARCER_STATE_DIR=/state`). Create that directory before the first start and
match `PUID`/`PGID` to the owner of the NAS mounts. It contains `archive-sync/`, `catalog-update/`,
`asset-publish/`, `crew-analysis/`, `jobs/`, `pipeline.lock` and
`scheduler.json`.

## Image

```sh
docker build -f Dockerfile -t marcer-pipeline:local ..
```

The GitHub workflow `.github/workflows/pipeline-image.yml` builds and pushes:

```text
ghcr.io/skoelle/marcer-gamedvd-launcher/pipeline:latest
ghcr.io/skoelle/marcer-gamedvd-launcher/pipeline:sha-<commit>
```

It runs on pushes to `main` that touch `tools/**` or `docker/**`, and on
`workflow_dispatch`. There is no app release tag for the pipeline image.

## Reverse proxy

Expose only the gallery and, if needed, the pipeline UI through the existing
reverse proxy with TLS and authentication. The pipeline UI has an optional
`MARCER_PIPELINE_TOKEN` for `POST` requests; `GET` endpoints are read-only. The
token field in the UI only appears when that variable is set. Do not publish
port `8080` directly to the internet.

## Scheduler

The pipeline service runs the weekly scheduler in-process:

- Default: Thursday 20:00 `Europe/Berlin` (`MARCER_SCHEDULE_CRON`)
- Persistent state in `$MARCER_STATE_DIR/scheduler.json`
- Missed runs are caught up within `MARCER_SCHEDULE_CATCH_UP_HOURS`
  (default 24; `0` skips missed runs)
- Manual runs do not move the schedule
- Output uses the normal job runner and e-mail notification

## Screenshots

The **Publish screenshots** button (or `POST /api/hook/screenshots`) packages
`MARCER_OUT_DIR` as `screenshots-<timestamp>.zip`, uploads it and updates
`latest.json`. It refuses to start while `shotgen.lock` exists and uses the
same job lock as catalog updates. The job panel shows the live stage
(`collect`/`pack`/`upload`/`manifest`) and tails the throttled progress lines
from `tools/asset-publish`, so a long pack/upload stays visible.

## E-mail notification

A successful full run with at least one `new` or `changed` sync file sends one
mail when the `MARCER_SMTP_*` / `MARCER_MAIL_*` variables are configured.
Dry runs, no-op runs and failed runs do not send mail.

## Deployment webhook

The image workflow can notify the Docker host after a successful GHCR push.
Set these **repository secrets** in GitHub (not in `docker/.env`):

- `WEBHOOK_URL`
- `WEBHOOK_TOKEN`

The workflow sends one `POST` with `Authorization: Bearer <token>`. The
endpoint is expected to update the whole Compose stack and return HTTP `200`
with:

```json
{"summary": {"updated": 1, "failed": 0}}
```

A value of `updated` other than 1 is fine (`> 0` is required); the step fails
when `updated == 0` or `failed > 0`. Without `WEBHOOK_URL` the step is
skipped.

## Update

```sh
docker compose pull
docker compose up -d
```

If the GHCR package is private, log in on the Docker host first:

```sh
echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
```

Image updates are intentionally manual for now. Pin `PIPELINE_IMAGE` to a
`sha-…` tag if you want reproducible deployments.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
