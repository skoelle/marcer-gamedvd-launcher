# ANALYSIS: Game Metadata Sources (Marcer GameDVD)

Behavioral/technical analysis of the additional game metadata available for the
Marcer GameDVD archive, and of how the console launcher and a future desktop
app can consume it. This is a technology-neutral analysis document in the style
of `SPEC.md` and `SPEC-screenshot-generator.md`.

**Status of verified facts:** everything in section 2 and 3 was verified on the
development machine on 2026-10-11 by parsing the real XLS files (read-only).
Paths to real data are never written down literally. They come exclusively from
the git-ignored local file `local/paths.env` (see section 1.2).

**Related documents:**
- [`SPEC.md`](SPEC.md) — behavioral specification of the launcher
- [`SPEC-screenshot-generator.md`](SPEC-screenshot-generator.md) — screenshot generation tool
- [`local/paths.env`](local/paths.env) — local data path definitions (git-ignored)

---

## 1. Purpose, Audience and Scope

### 1.1 Purpose

Document what additional metadata exists beyond the ZIP file names on disk,
whether it can be read reliably, where the extracted data should be stored,
and which features it can power.

### 1.2 Path policy

All absolute paths in this document are symbolic. Consumers resolve them via
`local/paths.env` (or via `launcher.config.json` for the launcher):

| Symbolic name | Meaning |
|---|---|
| `MARCER_ROOT_DIR` | Game DVD root (main layer) |
| `MARCER_PATCH_DIR` | Patch/update layer |
| `MARCER_OUT_DIR` | Generated screenshot output directory |
| `<PATCH>/Title Sorted/` | XLS metadata + title-sorted game trees inside the patch layer |
| `<OUT>/` | Screenshot artifacts (`index.json`, PNG tree) |

### 1.3 Scope

- In scope: the three XLS workbooks under `<PATCH>/Title Sorted/`, the
  screenshot artifacts under `<OUT>/`, title↔folder matching, proposed data
  model and storage, proposed tooling, feature ideas.
- Out of scope (for this document): implementation. Implementation lands as
  separate features per the roadmap in section 7.

---

## 2. Data Source Inventory

### 2.1 XLS workbooks (`<PATCH>/Title Sorted/`)

Three workbooks exist. All three are **Excel 5.0/95 (BIFF5)** files stored as
OLE2 compound documents (`.xls`, `Composite Document File V2`), one worksheet
each, code page latin-1. They were last saved by "Marcer GameUSB" (workbook
title). Verified readable with Python `olefile` (installed system-wide) plus a
small BIFF5 record parser (~50 lines: `LABEL` 0x0204, `RK` 0x027E, `MULRK`
0x00BD, `NUMBER` 0x0203). No `xlrd`/`pandas` required; `openpyxl` cannot read
this format.

#### 2.1.1 `Games.xls` — cracked games (main dataset)

| Property | Verified value |
|---|---|
| Size | ~1.8 MB |
| Data rows | 11,483 (worksheet rows up to r14582, sparse) |
| Distinct `Game Title` values | 3,542 |
| Average rows per title | 3.2 (one row per crack/release variant) |
| Most variants for one title | Arkanoid (30), Xenon 2 (21), Out Run (21) |

Columns (14, 0-based):

| # | Column | Content | Type notes |
|---|---|---|---|
| 0 | `Game Title` | Title text | text |
| 1 | `Publisher` | Original publisher | text, often empty for crack rows |
| 2 | `Cracked by` | Cracker nick | text |
| 3 | `Cracking Crew` | Crew name | text |
| 4 | `Intro Code` | Intro author/tag | text |
| 5 | `Special` | Release/feature notes (e.g. `US Release`, `EU Release`, `Cheat`, `Budget`, `Mono`) | text |
| 6 | `Language` | e.g. `English`, `German`, `French` | text |
| 7 | `Disks` | Disk count | number |
| 8 | `RAW-Dump` | `Yes` or empty | flag |
| 9 | `Pasti Dump` | `Yes` or empty | flag |
| 10 | `Boxscan` | `Yes` or empty | flag |
| 11 | `Release Date` | Year **or** full date | **mixed**: Excel serial year number (e.g. `1987`) *and* text dates (`24-02-1987`) |
| 12 | `TOS / Bad` | TOS/bad-dump notes (e.g. `Not Ste`, `TOS Patched`) | text |
| 13 | `Special` | Second, different `Special` column (free text) | text |

Quirks:
- Header row is row 0; row 1 contains a generation note (`Date updated: …`,
  `Runned 1.62/2mb`); data starts at row 3.
- Column 5 and column 13 share the header name `Special` — they carry different
  meanings (structured flag vs. free text) and must be renamed on extraction
  (e.g. `special_flag`, `special_note`).
