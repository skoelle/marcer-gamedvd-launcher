# Crew Analysis — Top Crews in the Cracked Section

Analysis of the `Crew Sorted` tree and the screenshot index joined with the
gameinfo metadata (`games-cracked.json`). The goal is a **crew view** for the cracked
section: which crews and scene groups have the most release ZIPs, analogous to
the catalog sections `games`, `pd`, `utils`, `magazines` and `falcon`.

Tool: [`tools/crew-analysis`](../tools/crew-analysis/README.md). It is
read-only towards the game trees and the normal `games-*.json`; it writes the
derived `crews.json`/`crew-images.json` into `GameinfoDirectory` and audit files
into `local/crew-analysis/`.

## Data sources

| Source | Role |
|---|---|
| `Crew Sorted/Cracked Games - Crew Sorted` | canonical group names, exact ZIP basename → crew mapping |
| `index.json` (screenshot archive) | ZIP universe (required; direct Disk-1 release layer, `skipped_disk_n` excluded) |
| `games-cracked.json` | `crew` / `cracked_by` per game folder and variant |

`Crew Sorted` alone is **not complete**: it contains 9,963 ZIPs. The
screenshot index contributes **8,938 direct Disk-1 release ZIPs** (10,722 raw
direct entries minus 1,784 `skipped_disk_n` disk-2+ entries). Only 4,856 direct
ZIPs match a Crew Sorted ZIP by exact basename. The remaining releases are
attributed through `games-cracked.json` and alias/fuzzy matching.

## Build the data

The normal game metadata is a prerequisite; this tool does not create it.
The gameinfo files live in `<MARCER_DATA_DIR>/gameinfo/` (`MARCER_DATA_DIR` is
the data directory); `<GameinfoDirectory>` below refers to that gameinfo
subfolder.

```sh
# 1) normal gameinfo -> games-*.json + manifest + unmatched report
tools/gameinfo-gen/run.sh extract

# 2) screenshot index + PNGs (or reuse an existing screenshot archive)
tools/screenshot-gen/run.sh run --scope cracked

# 3) crew data -> <GameinfoDirectory>/crews.json + local/crew-analysis/
tools/crew-analysis/run.sh

# 4) optional: crew card images -> <GameinfoDirectory>/crew-images.json
tools/crew-analysis/run.sh images --top 128 --write-images --force
```

- Step 2 is required for both `ranking` and `images`: the screenshot index is
  the only ZIP source. A missing `index.json` is an error (no filesystem
  fallback).
- `crew-analysis` reads `games-cracked.json`; it never modifies the
  `games-*.json` files.
- Generate screenshots and crew data from the same snapshot. `crews.json`
  stores full ZIP rel paths and `crew-images.json` references PNG
  basenames/paths from the screenshot archive.
- `gameinfo-*.zip` packaging can include the normal metadata plus the optional
  `crews.json`/`crew-images.json` (the app falls back when they are absent).
  The archive packaging/upload itself is outside `tools/asset-manifest`, which
  only publishes the `latest.json` pointer.

## Method

1. **ZIP universe:** direct Disk-1 release ZIPs only, read from
   `index.json` (`Title Sorted/Cracked Games - Title Sorted/<letter>/<folder>/
   <zip>`). Entries with `status: skipped_disk_n` (disk 2+) are excluded;
   subfolders such as `STX`, `Original`, `Demo Version`, `RAW` and `IPF` are
   preservation/extra variants and are excluded by default.
2. **Group registry:** all Crew Sorted folder names are canonical groups. Every
   `crew` and `cracked_by` label from `games-cracked.json` is added; labels not
   already known become their own group (e.g. individual crackers). Placeholders
   such as `Original` and `Unknown` are excluded.
3. **Alias normalization:** explicit aliases from
   [`tools/crew-analysis/aliases.json`](../tools/crew-analysis/aliases.json),
   plus generic rules: leading `The`, region/language suffixes (`- USA`,
   `- French`, …), abbreviation suffixes (`- MCA`, `- TCR`, …), combined-credit
   normalization (`MCA & Hotline` → `Hotline and MCA`) and a strict fuzzy
   fallback for typos.
4. **Attribution (crew view):**
   - exact ZIP basename match against Crew Sorted;
   - otherwise the matching `crew` / `cracked_by` of the folder, with **`crew`
     preferred over `cracked_by`**;
   - otherwise a global alias/fuzzy match over the registry.
5. **Joint credits** such as `Hotline and MCA`, `Replicants/Union` or
   `Lethal / Hotline` stay their own group; they are not split into their
   members.
6. **Audit:** every ZIP records its match source. Unmatched and ambiguous ZIPs
   are written to `unmatched.txt` / `ambiguous.txt`; all gameinfo labels and
   their canonical mapping are written to `groups-review.csv`.

