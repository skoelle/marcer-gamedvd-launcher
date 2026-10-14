# ANALYSIS: Boxscan & Manual Asset Structure (Marcer GameDVD)

Technical analysis of the `Boxscan/` and `Manual/` companion folders that live
next to the game ZIPs in the archive, and of what a consumer (Flutter desktop
app, gallery, tools) must expect when reading them. Companion document to
[`ANALYSIS-game-data.md`](ANALYSIS-game-data.md) — that document covers the
XLS metadata, this one covers the on-disk scan/manual assets.

**Status of verified facts:** everything in sections 2–5 was verified on the
development machine on 2026-10-14 by listing the real directories and by
opening ZIP archives read-only. Counts come from the patch layer and the
main layer as of that date and will grow over time — treat all numbers as
order-of-magnitude, not as a contract. Literal paths are never written down;
they come exclusively from the git-ignored `local/paths.env` (section 1.2).

**Related documents:**
- [`ANALYSIS-game-data.md`](ANALYSIS-game-data.md) — XLS metadata model, `games-*.json`
- [`SPEC.md`](SPEC.md) — launcher behavior (navigation, what is shown)
- [`SPEC-gallery-webapp.md`](SPEC-gallery-webapp.md) — gallery UI contract
- [`SPEC-screenshot-generator.md`](SPEC-screenshot-generator.md) — `exclude_dirs` = `boxscan`, `manual`, `kryoflux`
- [`local/paths.env`](../local/paths.env) — local data path definitions (git-ignored)

---

## 1. Purpose, Audience and Scope

### 1.1 Purpose

Document where box scans and manuals live in the archive, in which structural
variants they appear, how they are named, and which rules a consumer must
implement to display them reliably. This is the basis for wiring box scans
into the Flutter desktop app.

### 1.2 Path policy

| Symbolic name | Meaning |
|---|---|
| `MARCER_ROOT_DIR` | Game DVD root (main layer) |
| `MARCER_PATCH_DIR` | Patch/update layer |
| `<ROOT>/Title Sorted/` | Title-sorted game tree in the main layer |
| `<PATCH>/Title Sorted/` | Title-sorted game tree in the patch layer |
| `<LAYER>/` | Either layer; both have the same internal shape |

### 1.3 Scope

- In scope: folder naming, nesting, file naming, archive contents, edge
  cases, current tooling behavior, requirements for a consumer.
- Out of scope: implementing the display (separate feature), image quality /
  scan source provenance, the XLS `Boxscan` flag semantics (covered in
  `ANALYSIS-game-data.md` section 3).

---

## 2. Where The Assets Live

### 2.1 Game tree shape

Both layers share this shape:

```
<TITLE-SORTED>/
  <Category>/                       # "Cracked Games - Title Sorted", "PD Games - Title Sorted", "Utilitys - Title Sorted"
    <Letter>/                       # "A".."Z", "0-9", "Ö" …
      <Game Name>/                  # the game folder — one per title/edition family
        <Game>.zip                  # the launchable game archive(s)
        Boxscan/                    # OPTIONAL — box scans
        Manual/                     # OPTIONAL — manuals (PDF)
        Original/  IPF/  RAW/  STX/  Kryoflux/  …   # other companion folders (dumps, originals)
```

`Boxscan/` and `Manual/` are **direct children of the game folder**, siblings
of the game ZIPs. They are optional — most game folders have neither.

### 2.2 Folder name variants (match case-insensitively!)

Verified name spellings:

| Folder | Occurrences (patch layer) | Occurrences (main layer) |
|---|---|---|
| `Boxscan` | 229 | 798 |
| `boxscan` | 0 | 1 |
| `Box Scan` | 0 | 1 |
| `Manual` | 17 | 547 |
| `Manuals` | 1 | 0 |

**Rule:** detect these folders case-insensitively and accept an optional
space between `Box` and `Scan`. No other spellings were found. Do **not**
match game-folder names that merely contain the word "box" (`Boxkite`,
`Boxing Champ`, `Box the Dragon…`) — only the exact names above.

### 2.3 Coverage

| Layer | Game folders | `Boxscan/` | `Manual/` |
|---|---|---|---|
| Main (`<ROOT>/Title Sorted/`) | ~9,994 | ~800 (~8 %) | ~547 (~5 %) |
| Patch (`<PATCH>/Title Sorted/`) | ~5,299 | ~229 (~4 %) | ~18 (< 1 %) |

