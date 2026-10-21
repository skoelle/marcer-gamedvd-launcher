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

### 3.4 Manual folders — shape distribution

| Layer | Game folders | `Manual/` | Loose files outside ZIPs |
|---|---|---|---|
| Main (`<ROOT>/Title Sorted/`) | ~9,994 | ~547 | **none** — everything is wrapped in ZIPs |
| Patch (`<PATCH>/Title Sorted/`) | ~5,299 | ~18 | PDFs, one GIF, one RAR |

Main layer, ZIP count per folder (n=547, 1,125 ZIPs total):

| ZIPs per folder | Folders |
|---|---|
| 1 | 98 |
| 2 | 370 (the dominant shape — a scan/text pair) |
| 3 | 43 |
| 4 | 28 |
| 5–8 | 8 |

### 3.5 The scan/text pair (main layer, the dominant pattern)

438 of 547 main-layer `Manual/` folders follow one pattern: **two ZIPs with
the same stem, one holding the image scan, one holding a text-layer PDF of
the same manual**:

```
Alien Syndrome/Manual/
  Alien Syndrome.zip       → Alien Syndrome.pdf         (image scan)
  Alien Syndrome_text.zip  → Alien Syndrome_text.pdf    (text-layer variant)
```

Verified counts across all 547 main-layer folders:

| Category | Count |
|---|---|
| ZIPs whose name does **not** end in `_text` (scan side) | 661 |
| ZIPs ending in `_text` / `_TEXT` / `_Text` (text side) | 464 |
| Orphan `_text` ZIPs with no matching scan ZIP | 5 (Epic, Gunship, Legend, Utopia, Warhead) |
| Folders with a pair | 438 |
| Folders with scan-only ZIPs (no text variant) | 109 |

**Size relation:** the scan PDF is usually larger than the text PDF
(`Elite.zip` 5.6 MB vs `Elite_text.zip` 2.1 MB), but not always
(`Chaos Strikes Back` — both ~1.38 MB). Do not use size to detect the
variant; use the `_text` stem suffix.

**Patch layer:** only 3 of 18 folders use the pair (`Beach Volley`,
`Conflict Europe`, `Little Puff in Dragonland`) — the patch layer is
younger and does not systematically carry text variants.

### 3.6 Inside the Manual ZIPs

**Almost always exactly one file per ZIP.** Content types, main layer
(sample of 200 folders / ~300 ZIPs, central directory only):

| Extension | Count | Meaning |
|---|---|---|
| `.pdf` | 378 | The manual (scan or text-layer) — the normal case |
| `.doc` | 35 | Original Atari ST document files (1980s/90s DTP format) |
| `.jpg` | 21 | Manual pages stored as images instead of PDF (rare) |
| `.txt` | 14 | Plain text |

Patch layer, the less uniform one:

| Extension / shape | Where |
|---|---|
| `.pdf` inside ZIP | most folders |
| loose `.pdf` | Daata Sound, Music Mouse, Tiger Cub |
| `.TXT` inside ZIP | `AIRBUS_E.zip` → `AIRBUS_E.TXT` |
| `.DOC` inside ZIP | `BEACHVOL.zip`, `GFATHER.zip`, `mtp_doc.zip` → `MTPRO.DOC` |
| `.msa` inside ZIP | **floppy disk images**, not documents: BBS Express ST, Crack Art, LDW Power, MidiTrack Platinum, Regent Base 2 |
| `.CDK` inside ZIP | `Midiman…/DOC/TMCHAP1.CDK` … `TMCHAP9.CDK` (one chapter per file) |
| `.hyp` / `.ref` / `.stg` inside ZIP | `Boxkite/bkit233_.zip` — ST SuperCard/Hi-Pascal online-help format |
| `.htm` + `.pdf` + `.DOC/` | `Master Tracks Pro 3.6 User Manual.zip` — a mixed archive |
| loose `.gif` | `Music Mouse/Atari_MM_KeyMap.gif` — a keymap image |
| loose `.rar` | `Avalon - Steinberg/Atari-Steinberg-Avalon-2.0-Manual.rar` — not a ZIP at all |

**Rule:** a Manual consumer must (a) open ZIPs and pick PDFs, (b) tolerate
loose PDFs, (c) treat `.msa` as a *disk image* (not a document — it belongs
to the game-data side, not the manual viewer), (d) skip RAR and unknown
formats gracefully with a note. A `_text` ZIP stem identifies the
text-layer variant of a paired manual (section 3.5).

### 3.7 Manual outlier: image-based manuals

Two main-layer folders hold **JPG page scans** instead of a PDF, using the
same `_d7` / `_i` naming as box scans (section 4.3):

