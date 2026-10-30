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
   labels become their own group. Canonical names listed in `aliases.json` are
   added as well, so a group missing from both sources can be introduced
   explicitly (e.g. `SuperGAU`). Placeholders such as `Original`/`Unknown` are
   excluded.
3. **Alias normalization:** explicit aliases from
   [`tools/crew-analysis/aliases.json`](../../tools/crew-analysis/aliases.json)
   plus generic rules: leading `The`, region/language suffixes (`- USA`,
   `- French`, …), abbreviation suffixes (`- MCA`, `- TCR`, …), combined-credit
   normalization (`MCA & Hotline` → `Hotline and MCA`) and a strict fuzzy
   fallback for typos. Canonical spellings follow the `Crew Sorted` folder
   names; curated abbreviations and typo variants (`SFX` → `Special FX`,
   `Klapauziuz` → `Klapauzius`, `Bergerdorf Atari Clan` →
   `Bergerdor Atari Clan - BAC`) are part of the registry. Release-code
   prefixes (`dbug###`, `SERE##`, `GFOR##`, `FOFT##`, `SFX###`, `auto###`, …)
   are matched against group names/aliases in the second pass (exact compact
   name, unique compact prefix, initials); ambiguous codes stay in
   `unmatched.txt` for review.
4. **Attribution (crew view):**
   - exact ZIP basename match against Crew Sorted; if that fails, retry after
     stripping trailing dump markers (`BAD`, `Cracked`, `Unknown`, `Demo`,
     `Tr`, `Disk N`, …) **only while a credit segment remains** (so a bare
     game title is never matched);
   - otherwise the folder's `crew`/`cracked_by`, with **`crew` preferred over
     `cracked_by`**;
   - otherwise a global alias/fuzzy match over the registry. Single-token
     abbreviation aliases only count in the credit suffix, never in the game
     title.
   The per-release `cracked_by`/`crew` shown in the crew view come from the XLS
   variant that matches the group label, else from the variant whose label
   tokens match the ZIP filename. When several variants exist and none can be
   identified, both fields stay empty instead of inheriting the first
   (often `Original`) variant.
5. **Second pass (label inference):** for releases with an empty/placeholder
   label, the game title is stripped from the ZIP filename and the remaining
   credit suffix is matched against (a) the assigned group's name/aliases,
   (b) cracker/crew labels already seen in that group's releases (only for
   groups with ≥ 2 ZIPs) and (c) the group registry (unique crew/cracker names
   in the credit). Filled fields are marked `inferred_fields` and written to
   `crews.json`; `label-inference.csv` keeps the evidence. XLS placeholders
   (`Original`, `Unknown`, `????`, `No 1 & No 2`) are always treated as empty.
6. **Unmatched ZIPs:** unique group-name matches, release-code prefixes
   (`dbug###` → D-Bug, `SERE##` → Serenade, …) and compact contiguous names
   (`Dead Eye` → Deadeye) in the credit suffix are assigned with
   `source: "inferred_name"`; all candidates (including medium/ambiguous) are
   written to `inferred-matches.csv` for review. Unknown names are only
   proposed in `new-groups-review.csv` (never auto-created).
7. **Joint credits** such as `Hotline and MCA`, `Replicants/Union` or
   `Lethal / Hotline` stay their own group; they are not split into members.
8. **Audit:** every ZIP records its match source; unmatched/ambiguous ZIPs go
   to `unmatched.txt`/`ambiguous.txt`, all labels and their mapping to
   `groups-review.csv`.

## Runtime artifacts

`crews.json` contains every canonical group plus its per-release list (year,
publisher, cracker, crew, disks, flags, TOS notes and the ZIP rel path).
`inferred_fields` lists labels completed from the ZIP name by the second pass;
the apps mark those values as `inferred`. Its
top-level `source` block uses logical names only (`crew_tree`,
`games-cracked.json`, `full-index.json.gz`/`index.json`, `crews.json`); absolute
local paths stay in the git-ignored `local/crew-analysis/` audits. The
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

## Audit files and review status

The git-ignored `local/crew-analysis/` directory holds the review artifacts;
`crews.json`/`crew-images.json` in the gameinfo directory are the published
outputs. `groups-review.csv` is a **label audit**, not a release report:

- `xls_variant_rows` counts XLS variant rows; `release_zips` counts the final
  release ZIPs in `crews.json` carrying that label.
- `canonical_group` is the label's group mapping, not the crew group of its
  releases.
- `alias_status=new` means the label is not registered in the Crew
  Sorted/`aliases.json` registry yet; it does not require a new group.

Review decisions for the 2026-10-30 run (TNT/SJ follow-up):

- `inferred-matches.csv`: the applied rows were manually checked and accepted.
  The current run has **22 `applied=yes`** matches; `First Samurai … - BAD`
  moved to an exact Crew Sorted match. The remaining 430 candidates (419
  ambiguous, 11 medium) intentionally stay unmatched.
- `new-groups-review.csv`: all **112** candidates were reviewed; **none**
  becomes a new group.
- The exact Crew Sorted fallback now strips trailing markers only while a
  credit segment remains (`TNT - SJ Crew - BAD` → SJ Crew). `TNT` is an alias
  of **TNT Crew**; title-only abbreviation matches (`Ice`, `Me`) no longer
  create false group assignments.
- Current counts: **885 groups, 8.508 releases, 430 unmatched**.
- `alias-review.csv` is a legacy leftover and is not generated by the current
  tool.
- `crew-image-suggestions.*` come from the separate `images` command and can
  be older than the ranking run.

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