## Runtime artifact and Crews tab

`tools/crew-analysis` writes **`crews.json`** into the `GameinfoDirectory`
(path override: `--crews-out`). It contains every canonical group plus its
per-release list (year, publisher, cracker, crew, disks, flags, TOS notes and
the ZIP rel path); the optional `excluded` flag hides a group from the
desktop Crews tab (selection in `tools/crew-analysis/crew-tab.json`), and
`image`
is reserved for the later cracktro/logo curation phase. `rel` is the **full index path**
(`Title Sorted/Cracked Games - Title Sorted/...`), matching `index.json` and
`GameCard.variants[].rel`; the app also accepts legacy section-relative paths
by prefixing the discovered cracked tree.

The desktop app loads it as part of the catalog bundle:

- a new **`crews`** section/tab (last tab) shows the curated selection
  (currently 128 groups; `kCrewInitialLimit` caps it at 128), searchable by
  crew name, aliases and release titles;
- a crew card prefers a curated image from `crew-images.json`, then the best
  available release screenshot, then a group icon;
- the detail panel lists **all releases** without screenshots, with year,
  publisher, cracker/crew, language, disks, RAW/PASTI/Boxscan, TOS/Bad and the
  ZIP name;
- clicking a release opens the **existing game lightbox** pinned to that
  cracked-game card/ZIP, without leaving the Crews tab;
- **double-clicking a crew card** opens the **crew release browser**: all
  releases as a responsive screenshot grid (up to 4 columns) on the left, the
  normal lightbox `GameInfoPanel` sidebar for the selected ZIP on the right.
  Arrow keys/`PgUp`/`PgDn` move through the releases, `Enter`/double-click on a
  release opens the normal game lightbox, `P`/`Space` launches, `Esc` closes.

The full data for all 886 groups is already in `crews.json`; the tab selection
is controlled by `tools/crew-analysis/crew-tab.json` (`include_until`, `keep`,
`exclude`) and can be expanded up to the 128 cap without a data change.

### Gallery webapp

`tools/gallery` consumes the same `crews.json`/`crew-images.json` artifact as a
read-only **Crews** tab (all groups; `excluded` is ignored there). The gallery joins each
release `rel` back to the cracked screenshot index for preview/status/kind,
shows a release browser with a screenshot grid and compact metadata panel, and
opens the existing game lightbox from a release. It has no launch/play control.
Legacy section-relative release paths are resolved through the cracked tree
prefix, as in the desktop app.

## Cracktro image suggestions

`tools/crew-analysis/run.sh images --top 128` generates a review set of typical
repeated screens per crew. It uses the existing per-ZIP screenshot sidecars
(`shots[].phash`, quality statistics) and the index preview/candidate mapping;
no new capture run is needed.

Ranking:

- clusters pHashes per crew (Hamming distance, default 8);
- prefers screens repeated across many **different games**, then many releases;
- filters the known plain TOS/GEM desktop hash and ranks screens that appear
  across many **other crews** lower (generic screens);
- writes the top 3 candidates per crew.

Outputs in `local/crew-analysis/`: `crew-image-suggestions.json`/`.csv`/`.md`
and a self-contained `crew-image-suggestions.html` contact sheet with the image
files. `--write-images` writes a starter
`<GameinfoDirectory>/crew-images.json` from the top suggestion per crew
(`source: "auto"`); entries should be reviewed/replaced manually. Curated
overrides in `tools/crew-analysis/manual-images.json` (same schema, keyed by
crew name) are merged over the automatic picks, so a later pipeline run does
not silently revert them. Groups in
`tools/crew-analysis/crew-tab.json` are skipped by `images` and hidden by the
app.

`crew-images.json` schema:

```json
{
  "schema": 1,
  "images": {
    "Replicants": {
      "rel": "Title Sorted/Cracked Games - Title Sorted/T/Treasure Trap/...zip",
      "name": "Treasure Trap v1.07 - Replicants.png",
      "source": "auto|manual",
      "note": "review me"
    }
  }
}
```

The app resolves `rel` + `name` against `ScreenshotDirectory`; if the file is
missing, the release-screenshot fallback is used.

### Tab selection (`crew-tab.json`)

`tools/crew-analysis/crew-tab.json` controls which groups the Crews tab shows:

