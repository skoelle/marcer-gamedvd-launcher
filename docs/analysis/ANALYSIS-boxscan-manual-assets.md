# ANALYSIS: Boxscan & Manual Asset Structure (Marcer GameDVD)

Structural analysis of the `Boxscan/` and `Manual/` companion folders that live
next to the game ZIPs in the archive. This document records the **external data
reality** only; the consumer behavior is specified in
[`SPEC-desktop.md`](../specs/SPEC-desktop.md) §"Box scans & manuals".

**Status of verified facts:** sections 2–5 were verified by read-only
directory listings and ZIP central-directory inspection. Counts are
order-of-magnitude and grow over time; the *structural variants* are the
contract, not the numbers. Paths come from the git-ignored `local/paths.env`.

**Related documents:**
- [`ANALYSIS-game-data.md`](ANALYSIS-game-data.md) — XLS metadata model
- [`SPEC-launcher.md`](../specs/SPEC-launcher.md) — overlay/navigation rules
- [`SPEC-desktop.md`](../specs/SPEC-desktop.md) — box-scan/manual UI behavior

---

## 1. Purpose and Scope

Document where box scans and manuals live, which structural variants and naming
schemes occur, and which edge cases a consumer must tolerate.

Out of scope: the UI implementation, scan provenance/quality, and the XLS
`Boxscan` flag (metadata only, see `ANALYSIS-game-data.md`).

Path symbols: `MARCER_ROOT_DIR` (main layer), `MARCER_PATCH_DIR` (patch layer),
`<LAYER>` for either layer.

---

## 2. Where The Assets Live

Both layers share this shape:

```
<TITLE-SORTED>/
  <Category>/                       # "Cracked Games - Title Sorted", "PD Games - Title Sorted", …
    <Letter>/
      <Game Name>/
        <Game>.zip                  # launchable game archive(s)
        Boxscan/                    # OPTIONAL — box scans
        Manual/                     # OPTIONAL — manuals
        Original/  IPF/  RAW/  STX/  Kryoflux/  …   # other companion folders
```

`Boxscan/` and `Manual/` are **direct children of the game folder**, siblings of
the game ZIPs. Most game folders have neither.

Folder name variants (match case-insensitively, accept an optional space):

| Folder | Accepted spellings |
|---|---|
| Box scans | `Boxscan`, `boxscan`, `Box Scan` |
| Manuals | `Manual`, `Manuals` |

Do **not** match game-folder names that merely contain the word "box"
(`Boxkite`, `Boxing Champ`, `Box to the Dragon…`).

They are ordinary directories, so the overlay rules of `SPEC-launcher.md` §7
apply: same relative folder name in both layers merges into one entry and the
patch layer wins for file resolution. Both layers usually contribute different
*files* to the same folder, so a consumer that reads only one layer misses
assets.

---

## 3. Content Inventory

### 3.1 Boxscan payload kinds

| Kind | Extensions | Meaning |
|---|---|---|
| Loose images | `.png`, `.jpg` | Scans stored directly in the folder (dominant shape) |
| Archives | `.zip` | One ZIP per edition/publisher, each holding that edition's scans |
| Stray documents | `.pdf` | Rare; a manual/advert accidentally placed in `Boxscan/` |

A `Boxscan/` ZIP either has exactly one top-level container folder (whose name
may differ from the game folder) or stores the images flat at archive root.
A robust rule: recursively collect image files, ignore everything else, and do
not assume a container depth.

### 3.2 Manual payload kinds

- **Main layer:** everything is wrapped in ZIPs. The dominant pattern is a
  **scan/text pair** with the same stem:

  ```
  Alien Syndrome/Manual/
    Alien Syndrome.zip       → Alien Syndrome.pdf         (image scan)
    Alien Syndrome_text.zip  → Alien Syndrome_text.pdf    (text-layer variant)
  ```

  The `_text` / `_TEXT` / `_Text` stem suffix identifies the text variant. Do
  not use file size to distinguish them. A small number of `_text` ZIPs have no
  matching scan ZIP (e.g. Epic, Gunship, Legend, Utopia, Warhead) — pairing must
  tolerate a missing half.
- **Patch layer:** less uniform — mostly ZIPs with a PDF, plus a few loose PDFs,
  one GIF, one RAR and some `_text` pairs.

Inside a manual ZIP there is almost always exactly one file:

| Extension | Meaning |
|---|---|
| `.pdf` | The manual (scan or text layer) — the normal case |
| `.doc` | Original Atari ST document (DTP format) |
| `.txt` | Plain text |
| `.jpg` | Manual pages stored as images instead of PDF (rare) |
| `.msa` | **Floppy disk image**, not a document (see 5.4) |
| `.cdk`, `.hyp`, `.ref`, `.stg`, `.htm` | Rare format outliers |

**Rule:** open ZIPs and pick PDFs; tolerate loose PDFs; treat `.msa` as a disk
image; skip RAR/unknown formats gracefully.

### 3.3 Image-based manuals

A few folders hold JPG page scans instead of a PDF, using the same `_d7` / `_i`
naming as box scans (see 4.3):

