# PirateFinder Catalogue Import

Fetches the weekly [PirateFinder](https://github.com/peteclarke-del/PirateFinder)
catalogue release, verifies its SHA-256, extracts the Atari ST subset into
compact JSON and matches the Marcer cracked-game ZIPs against it.

The catalogue is a read-only SQLite database licensed **CC BY-NC-SA 4.0**
(because it includes Atari Legend data). This tool keeps it and every derived
file in `MARCER_PIRATEFINDER_DIR` (default `local/piratefinder/`, git-ignored)
and **never** redistributes it. Nothing is written to the game trees, the
screenshot/gameinfo artifacts or the repository.

See [`docs/ANALYSIS-piratefinder.md`](../../docs/ANALYSIS-piratefinder.md) for
the findings and measured results.

## Requirements

- Python 3.12 (the repo `.venv`; only the standard library is used)
- `local/paths.env` for the match step:
  - `MARCER_ROOT_DIR` (required for `--scan`, optional for `--index`)
  - `MARCER_PATCH_DIR` (optional overlay)
  - `MARCER_OUT_DIR` (contains `index.json`, default match input)
  - `MARCER_DATA_DIR` (contains `games-cracked.json`)
  - `MARCER_PIRATEFINDER_DIR` (optional output override)

## Usage

```sh
tools/piratefinder-gen/run.sh fetch                 # newest catalogue-* release
tools/piratefinder-gen/run.sh fetch --tag catalogue-2026-10-19
tools/piratefinder-gen/run.sh extract
tools/piratefinder-gen/run.sh match --limit 200     # trial run
tools/piratefinder-gen/run.sh match                 # all direct release ZIPs
tools/piratefinder-gen/run.sh report                # regenerate reports
```

`match` uses the screenshot index (`index.json`) by default, just like
`tools/crew-analysis`. Use `--scan` to walk `MARCER_ROOT_DIR` instead, and
`--include-subdirs` to include `STX`/`Original`/`Demo`/`RAW`/… variants.

## How matching works

1. **Hash (exact).** Every `.msa`/`.st`/`.stx` member of a ZIP is decoded and
   hashed. `.msa` is unpacked to raw sectors with the same rules as
   PirateFinder's decoder; `.st` is hashed as-is; `.stx` is hashed as a file.
   Hashes are looked up in the catalogue's `images` table by SHA-1, MD5,
   SHA-512 and CRC32 + size.
2. **Title fallback (likely).** ZIPs without a matching image (for example
   `.prg` releases, protected `.stx`, or a different dump) are matched by
   normalised title against PirateFinder's single-disk rows, narrowed by the
   gameinfo `crew`/`cracked_by`, release year and publisher.

A hash match is reported as `exact`; a title match as `likely`. If several
single disks share a title and the metadata cannot choose one, the ZIP goes
to `ambiguous.txt` together with the candidates.

## Output

```
<MARCER_PIRATEFINDER_DIR>/
  raw/       catalogue-layoutN.sqlite.gz/.sqlite, .sha256, groups.toml, source.json
  index/     meta.json, disks-st.json, images-st.json, crews-st.json,
             contents-by-title.json, series-aliases.json, groups.json
  matches/   matches.json, matches.csv, unmatched.txt, ambiguous.txt, missing.txt
  report/    report.md, crew-coverage.csv, alias-candidates.csv, gameinfo-gaps.csv
```

`matches.json` is the reusable artifact: one entry per ZIP with status,
method, matched disk (label, year, publisher, crew, cracker, contents,
virus flags) and menu-disk appearances. `report/` is the human-readable
analysis.

## Licence / attribution

The source code of this tool is MIT. The catalogue data remains
**CC BY-NC-SA 4.0**, © the PirateFinder contributors and Atari Legend; the
`meta` table and the release notes carry the exact source list and terms.
Reports and logs credit the source. Do not commit or publish the raw database
or derived index files.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