```
Aaargh/Manual/aaargh_melbourne_house.zip
  aaargh_melbourne_house_d7.jpg, _d7_2.jpg, _d7_3.jpg
  aaargh_melbourne_house_i.jpg,  _i_2.jpg … _i_10.jpg     (13 files total)
Bad Cat/Manual/bad_cat_highlights (2).zip
  bad_cat_highlights_i.jpg, _d7.jpg, _d7_2.jpg, _d7_3.jpg  (4 files)
```

These are inlay/multi-page scans: the `_d7*` group is the box-style pages,
the `_i*` group the inlay pages. A manual viewer that only renders PDFs
would show nothing here — the consumer must fall back to the image gallery
path (section 8, requirement 4) for these.

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
- Some `Manual/` folders contain only a non-ZIP file (the `.rar` in 3.6).
- Five `_text` scan pairs are broken: `Epic`, `Gunship`, `Legend`,
  `Utopia`, `Warhead` have an `_text.zip` but no matching scan ZIP
  (section 3.5). A consumer pairing by stem must not assume the other half
  exists.

### 6.4 Disk images inside `Manual/` (patch layer)

Five patch-layer `Manual/` ZIPs contain `.msa` **floppy disk images**
(BBS Express ST, Crack Art, LDW Power, MidiTrack Platinum, Regent Base 2).
These are not documents — they are the original manual *disks*. A consumer
must never hand them to a PDF viewer, and (per `SPEC.md`) never offer them
as launchable game archives either. The same applies to the four `.MSA`
files inside `Replay16-Box&Contents.zip` (6.1). Recommended handling: skip
with an "original disk" note, or route to the dump side of the app later.

### 6.5 Name collisions and odd characters

- File names with **spaces** (`captain blood_pocketsoft_front.png`), `&`
  (`Replay16-Box&Contents.zip`), parentheses, hyphens, commas.
- Case collisions possible (`GUNSHIP_fre_F.png` vs `GUNSHIP_fre_b.png` —
  mixed case within one folder). Never lowercase a path before using it on a
  case-sensitive filesystem.
- One `Manual/` folder is spelled `Manuals/` (3.2) — case-insensitive
  matching alone does not cover it; accept both singular and plural.
- ZIP stems with commas or 8.3-style names: `Addams Family, The.zip`,
  `AMBER.ZIP` → `AMBER.DOC`, `CAPTIVE.DOC.zip` → `CAPTIVE.DOC`
  (an archive named after its content's extension — do not parse the
  extension from the ZIP name, read the central directory).

### 6.6 Hidden files and NAS metadata

`@eaDir` (Synology) folders exist next to the game trees. They are hidden
and must be skipped, matching the launcher's existing hidden-file filter.

---

## 7. Current Consumer Behavior (as of this writing)

### 7.1 Console launcher

`OverlayDirectoryBrowser` lists **all** non-hidden directories and `*.zip`
files. `Boxscan/` and `Manual/` therefore appear as navigable folders, and
the edition ZIPs inside them appear as entries like any other ZIP. Only
loose non-ZIP files (PDFs, PNGs) are invisible, which is why
`demo.sh` states "PDFs — should NOT appear".

### 7.2 Tools

- `tools/screenshot-gen`: explicitly excludes `boxscan`, `manual`,
  `kryoflux` via `exclude_dirs` — correct, these titles have no game output.
- `tools/gallery` / `apps/marcer_desktop`: expose a **`boxscan` tri-state
  facet** (`any`/`yes`/`no`) sourced from XLS column 10
  (`ANALYSIS-game-data.md` section 3). This flag is metadata only; the
  desktop app additionally reads the actual scan images through the
  `Box scans`/`Manuals` chips (section 8). The flag and the folder are
  independent signals: a title can carry the XLS flag without a `Boxscan/`
  folder and vice versa.

---

## 8. Requirements For A Consumer (Flutter Desktop App)

> **Desktop app status (2026-10-21): implemented lazily per selected card.**
> `lib/local_assets.dart` discovers both layers (case-insensitive `Boxscan`/
> `Manual`/`Manuals`), lists loose files and ZIP central directories in a
> background isolate and materializes media on demand into a session temp cache
> under `<system temp>/marcer_local_assets_<pid>/` (no automatic cleanup;
> nothing persisted across runs); `GameInfoPanel` shows
> `Box scans (N)`/`Manuals (N)` chips
> (`lib/widgets/local_assets_chips.dart`, `local_assets_dialog.dart`). Box
> scans open an edition gallery + viewer; manuals group scan/text pairs, open
> PDFs/DOC/TXT in the OS default app, show image-page manuals in the viewer and
> `.msa` as info-only; RAR/unknown formats are skipped silently. See the
> desktop README "Box scans & manuals".

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
3. **Edition grouping** — group loose images by their first subfolder inside
   `Boxscan/` (or by the `Boxscan/` folder itself); group archived sets by
   the ZIP stem (the edition label, section 4.6), regardless of an optional
   container folder inside the ZIP.
