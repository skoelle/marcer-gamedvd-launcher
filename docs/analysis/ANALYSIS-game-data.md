# ANALYSIS: Game Metadata Sources (Marcer GameDVD)

Analysis of the additional game metadata available for the Marcer GameDVD
archive and how it is extracted into the runtime `games-*.json` artifacts.
This document records the **external data reality** and the artifact schema;
the consumer behavior is specified in
[`SPEC-desktop.md`](../specs/SPEC-desktop.md) and
[`SPEC-gallery-webapp.md`](../specs/SPEC-gallery-webapp.md).

**Status of verified facts:** sections 2–3 were verified by parsing the real
XLS files read-only; counts are order-of-magnitude and grow over time. Paths
come from the git-ignored `local/paths.env`.

**Related documents:**
- [`SPEC-launcher.md`](../specs/SPEC-launcher.md) — launcher behavior
- [`SPEC-screenshot-generator.md`](../specs/SPEC-screenshot-generator.md) — screenshot artifacts
- [`ANALYSIS-crews.md`](ANALYSIS-crews.md) — crew data derived from the same sources

---

## 1. Purpose and Scope

Document what metadata exists beyond ZIP file names, whether it can be read
reliably, where the extracted data is stored, and how it is matched to on-disk
folders.

Path symbols: `MARCER_ROOT_DIR` (main layer), `MARCER_PATCH_DIR` (patch layer),
`MARCER_DATA_DIR` (data directory; derived gameinfo goes to
`MARCER_DATA_DIR/gameinfo/`), `MARCER_OUT_DIR` (screenshot artifacts).
`<PATCH>/Title Sorted/` holds the XLS sources and title-sorted trees.

Out of scope: UI features and tool implementation details (see the tool README).

---

## 2. Data Source Inventory

### 2.1 XLS workbooks (`<PATCH>/Title Sorted/`)

Three workbooks exist, all **Excel 5.0/95 (BIFF5)** files stored as OLE2
compound documents (`.xls`, one worksheet each, code page latin-1). They are
readable with Python `olefile` plus a small BIFF5 record parser; `xlrd`/
`pandas` are not required and `openpyxl` cannot read this format.

#### `Games.xls` — cracked games

~11,500 data rows, ~3,500 distinct titles, one row per crack/release variant.
Columns (0-based):

| # | Column | Content | Type notes |
|---|---|---|---|
| 0 | `Game Title` | Title text | text |
| 1 | `Publisher` | Original publisher | text, often empty for crack rows |
| 2 | `Cracked by` | Cracker nick | text |
| 3 | `Cracking Crew` | Crew name | text |
| 4 | `Intro Code` | Intro author/tag | text |
| 5 | `Special` | Structured flag (`US Release`, `Cheat`, `Budget`, `Mono`, …) | text |
| 6 | `Language` | e.g. `English`, `German`, `French` | text |
| 7 | `Disks` | Disk count | number |
| 8 | `RAW-Dump` | `Yes` or empty | flag |
| 9 | `Pasti Dump` | `Yes` or empty | flag |
| 10 | `Boxscan` | `Yes` or empty | flag |
| 11 | `Release Date` | Year **or** full date | mixed: Excel serial year *and* text dates (`24-02-1987`) |
| 12 | `TOS / Bad` | TOS/bad-dump notes | text |
| 13 | `Special` | Second, free-text `Special` column | text |

Quirks:
- Header row is row 0; row 1 is a generation note; data starts at row 3.
- Columns 5 and 13 share the header name `Special` but have different meanings
  (structured flag vs. free text) — rename on extraction (`special_flag`,
  `special_note`).
- There is **no ZIP file name column**; matching is by title only.

#### `PD Games.xls` — public domain games

~2,200 rows, ~1,700 titles. Columns: `Game Title | Version | Publisher |
Company/Author | Licence | Screen Format | Language | Disks | Release Date |
Add. Info | Tos/Bad`.

#### `Utils_.xls` — utilities/programs

~6,700 rows, ~3,500 titles. Columns: `Utility Title | Version | Publisher/Crew |
Company/Author | Licence | Cracked by | Cracking Crew | Cracktro | Screen
Format + Infos | Language | Disks | Release Date | Raw Dump | Tos/Bad`.

### 2.2 Screenshot artifacts (`<OUT>/`)

Produced by `tools/screenshot-gen`; see
[`SPEC-screenshot-generator.md`](../specs/SPEC-screenshot-generator.md).
The index is keyed **per ZIP** (`{ "version": 1, "entries": { "<rel zip path>":
{…} } }`) with fields `candidates`, `capture_method`, `duration_s`, `kind`
(`game`/`desktop`/…), `last_run`, `layer`, `mtime`, `name`, `preview`, `rel`,
`size`, `status`, `zip_contents`. PNGs mirror the source tree, one preview per
entry plus optional `_cNN` candidates and a sidecar `.json`.

The XLS data is keyed **per title** (one title → many ZIP variants), so a join
must go title → folder → ZIPs.

### 2.3 On-disk title-sorted trees

