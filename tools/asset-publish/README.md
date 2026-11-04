# asset-publish

Packages the Marcer GameDVD catalog data into deterministic ZIP archives for
the desktop app and the `catalog-latest` release pointer.

It supports two asset kinds: **gameinfo** and **screenshots**. Both use local
deterministic packaging, optional FTP upload and the automatic `latest.json`
update.

## What it does

### gameinfo

1. Reads `<MARCER_DATA_DIR>/gameinfo`.
2. Selects only the published files:
   - `games-*.json` (`games-cracked.json`, `games-pd.json`, `games-utils.json`)
   - `manifest.json`
   - `crews.json` / `crew-images.json` (when present)
   - `crew-cluster.json` (manually created cluster file, when present)
   - `full-index.json.gz` (screenshot-independent catalog index)
   - `unmatched-report.txt`
3. Ignores everything else: `.marcer-assets.json`, `*.bak-*`, `*.tmp`,
   `*.part`, hidden files, `__MACOSX`, legacy ZIPs.

### screenshots

1. Reads `MARCER_OUT_DIR`.
2. Selects the five root index files (`index.json`, `index-pd.json`,
   `index-utils.json`, `index-magazine.json`, `index-falcon.json`) and every
   `.png` below it.
3. Excludes `logs/`, `@eaDir`, `__MACOSX`, hidden files/directories, sidecar
   JSON, old `screenshots-*.zip`/`.7z` archives and the helper shell script.

### Both kinds

4. Builds a content signature from the sorted
   `(relpath, size, sha256)` list.
5. If the signature matches the state file and the recorded archive still
   exists, the run is a **skip** (use `--force` to repack).
6. Otherwise writes `<kind>-<yyyyMMdd-HHmmss>.zip` into the output directory
   and records the new signature.
7. With `--upload` only: uploads the archive via FTP and then runs
   `tools/asset-manifest` so `latest.json` points at the new archive.

The ZIP is deterministic: entries are sorted, paths are POSIX and every entry
uses the fixed timestamp `1980-01-01 00:00:00`, so identical content produces
identical bytes. Screenshot archives are stored without extra deflate
compression (PNGs are already compressed); gameinfo archives use deflate.

The archive is written to a temporary `.part` file and moved into place with
`os.replace`, so readers never see a half-written ZIP.

## Requirements

- Python 3.12 (the repo `.venv`; standard library only)
- `local/paths.env` for local runs:

```sh
MARCER_DATA_DIR="/path/to/GamesDVD-Update/Data"
# Optional:
#MARCER_ASSET_OUT_DIR="/path/to/GamesDVD-Update/Data"
#MARCER_STATE_DIR="/state"  # optional; default is <MARCER_DATA_DIR>/state

# Only needed for --upload:
MARCER_FTP_HOST="host:2121"
MARCER_FTP_USER="user"
MARCER_FTP_PASS="password"
#MARCER_FTP_ASSETS_REMOTE="/Uploads/MarcerGameDVDLauncher-assets/"
#MARCER_FTP_ENCODING="latin-1"
```

`--upload` also needs `tools/asset-manifest` authentication: either the
authenticated `gh` CLI or `MARCER_GITHUB_TOKEN` for the GitHub token API (used
by the Docker pipeline).

## Usage

```sh
# Local ZIP only (no network)
tools/asset-publish/run.sh publish --only gameinfo
tools/asset-publish/run.sh publish --only screenshots

# ZIP + FTP upload + latest.json
tools/asset-publish/run.sh publish --only gameinfo --upload
tools/asset-publish/run.sh publish --only screenshots --upload

# Preview both modes without writing or connecting
tools/asset-publish/run.sh publish --only gameinfo --dry-run
tools/asset-publish/run.sh publish --only screenshots --upload --dry-run

# Repack and re-upload even when the content signature is unchanged
tools/asset-publish/run.sh publish --only gameinfo --upload --force
```

Useful options:

| Option | Meaning |
|---|---|
| `--only gameinfo\|screenshots` | asset kind |
| `--upload` | upload to `MARCER_FTP_ASSETS_REMOTE` and update `latest.json` |
| `--dry-run` | print `would-*` actions, write/connect nothing |
| `--force` | pack (and upload) even when the signature is unchanged |
| `--json` | machine-readable result (status, archive, signature, size, sha256, upload state) |
| `--no-progress` | suppress the throttled progress lines on stderr |
| `--data-dir PATH` | override `MARCER_DATA_DIR` |
| `--source PATH` | override the source directory |
| `--output-dir PATH` | override the archive output directory |
| `--state-file PATH` | override the signature state file |