4. **Display** — thumbnails with bounded decode, aspect-preserving fit,
   no fixed aspect assumption (section 5); an ordered gallery per edition
   (front-first where inferable, otherwise name order). The same image
   path must also serve the image-based manuals of section 3.7.
5. **Manuals** — for `Manual/`: pair `<stem>.zip` with `<stem>_text.zip`
   by stem (3.5) and expose both variants to the user (scan = visual,
   `_text` = selectable text); inside each ZIP take the PDF (or the JPGs,
   3.7). Loose PDFs count too. `.msa`/`.MSA` entries are **disk images**,
   not documents (6.4) — never show them in a PDF viewer. RAR and unknown
   formats are skipped silently (no UI note is shown).
6. **Robustness** — case-insensitive matching everywhere; paths with spaces,
   `&`, commas, parentheses; tolerate folders vanishing mid-scan (6.3);
   tolerate half-broken scan/text pairs (6.3); skip hidden entries
   (`@eaDir`); never assume names carry front/back semantics.
7. **Scope control** — the assets are large (10s of MB per game). Index
   paths lazily; do not pre-extract or pre-decode archives at startup.
8. **Independence from the XLS flag** — the XLS facet stays "XLS says yes"
   (metadata); on-disk availability is surfaced separately by the per-card
   `Box scans`/`Manuals` chips (no grid badge). The two signals are never
   merged.

---

## 9. Open Questions

The desktop implementation (2026-10-21) answered the consumer questions below;
the product/data questions that remain are listed separately.

**Answered by the implementation:**
- [x] Box scans are read-only and extracted on demand into a session temp
      cache (`<system temp>/marcer_local_assets_<pid>/`); nothing is copied
      into `MARCER_DATA_DIR` and nothing is persisted across runs.
- [x] Manuals expose both the scan and the `_text` variant; the 5 half-broken
      pairs are tolerated (the existing half is shown alone).
- [x] The five `.msa` manual disks are shown as info-only disk images and are
      never opened as documents.

**Still open (product/data decisions):**
- [ ] Should the edition grouping surface as a UI facet (publisher/region of
      the *scan*) or stay a gallery tab per game? (currently: gallery per game)
- [ ] `Manuals` plural (1 case) — fix the data, or keep supporting both
      spellings forever? (the app already supports both)
- [ ] The ~7 % ZIP-only and ~1 % mixed Boxscan folders in the patch layer:
      are more ZIPs planned, or is loose-image the long-term convention?

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
- Central directory listing of **all 18** patch-layer Manual folders and a
  sample of **200** main-layer Manual folders; full stem-pairing check over
  all 547 main-layer Manual folders (scan vs `_text`).

Re-verification: re-run the same listings; counts are expected to grow, the
*structural variants* (sections 3–6) should not.

---

## Conformance Checklist (verified against the desktop implementation)

Checked against `apps/marcer_desktop/lib/local_assets.dart` on 2026-10-21.

- [x] Finds `Boxscan`/`boxscan`/`Box Scan` and `Manual`/`Manuals`
      case-insensitively in both layers
- [x] Merges root + patch assets per `SPEC.md` section 7 (patch wins)
- [x] Collects loose images and recursive in-ZIP images; ignores PDFs/MSA/TXT/other
- [x] Handles flat ZIPs, container-folder ZIPs, and multi-level ZIPs
- [x] Handles one optional edition-directory level with label inheritance
      (loose subfolders: first directory segment; ZIP contents: ZIP stem)
- [x] Shows images aspect-preserving with bounded decode; no fixed aspect ratio
- [x] Pairs manual `<stem>.zip` with `<stem>_text.zip`; tolerates missing halves
- [x] Renders manual PDFs **and** image-page manuals (JPG-in-ZIP, 3.7)
- [x] Never treats `.msa`/`.MSA` as documents or launchable archives (6.4)
- [x] Skips RAR / unknown formats in `Manual/` silently (no UI note)
- [x] Survives paths with spaces / `&` / commas / parentheses and vanishing folders
- [x] Skips hidden entries (`@eaDir`)
- [x] Does not conflate the XLS `Boxscan` flag with on-disk availability