| Tree | Location | Purpose |
|---|---|---|
| Cracked games | `<PATCH>/Title Sorted/Cracked Games - Title Sorted/<Letter>/<Game>/` | ~1,800 game folders |
| PD games | `<PATCH>/Title Sorted/PD Games - Title Sorted/…` | PD game folders |
| Utilities | `<PATCH>/Title Sorted/Utilitys - Title Sorted/…` | utility folders |

The launcher's browse trees contain the same structure, so folder names are the
natural join key between navigation and XLS metadata.

---

## 3. Matching (XLS titles ↔ on-disk folders)

### 3.1 Measured match rates

A plain normalization (NFKD + case-fold + whitespace) matches roughly 39 % of
XLS titles to an exact folder name, but **75 % of on-disk folders** to an XLS
entry — the launcher-relevant direction. With the full exact → prefix → fuzzy
strategy against the ROOT∪PATCH folder union the folder match rate is ~95 %.

### 3.2 Unmatched causes

1. Title genuinely absent from XLS (mostly educational titles).
2. Punctuation/spacing variants (`L Orthographe` vs. `L'Orthographe`).
3. Article inversion (`Deep, The` vs. `The Deep`).
4. Version/edition suffixes (`A320 Airbus v1.04 - Edition Europe`).
5. Publisher/edition qualifiers (`Tetris - Mirrorsoft`).
6. Encoding quirks in non-ASCII titles.

### 3.3 Matching strategy

1. Normalize both sides: NFKD, strip combining characters, lowercase, remove
   punctuation, collapse whitespace.
2. Exact match on the normalized key.
3. Prefix rule: folder `X v1.2 - Something` matches XLS `X` when the leading
   token sequence equals the full normalized XLS title.
4. Fuzzy fallback (token-set / Levenshtein with threshold).
5. Emit an **unmatched report** (both directions) as a tool artifact.

---

## 4. Storage and Data Model

Derived metadata is written to **`MARCER_DATA_DIR/gameinfo/`**; the extractor is
the only writer and all consumers are read-only. The data is optional for every
consumer: a missing directory degrades to no metadata.

### 4.1 File layout

| File | Content |
|---|---|
| `games-cracked.json` | Extracted `Games.xls` |
| `games-pd.json` | Extracted `PD Games.xls` |
| `games-utils.json` | Extracted `Utils_.xls` |
| `manifest.json` | Generation metadata (4.3) |
| `unmatched-report.txt` (optional) | Human-readable matching gaps |
| `crews.json`, `crew-images.json` | Crew artifacts from `tools/crew-analysis` (see [`ANALYSIS-crews.md`](ANALYSIS-crews.md)) |

One file per source kind keeps each file small and lets a consumer load only
the kinds it needs.

### 4.2 Schema (`games-cracked.json`)

```json
{
  "schema_version": 1,
  "kind": "cracked",
  "source": "Games.xls",
  "generated_at": "2026-10-11T00:00:00Z",
  "games": [
    {
      "folder": "10th Frame",
      "letter": "0-9",
      "variants": [
        {
          "title": "10th Frame",
          "publisher": "Access",
          "cracked_by": "Original",
          "crew": "",
          "intro_code": "",
          "special_flag": "US Release",
          "language": "English",
          "disks": 1,
          "raw_dump": true,
          "pasti_dump": true,
          "boxscan": true,
          "release": "1987",
          "tos_bad": "",
          "special_note": ""
        }
      ]
    }
  ]
}
```

- `games[]` is keyed by the **matched on-disk folder**; `variants[]` holds all
  XLS rows for that title.
- `release` is normalized to a string, either `"YYYY"` or `"DD-MM-YYYY"` (the
  source is mixed).
- `pd`/`utils` use the same envelope with kind-specific variant fields
  (`version`, `licence`, `screen_format`, `add_info`, `cracktro`, …).
- XLS flag columns (`Yes`/empty) become JSON booleans; JSON is UTF-8.

### 4.3 `manifest.json`

```json
{
  "schema_version": 1,
  "generated_at": "2026-10-11T00:00:00Z",
  "generator": "tools/gameinfo-gen",
  "sources": [
    { "file": "Games.xls", "mtime": 0, "size": 0, "matched_folders": 1372, "unmatched_folders": 450 }
  ]
}
```

Consumers use `generated_at`/source `mtime` to detect stale data without
failing.

---

## 5. Tool

`tools/gameinfo-gen` implements the extraction (see
[`tools/gameinfo-gen/README.md`](../../tools/gameinfo-gen/README.md)):

- Python 3, `olefile` + embedded BIFF5 parser, `run.sh` sourcing
  `local/paths.env`.
- Inputs: the three XLS files (`PATCH` preferred, `ROOT` fallback).
- Matching against the three ROOT∪PATCH trees; atomic output to
  `MARCER_DATA_DIR/gameinfo`.
- Exit 0 even with unmatched entries; non-zero on source/IO errors.
- Never writes under `MARCER_ROOT_DIR`/`MARCER_PATCH_DIR`, never modifies the
  XLS sources.

Run `tools/crew-analysis/run.sh` afterwards to add `crews.json`/
`crew-images.json` to the same directory.
