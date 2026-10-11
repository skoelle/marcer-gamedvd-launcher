# Game-Info Extractor

Extracts game metadata from the Marcer GameDVD XLS workbooks into JSON files
for the launcher and future tools. See
[`ANALYSIS-game-data.md`](../../ANALYSIS-game-data.md) for the full analysis
and data model.

## Requirements

- Python 3 with the repo `.venv` (`olefile`)
- Environment in `local/paths.env` (git-ignored): `MARCER_PATCH_DIR` and
  `MARCER_DATA_DIR` (required), `MARCER_ROOT_DIR` (optional, enables full
  folder matching)

## Usage

```bash
tools/gameinfo-gen/run.sh extract             # full run, writes to MARCER_DATA_DIR
tools/gameinfo-gen/run.sh extract --dry-run   # summary only, no writes
tools/gameinfo-gen/run.sh extract --kind cracked
tools/gameinfo-gen/run.sh check               # validate output vs sources (exit 1 on stale)
tools/gameinfo-gen/run.sh report              # audit summary (TOS notes, dump flags, coverage)
```

`extract` reads the three workbooks (`Games.xls`, `PD Games.xls`,
`Utils_.xls`; PATCH copy preferred, ROOT as fallback), scans the
title-sorted trees in ROOT and PATCH, matches folders to XLS titles
(exact, prefix, fuzzy) and writes into `MARCER_DATA_DIR`:

- `games-cracked.json`, `games-pd.json`, `games-utils.json`
- `manifest.json` (counts, source mtimes, match statistics)
- `unmatched-report.txt` (folders without data, titles without folder)

The extractor is the only writer of that directory. It never modifies the
XLS sources or the game trees. Rerun whenever the XLS files change
(`check` detects staleness).

## Config

Defaults live in `gameinfo.py`. Override via `config.example.json` (copy
and adjust) or `config.local.json` (git-ignored). No real paths in config —
those come from `local/paths.env` via `run.sh`.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
