# ANALYSIS: Pete Clarke Greaseweazle PirateFinder Catalog

Analysis of the
[Pete Clarke Greaseweazle PirateFinder Catalog](https://github.com/peteclarke-del/PirateFinder)
and how its Atari ST data is used for the Marcer GameDVD project. The
implementation is the read-only tool
[`tools/piratefinder-gen`](../../tools/piratefinder-gen/README.md); consumer
behavior is specified in [`SPEC-desktop.md`](../specs/SPEC-desktop.md).

**Licence:** the PirateFinder-Catalog is **CC BY-NC-SA 4.0**, because it
includes Atari Legend data under that licence. The tool does not redistribute
the database or derived index files; it fetches the release from GitHub and
keeps everything local (`MARCER_PIRATEFINDER_DIR`, default
`local/piratefinder/`). The raw SQLite is not committed and must not be
published with the Marcer artifacts.

---

## 1. What the catalogue is

- A read-only **SQLite** database, published weekly as a GitHub release tagged
  `catalogue-YYYY-MM-DD`.
- Asset: `catalogue-layout3.sqlite.gz` (~90 MB compressed, ~300 MB
  uncompressed). Schema version 3; `meta` carries build date, builder version,
  source status and licence.
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

The extracted ST subset has ~24k disks (menu/pack/single/compilation), ~29k
images, ~48k contents rows and ~530 crews with history.

## 2. How it is used

```sh
tools/piratefinder-gen/run.sh fetch     # newest catalogue-* release + SHA-256
tools/piratefinder-gen/run.sh extract   # ST subset -> compact JSON
tools/piratefinder-gen/run.sh match     # Marcer cracked ZIPs vs. catalogue
tools/piratefinder-gen/run.sh report    # regenerate the reports
```

### Matching

The universe follows the same direct-release rule as `tools/crew-analysis`:
direct release ZIPs under `Title Sorted/Cracked Games - Title Sorted`, read
from `index.json` by default or from disk with `--scan`.

1. **Hash (exact).** Every `.msa`/`.st`/`.stx` member of a ZIP is decoded and
   hashed. MSA is unpacked to raw sectors; `.st` is hashed as-is; `.stx` is
   hashed as a file. Lookup order is SHA-1, MD5, SHA-512, then CRC32 + size.
2. **Title (likely).** ZIPs with no hash match are matched by a normalised
   title against the catalogue's single-disk rows. The ZIP stem's cracker part
   (“Game - Cracker”), part number (“Disk 2”), gameinfo crew/cracker labels,
   year and publisher narrow the candidates. A short local title may match a
   longer catalogue title as a prefix (`Ween` → `Ween - The Prophecy`).

Results are `exact` (hash) or `likely` (title). If several catalogue disks
remain and the metadata cannot choose one, the ZIP is reported as **ambiguous**
with its candidates instead of guessing.

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

Approximate, from a real release and the direct cracked ZIP universe:

- ~99 % of ZIPs expose a recognised image member.
- ~66 % match the catalogue — ~43 % by hash, ~23 % by title fallback.
- ~16 % stay unmatched, ~17 % ambiguous (candidates listed); a match can also
  have menu-disk appearances.
- Hash matches are dominated by SHA-1; the hash rate is limited by catalogue
  coverage and dumps that differ from TOSEC/Atari Legend, not by decoder
  failures.

### Crew data

`crew-coverage.csv` lists the Marcer crew/cracker labels covered exactly or via
an alias/abbreviation; `alias-candidates.csv` lists uncovered labels with a
plausible catalogue name (e.g. `No Limits` → `no limit`). The ~530 ST crew
histories (members, founding date, notes, Wikipedia) are available as a
separate artifact and joined by name/platform in the app.

### Metadata gaps

`gameinfo-gaps.csv` lists matched releases where the local XLS variant has no
year, publisher, crew or cracker but the catalogue does. It is a candidate list
for review, not an automatic overwrite.

### Virus flags

The catalogue's virus-flagged images are all Amiga; the extracted ST images
carry **no** virus flags. An ST virus warning cannot be sourced from this
catalogue.

## 4. Limitations / non-goals

- No redistribution: the raw SQLite, the index and the match files are derived
  from CC BY-NC-SA 4.0 data and stay in the git-ignored data directory.
- Title matches are “likely”, not exact; ambiguous ZIPs remain unresolved by
  design.
- The catalogue is ST/Amiga menu-disk and TOSEC-oriented. Games absent from its
  TOSEC subset cannot match by title; they only match if their exact dump is
  present.
- ST virus information is not available (see above).

## 5. Reproduction

```sh
tools/piratefinder-gen/run.sh fetch --tag catalogue-2026-10-19
tools/piratefinder-gen/run.sh extract
tools/piratefinder-gen/run.sh match
tools/piratefinder-gen/run.sh report
.venv/bin/python -m unittest discover -s tools/piratefinder-gen/tests -v
```

The match step reads the local trees and `index.json` and writes only below
`MARCER_PIRATEFINDER_DIR`.
