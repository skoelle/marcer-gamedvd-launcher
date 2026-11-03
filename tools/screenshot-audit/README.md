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

# Find error/no_usable entries and retry with TOS/memory options
tools/screenshot-audit/run.sh retry

# Preview the retry plan
tools/screenshot-audit/run.sh retry --dry-run

# Retry only a small sample per cluster (recommended for huge clusters)
tools/screenshot-audit/run.sh retry --sample 2 --jobs 6

# Apply reviewed valid clusters (done/game or done/textscreen)
tools/screenshot-audit/run.sh apply --action valid --dry-run
tools/screenshot-audit/run.sh apply --action valid

# Mark all reviewed no_usable clusters (including desktop entries)
tools/screenshot-audit/run.sh apply --action no_usable --dry-run
tools/screenshot-audit/run.sh apply --action no_usable
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
| `--limit N` | max entries per cluster group |
| `--sample N` | retry only the first N entries per cluster group |
| `--memsize VALUE` | memory fallback when the registry has no `memsize` list (`0` = 512 KiB) |
| `--dry-run` | print targets, change nothing |
| `--no-click` | skip the `retry-desktop` click pass |
| `--include-no-usable` | also retry entries already marked `no_usable_shots` (default: skip) |

Options (`apply`):

| Option | Meaning |
|---|---|
| `--action LIST` | registry action(s) to apply, comma-separated; default `no_usable` |
| `--dry-run` | show counts and sample paths, change nothing |

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
- `no_usable` — reviewed bad/blank/desktop screen; optional `try` retries,
  then `apply` marks the remaining matches as `no_usable_shots`.
- `valid` — cracktro/menu or otherwise desired shared screen. Optional
  `status`/`kind` make `apply --action valid` set the desired state for every
  matching entry (including `desktop`/`no_usable`).
- unclassified clusters appear in the report for manual review.

`retry`/`apply` use exact pHash matching by default (`--registry-distance 0`);
`scan` still uses distance 2 to group re-encoded variants.

Example valid state:

```json
"b939393939393931": {
  "label": "Aura textscreen",
  "action": "valid",
  "status": "done",
  "kind": "textscreen"
}
```

Example with retry options:

```json
"ffbf9c9c9c888088": {
  "label": "Mono GEM desktop after failed start",
  "action": "no_usable",
  "try": {
    "tos": ["1.02", "1.00"],
    "memsize": ["0"],
    "retry_any": true
  }
}
```

`memsize: ["0"]` is 512 KiB. `no_drive_b: true` omits `--disk-b` and passes
`--drive-b off`. `retry_any: true` lets `retry-desktop`/`retry-desktop-auto`
process `done` entries too (not only `desktop`).

Additional `try` fields:

- `monitor`: list of `mono`/`color` overrides
- `tos_res`: list of `low`/`med`/`high`
- `press_keys`: list of xdotool keys (`space`, `Return`, …)
- `auto_program_indexes`: alternative program candidates for auto retry
- `modes`: subset of `plain`, `auto`, `click` (default all three)

## Retry behaviour

For every entry whose current preview matches an `error` or `no_usable`
screen with `try` options:

1. `run --force [--memsize N] [--no-drive-b]`
2. `run --retry-desktop-auto --retry-any --force ...`
3. `run --retry-desktop --retry-any --force ...` (when `xdotool` exists)
4. Repeat for each TOS/memory combination
5. Mark remaining entries as `no_usable_shots` (preview kept)

A real `done` result with a different preview stops the chain. A plain
desktop does **not** stop it; after all attempts the cluster is marked
`no_usable_shots`. `apply` is the bulk step for reviewed clusters without a
successful retry.

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
