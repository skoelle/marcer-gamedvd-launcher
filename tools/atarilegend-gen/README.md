# AtariLegend Importer / Matcher

Downloads the weekly [AtariLegend database dump](https://www.atarilegend.com/data/database-dumps/)
(MariaDB, minus the `users` table) and matches it against the on-disk
Marcer GameDVD screenshot-index folders. This is the first step of the
desktop-app integration: measure and prepare a title join between the
archive and AtariLegend metadata.

The dump is parsed with the Python standard library only — no extra
dependencies. The tool never writes into the game trees; output goes to
`MARCER_ATARILEGEND_DIR`.

## Requirements

- Python 3 with the repo `.venv`
- Environment in `local/paths.env` (git-ignored):
  - `MARCER_ATARILEGEND_DIR` (dump cache + reports + later the artifact)
  - `MARCER_OUT_DIR` (screenshot index: `index.json`, `index-pd.json`,
    `index-utils.json`)

## Usage

```bash
tools/atarilegend-gen/run.sh fetch                 # download the newest YYYY-MM-DD.sql.gz
tools/atarilegend-gen/run.sh report                # row inventory of relevant tables
tools/atarilegend-gen/run.sh match                 # match against the screenshot index
tools/atarilegend-gen/run.sh match --section cracked
tools/atarilegend-gen/run.sh match --dump /path/to/dump.sql.gz --json /tmp/report.json
```

`fetch` resolves the latest dump date from the directory listing and caches
it under `MARCER_ATARILEGEND_DIR/dump/`. `match` reads the newest cached dump,
parses only the needed tables, builds the AtariLegend name index
(`games.name` + `game_akas` + `game_releases.name` + `game_release_akas`),
and matches every folder of the screenshot index in stages:

1. **exact** — normalized key equality (casefold, punctuation, article
   inversion `Tale, A` → `tale`, articles stripped)
2. **prefix** — one normalized key is a word-prefix of the other
   (e.g. `1943` ↔ `1943 the battle of midway`), longest wins
3. **fuzzy** — `difflib` ratio ≥ `fuzzy_cutoff` inside a blocking bucket

Results are written to `MARCER_ATARILEGEND_DIR/atarilegend-match.json` and
`.txt` (per-section statistics, `(kind, letter, folder) → al_game_id` map,
unmatched and ambiguous folders).

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)

The downloaded AtariLegend data is provided by AtariLegend under the
[Creative Commons BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)
license and is **not** redistributed with this repository or the app release.
