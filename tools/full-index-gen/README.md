# Full Index Generator

Builds the **screenshot-independent** catalog index
`<MARCER_DATA_DIR>/gameinfo/full-index.json.gz`.

The index lists every ZIP of the catalog sections (cracked, pd, utils,
magazine, falcon) with its section, layer, size/mtime, disk-image hashes and a
stable container fingerprint. It is generated from the game trees alone, so
the pipeline does **not** depend on `tools/screenshot-gen` or the screenshot
index (`index*.json`). New ZIPs become visible in the desktop app immediately,
before screenshots exist.

The screenshot index stays the authority for screenshot state
(`preview`/`candidates`/`status`/`kind`); the desktop app merges both. See
[`docs/PLAN-docker-pipeline.md`](../../docs/PLAN-docker-pipeline.md).

## Requirements

- Python 3.12 (the repo `.venv`; standard library only)
- `local/paths.env`:
  - `MARCER_ROOT_DIR` (required)
  - `MARCER_PATCH_DIR` (optional overlay; patch wins)
  - `MARCER_DATA_DIR` (required; writes `gameinfo/full-index.json.gz`)
  - `MARCER_OUT_DIR` (only for `check --parity`)

## Usage

```sh
tools/full-index-gen/run.sh run                 # build/update
tools/full-index-gen/run.sh run --full          # re-hash every ZIP
tools/full-index-gen/run.sh run --scope cracked # one section
tools/full-index-gen/run.sh check               # exit 1 when stale
tools/full-index-gen/run.sh check --parity      # also compare rel/layer with index*.json
tools/full-index-gen/run.sh run --dry-run       # scan only
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
  "schema": 1,
  "tool": "tools/full-index-gen",
  "counts": {"zips": 19347, "members": 24000, "errors": 0},
  "errors": [],
  "entries": {
    "Title Sorted/.../Game.zip": {
      "section": "cracked",
      "name": "Game.zip",
      "size": 134227,
      "mtime": 1700000000,
      "layer": "ROOT|PATCH|BOTH",
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

## Incremental

Entries are reused when `size`, `mtime` and `section` are unchanged, so only
new/changed ZIPs are decoded. The first run is the expensive one (~40–60 min
for ~39k ZIPs over a network share; `--scope cracked` alone is ~19k); later
runs take seconds. `MARCER_FULL_INDEX_WORKERS` (default `4`) sets the hashing
workers.

## Tests

```sh
.venv/bin/python -m unittest discover -s tools/full-index-gen/tests -v
```
