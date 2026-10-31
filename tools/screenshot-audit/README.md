# screenshot-audit

Read-only audit for screenshot indexes, plus a targeted retry for known error
screens.

The audit reads `index*.json` and the per-entry sidecar JSON files written by
`tools/screenshot-gen`. It clusters the **preview pHash** across entries and
reports screens that appear in unrelated game folders. Cracktros and loader
menus are valid previews and are whitelisted; TOS/GEMDOS error dialogs are
flagged and can be retried.

## Requirements

- Python 3.12 with the repo `.venv` (`Pillow`, `imagehash`, `numpy`, `scipy`)
- `MARCER_OUT_DIR` in `local/paths.env`
- `MARCER_TOS102_IMG` and `MARCER_TOS100_IMG` for `retry`
- `xdotool` for the optional click retry

TOS 1.00 is downloaded from the same source as the desktop app
(`https://www.atariworld.org/files/images/tos100uk.zip`) and stored as
`local/TOS100.IMG` (`MARCER_TOS100_IMG`).

## Usage

```sh
# Full audit of all sections
tools/screenshot-audit/run.sh scan

# One section only
tools/screenshot-audit/run.sh scan --section pd

# Find error-screen entries and retry them with TOS 1.02 -> 1.00
tools/screenshot-audit/run.sh retry

# Preview the retry plan
tools/screenshot-audit/run.sh retry --dry-run
```

Options (`scan`):

| Option | Meaning |
|---|---|
| `--section NAME` | limit to `cracked`, `pd`, `utils`, `magazine`, `falcon` (repeatable) |
| `--min-folders N` | report unclassified shared screens only from N game folders (default 3) |
| `--phash-distance N` | near-cluster distance (0 = exact, max 3; default 0) |
| `--limit-clusters N` | clusters embedded in the report (default 50) |
| `--registry FILE` | screen classification registry (default `screens.json`) |
| `--workers N` | parallel preview analysis (default 8) |

Options (`retry`):

| Option | Meaning |
|---|---|
| `--tos LIST` | TOS retry order (default `1.02,1.00`) |
| `--jobs N` | parallel Hatari jobs (default 4) |
| `--limit N` | max entries per section |
| `--dry-run` | print targets, change nothing |
| `--no-click` | skip the `retry-desktop` click pass |
| `--include-no-usable` | also retry entries already marked `no_usable_shots` (default: skip) |

## Registry

`tools/screenshot-audit/screens.json` maps pHashes to a reviewed decision:

```json
{
  "screens": {
    "cdc93236cdc93236": {
      "label": "Error while loading [Invalid argument]",
      "action": "error",
      "notes": "retry TOS 1.02 then 1.00"
    },
    "949c2b9c3b62e52b": {
      "label": "LAPD bootsector cracktro",
      "action": "valid"
    }
  }
}
```

- `error` — known bad screen; `retry` recaptures these entries.
- `valid` — cracktro/menu or otherwise desired shared screen; ignored.
- unclassified clusters appear in the report for manual review.

The registry matching uses a small pHash distance (`--registry-distance`,
default 2), so a re-encoded screenshot still matches.

## Retry behaviour

For every entry whose current preview matches an `error` screen:

1. `run --force --tos 1.02`
2. `run --retry-desktop-auto --force --tos 1.02`
3. `run --retry-desktop --force --tos 1.02` (when `xdotool` exists)
4. Repeat with TOS 1.00 for entries that are still error, blank, desktop or
   `no_usable_shots`
5. Mark remaining entries as `no_usable_shots` (preview kept)

A real `done` preview stops the chain. A plain desktop does **not** stop it,
because the goal is a usable game/cracktro screenshot.

## Output

Reports go to `local/screenshot-audit/<timestamp>/` (git-ignored):

- `audit.json` — summary, clusters, flagged entries
- `worklist.csv` — flagged entries
- `report.html` — summary, cluster tables, embedded contact sheets
- `contact-sheets/*.png` — visual review sheets for error/review clusters
- retry runs also store the per-section `--only-file` target lists

## Tests

```sh
.venv/bin/python -m unittest discover -s tools/screenshot-audit/tests -v
```

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
