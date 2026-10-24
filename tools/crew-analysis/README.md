# Crew Analysis

Ranks the cracked-game crews and scene groups by the number of direct release
ZIPs. The result is the "crew view" used when looking at the cracked section the
same way the catalog exposes `games`, `pd`, `utils`, `magazines` and `falcon`.

See [`ANALYSIS-crews.md`](../../docs/ANALYSIS-crews.md) for the methodology,
the current tab selection (currently 60 groups) and the data-quality caveats.

## Data sources

| Source | Purpose |
|---|---|
| `<RootDirectory>/Crew Sorted/Cracked Games - Crew Sorted` | canonical group names and exact ZIP basename matches |
| `<RootDirectory>/Title Sorted/Cracked Games - Title Sorted` (+ `PatchDirectory` overlay) | ZIP universe (direct release layer only by default) |
| `<GameinfoDirectory>/games-cracked.json` | `crew` / `cracked_by` metadata per game folder |
| `<ScreenshotDirectory>/index.json` | fast merged ZIP list (used by default; `--scan` reads the filesystem instead) |

## Build order / prerequisites

`crew-analysis` reads the normal game metadata; it does not create it. Run the
pipeline in this order:

```sh
# 1) normal gameinfo (required input)
tools/gameinfo-gen/run.sh extract

# 2) screenshot index + PNGs (or reuse an existing archive)
tools/screenshot-gen/run.sh run --scope cracked

# 3) crew data (writes <GameinfoDirectory>/crews.json)
tools/crew-analysis/run.sh

# 4) optional: crew card images (writes <GameinfoDirectory>/crew-images.json)
tools/crew-analysis/run.sh images --top 128 --write-images --force
```

- Step 2 can be skipped for the ranking by using `--scan` (reads
  `Title Sorted` directly); `images` needs the screenshot index/sidecars.
- `crew-analysis` never writes or modifies `games-*.json`. It only adds
  `crews.json` and `crew-images.json` to `GameinfoDirectory`.
- Generate screenshots and crew data from the same data snapshot:
  `crew-images.json` references PNG basenames/paths from the screenshot
  archive.

## Usage

```sh
tools/crew-analysis/run.sh                    # ranking, top 24
tools/crew-analysis/run.sh --top 50
tools/crew-analysis/run.sh --scan             # ignore index.json, scan Title Sorted on disk
tools/crew-analysis/run.sh --include-subdirs  # include STX/Original/Demo/RAW/... subfolders
tools/crew-analysis/run.sh --out /tmp/crews

# Phase 2: cracktro image suggestions for the top crews
tools/crew-analysis/run.sh images --top 128 --per-crew 3
tools/crew-analysis/run.sh images --top 128 --write-images   # starter crew-images.json
# curated overrides in tools/crew-analysis/manual-images.json are merged
```

Environment (via the repo `local/paths.env`):

- `MARCER_ROOT_DIR` — required; contains `Crew Sorted/` and `Title Sorted/`
- `MARCER_PATCH_DIR` — optional patch layer for the filesystem scan
- `MARCER_DATA_DIR` — required; contains `games-cracked.json`
- `MARCER_OUT_DIR` — optional; contains `index.json` (default ZIP source)

## Output

### `crews.json` (GameinfoDirectory)

The per-crew release list consumed by the desktop app's and gallery webapp's
**Crews** tabs:

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

It contains **all** groups; the UI shows the curated selection (currently 60, cap 128). The
`image` field is reserved for the later cracktro/logo curation phase.
`--crews-out` overrides the path (default `<GameinfoDirectory>/crews.json`).

### `crew-images.json` (GameinfoDirectory)

Curated card image per crew (optional). The `images` command can create a
starter file from its best suggestions (`source: "auto"`); review/replace the
entries manually.

```json
{
  "schema": 1,
  "images": {
    "Replicants": {
      "rel": "Title Sorted/Cracked Games - Title Sorted/T/Treasure Trap/...zip",
      "name": "Treasure Trap v1.07 - Replicants.png",
      "source": "auto",
      "note": "review me"
    }
  }
}
```

`rel` is the full release index path and `name` the image basename below its
screenshot directory. The app prefers this image, then the best release
screenshot, then the group icon.

Manual corrections live in `manual-images.json` (same schema, keyed by crew
name). `images --write-images` merges them over the automatic top suggestions,
so re-running the pipeline never silently replaces a curated pick.

### `local/crew-analysis/`

| File | Contents |
|---|---|
| `crew-ranking.md` | human-readable ranking + summary |
| `crew-ranking.csv` | `rank,group,zips` |
| `crew-ranking.json` | full result incl. counts, sources and configuration |
| `groups-review.csv` | every gameinfo label with its canonical group and mapping status |
| `unmatched.txt` | direct ZIPs that could not be attributed |
| `ambiguous.txt` | ZIPs with an ambiguous exact Crew-Sorted basename |
| `crew-image-suggestions.json` | top cracktro candidates per crew (pHashes, stats) |
| `crew-image-suggestions.csv` | flat suggestion list incl. image paths |
| `crew-image-suggestions.md` | review table |
| `crew-image-suggestions.html` | contact sheet with the candidate images |

## Registry

- `aliases.json` — canonical group names and their aliases.
- `exclude.txt` — labels that are not scene groups (placeholders, region/
  language notes, …).
- `crew-tab.json` — tab selection: `include_until` (visible through this
  group), `keep` (visible after the cutoff), `exclude` (always hidden). The
  group stays in `crews.json` (with `"excluded": true`) and in the ranking
  audit; the app filters it out, and `images` skips it.
- `manual-images.json` — curated crew card images, merged by
  `images --write-images`.

The tool applies the registry plus generic rules (leading `The`, region
descriptors such as `- USA`, combined-credit normalization, abbreviations and a
strict fuzzy fallback). New gameinfo labels become their own canonical groups,
so `groups-review.csv` is the audit trail for curating `aliases.json`.

The `images` command additionally reads the per-ZIP screenshot sidecars
(`shots[].phash`) and clusters repeated screens per crew. A screen that appears
across many **different crews** is treated as generic (TOS/GEM desktop, common
menu) and ranked lower; the plain-desktop hash is filtered outright.

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