- Each title has multiple rows: one per crack/release variant (different
  cracker, crew, publisher region). There is **no ZIP file name column** —
  matching to on-disk entries is by title only (see section 3).

#### 2.1.2 `PD Games.xls` — public domain games

| Property | Verified value |
|---|---|
| Data rows | 2,207 (up to r4030) |
| Distinct titles | 1,726 |

Columns (12): `Game Title | Version | Publisher | Company /Author | Licence |
Screen Format | Language | Disks | Release Date | Add. Info | Tos / Bad |`
(trailing empty columns).

#### 2.1.3 `Utils_.xls` — utilities/programs

| Property | Verified value |
|---|---|
| Data rows | 6,754 (up to r10211) |
| Distinct titles | 3,567 |

Columns (14): `Utility Title | Version | Publisher / Crew | Company /Author |
Licence | Cracked by | Cracking Crew | Cracktro | Screen Format + Infos |
Language | Disks | Release Date | Raw Dump | Tos / Bad`.

### 2.2 Screenshot artifacts (`<OUT>/`, produced by `tools/screenshot-gen`)

| Property | Verified value |
|---|---|
| `index.json` entries | 22,938 |
| Structure | `{ "version": 1, "entries": { "<rel zip path>": {…} } }` |
| Key | ZIP path relative to the scope tree root, e.g. `Title Sorted/Cracked Games - Title Sorted/0-9/10th Frame/10th Frame - Pedro.zip` |
| Entry fields | `candidates`, `capture_method`, `duration_s`, `kind` (`game`/`desktop`), `last_run`, `layer` (`ROOT`/`PATCH`), `mtime`, `name`, `preview`, `rel`, `size`, `status`, `zip_contents` |
| PNGs | Mirroring the source tree under `<OUT>/Title Sorted/…`, one preview PNG (+ optional `_cNN.png` candidates) and one sidecar `.json` per entry |

The screenshot index is keyed **per ZIP**, the XLS data is keyed **per title**
(one title → many ZIP variants). A future join must go title → folder → ZIPs
(see section 3.3).

### 2.3 On-disk title-sorted trees

| Tree | Location | Purpose |
|---|---|---|
| Cracked games | `<PATCH>/Title Sorted/Cracked Games - Title Sorted/<Letter>/<Game>/` | 1,822 game folders (verified) |
| PD games | `<PATCH>/Title Sorted/PD Games - Title Sorted/…` | PD game folders |
| Utilities | `<PATCH>/Title Sorted/Utilitys - Title Sorted/…` | utility folders |

The launcher's browse trees (`MARCER_ROOT_DIR` + `MARCER_PATCH_DIR` overlay)
contain the same/similar folder structure, so folder names are the natural
join key between launcher navigation and XLS metadata.

---

## 3. Matching Analysis (XLS titles ↔ on-disk folders)

### 3.1 Measured match rates (cracked games, verified)

| Direction | Rate |
|---|---|
| XLS title == folder name (exact, incl. case) | 1,300 / 3,542 (37 %) |
| XLS title match after NFKD + case-fold + whitespace normalize | 1,372 / 3,542 (39 %) |
| **Disk folder found in XLS** after same normalization | **1,372 / 1,822 (75 %)** |

The launcher-relevant direction is the second one (folder → XLS data): 75 %
of the on-disk cracked-game folders already match with a simple normalization.

**Update (M1, verified by `tools/gameinfo-gen`):** with the full
exact → prefix → fuzzy strategy and the ROOT∪PATCH folder union
(3,289 cracked folders) the match rate is **94.5 %** (3,108 matched:
2,532 exact, 434 prefix, 142 fuzzy; 181 folders without XLS entry).

### 3.2 Unmatched causes (sampled, categorized)

1. **Title genuinely absent from XLS** — mostly educational titles
   (`Bentley Bear *`, `Codoroute *`, `Denver *`, `Gruneberg Linkword *`, …).
2. **Punctuation/spacing variants** — disk strips punctuation:
   `A La Conquete De L Orthographe` vs. XLS `A La Conquete de L'Orthographe`.
3. **Article inversion** — disk `Deep, The` vs. XLS `The Deep` style titles.
4. **Version/edition suffixes** — disk `A320 Airbus v1.04 - Edition Europe`
   vs. XLS `A320 Airbus`.
5. **Publisher/edition qualifiers in folder names** —
   `Tetris - Mirrorsoft`, `Striker - Rage Software`, `Barbarian - Palace`.
6. **Encoding** — non-ASCII titles (`Kletba Jižní Zeme` with latin-1 `\x9x`
   bytes in the XLS text stream).

