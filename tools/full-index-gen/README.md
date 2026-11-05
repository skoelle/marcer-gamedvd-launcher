# Full Index Generator

Builds the **screenshot-independent** catalog index
`<MARCER_DATA_DIR>/gameinfo/full-index.json.gz`.

The index lists every ZIP of the catalog sections (cracked, pd, utils,
magazine, falcon) with its section, layer, size/mtime, disk-image hashes, a
stable container fingerprint and (when available) its FTP availability from the
`archive-sync` remote inventory. It is generated from the game trees alone, so
the pipeline does **not** depend on `tools/screenshot-gen` or the screenshot
index (`index*.json`). New ZIPs become visible in the desktop app immediately,
before screenshots exist.

The screenshot index stays the authority for screenshot state
(`preview`/`candidates`/`status`/`kind`); the desktop app merges both. See
[`docs/PLAN-docker-pipeline.md`](../../docs/plans/PLAN-docker-pipeline.md).

## Requirements

- Python 3.12 (the repo `.venv`; standard library only)
- `local/paths.env`:
  - `MARCER_ROOT_DIR` (required)
  - `MARCER_PATCH_DIR` (optional overlay; patch wins)
  - `MARCER_DATA_DIR` (required; writes `gameinfo/full-index.json.gz`)
  - `MARCER_OUT_DIR` (only for `check --parity`)
  - `MARCER_STATE_DIR` (optional; inventory defaults to
    `$MARCER_STATE_DIR/archive-sync/remote-inventory.json.gz`)

## Usage

```sh
tools/full-index-gen/run.sh run                 # build/update
tools/full-index-gen/run.sh run --full          # re-hash every ZIP
tools/full-index-gen/run.sh run --scope cracked # one section
tools/full-index-gen/run.sh check               # exit 1 when stale
tools/full-index-gen/run.sh check --parity      # also compare rel/layer with index*.json
tools/full-index-gen/run.sh run --dry-run       # scan only
tools/full-index-gen/run.sh run --ftp-inventory /state/archive-sync/remote-inventory.json.gz
tools/full-index-gen/run.sh run --no-ftp-status # do not read the inventory; clear ftp_status
tools/full-index-gen/run.sh run --keep-ftp-status # keep existing values (partial sync)
```

Trial runs on a subset (writes a filtered index; `--only` requires `--out`
so the production index cannot be overwritten by accident):

```sh
tools/full-index-gen/run.sh run --only Mazewar --out /tmp/full-index.json.gz
```

## Build order

Run the whole local pipeline once (recommended):

```sh
tools/catalog-update/run.sh
```

It syncs the FTP, refreshes only the steps whose inputs changed, and publishes
gameinfo only when the content signature changed or an upload/manifest update
is pending.

Manual equivalent:

```sh
tools/archive-sync/run.sh sync
tools/gameinfo-gen/run.sh extract
tools/full-index-gen/run.sh run
tools/crew-analysis/run.sh
tools/asset-publish/run.sh publish --only gameinfo --upload
```

`shotgen` and the screenshot archive run later on the dev machine; they are
not inputs to this tool.

## Output

`full-index.json.gz` (deterministic, gzip, no timestamp):

```json
{
  "schema": 2,
  "tool": "tools/full-index-gen",
  "counts": {
    "zips": 19347, "members": 24000, "errors": 0,
    "ftp_on": 18000, "ftp_physical_dvd": 1200,
    "ftp_deleted": 147, "ftp_unknown": 0
  },
  "errors": [],
  "entries": {
    "Title Sorted/.../Game.zip": {
      "section": "cracked",
      "name": "Game.zip",
      "size": 134227,
      "mtime": 1700000000,
      "layer": "ROOT|PATCH|BOTH",
      "ftp_status": "on_ftp|physical_dvd|ftp_deleted",
      "fingerprint": "a1454725:380945",
      "members": [
        {
          "name": "Game.MSA", "format": "msa",
          "crc32": "a1454725", "size": 380945,
          "raw":  {"sha1": "…", "sha512": "…", "crc32": "…", "size": 380945},
          "file": {"sha1": "…", "sha512": "…", "crc32": "…", "size": 380945}
        }
      ]
    }
  }
}
```

- `raw` is the decoded disk image (TOSEC `.st`); `file` is the stored member
  (`.msa`/`.stx`). `.st` members carry only `raw`.
- `fingerprint` is the sorted `crc32:size` list of the image members; the app
  can look a renamed ZIP up without reading the disk image.
- Hashes: SHA-1 + SHA-512 + CRC32 + size (MD5 is omitted; SHA-1 has the same
  coverage in the PirateFinder catalogue).
- `ftp_status` is optional and comes from the last complete `archive-sync`
  inventory: `on_ftp` (remote file exists), `physical_dvd` (local ROOT/BOTH
  ZIP that is no longer on FTP) or `ftp_deleted` (local PATCH-only ZIP that is
  no longer on FTP). The desktop app renders `PHYSICAL-DVD` / `FTP-DELETED`
  badges and blocks FTP downloads for those ZIPs. Without an inventory the
  existing `ftp_status` values are kept, so a manual run never silently drops
  published badges; `--no-ftp-status` clears them explicitly. A ZIP is matched
  case-insensitively by its relative path.

## FTP inventory

The inventory is written by `tools/archive-sync` after a **complete** remote
scan (no `--only`, no incomplete directories) to
`$MARCER_STATE_DIR/archive-sync/remote-inventory.json.gz` (default state root:
`$MARCER_DATA_DIR/state`). Partial or failed scans never replace the last
complete snapshot. `catalog-update` passes the same path to `check` and `run`,
so a change that only affects FTP availability still fails the check, rebuilds
the index and republishes the gameinfo asset. After a targeted (`--only`) sync
the inventory is deliberately stale; `catalog-update` then passes
`--keep-ftp-status`, which neither reads the inventory nor changes existing
badges until the next complete scan.

## Incremental

Entries are reused when `size`, `mtime` and `section` are unchanged, so only
new/changed ZIPs are decoded. The FTP status is recomputed for every entry on
each run; an inventory change alone does not require re-hashing. The first run
is the expensive one (~40–60 min for ~39k ZIPs over a network share;
`--scope cracked` alone is ~19k); later runs take seconds.
`MARCER_FULL_INDEX_WORKERS` (default `4`) sets the hashing workers.

## Tests

```sh
.venv/bin/python -m unittest discover -s tools/full-index-gen/tests -v
```