```json
{
  "include_until": "Arthur Dent",
  "keep": [
    "Bavarian Cracking Service - BCS",
    "Overlanders",
    "Rebeliants",
    "ACF",
    "Carebears - TCB",
    "Climax",
    "Fallen Angels",
    "GMC Crackings",
    "Joker",
    "Nasty",
    "RCAP",
    "Awesome",
    "Fairlight",
    "Hobbits Brothers",
    "Invisible",
    "Kopa",
    "Ramsess",
    "Skinhead",
    "Softrunner Group International - SRG",
    "Zuul",
    "Corporation - TMB and PP and SS",
    "DMA",
    "Hemoroids",
    "Hofa",
    "Maartau",
    "No Limit",
    "Replicants / Masters",
    "Sharaz Jek",
    "A-Team",
    "Adrenalin UK",
    "Atari ST Computer Studio",
    "Conceptors",
    "ST Bandits",
    "Tex / Union",
    "Genesis Inc"
  ],
  "exclude": []
}
```

All groups up to `include_until` are visible; after it only the `keep` list is
visible. `exclude` always wins. The tool writes the result as
`"excluded": true/false` in `crews.json`; the desktop app only reads that flag (the gallery ignores it).

## Current result

Generated from the local screenshot index (2026-10-26):

- Direct release ZIPs: **8,938**
- Disk 2+ excluded (`skipped_disk_n`): **1,784**
- Assigned: **8,479**
- Unmatched: **459**
- Ambiguous exact matches: **4**
- Groups with at least one ZIP: **886**
- Match sources: exact 4,856 · gameinfo crew 2,352 · gameinfo cracker 586 ·
  alias/fuzzy 685

### Top 24 (curated core)

| # | Group | ZIPs |
|---:|---|---:|
| 1 | Replicants | 876 |
| 2 | Elite | 820 |
| 3 | Atari Legend | 693 |
| 4 | D-Bug | 365 |
| 5 | Empire | 345 |
| 6 | Blade Runners | 295 |
| 7 | Medway Boys - TMB | 227 |
| 8 | Menacing Cracking Alliance - MCA | 203 |
| 9 | Cynix | 177 |
| 10 | Bust | 165 |
| 11 | International Cracking Service - ICS | 139 |
| 12 | Klapauzius | 131 |
| 13 | Delight | 112 |
| 14 | Atariforce | 96 |
| 15 | Vmax | 94 |
| 16 | Hotline | 93 |
| 17 | Automation | 85 |
| 18 | Pompey Pirates | 79 |
| 19 | Boss | 78 |
| 20 | Hotline and MCA | 76 |
| 21 | Corporation - TCR | 74 |
| 22 | Superior | 68 |
| 23 | TEX - The Exceptions | 60 |
| 24 | Was Not Was | 57 |

The desktop Crews tab currently shows 128 curated groups; the gallery shows all 886 groups. The complete ranking is in
`local/crew-analysis/crew-ranking.csv`, and groups outside the selection are
marked `"excluded": true` in `crews.json`.

`Bust`, `Klapauzius` and `Boss` are individual crackers in the gameinfo data;
they appear because their releases have no separate crew label (the crew view
falls back to `cracked_by`). The next ranks are `Revolution` (55), `42 Crew`
(54), `Bad Brew Crew - BBC` (53) and `Vectronix` (48).

Because this is a **crew view**, individual crackers whose releases are
credited to a crew (for example `Snake`, `CB`, `Cameo` or `Lethal`) do not
appear in the primary ranking. They are still part of the registry and are
visible in `groups-review.csv`; they only become primary when a release has no
matching crew label.

## Caveats

- **Counts are Disk-1 ZIP files, not distinct games.** File versions count
  individually; disk-2+ ZIPs (`skipped_disk_n`) are excluded.
- **Index only:** the tool reads the merged `index.json` ZIP list (root +
  patch) and never scans the filesystem. A stale index can lag behind new ZIPs.
- **Crew Sorted is a hint, not the source of truth.** It supplies canonical
  names and exact matches; the actual release count comes from the screenshot
  index and gameinfo.
- **Alias curation is ongoing.** Labels such as `Empire - USA`, `The Empire`,
  `MCA & Hotline` and `STCS` are normalized automatically or explicitly; new
  gameinfo data can add new labels. Check `groups-review.csv` and extend
  `aliases.json` / `exclude.txt` when needed.
- **Joint releases** remain separate entries by design. A release credited to
  `Hotline and MCA` counts for that combined group, not for `Hotline` and
  `MCA` individually.
- `Crew Sorted` and `Title Sorted` are local data (Marcer's archive); the tool
  does not bundle or redistribute them.

## Reproduce

```sh
tools/crew-analysis/run.sh
tools/crew-analysis/run.sh --top 50
```

Outputs:

- `<GameinfoDirectory>/crews.json` — runtime crew/release artifact consumed by
  the desktop app.
- `<GameinfoDirectory>/crew-images.json` — optional curated cracktro images.
- `local/crew-analysis/` (git-ignored) — `crew-ranking.md`,
  `crew-ranking.csv`, `crew-ranking.json`, `groups-review.csv`,
  `unmatched.txt`, `ambiguous.txt`, `crew-image-suggestions.*` (after
  `images`).

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