The patch layer is younger and holds the newer/curated additions; the main
layer holds the bulk. An overlay-aware consumer must merge both (see
section 7.1).

### 2.4 Overlay interaction

`Boxscan/` and `Manual/` are ordinary directories — the overlay rules of
`SPEC.md` section 7 apply unchanged: same relative folder name in both layers
merges into one entry, patch wins for file resolution. In practice both
layers usually contribute different *files* to the same `Boxscan/` folder
(main: loose PNGs, patch: edition ZIPs — see the `Captain Blood` example in
section 4.5), so a consumer that only reads one layer will miss assets.

---

## 3. Content Inventory (What Is Actually Inside)

### 3.1 Boxscan folders — payload kinds

A `Boxscan/` folder contains any mix of three payload kinds:

| Kind | Extensions | Meaning |
|---|---|---|
| Loose images | `.png`, `.jpg` | Scans stored directly in the folder |
| Archives | `.zip` | One ZIP per edition/publisher, each holding that edition's scans |
| Stray documents | `.pdf` | Rare; a manual/advert accidentally placed in `Boxscan/` (see 6.2) |

### 3.2 Boxscan folders — shape distribution (patch layer, n=229)

| Shape | Count | Share |
|---|---|---|
| Only loose images (no ZIP) | 210 | ~92 % |
| Only ZIPs (no loose images) | 16 | ~7 % |
| Mixed (ZIPs **and** loose images) | 3 | ~1 % |

Loose-image counts per folder: mostly 2 (front+back), sometimes 1, 3, 4,
up to 10. Total loose images in the patch layer: ~456 (233 `.jpg`, 223
`.png`).

ZIP counts per folder: 1 (most common), 2, up to 5 (`Captain Blood`). Total
Boxscan ZIPs in the patch layer: 29. The main layer has ~497 Boxscan ZIPs
across ~449 folders; the remaining ~350 folders hold only loose images.

### 3.3 Inside the Boxscan ZIPs (all 29 patch-layer ZIPs opened)

| Property | Verified value |
|---|---|
| ZIPs with a single top-level folder | 17 |
| ZIPs flat (files at archive root) | 12 |
| Images per ZIP | 2 (most common), 3, 5, 6, 8, 13, up to 25 |
| Extensions inside | `.jpg` (214), `.png` (25), plus rare non-image files |
| Nested subfolders beyond the container | only `Replay 16 - Box & Contents/…` (multi-level, see 6.1) |

**Both layouts must be handled:** either exactly one top-level directory
(the container, whose name may differ from the game folder name), or files
directly at archive root. A robust rule: recursively collect all image
files inside the ZIP, ignore everything else, and do not assume any
container depth.

### 3.4 Manual folders

| Layer | Shape |
|---|---|
| Patch (n=18) | 14 folders with 1–3 ZIPs (each ZIP holds one PDF), 4 folders with only loose files (2× PDF, 1× PDF+GIF, 1× RAR) |
| Main (sample n=40) | ~30 folders with 2 ZIPs, 6 with 1 ZIP, 4 with 3–4 ZIPs |

Inside the Manual ZIPs: almost always exactly **one PDF**. Verified outliers:

- `Manual/Atari-Steinberg-Avalon-2.0-Manual.rar` — a **RAR**, not a ZIP (1 case)
- `Manual/Atari_MM_KeyMap.gif` — a loose **GIF** next to PDFs (1 case)
- Some Manual folders also carry a `*_text.zip` sibling (text-layer PDF next
  to the scan PDF, e.g. `Conflict Europe.zip` + `Conflict Europe_text.zip`)

**Rule:** a Manual consumer must handle ZIP-with-PDF, loose PDF, and at
least tolerate RAR (or skip it gracefully). A text variant of a manual is
recognised by the `_text` suffix in the ZIP/PDF stem.

---

## 4. File Naming Conventions

Names are **not** systematic. Four generations of naming coexist; a consumer
must not parse names for meaning, only display them. Ordering within a
folder is therefore by name only (or by edition label, see 4.6).

### 4.1 `bild### (2).jpg` — legacy scan-archive export

```
Captain Blood (Atari St)/bild496 (2).jpg
Captain Blood (Atari St)/bild497 (2).jpg
```

Sequential scan-archive IDs, almost always inside a container folder, always
`.jpg`. The `(2)` suffix is constant. Carries no front/back information —
order within the ZIP is the only hint (front usually first).