### 3.3 Proposed matching strategy (for the extractor tool)

1. Normalize both sides: NFKD, strip combining characters, lowercase, remove
   all punctuation, collapse whitespace (`A La Conquete…` case works).
2. Exact match on normalized key.
3. Fuzzy fallback (e.g. token-set / Levenshtein with threshold) **plus**
   prefix rule: folder `X v1.2 - Something` matches XLS title `X` when the
   leading token sequence equals the full normalized XLS title.
4. Emit an **unmatched report** (both directions) as a tool artifact —
   unmatched folders may indicate XLS gaps worth fixing at the source.

---

## 4. Use-Case Ideas

All ideas below consume the extracted data model from section 5. None are
implemented yet.

### 4.1 Info overlay in the console launcher

Key idea: pressing a dedicated key (e.g. `i`) while a game/ZIP is selected
shows an info box with: publisher, cracker, crew, year, language, disk count,
dump flags (`RAW-Dump`/`Pasti Dump`/`Boxscan`), TOS/bad notes, special notes.

- Data needed: one record per selected entry (title match of the selected
  folder/ZIP), variant list if multiple cracks exist.
- Fits the existing `?` help-box rendering pattern (see `MenuRenderer`).
- Graceful degradation: if no game info data is present, the key does nothing
  (or shows "no data").

### 4.2 Search and sort

- Sort the current directory listing by an alternative key: title, publisher,
  year, cracker — instead of plain folder-name order.
- Search/filter: type-ahead filter across all known titles (not just the
  current directory), jumping to matches.
- Both change navigation behavior and therefore require `SPEC.md`,
  `AGENTS.md` and `README.md` updates when implemented.

### 4.3 Desktop application (infos + screenshots)

A separate desktop app (future project, out of launcher scope) would:
- Browse the same trees (ROOT/PATCH overlay semantics as the launcher).
- Show the XLS metadata (section 5 data model) **and** the screenshot preview
  images from `<OUT>/` (join: gameinfo `folder` → `index.json` entries whose
  `rel` path lies under that folder; per-ZIP previews already exist).
- Provide search/sort UI (section 4.2) with instant filtering over the full
  catalog (~3.5k cracked + ~1.7k PD + ~3.6k utility titles).

### 4.4 Archive audits / data quality reports

The same extractor can produce reports such as:
- Games with `TOS / Bad` notes (need TOS patching or are bad dumps).
- Games missing RAW/PASTI dumps (preservation gaps vs. `Missing.txt`).
- Folders with no XLS entry and XLS titles with no folder (section 3.3
  unmatched report).
- Screenshot coverage: folders/ZIPs without a `done` screenshot in
  `index.json`.

---

## 5. Proposed Data Model and Storage

### 5.1 Storage location (decision)

**Decision:** extracted metadata is generated into **`<PATCH>/Data/`**
(`MARCER_PATCH_DIR/Data/`).

Rationale:
- The data belongs to the DVD/patch content, not to the launcher code — it
  updates together with the XLS sources, like the screenshot artifacts
  already do in `<OUT>/`.
- No repo weight; no sync burden between XLS updates and git.
- Both consumers (console launcher on any platform, future desktop app on the
  iMac) read the same files from the NAS/patch mount.
- The launcher build (GitHub Actions) stays independent of the NAS.

Rules:
- The extractor tool is the **only writer**. Launcher and desktop app are
  strictly read-only consumers.
- The launcher must treat the data as **optional** (graceful fallback when
  `<PATCH>/Data/` is missing or incomplete).
- Data files are derived artifacts; they are not committed to git and not
  shipped inside the launcher release ZIP.

### 5.2 File layout under `<PATCH>/Data/`

| File | Content |
|---|---|
| `games-cracked.json` | Extracted `Games.xls` (cracked games) |
| `games-pd.json` | Extracted `PD Games.xls` (PD games) |
| `games-utils.json` | Extracted `Utils_.xls` (utilities) |
| `manifest.json` | Generation metadata (see 5.4) |
| `unmatched-report.txt` (optional) | Human-readable matching gaps (section 3.3) |

One file per source kind keeps each file small and lets the launcher load
only `games-cracked.json` (the only tree it browses today).

### 5.3 Schema sketch (`games-cracked.json`)

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

Notes:
- `games[]` is keyed by **matched on-disk folder name** (`folder` + `letter`),
  since that is the launcher's navigation identity. `variants[]` holds all
  XLS rows for that title (section 2.1.1).
- `release` is normalized to a string: either `"YYYY"` or `"DD-MM-YYYY"`
  (source data is mixed, section 2.1.1).
- `pd`/`utils` files use the same envelope with kind-specific variant fields
  (`version`, `licence`, `screen_format`, `add_info`, `cracktro`, …).