## Progress output

A run that has to hash and pack many screenshot PNGs would otherwise be
silent until the final result. To keep the pipeline job log and the console
informative, `asset-publish` reports its progress on **stderr** (stdout stays
reserved for the `--json` result):

- `==> collect` / `==> pack` / `==> upload` / `==> manifest` stage markers,
  which the catalog-pipeline runner turns into the visible job stage;
- throttled counter lines (about one per second), e.g.
  `collect: 12345 files hashed`, `pack: 3400/12800 entries (26%)`,
  `upload: 42% (1234567/2938475 bytes)`.

Counter lines are enabled by default and can be disabled with
`--no-progress`; the stage markers are then still printed.

## Paths

| Thing | gameinfo | screenshots |
|---|---|---|
| Source | `<MARCER_DATA_DIR>/gameinfo` | `MARCER_OUT_DIR` |
| ZIP output | `MARCER_ASSET_OUT_DIR`, else `MARCER_DATA_DIR` | `MARCER_OUT_DIR` |
| Name | `gameinfo-<yyyyMMdd-HHmmss>.zip` | `screenshots-<yyyyMMdd-HHmmss>.zip` |
| State | `MARCER_STATE_DIR/asset-publish/state.json` | same file, separate `assets.screenshots` entry |
| FTP target | `MARCER_FTP_ASSETS_REMOTE` | same |

The state file holds the content signature, the archive name/size/SHA-256 and
the upload/manifest state. It is written atomically and ignored by the packer
itself.

## FTP upload and `latest.json`

The Marcer FTP server does **not** allow `RNFR`/`RNTO` or `DELE` (it may even
disconnect the session for such commands). With `--upload` the archive is
therefore stored **directly under its final name** in binary mode (passive
FTP):

1. If a remote file with the final name already has exactly the local size,
   the transfer is skipped (e.g. a crash after the upload but before the state
   update).
2. Otherwise `STOR <name>.zip` writes/overwrites the final file.
3. The remote size is verified with `SIZE`. A mismatch is reported as an
   error; the partial file stays on the server because it cannot be deleted,
   and the next `--upload` run overwrites it.

The connection uses `MARCER_FTP_HOST` (`host` or `host:port`),
`MARCER_FTP_USER`/`MARCER_FTP_PASS` (an empty user means `anonymous`) and
`MARCER_FTP_ENCODING` (default `utf-8`). The Marcer server returns non-ASCII
names as ISO-8859-1; use `latin-1` for listings with umlauts. Asset archive
names themselves are ASCII.

Old `<name>.zip.part` files from the earlier rename-based version are left
untouched. They are harmless: `tools/asset-manifest` only matches
`gameinfo-<yyyyMMdd-HHmmss>.zip`.

After a successful upload, `tools/asset-manifest` runs automatically (without
`--only`, so the screenshots entry stays in the pointer) and replaces the
`latest.json` asset on the `catalog-latest` GitHub release. Its output is
captured and shown on failure.

Failure handling:

- **Upload fails** → the local archive stays recorded but marked
  `uploaded: false`; the next `--upload` run retries the upload without
  repacking (overwriting any partial remote file). Exit `1`.
- **Manifest update fails** → the archive remains marked `uploaded: true`
  with `manifest_dirty: true`; the next `--upload` run retries only the
  pointer update. Exit `1`. If the content is unchanged and the pointer is
  clean, a further `--upload` run is a no-op (`skipped`).

## Exit codes and result

- `0`: created, uploaded, skipped, or dry-run (`would-*`)
- `1`: configuration, FTP, manifest or I/O error (message on stderr)

With `--json` the result looks like:

```json
{
  "kind": "gameinfo",
  "status": "uploaded",
  "source": "/data/gameinfo",
  "output_dir": "/data",
  "state_file": "/data/state/asset-publish/state.json",
  "signature": "…",
  "files": 7,
  "archive": "/data/gameinfo-20261028-174408.zip",
  "size": 1046125,
  "sha256": "…",
  "created": true,
  "uploaded": true,
  "remote": "/Uploads/MarcerGameDVDLauncher-assets/gameinfo-20261028-174408.zip",
  "manifest_updated": true,
  "force": false,
  "upload": true,
  "dry_run": false
}
```

Error results keep `status: "error"` plus `stage` (`upload`/`manifest`) and
`error` (message). `uploaded` reflects whether the ZIP reached the server.

## Tests

```sh
.venv/bin/python -m unittest discover -s tools/asset-publish/tests -v
```

The tests use a fake FTP client and a mocked `asset-manifest` runner; they
never touch a real server or GitHub.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