```
Aaargh/Manual/aaargh_melbourne_house.zip
  aaargh_melbourne_house_d7.jpg, _d7_2.jpg, …  (box-style pages)
  aaargh_melbourne_house_i.jpg,  _i_2.jpg …     (inlay pages)
```

A viewer that only renders PDFs would show nothing here; fall back to the image
gallery path.

---

## 4. File Naming Conventions

Names are **not** systematic; four generations coexist. Do not parse names for
meaning beyond the explicit ordering markers below; order by name or edition
label.

### 4.1 `bild### (2).jpg` — legacy scan-archive export

Sequential scan-archive IDs, almost always inside a container folder, always
`.jpg`. Carries no front/back information; order inside the archive is the only
hint (front usually first).

### 4.2 `<game>_<edition>_<side>.png` — descriptive PNG

Lowercase, underscores, optional publisher and language/region token
(`actionf_mind_front.png`, `amberstar_ger_back.png`,
`atomix_e-fr_front.png`). Side markers seen: `front`, `back`, `f`, `b`, `ba`,
`fro`, and `fr` (ambiguous: front in old names, but also a language token —
never use `fr` as a side marker).

### 4.3 `<game>_<publisher>_d7.jpg` / `_d7_2.jpg` — disc-style JPG pair

A pair (or triple) per edition; `_d7` is the first image, `_d7_2`/`_d7_3` the
following ones. Front/back order is **not** encoded in the name — treat the set
as an ordered gallery.

### 4.4 Special tokens

| Token | Meaning |
|---|---|
| `_comic_` + `_p1`…`_p4` | Multi-page comic/inlay scan |
| `_ger_`, `_de_`, `_fr_`, `_fre_`, `_e-fr_` | Language/region of that edition |
| `_v101_`, `_v102_`, … | Game version the scan belongs to |
| `kixx`, `ftl`, `rainbird`, `mirrorsoft`, `grandslam`, … | Publisher/label of that edition |

### 4.5 Edition folders inside `Boxscan/`

Some games group their scans into edition subfolders:

```
Gunship/Boxscan/
  gunship_b.png, gunship_f.png            # loose, unlabelled edition
  Frenchbox/  GUNSHIP_fre_b.png, … , Gunship (orange box) (FR) (Atari St).zip
  Greybox v1/ GUNSHIP_02_B.png, GUNSHIP_02_F.png
  Redbox/     gunship_b.png, gunship_f.png, gunship_back.png, gunship_front.png
```

The inconsistencies are deliberate data reality: loose files coexist with
edition folders, names may contain spaces, and the same front/back can appear
twice under different names. Treat one directory level below `Boxscan/` as an
optional **edition label**; images inherit that label. Do not dedupe by content
or inferred side.

### 4.6 ZIP file names = edition labels

The Boxscan ZIP name identifies the edition/publisher:

```
Aussie Joker Poker (NA) (Atari St).zip        # region + platform
Bermuda Project (NA) (Atari St) - Microdeal.zip
Chambers of Shaolin - Grandslam - UK.zip       # publisher + region
Rainbird - bluebox.zip / Rainbird - Whitebox.zip   # label variant
elite_v101.zip / elite_v102.zip                # game version
Replay16-Box&Contents.zip                      # free-form
```

Treat the whole stem as the edition label; do not parse it further unless a
region/publisher facet is needed.

---

## 5. Edge Cases & Outliers

### 5.1 `Replay16-Box&Contents.zip` — box contents, not a scan set

The only multi-level, non-scan archive found. It contains box pages, a sampler
cartridge, a user guide, a brochure, a disk wallet — 25 images plus **4 `.MSA`
disk images** and a `Readme.txt`. Filter recursively by extension, otherwise
disk images are offered as scans.

### 5.2 Non-image files inside `Boxscan/`

At least one folder (`Prodigy Midi Sequencer/Boxscan/`) contains loose PDFs
(manual + adverts) next to images. A consumer showing "all files" would render
PDFs as broken images.

### 5.3 Missing / empty / vanished folders

Folders can vanish between listing and read (live NAS/Dropbox sync). Treat a
vanished folder as empty, not as a fatal error. Some `Manual/` folders contain
only a non-ZIP file (a `.rar`); some `_text` pairs are incomplete (3.2).

### 5.4 Disk images inside `Manual/`

Some patch-layer manual ZIPs contain `.msa` **floppy disk images** — the
original manual disks. Never hand them to a PDF viewer and never offer them as
launchable game archives; skip them with an "original disk" note or route them
to the dump side later.

### 5.5 Name collisions and odd characters

- Spaces (`captain blood_pocketsoft_front.png`), `&`
  (`Replay16-Box&Contents.zip`), parentheses, hyphens, commas.
- Case collisions are possible (`GUNSHIP_fre_F.png` vs `GUNSHIP_fre_b.png`);
  never lowercase a path before using it on a case-sensitive filesystem.
- Accept both `Manual` and `Manuals`.
- ZIP names may be misleading (`CAPTIVE.DOC.zip` → `CAPTIVE.DOC`); read the
  central directory instead of parsing the extension from the ZIP name.

### 5.6 Hidden files and NAS metadata

`@eaDir` (Synology) folders exist next to the game trees. They are hidden and
must be skipped, matching the launcher's hidden-file filter.
