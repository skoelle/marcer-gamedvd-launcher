# Game-Info Extractor

Extracts game metadata from the Marcer GameDVD XLS workbooks into JSON files
for the launcher and future tools. See
[`ANALYSIS-game-data.md`](../../docs/analysis/ANALYSIS-game-data.md) for the full analysis
and data model.

## Requirements

- Python 3 with the repo `.venv` (`olefile`)
- Environment in `local/paths.env` (git-ignored): `MARCER_PATCH_DIR` and
  `MARCER_DATA_DIR` (required; gameinfo output goes to `MARCER_DATA_DIR/gameinfo`),
  `MARCER_ROOT_DIR` (optional, enables full folder matching)

## Usage

```bash
tools/gameinfo-gen/run.sh extract             # full run, writes to MARCER_DATA_DIR/gameinfo
tools/gameinfo-gen/run.sh extract --dry-run   # summary only, no writes
tools/gameinfo-gen/run.sh extract --kind cracked
tools/gameinfo-gen/run.sh check               # validate output vs sources (exit 1 on stale)
tools/gameinfo-gen/run.sh report              # audit summary (TOS notes, dump flags, coverage)
```

`extract` reads the three workbooks (`Games.xls`, `PD Games.xls`,
`Utils_.xls`; PATCH copy preferred, ROOT as fallback), scans the
title-sorted trees in ROOT and PATCH, matches folders to XLS titles
(exact, prefix, fuzzy) and writes into `MARCER_DATA_DIR/gameinfo`:

- `games-cracked.json`, `games-pd.json`, `games-utils.json`
- `manifest.json` (counts, source mtimes, match statistics)
- `unmatched-report.txt` (folders without data, titles without folder)

`extract` writes only the normal metadata files listed above. It never modifies
the XLS sources or the game trees. Other tools add derived files to the same
directory: `tools/crew-analysis` writes `crews.json` and `crew-images.json`.
Rerun `extract` whenever the XLS files change (`check` detects staleness); rerun
`tools/crew-analysis` afterwards so the crew data joins the new metadata.

## Build order

Run the whole local pipeline once (recommended):

```sh
tools/catalog-update/run.sh                # sync + all steps, when needed
```

Manual equivalent (no screenshots required):

```sh
tools/gameinfo-gen/run.sh extract          # 1) games-*.json
tools/full-index-gen/run.sh run            # 2) gameinfo/full-index.json.gz
tools/crew-analysis/run.sh                 # 3) crews.json
tools/asset-publish/run.sh publish --only gameinfo --upload

# optional, after screenshots were captured on the dev machine:
tools/screenshot-gen/run.sh run --scope cracked     # index.json + PNGs
tools/crew-analysis/run.sh images --top 128 --write-images --force
```

`crew-analysis` only reads `games-cracked.json` (and the full index); it never
rewrites the `games-*.json` files. See
[`ANALYSIS-crews.md`](../../docs/analysis/ANALYSIS-crews.md) and the
[crew-analysis README](../crew-analysis/README.md).

## Config

Defaults live in `gameinfo.py`. Override via `config.example.json` (copy
and adjust) or `config.local.json` (git-ignored). No real paths in config —
those come from `local/paths.env` via `run.sh`.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
