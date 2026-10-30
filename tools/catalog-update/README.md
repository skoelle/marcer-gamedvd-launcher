# catalog-update

Runs the local catalog pipeline once:

```text
archive-sync
  -> gameinfo-gen (when needed)
  -> full-index-gen (when needed)
  -> crew-analysis (when needed)
  -> asset-publish (only when the gameinfo content changed)
```

This is the one-shot counterpart to the planned Docker pipeline in
[`docs/plans/PLAN-docker-pipeline.md`](../../docs/plans/PLAN-docker-pipeline.md).
It never modifies the root tree, never deletes files, and has no rename
detection.

## Requirements

- Python 3.12 (the repo `.venv`)
- `local/paths.env` with `MARCER_ROOT_DIR`, `MARCER_PATCH_DIR` and
  `MARCER_DATA_DIR`
- FTP credentials for `archive-sync` and `asset-publish`
- `gh` authentication for the `latest.json` update after an upload

## Usage

```sh
tools/catalog-update/run.sh
tools/catalog-update/run.sh --only "Title Sorted/PD Games - Title Sorted/T"
tools/catalog-update/run.sh --dry-run
tools/catalog-update/run.sh --skip-publish
```

Options:

| Option | Meaning |
|---|---|
| `--only PREFIX` | sync only this relative prefix (repeatable; passed to `archive-sync`) |
| `--exclude PATTERN` | exclude a name/path glob (repeatable; passed to `archive-sync`) |
| `--dry-run` | run `archive-sync plan` and read-only checks; write nothing |
| `--skip-publish` | update the local catalog but do not package/upload gameinfo |
| `--no-crew` | skip `crew-analysis` |
| `--report-dir DIR` | run report directory (default `local/catalog-update`) |
| `--sync-report-dir DIR` | `archive-sync` report directory (default `local/archive-sync`) |

The default is a full archive sync. Use `--only` for a targeted update such as
the PD/T folder.

## Step selection

| Condition | Action |
|---|---|
| Sync failed | abort |
| `gameinfo-gen check` fails | `gameinfo-gen extract` |
| new folder in `cracked`, `pd` or `utils` | `gameinfo-gen extract` |
| new/changed ZIPs, gameinfo rebuilt or full index stale | `full-index-gen run` |
| gameinfo rebuilt or cracked tree changed | `crew-analysis` (ranking) |
| gameinfo content changed or upload/manifest pending | `asset-publish --upload` |
| nothing changed | publish skipped |

New folders are detected from the sync report without walking the whole
archive: a parent folder that is absent in root and has no older patch files
counts as new. A new ZIP inside an existing folder therefore does not trigger
a needless gameinfo rebuild.

## Publish gate

`asset-publish` is not called just because publishing is enabled. If the
catalog did not change and the publish state is clean (uploaded archive exists,
no `manifest_dirty`), the whole publish step is skipped.

Only when the catalog changed or a previous upload/manifest update is pending,
the tool runs a **read-only dry-run**:

```sh
tools/asset-publish/run.sh publish --only gameinfo --upload --dry-run --json
```

- `would-skip` -> no packaging and no upload
- `would-create-upload` -> pack, upload and update `latest.json`
- `would-upload` -> upload the existing archive and update `latest.json`
- `would-update-manifest` -> retry the pending `latest.json` update

Only the last three statuses trigger the real publish. A pending upload or a
failed manifest update from an earlier run is therefore retried automatically.

## Run report

Unless `--dry-run` is used, each run writes
`local/catalog-update/runs/<timestamp>.json` (git-ignored):

- overall status and error
- executed steps with args, exit code and duration
- sync counts and detected new gameinfo folders
- whether gameinfo, full index, crew analysis and publish ran
- publish status

A lock file at `local/catalog-update/run.lock` prevents concurrent runs. A lock
owned by a dead process or older than 24 hours is treated as stale.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success (including no-op runs and dry-runs) |
| `1` | a pipeline step failed |
| `2` | configuration/usage error |
| `130` | interrupted |

## What is not included

- Screenshot generation or `index*.json` updates
- `crew-analysis images`
- Deletion, pruning or rename detection in root/patch

## Tests

```sh
.venv/bin/python -m unittest discover -s tools/catalog-update/tests -v
```

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