### 4.2 `<game>_<edition>_<side>.png` — descriptive PNG

```
actionf_mind_front.png
actionf_mind_back.png
amberstar_ger_back.png
atomix_e-fr_front.png
blacklamp_rainbird_back.png
cabal_hq_front.png
```

Lowercase, underscores, optional publisher (`rainbird`, `hq`) and optional
language/region token (`ger`, `de`, `e-fr`, `fr`, `fre`). Sides seen:
`front`, `back`, `f`, `b`, `fr` (front!), `ba` (back), `fro`.

### 4.3 `<game>_<publisher>_d7.jpg` / `_d7_2.jpg` — disc-style JPG pair

```
battle_chess_d7_3.jpg
battle_chess_d7_4.jpg
chaos_strikes_back_v2.1_ftl_d7.jpg
chaos_strikes_back_v2.1_ftl_d7_2.jpg
```

A pair (or triple) per edition; `_d7` is the first image, `_d7_2` /
`_d7_3` / `_d7_4` the following ones. Front/back order is **not** encoded
in the name — treat the set as an ordered gallery.

### 4.4 Special tokens

| Token | Meaning | Example |
|---|---|---|
| `_comic_` + `_p1`…`_p4` | Multi-page comic/inlay scan | `better_comic_p1.png` |
| `_ger_`, `_de_`, `_fr_`, `_fre_`, `_e-fr_` | Language/region of that edition | `memory2_fr.png` |
| `_v101_`, `_v102_` | Game version the scan belongs to | `elite101_f.png`, `elite_v101.zip` |
| `kixx`, `ftl`, `rainbird`, `mirrorsoft`, `grandslam`, … | Publisher/label of that edition | `blacklamp_rainbird_fr.png` |

### 4.5 Edition folders *inside* `Boxscan/`

A handful of games group their scans into edition subfolders:

```
Gunship/Boxscan/
  gunship_b.png, gunship_f.png            # loose, unlabelled edition
  Frenchbox/  GUNSHIP_fre_b.png, GUNSHIP_fre_F.png, Gunship (orange box) (FR) (Atari St).zip
  Greybox v1/ GUNSHIP_02_B.png, GUNSHIP_02_F.png
  Greybox v2/ gunship_88_b.png, gunship_88_f.png, Gunship (Gray box) (Atari St).zip
  Redbox/     gunship_b.png, gunship_f.png, gunship_back.png, gunship_front.png
Captain Blood/Boxscan/
  capt_blod_f.png, capt_blod_b.png, captain_blood_front.png, captain_blood_back.png,
  Captain Blood (Atari St).zip
  Pocketsoft/ captain blood_pocketsoft_front.png, captain blood_pocketsoft_back.png, Pocketsoft.zip
  Smash16/    captain_blood_smash16_front.png, captain_blood_smash16_back.png, Smash16.zip
Out Run/Boxscan/
  outrun_f.png, outrun_b.png
  Klassix/    outrun_front.png, outrun_back.png
```

~41 of ~800 main-layer Boxscan folders (and at least 1 in the patch layer)
use this. Note the inconsistencies even *within* one folder: `Pocketsoft/`
contains a file name with a **space** (`captain blood_pocketsoft_front.png`),
`Redbox/` stores the same front/back twice under two naming schemes, and
loose files at `Boxscan/` top level coexist with edition folders.

**Rule:** treat one directory level below `Boxscan/` as an optional *edition
label*; images found there inherit that label. Do not dedupe by content or
by inferred side — a folder may legitimately contain the same box front
under different names.

### 4.6 ZIP file names = edition labels

The Boxscan ZIP name identifies the edition/publisher the scans belong to:

```
Aussie Joker Poker (NA) (Atari St).zip        # region + platform
Bermuda Project (NA) (Atari St) - Microdeal.zip
Chambers of Shaolin - Grandslam - UK.zip       # publisher + region
Rainbird - bluebox.zip / Rainbird - Whitebox.zip   # label variant
elite_v101.zip / elite_v102.zip                # game version
Replay16-Box&Contents.zip                      # free-form
```

Naming patterns observed: `Title (Region) (Atari St)`, `Title - Publisher -
Region`, `publisher - variant`, `title_vNNN`. Some names contain `&`,
parentheses and hyphens — treat the whole stem as the edition label, do not
parse it further unless a specific region/publisher facet is needed later.

---

## 5. Image Properties

