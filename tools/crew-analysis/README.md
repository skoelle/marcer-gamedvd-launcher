# Crew Analysis

Ranks the cracked-game crews and scene groups by the number of direct release
ZIPs. The result is the "crew view" used when looking at the cracked section the
same way the catalog exposes `games`, `pd`, `utils`, `magazines` and `falcon`.

See [`ANALYSIS-crews.md`](../../docs/ANALYSIS-crews.md) for the methodology,
the current top 24 and the data-quality caveats.

## Data sources

| Source | Purpose |
|---|---|
| `<RootDirectory>/Crew Sorted/Cracked Games - Crew Sorted` | canonical group names and exact ZIP basename matches |
| `<RootDirectory>/Title Sorted/Cracked Games - Title Sorted` (+ `PatchDirectory` overlay) | ZIP universe (direct release layer only by default) |
| `<GameinfoDirectory>/games-cracked.json` | `crew` / `cracked_by` metadata per game folder |
| `<ScreenshotDirectory>/index.json` | fast merged ZIP list (used by default; `--scan` reads the filesystem instead) |

## Usage

```sh
tools/crew-analysis/run.sh                    # top 24, writes local/crew-analysis/
tools/crew-analysis/run.sh --top 50
tools/crew-analysis/run.sh --scan             # ignore index.json, scan Title Sorted on disk
tools/crew-analysis/run.sh --include-subdirs  # include STX/Original/Demo/RAW/... subfolders
tools/crew-analysis/run.sh --out /tmp/crews
```

Environment (via the repo `local/paths.env`):

- `MARCER_ROOT_DIR` — required; contains `Crew Sorted/` and `Title Sorted/`
- `MARCER_PATCH_DIR` — optional patch layer for the filesystem scan
- `MARCER_DATA_DIR` — required; contains `games-cracked.json`
- `MARCER_OUT_DIR` — optional; contains `index.json` (default ZIP source)

## Output

### `crews.json` (GameinfoDirectory)

The per-crew release list consumed by the desktop app's **Crews** tab:

```json
{
  "schema": 1,
  "generated_at": "…",
  "groups": [
    {
      "id": "replicants",
      "name": "Replicants",
      "kind": "crew",
      "rank": 1,
      "zips": 1129,
      "aliases": ["Replicants"],
      "image": null,
      "releases": [
        {
          "rel": "Title Sorted/Cracked Games - Title Sorted/R/R-Type/R-Type - Replicants.zip",
          "letter": "R", "folder": "R-Type", "zip": "…",
          "title": "R-Type", "year": "1988",
          "publisher": "…", "cracked_by": "…", "crew": "Replicants",
          "language": "English", "disks": 1,
          "raw_dump": false, "pasti_dump": false, "boxscan": false,
          "tos_bad": "", "special_flag": "", "special_note": "",
          "source": "exact", "ambiguous": false
        }
      ]
    }
  ]
}
```

It contains **all** groups (the UI starts with the top 24 cards). The
`image` field is reserved for the later cracktro/logo curation phase.
`--crews-out` overrides the path (default `<GameinfoDirectory>/crews.json`).

### `local/crew-analysis/`

| File | Contents |
|---|---|
| `crew-ranking.md` | human-readable ranking + summary |
| `crew-ranking.csv` | `rank,group,zips` |
| `crew-ranking.json` | full result incl. counts, sources and configuration |
| `groups-review.csv` | every gameinfo label with its canonical group and mapping status |
| `unmatched.txt` | direct ZIPs that could not be attributed |
| `ambiguous.txt` | ZIPs with an ambiguous exact Crew-Sorted basename |

## Registry

- `aliases.json` — canonical group names and their aliases.
- `exclude.txt` — labels that are not scene groups (placeholders, region/
  language notes, …).

The tool applies the registry plus generic rules (leading `The`, region
descriptors such as `- USA`, combined-credit normalization, abbreviations and a
strict fuzzy fallback). New gameinfo labels become their own canonical groups,
so `groups-review.csv` is the audit trail for curating `aliases.json`.

## Rules

- Only **direct release ZIPs** are counted by default; `STX`, `Original`,
  `Demo`, `RAW`, `IPF`, … subfolders are preservation/extra variants.
- The **crew view prefers `crew` over `cracked_by`**. An individual cracker is
  only the primary group when the release has no matching crew label. Crackers
  whose releases are credited to a crew (e.g. `Snake`, `CB`, `Cameo`) therefore
  do not appear in the primary top list; they remain in `groups-review.csv`.
- Joint credits such as `Hotline and MCA` stay separate groups; they are not
  split into their members.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
