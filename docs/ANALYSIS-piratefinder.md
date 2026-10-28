# ANALYSIS: Pete Clarke Greaseweazle PirateFinder Catalog

Analysis of the [Pete Clarke Greaseweazle PirateFinder Catalog](https://github.com/peteclarke-del/PirateFinder)
catalogue and how its Atari ST data can be used for the Marcer GameDVD
project. The implementation is the read-only tool
[`tools/piratefinder-gen`](../tools/piratefinder-gen/README.md).

**Status of verified facts:** everything in sections 2–6 was measured on
2026-10-24 against the real Marcer trees and the PirateFinder-Catalog release
`catalogue-2026-10-19` (schema/layout 3). Paths come from the git-ignored
`local/paths.env`; the catalogue is kept in `MARCER_PIRATEFINDER_DIR`
(default `local/piratefinder/`).

**Licence:** the PirateFinder-Catalog is **CC BY-NC-SA 4.0**, because it
includes Atari Legend data under that licence. The tool does not redistribute
the database or derived index files; it fetches the release from
PirateFinder-Catalog's GitHub releases and keeps everything local. The raw SQLite is
not committed and must not be published with the Marcer artifacts.

---

## 1. What the catalogue is

- A read-only **SQLite** database, published weekly as a GitHub release tagged
  `catalogue-YYYY-MM-DD`.
- Asset: `catalogue-layout3.sqlite.gz`, 88.5 MB compressed, 313.6 MB
  uncompressed at the time of measurement.
- Schema version 3; `meta` carries the build date, builder version, source
  status and the licence.
- It covers Amiga and Atari ST menu disks, compacts, packs, compilations and
  single cracks, with disk contents, TOSEC hashes, virus flags, download
  locations, pictures/trivia and crew histories.

Relevant tables:

| Table | Contents |
|---|---|
| `disks` | One row per disk/part/version: label, series, year/month/day, publisher, cracker, crew, kind |
| `contents` | What is on each disk, in menu order |
| `images` | Known dumps with CRC32/MD5/SHA-1/SHA-512, size, rank, TOSEC flags, virus fields |
| `crews` | Crew histories, members, founding date, URL, Wikipedia article |
| `series`, `series_alias` | Series and their short names |
| `locations`, `media`, `trivia` | Not used in this phase |

The ST subset extracted by the tool:

| Metric | Count |
|---|---:|
| ST disks | 23,782 |
| — menu | 10,684 |
| — pack | 4,088 |
| — single | 8,769 |
| — compilation | 241 |
| ST images | 28,650 |
| ST contents rows | 48,256 |
| ST crews (with history) | 532 |
| Distinct ST content titles indexed for “also on …” | 13,929 |

## 2. How it is used

`tools/piratefinder-gen` has four commands:

```sh
tools/piratefinder-gen/run.sh fetch     # newest catalogue-* release + SHA-256
tools/piratefinder-gen/run.sh extract   # ST subset -> compact JSON
tools/piratefinder-gen/run.sh match     # Marcer cracked ZIPs vs. catalogue
tools/piratefinder-gen/run.sh report    # regenerate the reports
```

### Matching

The universe follows the same direct-release rule as `tools/crew-analysis`:
direct release ZIPs under `Title Sorted/Cracked Games - Title Sorted` (10,722
in the current tree, including disk-2+ ZIPs; `crew-analysis` additionally
excludes `skipped_disk_n`). It is read from `index.json` by default or from disk
with `--scan`.

1. **Hash (exact).** Every `.msa`/`.st`/`.stx` member of a ZIP is decoded and
   hashed. MSA is unpacked to raw sectors with the same rules as
   PirateFinder-Catalog's vendored decoder; `.st` is hashed as-is; `.stx` is hashed as
   a file. Lookup order is SHA-1, MD5, SHA-512, then CRC32 + size.
2. **Title (likely).** ZIPs with no hash match are matched by a normalised
   title against PirateFinder-Catalog's single-disk rows. The ZIP stem’s cracker part
   (“Game - Cracker”), part number (“Disk 2”), gameinfo crew/cracker labels,
   year and publisher narrow the candidates. A short local title may match a
   longer catalogue title as a prefix (“Ween” → “Ween - The Prophecy”).

Results are `exact` (hash) or `likely` (title). If several catalogue disks
remain and the metadata cannot choose one, the ZIP is reported as
**ambiguous** with its candidates instead of guessing.

### Output

```
<MARCER_PIRATEFINDER_DIR>/
  raw/       catalogue-layout3.sqlite.gz/.sqlite, .sha256, groups.toml, source.json
  index/     meta.json, disks-st.json, images-st.json, crews-st.json,
             contents-by-title.json, series-aliases.json, groups.json
  matches/   matches.json, matches.csv, unmatched.txt, ambiguous.txt, missing.txt
  report/    report.md, crew-coverage.csv, alias-candidates.csv, gameinfo-gaps.csv
```

## 3. Measured results

Source: release `catalogue-2026-10-19`, universe 10,722 direct cracked ZIPs.

| Result | ZIPs | Share |
|---|---:|---:|
| ZIPs with a recognised image member | 10,623 | 99.1 % |
| **Matched (total)** | **7,124** | **66.4 %** |
| — by hash | 4,627 | 43.2 % |
| — by title fallback | 2,497 | 23.3 % |
| Unmatched | 1,735 | 16.2 % |
| Ambiguous (candidates listed) | 1,862 | 17.4 % |
| Missing file in both layers | 1 | <0.1 % |
| Matched with menu-disk appearances | 5,065 | 71.1 % of matches |

Hash methods: SHA-1 4,596, SHA-512 31. No CRC32/MD5-only match occurred in
this run. The hash rate is limited by catalogue coverage and by dumps that
differ from the TOSEC/Atari Legend entries; it is not a decoder failure
(99.1 % of ZIPs decoded).

### Crew data

- `crew-coverage.csv`: 1,440 distinct Marcer crew/cracker labels from
  `games-cracked.json`; 376 are covered exactly or through a PirateFinder-Catalog
  alias/abbreviation.
- `alias-candidates.csv`: 100 uncovered labels with a plausible PirateFinder-Catalog
  crew name, e.g. `No Limits` → `no limit`, `Mug UK` → `mug u k`,
  `I.Cs Workshop` → `i c workshop`, `Medway Boys / BBC` → `medway boys`.
- The 532 ST crew histories (members, founding date, notes, Wikipedia) are
  available as a separate artifact; joining them by name/platform is the
  obvious next step for the crew view.

### Metadata gaps

`gameinfo-gaps.csv` lists matched releases where the local XLS variant has no
year, publisher, crew or cracker but PirateFinder-Catalog does. It is a candidate list
for a review/merge step, not an automatic overwrite.

### Virus flags

PirateFinder-Catalog's 1,288 virus-flagged images are all Amiga; the extracted ST
images carry **no** `virus`, `virus_damage` or `antivirus` flags. A virus
warning for the ST cracked section therefore cannot be sourced from this
catalogue.

## 4a. Implemented in the desktop app (Phase A/B1)

The desktop app now has an optional **PirateFinder-Catalog** row in the shared
settings form (below the data-directory field; no config path) and a third
**PirateFinder-Catalog** row in the existing top-bar **Catalog data** dialog:

- `lib/piratefinder_data.dart` fetches the small `latest.json` pointer from the
  generic `skoelle/piratefinder-catalog-json` GitHub release
  (`catalog-latest`) and downloads
  `piratefinder-catalog-atari-st.json.gz` on request (no auto-download).
- The asset is verified against its SHA-256 and stored under
  `<GameinfoDirectory>/piratefinder/` with a `.piratefinder-catalog.json` marker
  (`source_tag`, `generated_at`, `asset`, `sha256`, `applied_at`).
- Release builds check silently at startup; the dataset badge counts a pending
  PirateFinder-Catalog update. The settings row mirrors AtariLegend: local status/path and a
  single **PirateFinder-Catalog** button that refreshes `latest.json` and
  then downloads; it also links to the
  [original PirateFinder project](https://github.com/peteclarke-del/PirateFinder).
  The **Catalog data** dialog still shows local/remote catalogue tag and
  generation date with **Install**/**Update**.
- The data is CC BY-NC-SA 4.0, lives inside the data directory
  (`GameinfoDirectory/piratefinder`) and is never written into the game trees
  or published artifacts.
- A **PirateFinder Crew Releases** section before the release variants is shown
  only for a title/crew match: distinct crews and a right-aligned red-gradient
  **Crews** button. The dialog tabs are `Release (N)`, `Menus (N)`, `Trivia (N)`
  and `Sources`; the Release tab keeps the game publisher at the top and lists
  each candidate with Release Name, crew + release date and crew info inline
  (no Crew tab, dropdown or release selector). Trivia lists only real
  `fact`/`note` entries gathered from the matching menu appearances (Wikipedia
  stubs excluded), de-duplicated by text+url and tagged with the source menu. Hash matching remains in the data layer
  but is not used for visibility. B1 is metadata-only; media and card-preview
  fallbacks are later phases.
- The data layout moved into `GameinfoDirectory` subfolders (`gameinfo/`,
  `atarilegend/`, `piratefinder/`); a startup migration moves legacy root-level
  gameinfo files and a configured `AtariLegendDirectory` into them.
- Hash matching was validated in Dart against the real data: in a 120-ZIP
  SHA-1 sample all 120 matched, and all 31 SHA-512 (Atari Legend `.msa`) samples
  matched.
- The crew view has a **More** action in the PirateFinder-Catalog block
  (`lib/widgets/piratefinder_crew_dialog.dart`): crew history, members,
  founded date and links plus all PF single releases, menus/packs, trivia and
  sources. `PirateFinderIndex.disksForCrew` resolves the credited disks by
  `crew_id` or normalised crew name.

## 4. What this enables (next phases)

1. **Crew view / crew dialog.** Implemented: the crew overview's
   PirateFinder-Catalog **More** action opens a crew lightbox with history,
   members, founding date, URL/Wikipedia, PF releases, menus/packs, trivia and
   sources. Attribution and the CC BY-NC-SA notice are included.
2. **Alias curation.** Feed the reviewed `alias-candidates.csv` into
   `tools/crew-analysis/aliases.json`; do not merge automatically, because
   individual crackers and crews share names.
3. **Release metadata overlay.** Show the matched PirateFinder-Catalog label, year,
   publisher, cracker and crew in “This ZIP”, and use the menu appearances
   for “also on Automation 250 / D-Bug 100 / …”.
4. **Search.** Reuse the catalogue’s per-title appearances and aliases to
   improve title matching/search without copying its text into the app.

## 5. Limitations / non-goals

- No app integration in this phase; the index and match files are local
  artifacts only.
- No redistribution: the raw SQLite, the index and the match files are
  derived from CC BY-NC-SA 4.0 data and stay in the git-ignored data
  directory.
- Title matches are “likely”, not exact; ambiguous ZIPs remain unresolved by
  design.
- The catalogue is ST/Amiga menu-disk and TOSEC-oriented. Games absent from
  its TOSEC subset (e.g. some educational/adventure titles) cannot match by
  title; they only match if their exact dump is present.
- ST virus information is not available (see above).

## 6. Reproduction

```sh
tools/piratefinder-gen/run.sh fetch --tag catalogue-2026-10-19
tools/piratefinder-gen/run.sh extract
tools/piratefinder-gen/run.sh match
tools/piratefinder-gen/run.sh report
.venv/bin/python -m unittest discover -s tools/piratefinder-gen/tests -v
```

The match step reads the local trees and `index.json` and writes only below
`MARCER_PIRATEFINDER_DIR`. A full run took about 17–19 minutes on the measured
NAS-backed tree (10,722 ZIPs).