| Property | Observed |
|---|---|
| Formats | `.png` (lossless re-scans, newer) and `.jpg` (scan-archive exports, older) — both must be supported |
| Orientation | Box fronts: portrait (~2:3). Box backs: portrait. Inlays/comics: portrait or square. Disc/cassette shots: landscape. **No fixed aspect ratio assumption.** |
| Sizes | Roughly 0.1–10 MB per file; `Replay16-Box&Contents.zip` alone is ~30 MB with 25 images |
| Resolution | Far above screen resolution — always downscale / fit, never decode at full size into a UI widget without bounds |
| Colour profile / metadata | Not audited; assume mixed sRGB, possibly unstripped EXIF |

For a UI consumer: decode with bounds (thumbnail for grids, fit-to-viewport
for the lightbox), keep aspect ratio, letterbox. Do not generate derived
crops — a box front is shown whole.

---

## 6. Edge Cases & Outliers (All Verified)

### 6.1 `Replay16-Box&Contents.zip` — a "box contents" archive, not a scan set

The only multi-level, non-scan archive found. Structure:

```
Replay 16 - Box & Contents/
  Box/
  Sampler Cartridge/
  User Guide (1992)/
  Xmas 1993 Brochure & Order Form (300dpi)/
  Floppy Disk Wallet & Disks/
    Microdeal Replay 16 Software Package v1.0 (1992)/
      Drumbeat.MSA  Editor.MSA  MIDIplay.MSA  Samples.MSA  Readme.txt
```

25 images plus **4 `.MSA` disk images** and a `Readme.txt`. A naive
"collect all files and launch/show them" consumer would offer disk images
as if they were scans. Filter by extension (section 3.3) — this archive is
the reason the filter must be recursive and extension-based, not
"one folder, then list files".

### 6.2 Non-image files inside `Boxscan/`

`Prodigy Midi Sequencer/Boxscan/` contains 7 loose PDFs (manual + adverts)
and 3 images — a manual misfiled as Boxscan. A box-scan consumer showing
"all files" would render PDFs as broken images.

### 6.3 Missing / empty / vanished folders

- `Dragonflight/Boxscan/` was present in one directory listing and gone on
  the next (live Dropbox sync on the NAS). Consumers must treat a vanished
  folder between scan and read as empty, not as a fatal error.
- Some `Manual/` folders contain only a non-ZIP file (the `.rar` in 3.4).

### 6.4 Name collisions and odd characters

- File names with **spaces** (`captain blood_pocketsoft_front.png`), `&`
  (`Replay16-Box&Contents.zip`), parentheses, hyphens, commas.
- Case collisions possible (`GUNSHIP_fre_F.png` vs `GUNSHIP_fre_b.png` —
  mixed case within one folder). Never lowercase a path before using it on a
  case-sensitive filesystem.
- One `Manual/` folder is spelled `Manuals/` (3.2) — case-insensitive
  matching alone does not cover it; accept both singular and plural.

### 6.5 Hidden files and NAS metadata

`@eaDir` (Synology) folders exist next to the game trees. They are hidden
and must be skipped, matching the launcher's existing hidden-file filter.

---

## 7. Current Consumer Behavior (as of this writing)

### 7.1 Console launcher

`OverlayDirectoryBrowser` lists **all** non-hidden directories and `*.zip`
files. `Boxscan/` and `Manual/` therefore appear as navigable folders, and
the edition ZIPs inside them appear as launchable entries — pressing Enter
on `Boxscan/elite_v101.zip` would hand a box-scan archive to Hatari. Only
loose non-ZIP files (PDFs, PNGs) are invisible, which is why
`demo.sh` states "PDFs — should NOT appear". There is currently **no**
`Boxscan`/`Manual` exclusion in the console launcher.

### 7.2 Tools

- `tools/screenshot-gen`: explicitly excludes `boxscan`, `manual`,
  `kryoflux` via `exclude_dirs` — correct, these titles have no game output.
- `tools/gallery` / `apps/marcer_desktop`: expose a **`boxscan` tri-state
  facet** (`any`/`yes`/`no`) sourced from XLS column 10
  (`ANALYSIS-game-data.md` section 3). This flag is metadata only — **no
  tool reads the actual scan images today.** The flag and the folder are
  independent signals: a title can carry the XLS flag without a `Boxscan/`
  folder and vice versa.

---

## 8. Requirements For A Consumer (Flutter Desktop App)

