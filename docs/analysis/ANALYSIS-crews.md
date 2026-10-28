# ANALYSIS: Crews in the Cracked Section

Analysis of the `Crew Sorted` tree joined with the screenshot-independent
`full-index.json.gz` and the gameinfo metadata (`games-cracked.json`). The result is a **crew view** for the
cracked section: which crews and scene groups have the most release ZIPs,
analogous to the catalog sections `games`, `pd`, `utils`, `magazines` and
`falcon`. The runtime artifacts are consumed by the desktop app
([`SPEC-desktop.md`](../specs/SPEC-desktop.md)) and the gallery
([`SPEC-gallery-webapp.md`](../specs/SPEC-gallery-webapp.md)).

Tool: [`tools/crew-analysis`](../../tools/crew-analysis/README.md). It is
read-only towards the game trees and the normal `games-*.json`; it writes the
derived `crews.json`/`crew-images.json` into `GameinfoDirectory` and audit files
into `local/crew-analysis/`.

## Data sources

| Source | Role |
|---|---|
| `Crew Sorted/Cracked Games - Crew Sorted` | canonical group names, exact ZIP basename → crew mapping |
| `full-index.json.gz` (gameinfo) | ZIP universe (preferred; direct Disk-1 release layer, disk-2+ excluded from the filename). Built by `tools/full-index-gen` |
| `index.json` (screenshot archive) | legacy fallback when the full index is missing |
| `games-cracked.json` | `crew` / `cracked_by` per game folder and variant |

`Crew Sorted` alone is incomplete; the full index supplies the release ZIPs,
and the remaining releases are attributed through `games-cracked.json` plus
alias/fuzzy matching.

## Build order

The normal game metadata and the full index are prerequisites:

```sh
tools/gameinfo-gen/run.sh extract
tools/full-index-gen/run.sh run
tools/crew-analysis/run.sh
# optional, after screenshots exist on the dev machine:
tools/screenshot-gen/run.sh run --scope cracked
tools/crew-analysis/run.sh images --top 128 --write-images --force
```

- The full index is the ZIP source for `ranking`; a missing
  `full-index.json.gz` falls back to `index.json` (legacy).
- `images` still needs the screenshot index.
- `crew-analysis` reads `games-cracked.json` but never modifies it.
- Generate screenshots and crew data from the same snapshot: `crews.json`
  stores full ZIP rel paths and `crew-images.json` references PNG basenames/
  paths from the screenshot archive.
- `gameinfo-*.zip` packaging may include `crews.json`/`crew-images.json`; the
  apps fall back when they are absent.

## Method

1. **ZIP universe:** direct Disk-1 release ZIPs from `index.json`
   (`Title Sorted/Cracked Games - Title Sorted/<letter>/<folder>/<zip>`).
   `status: skipped_disk_n` (disk 2+) and subfolder variants (`STX`,
   `Original`, `Demo Version`, `RAW`, `IPF`) are excluded.
2. **Group registry:** all Crew Sorted folder names are canonical groups. Every
   `crew` and `cracked_by` label from `games-cracked.json` is added; unknown
   labels become their own group. Placeholders such as `Original`/`Unknown` are
   excluded.
3. **Alias normalization:** explicit aliases from
   [`tools/crew-analysis/aliases.json`](../../tools/crew-analysis/aliases.json)
   plus generic rules: leading `The`, region/language suffixes (`- USA`,
   `- French`, …), abbreviation suffixes (`- MCA`, `- TCR`, …), combined-credit
   normalization (`MCA & Hotline` → `Hotline and MCA`) and a strict fuzzy
   fallback for typos.
4. **Attribution (crew view):**
   - exact ZIP basename match against Crew Sorted;
   - otherwise the folder's `crew`/`cracked_by`, with **`crew` preferred over
     `cracked_by`**;
   - otherwise a global alias/fuzzy match over the registry.
5. **Joint credits** such as `Hotline and MCA`, `Replicants/Union` or
   `Lethal / Hotline` stay their own group; they are not split into members.
6. **Audit:** every ZIP records its match source; unmatched/ambiguous ZIPs go
   to `unmatched.txt`/`ambiguous.txt`, all labels and their mapping to
   `groups-review.csv`.

## Runtime artifacts

`crews.json` contains every canonical group plus its per-release list (year,
publisher, cracker, crew, disks, flags, TOS notes and the ZIP rel path). The
optional `excluded` flag hides a group from the desktop Crews tab (selection in
`tools/crew-analysis/crew-tab.json`); `image` is reserved for cracktro/logo
curation. `rel` is the full index path, matching `index.json` and
`GameCard.variants[].rel`; legacy section-relative paths are accepted by
prefixing the discovered cracked tree.

`crew-tab.json` controls the selection: all groups up to `include_until` are
visible, after it only the `keep` list, and `exclude` always wins. The tool
writes the result as `"excluded": true/false` in `crews.json`; the desktop app
reads that flag, the gallery ignores it.

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

## Cracktro image suggestions

`tools/crew-analysis/run.sh images --top 128` generates a review set of typical
repeated screens per crew from the existing per-ZIP screenshot sidecars
(`shots[].phash`, quality statistics); no new capture run is needed.

- Cluster pHashes per crew (Hamming distance, default 8).
- Prefer screens repeated across many **different games**, then many releases.
- Filter the known plain TOS/GEM desktop hash and rank screens that appear
  across many **other crews** lower (generic screens).
- Write the top 3 candidates per crew to `local/crew-analysis/` (JSON/CSV/MD +
  self-contained HTML contact sheet).
- `--write-images` writes a starter `<GameinfoDirectory>/crew-images.json`
  (`source: "auto"`); review/replace manually. Curated overrides in
  `tools/crew-analysis/manual-images.json` are merged over the automatic picks,
  so a pipeline run does not revert them.

## Caveats

- **Counts are Disk-1 ZIP files, not distinct games.** File versions count
  individually; disk-2+ ZIPs are excluded.
- **Index only:** the full index (root + patch) is read; a stale full index
  can lag behind new ZIPs until `full-index-gen` runs.
- **Crew Sorted is a hint, not the source of truth.** It supplies canonical
  names and exact matches; the release count comes from the full index and
  gameinfo.
- **Alias curation is ongoing.** New gameinfo data can add labels; check
  `groups-review.csv` and extend `aliases.json`/`exclude.txt`.
- **Joint releases** remain separate entries by design.
- `Crew Sorted` and `Title Sorted` are local archive data; the tool does not
  bundle or redistribute them.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