- Booleans: XLS flag columns (`Yes`/empty) become JSON booleans.
- JSON UTF-8 (fixes the latin-1 quirks at extraction time).

### 5.4 `manifest.json`

```json
{
  "schema_version": 1,
  "generated_at": "2026-10-11T00:00:00Z",
  "generator": "tools/gameinfo-gen",
  "sources": [
    { "file": "Games.xls", "mtime": 0, "size": 0, "rows": 11483, "titles": 3542, "matched_folders": 1372, "unmatched_folders": 450 }
  ]
}
```

Consumers can check `generated_at`/source `mtime` to detect stale data and the
launcher can log a hint ("game info data outdated") without failing.

### 5.5 Launcher integration (sketch, future feature)

- New optional config key in `launcher.config.json`: `GameInfoDirectory`.
  Default when absent: auto-detect `<PatchDirectory>/Data`.
- Load `games-cracked.json` once at startup into a
  `folder → variants[]` dictionary (a few MB JSON is negligible for .NET).
- New key binding for the info overlay (section 4.1); no behavior change when
  the data is absent.
- Per project policy: implementation then requires updates to `SPEC.md`,
  `AGENTS.md` (module overview) and `README.md`.

---

## 6. Tool: `tools/gameinfo-gen` (implemented, M1 done 2026-10-11)

Mirrors the conventions of `tools/screenshot-gen`:

| Aspect | Proposal |
|---|---|
| Language | Python 3 (same as `shotgen.py`) |
| XLS parsing | `olefile` (already installed system-wide) + embedded BIFF5 parser; alternatively pinned in repo `.venv` |
| Wrapper | `run.sh` that sources `local/paths.env` and runs with the repo venv (like `tools/screenshot-gen/run.sh`) |
| Inputs | The three XLS files under `<PATCH>/Title Sorted/` (paths via `paths.env`; overridable via CLI flags) |
| Matching | Section 3.3 strategy, against the three title-sorted trees under `<PATCH>/Title Sorted/` |
| Outputs | Section 5.2 files into `<PATCH>/Data/` (atomic write: temp file + rename) |
| Runtime | Seconds, not hours (no emulator involved; read-only NAS access) |
| Exit codes | 0 = success (even with unmatched entries), non-zero = source/IO error |

Non-goals: writing anywhere under `MARCER_ROOT_DIR`/`MARCER_PATCH_DIR` other
than `<PATCH>/Data/`; network access; modifying the XLS sources.

---

## 7. Roadmap / Next Steps

| Milestone | Content | Depends on |
|---|---|---|
| **M0** | This analysis document | — |
| **M1** | `tools/gameinfo-gen` extractor + `<PATCH>/Data/` output + unmatched report — **done 2026-10-11** (cracked: 3,108/3,289 folders matched = 94.5 %) | M0 |
| **M2** | Launcher: optional `GameInfoDirectory` + info overlay (`i` key) | M1 |
| **M3** | Launcher: search/sort over the catalog (SPEC + README + AGENTS updates) | M2 |
| **M4** | Desktop app: browse + infos + screenshot previews (join with `<OUT>/index.json`) | M1 (+ screenshot coverage from `tools/screenshot-gen`) |
| **M5** | Audit reports (dumps, TOS notes, coverage) as generator option | M1 |

Open questions (deferred to the respective milestones):
- M2: which subset of fields the info box shows (screen space is limited).
- M3: sort/search key bindings and interaction with the ROOT/PATCH overlay.
- M4: technology choice for the desktop app; screenshot scaling; whether it
  reuses `<OUT>/index.json` or a merged catalog file.
- M1: whether PD/Utils trees get their own folder matching pass in the first
  version or only a title-index extraction (no folder key).

---

## Conformance Checklist (for future implementation)

- [x] Extractor reads all three XLS files via `local/paths.env` only; no
      hard-coded absolute paths.
- [x] Extractor writes exclusively to `<PATCH>/Data/`; NAS sources remain
      read-only.
- [x] `manifest.json` matches the real output files (counts, timestamps)
      (`tools/gameinfo-gen/run.sh check` exits 0).
- [ ] Launcher works unchanged when `<PATCH>/Data/` is absent (graceful
      fallback). *(M2, launcher not touched yet — default behavior unchanged.)*
- [ ] Launcher never writes to `<PATCH>/Data/`. *(M2)*
- [ ] `SPEC.md`, `AGENTS.md` and `README.md` updated with each behavioral
      change (M2, M3).
- [ ] Manual test run via `scripts/start.cmd` (Windows) or `scripts/start.sh`
      (Linux/macOS) before delivery of any launcher change.