Derived directly from sections 2–6:

1. **Discovery** — for each game folder, look for child directories named
   `boxscan` / `box scan` / `manual` / `manuals`, case-insensitively, in
   **both** layers; merge via the overlay rules of `SPEC.md` section 7.
2. **Payload collection** — inside a `Boxscan/` folder: collect loose
   image files (`.png`, `.jpg`, `.jpeg`, case-insensitive) plus, recursively
   inside every nested `.zip`, all image files. Ignore everything else
   (`.pdf`, `.msa`, `.txt`, `.rar`, directories themselves). Do not assume a
   container folder; handle flat and nested ZIPs, and one optional edition
   directory level.
3. **Edition grouping** — group collected images by their immediate parent
   (container folder inside a ZIP, edition subfolder, or the `Boxscan/` folder
   itself for loose files); use the ZIP stem as the edition label for
   archived sets.
4. **Display** — thumbnails with bounded decode, aspect-preserving fit,
   no fixed aspect assumption (section 5); an ordered gallery per edition
   (front-first where inferable, otherwise name order).
5. **Manuals** — for `Manual/`: collect loose PDFs plus PDFs inside ZIPs;
   show as documents (open externally / built-in viewer), not as images.
   Tolerate RAR and other formats by skipping with a note.
6. **Robustness** — case-insensitive matching everywhere; paths with spaces,
   `&`, parentheses; tolerate folders vanishing mid-scan (6.3); skip hidden
   entries (`@eaDir`); never assume names carry front/back semantics.
7. **Scope control** — the assets are large (10s of MB per game). Index
   paths lazily; do not pre-extract or pre-decode archives at startup.
8. **Independence from the XLS flag** — decide explicitly whether the
   `Boxscan` facet should become "has images" (folder-based) or stay
   "XLS says yes" (metadata). Recommended: keep the XLS facet as-is and add
   a separate, derived "scans available" badge so neither signal is lost.

### 8.1 Console-launcher follow-up (separate change)

Consider excluding `Boxscan/`, `Manual/`, `Kryoflux/` and similar companion
folders from the console navigation (7.1), so scan archives can no longer be
launched with Hatari. This is a `SPEC.md` behavior change and needs its own
spec + README update.

---

## 9. Open Questions

- [ ] Should box scans be readable offline only, or also cached/extracted
      into `MARCER_DATA_DIR` alongside `games-*.json`?
- [ ] Should the edition grouping surface as a UI facet (publisher/region of
      the *scan*) or only as a gallery tab per game?
- [ ] `Manuals` plural (1 case) — fix the data, or keep supporting both
      spellings forever?
- [ ] The ~7 % ZIP-only and ~1 % mixed Boxscan folders in the patch layer:
      are more ZIPs planned, or is loose-image the long-term convention?
- [ ] Console launcher: exclude companion folders (8.1) — yes/no?

---

## 10. Verification Method

All counts and shapes in sections 2–4 were produced by read-only shell
inspection (`find`, `ls`, `unzip -l` / `unzip -Z1`) against the real archive
on 2026-10-14:

- Full enumeration of `Boxscan/` and `Manual/`/`Manuals/` directories in both
  layers (name matching via `find -iname`).
- Per-folder classification (loose images vs. ZIPs vs. subfolders).
- Central directory listing of **all 29** patch-layer Boxscan ZIPs
  (`unzip -Z1`) — no archives were extracted or modified.

Re-verification: re-run the same listings; counts are expected to grow, the
*structural variants* (sections 3–6) should not.

---

## Conformance Checklist (for the future consumer)

- [ ] Finds `Boxscan`/`boxscan`/`Box Scan` and `Manual`/`Manuals`
      case-insensitively in both layers
- [ ] Merges root + patch assets per `SPEC.md` section 7
- [ ] Collects loose images and recursive in-ZIP images; ignores PDFs/MSA/TXT/other
- [ ] Handles flat ZIPs, container-folder ZIPs, and multi-level ZIPs
- [ ] Handles one optional edition-directory level with label inheritance
- [ ] Shows images aspect-preserving with bounded decode; no fixed aspect ratio
- [ ] Shows manuals as documents; tolerates RAR by skipping
- [ ] Survives paths with spaces / `&` / parentheses and vanishing folders
- [ ] Skips hidden entries (`@eaDir`)
- [ ] Does not conflate the XLS `Boxscan` flag with on-disk availability
