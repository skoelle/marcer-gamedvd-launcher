# AtariLegend Importer / Matcher

Downloads the weekly [AtariLegend database dump](https://www.atarilegend.com/data/database-dumps/)
(MariaDB, minus the `users` table), mirrors it into a queryable SQLite
artifact and matches it against the on-disk Marcer GameDVD screenshot-index
folders. See [`ANALYSIS-atarilegend.md`](../../docs/analysis/ANALYSIS-atarilegend.md).

The dump is parsed with the Python standard library only (the SQLite build
uses the bundled `sqlite3` module) — no extra dependencies. The tool never
writes into the game trees; output goes to `MARCER_ATARILEGEND_DIR`.

## Requirements

- Python 3 (the repo `.venv` is used when present, else `python3`)
- Environment in `local/paths.env` (git-ignored):
  - `MARCER_ATARILEGEND_DIR` (dump cache + artifact + reports)
  - `MARCER_OUT_DIR` (screenshot index: `index.json`, `index-pd.json`,
    `index-utils.json`)

## Usage

```bash
tools/atarilegend-gen/run.sh fetch                 # download the newest YYYY-MM-DD.sql.gz
tools/atarilegend-gen/run.sh extract               # build atarilegend.sqlite + match map (analysis)
tools/atarilegend-gen/run.sh extract --no-match     # DB only, skip the folder match
tools/atarilegend-gen/run.sh report                # row inventory of relevant tables
tools/atarilegend-gen/run.sh match                 # match report only (no DB)
tools/atarilegend-gen/run.sh match --section cracked
tools/atarilegend-gen/run.sh index                 # compact runtime index (folders + facets)
tools/atarilegend-gen/run.sh detail --slug buggy-boy
tools/atarilegend-gen/run.sh detail --folder cracked/B/Buggy\ Boy --json /tmp/d.json
tools/atarilegend-gen/run.sh fixtures              # detail fixtures for known games (diff harness)
```

`extract` builds the full SQLite mirror for **tool-side analysis** — the app
does not ship it. The app-facing formats are `index` (the compact runtime
index) and `detail` (the assembled game payload); both are references for the
Dart implementation in the desktop app (see `ANALYSIS-atarilegend.md` §4/§6).

`fetch` resolves the latest dump date from the directory listing and caches
it under `MARCER_ATARILEGEND_DIR/dump/`.

`extract` parses **all** dump tables into `MARCER_ATARILEGEND_DIR/atarilegend.sqlite`:

- one table per dump table (same names/columns; `int → INTEGER`,
  `decimal/float → REAL`, else `TEXT`; NULLs preserved)
- indexes reconstructed from the dump `PRIMARY KEY`/`KEY`/`UNIQUE` clauses
- `folders` — the `(kind, letter, folder) → al_game_id` match mapping
- `_meta` (schema version, source file + SHA-256, counts) and
  `_table_stats` (per-table column/row counts)

`match` (also run inside `extract`) builds the AtariLegend name index
(`games.name` + `game_akas` + `game_releases.name` + `game_release_akas`)
and matches every folder of the screenshot index in stages:

1. **exact** — normalized key equality (casefold, punctuation, article
   inversion `Tale, A` → `tale`, articles stripped)
2. **prefix** — one normalized key is a word-prefix of the other
   (e.g. `1943` ↔ `1943 the battle of midway`), longest wins
3. **fuzzy** — `difflib` ratio ≥ `fuzzy_cutoff` inside a blocking bucket

The match report is written to `MARCER_ATARILEGEND_DIR/atarilegend-match.json`
and `.txt` (per-section statistics, the match map, unmatched and ambiguous
folders).

`index` writes `atarilegend-index.json`: the `(kind|letter|folder) → al_game_id`
map plus per-game developer/author/genre facets — the data the app needs for
the new filter dropdowns. `detail` assembles the "AtariLegend details" payload
for one game (game info, genres, developers, authors, releases with boxscans,
screenshots, music, reviews, magazines, videos, facts) including the derived
`atarilegend.com` URLs. `fixtures` writes `detail-<slug>.json` for a fixed set
of known games into `<dir>/fixtures/` as a local diff harness for the app
parser (not committed — AtariLegend data is CC BY-NC-SA 4.0).

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)

The downloaded AtariLegend data is provided by AtariLegend under the
[Creative Commons BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)
license and is **not** redistributed with this repository or the app release.
