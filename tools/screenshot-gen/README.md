# Screenshot Generator

Generates preview screenshots for the Marcer GameDVD archive by booting each
ZIP in Hatari on a virtual X display. The result documents the actual **boot
state** of every ZIP (game, crack intro, TOS desktop, text screen or no usable
image) and the differences between release/crack variants — it is deliberately
not a collection of curated in-game or AtariLegend screenshots. See
[`SPEC-screenshot-generator.md`](../../docs/SPEC-screenshot-generator.md) for the
full specification.

## Requirements

- Hatari (verified with 2.4.1), Xvfb, `xdotool` (for the desktop click
  retry), Python 3 with the repo `.venv`
  (`Pillow`, `imagehash`, `numpy`, `scipy`)
- Environment in `local/paths.env` (git-ignored):
  `MARCER_ROOT_DIR`, `MARCER_PATCH_DIR`, `MARCER_OUT_DIR`, `MARCER_TOS_IMG`
  (default TOS 1.04), for the TOS-1.02 retry `MARCER_TOS102_IMG` and for the
  Falcon scope `MARCER_TOS404_IMG` (TOS 4.04).
  Optional `MARCER_DATA_DIR` (the gameinfo directory with
  `games-<scope>.json`) enables the `screen_format` monitor rules.

## Usage

```bash
tools/screenshot-gen/run.sh index          # build/refresh the zip index (default scope)
tools/screenshot-gen/run.sh run            # process pending entries (default scope)
tools/screenshot-gen/run.sh run --hours 8  # night run with time budget
tools/screenshot-gen/run.sh run --limit 3  # small test batch
tools/screenshot-gen/run.sh run --only Xevious   # only matching paths
tools/screenshot-gen/run.sh run --jobs 8   # parallel workers (e.g. night runs)
tools/screenshot-gen/run.sh run --retry-no-usable   # only no_usable_shots again

# Old titles that hang on TOS 1.04 (black screen -> no_usable_shots) but run
# on TOS 1.02: boot the no_usable entries with a non-default TOS. A successful
# capture records `tos: "1.02"` in the index/metadata (shown as a `TOS 1.02`
# badge in the gallery and desktop app, which then preselect the TOS 1.02
# Play variant); failed attempts are remembered in `tos_tried`.
tools/screenshot-gen/run.sh run --retry-no-usable --tos 1.02
tools/screenshot-gen/run.sh run --retry-no-usable --tos 1.02 --only Bellum

# Scopes: every command works on exactly one scope per invocation
# (default: the configured scope_default, see "Scopes" below).
tools/screenshot-gen/run.sh index --scope utils       # build index-utils.json
tools/screenshot-gen/run.sh run --scope utils --jobs 8 --limit 50
tools/screenshot-gen/run.sh detect --scope utils
tools/screenshot-gen/run.sh prune --scope utils
tools/screenshot-gen/run.sh index --scope pd          # build index-pd.json
tools/screenshot-gen/run.sh run --scope pd --jobs 4 --limit 16

# Desktop entries (game never started): find the GEM program icon in the
# existing desktop previews, then boot once more and click it:
tools/screenshot-gen/run.sh detect         # offline icon detection (no Hatari)
tools/screenshot-gen/run.sh run --retry-desktop   # click + capture (one attempt)
tools/screenshot-gen/run.sh run --scope magazine --retry-desktop-auto --jobs 4

# Remove blank white previews that only show Hatari's drive-LED overlay:
tools/screenshot-gen/run.sh cleanup-drive-led --dry-run   # report only
tools/screenshot-gen/run.sh cleanup-drive-led             # delete + flag
tools/screenshot-gen/run.sh run --retry-drive-led         # refetch the flagged bootable ones

# Remove pixel-exact duplicate candidates (offline, no Hatari):
tools/screenshot-gen/run.sh cleanup-duplicates --dry-run   # report only
tools/screenshot-gen/run.sh cleanup-duplicates             # delete + update index
tools/screenshot-gen/run.sh cleanup-duplicates --list      # print removed names
tools/screenshot-gen/run.sh cleanup-duplicates --candidates-only
tools/screenshot-gen/run.sh cleanup-duplicates --scope pd --only "10th Frame"

# Promote the application-window candidate of successful desktop retries
# (e.g. utils; offline, no Hatari):
tools/screenshot-gen/run.sh promote-app-screens --scope utils --dry-run --list
tools/screenshot-gen/run.sh promote-app-screens --scope utils
tools/screenshot-gen/run.sh promote-app-screens --scope utils --only Alvi

# Refine the entry kind of "desktop" entries (offline, no Hatari):
tools/screenshot-gen/run.sh reclassify --dry-run          # kind counts only
tools/screenshot-gen/run.sh reclassify                    # write index + JSON
tools/screenshot-gen/run.sh reclassify --list textscreen  # print matching paths

# Drop logs/empty output dirs of index entries that no longer exist
# (e.g. after excluding directories):
tools/screenshot-gen/run.sh prune --dry-run   # report only
tools/screenshot-gen/run.sh prune             # delete
```

Interrupt with Ctrl+C at any time. Progress is saved after every entry.
The first Ctrl+C asks the workers to finish their current entry; a second
Ctrl+C forces an immediate exit (the PID lock then remains stale and is
replaced on the next start). FIFO commands are non-blocking, so a crashed
Hatari can no longer leave workers hanging forever.
A later `run` skips completed entries (`done`, `desktop`, `no_usable_shots`)
and retries unfinished or failed ones (`pending`, `interrupted`, `timeout`,
`error`). The `no_usable_shots` entries are not retried by a normal run;
repeat them explicitly with `run --retry-no-usable`. A TOS version already
attempted via `--tos` is skipped on the next `run --retry-no-usable --tos`
invocation (recorded in `tos_tried`); `--force` retries it anyway.

## Scopes

The archive is processed in named **scopes** (config `scope_default` +
`scopes`). Every subcommand (`index`, `run`, `detect`, `reclassify`,
`cleanup-drive-led`, `cleanup-duplicates`, `promote-app-screens`, `prune`)
works on exactly one
scope per invocation,
selected with `--scope <name>`; without the flag the configured
`scope_default` (cracked) is used. There is deliberately no "all scopes"
mode — run the command once per scope.

Each scope has its own tree list and its own index file:

| Scope  | Trees (under root/patch)                   | Index file         |
|--------|--------------------------------------------|--------------------|
| `cracked` (default) | `Title Sorted/Cracked Games - Title Sorted` | `index.json`   |
| `utils` (`--scope utils`) | `Title Sorted/Utilitys - Title Sorted` | `index-utils.json` |
| `pd` (`--scope pd`) | `Title Sorted/PD Games - Title Sorted` | `index-pd.json`   |
| `magazine` (`--scope magazine`) | `Bonus/Magazine Cover Disks` | `index-magazine.json` |
| `falcon` (`--scope falcon`) | `Falcon 030/Title Sorted` | `index-falcon.json` |

The `magazine` scope additionally sets `"exclude_dirs": ["dupes"]` so the
per-magazine `Dupes/` sub-folders (alternate dumps) never reach the index;
the scope-specific list is merged with the global `exclude_dirs`. It also
sets `"boot": "auto"`: cover disks that are GEMDOS file collections (e.g.
ST Computer) are extracted and their largest program autostarted with
`-d` + `--auto` (floppy-image disks keep `--disk-a`).

The `falcon` scope runs Hatari as a Falcon (`scopes.falcon.profile`:
`machine falcon`, 14 MB, `--dsp emu`, Videl RGB, CPU 16 MHz) with its own
TOS 4.04 (`MARCER_TOS404_IMG`) and its own timepoints (`[15, 30, 60]`).
Falcon titles are mostly GEMDOS hard-disk archives, so they are extracted
and booted with `-d` + `--auto` (a picked boot program) and the floppy drives
disabled (`--drive-a off --drive-b off`, otherwise TOS 4.04 shows a blocking
"Drive A:" dialog). The boot pick skips STZip self-extractors and prefers a
numbered set's lowest part. ZIPs holding a single floppy image use `--disk-a`;
two images are mounted as drive A/B. The ST `--mono` logic does not apply to
the Videl.

The default scope always maps to `index.json` — that is the file the
gallery and the desktop app read (the cracked view); other scope index
files were invisible to them until the `magazine`/`falcon` sections were
added (`index-magazine.json`, `index-falcon.json`, now read by both UIs).
Every other scope uses
`index-<name>.json`, overridable per scope with an explicit `"index"`
key. One scope never reads or writes another scope's index, so a utils
run cannot corrupt or bloat the curated cracked state (and each
per-entry index save stays small). Logs and mirror previews of all
scopes live side by side under `MARCER_OUT_DIR` (mirroring the source
tree, so the scope trees keep them separated). The output lock
(`shotgen.lock`) is shared: only one shotgen invocation runs at a time,
regardless of scope.

Root and patch layers are merged case-insensitively, like in the console
launcher: if the two layers hold the same ZIP under names that differ only
in case (e.g. `Crossbow - Medway boys.zip` vs. `Crossbow - Medway Boys.zip`),
they are **one** entry — the patch spelling wins, including for the preview
file name (see SPEC-screenshot-generator §4.1 and §10.2). The same applies to
**folder names**: a folder present in both layers under spellings that differ
only in case (root `…Prof Plays a New Game`, patch `…Prof Plays a new Game`)
is canonicalised to the patch spelling for *every* file below it, root-only
files included. Otherwise the mirror and log trees would grow two
case-variant sibling folders, which a case-insensitive NAS or sync client
renames into `…_DiskStation_…CaseConflict` folders while a run is writing
into them. Root-only entries still read their source from their own layer
spelling (index field `src_rel`); the canonical relative path stays the
output identity.

By default entries are processed one at a time. `--jobs N` runs N workers
in parallel; each worker boots its own Hatari instance on its **own Xvfb
display** (`:99`, `:100`, ...) and needs roughly 220 MB RAM and ~35% of one
CPU core. Separate displays are required for the click retry (Hatari only
tracks the mouse when its window has focus, so two instances on one display
would fight over the pointer). All index writes are serialized under a
lock, so parallel workers never overwrite each other's updates, and Ctrl+C
stops every worker after its current entry. Keep total CPU below ~90%,
otherwise the wall-clock screenshot timepoints may drift. `--jobs 1` (the
default) is the classic serial behavior.

### Desktop auto retry (`run --retry-desktop-auto`)

A click-free alternative to the GEM desktop click chain. It selects the
`desktop` entries and, before booting, finds the program to start:

- **GEMDOS archives** (Falcon, magazine ST-Computer): extract and autostart
  the largest program with `-d` + `--auto C:\…`.
- **Floppy images** (`.msa`/`.st`): the FAT12 directory is scanned in memory
  (MSA header + track RLE, standard BPB/FAT). A disk's own `AUTO/` program
  wins, else the largest launchable `.PRG`/`.TOS`/`.TTP`/`.APP`. Hatari is
  started with `--disk-a <image> --auto "A:\<path>"` (plus drive B for a
  second image). Self-extracting archives (LZH/STZip "SFX", which only unpack
  onto the write-protected floppy) are skipped.
- **Unreadable images** (`.stx`/`.ipf`, non-DOS disks, empty images) and
  SFX-only disks have no detectable program: the entry is marked
  `auto_retried` / `auto_result: no_program` and stays `desktop` (the
  `--retry-desktop` click path remains for those).

Completed attempts store `auto_retried`, `auto_result` and `auto_program`;
`--force` re-runs them. No `xdotool`/`detect` run is required.

### Desktop click retry (`detect` + `run --retry-desktop`)

Some ZIPs boot to the GEM desktop because the program icon was never
clicked. `detect` runs fully offline over all `desktop` entries: it
matches templates of the standard GEM icons (`assets/icon-prg.png` for a
program icon, `assets/icon-drive.png` for a DISKSTATION drive icon)
against each existing preview PNG (FFT normalized cross correlation, also
tries the inverted/selected icon). Every template is tried at the 1x scale
and as a binarized 0.5x variant, so the half-sized icons of native mono
high-res captures (`- Mono` folders) are found too; the best variant wins
(its `scale` is stored in `click`), but a smaller scale must beat the 1x
match by a margin (0.02) before it takes over so weak color false
positives keep their pixel. Hits are stored as `click` (strategy,
screenshot pixel of the icon center, score, scale) in the index; misses
are marked `icon_found: false` and are never booted again
(`detect --force` redoes them).

`run --retry-desktop` then selects only entries with `status: desktop`
and a stored `click` that have not been clicked yet (`click_retried`).
Per entry it boots Hatari, takes one probe screenshot at
`click_retry.probe_time` (default 10 s) and:

- if it shows the desktop: runs the click strategy, then restarts the
  normal capture timepoints (`click_retry.timepoints_after_click`) from
  that moment;
- if a game (or any non-desktop screen) is already running: no click,
  capture continues normally.

**Click strategies.** The X pointer is positioned on the icon via
`xdotool` (using the window geometry of the running Hatari instance); the
double click itself is sent with Hatari's own
`hatari-event doubleclick` command through the control FIFO, which GEM
registers far more reliably than XTest clicks. After each click the
pointer is parked on the empty part of the window title bar (row y=182),
because GEM's arrow stays where it was clicked and would otherwise cover
the icon of the following window (same grid cell) during template
matching. The park deliberately stays inside the window: a warp to the
window/screen edge (e.g. the bottom-right corner) makes Hatari's relative
mouse handling drift, after which every later click misses its icon.
`click_retry.window_icon_min_score` (0.80, the same bar for the 0.5x mono
variant — genuine mono icons score ~1.0 while a folder only reaches ~0.73
on the program template) tolerates the arrow if it does end up on an icon.

- `prg` — the desktop already shows the program icon: one double click
  starts the game.
- `drive` — the desktop only shows drive icons. The probe screenshot is
  checked for an already-open GEM window first; if one is open, the drive
  click is skipped and that window is enlarged before the icon scan. Only
  when no window is open is `DISKSTATION A` double clicked (wait
  `click_retry.step_wait`). After a drive click the program icon
  (`assets/icon-prg.png`) is checked first; only when it is absent is the
  window enlarged and scanned for the program icon, then the folder icon
  (`assets/icon-folder.png`), then scrolled. The window is then walked
  (bounded by `click_retry.drive_max_depth`, default 2): program icon
  first, otherwise the folder icon to descend, then scan again.

```text
Probe screenshot (10 s)
├─ GEM window already open?
│  ├─ yes → enlarge the window
│  │        → look for the PRG icon
│  │        → otherwise look for the folder icon
│  │        → otherwise scroll
│  └─ no  → click DISKSTATION A
│            → PRG visible?
│               ├─ yes → continue with the PRG click
│               └─ no  → enlarge the window
│                         → look for the PRG icon
│                         → otherwise look for the folder icon
│                         → otherwise scroll
└─ then as before: open folders, descend (max_depth)
```

**TTP launchers.** If a program click opens GEM's TTP command-line dialog
(`ANWENDUNG ÖFFNEN`, detected with `assets/ttp-dialog-title.png` /
`ttp-dialog-buttons.png`), the chain does **not** treat it as a started
program. It clicks `ABBRUCH` (`assets/ttp-dialog-abort.png`, single click),
waits for the dialog to close and tries the **next program icon in the same
window** (`click_retry.max_icon_attempts`, default 8). The same window is
searched; it does not backtrack to other folders. If every icon is a TTP
or never starts, the result is `click-failed`. Cancellation is retried up
to `click_retry.ttp_cancel_attempts` (default 2); a dialog that cannot be
closed aborts the chain. For the single-icon `prg` strategy the dialog is
also cancelled, but there is no alternate stored icon to try.

Both strategies verify their clicks (`click_retry.drive_attempts` /
`click_retry.prg_attempts` / `click_retry.folder_attempts`, default 3
each). The folder click is classified with the icon templates rather than
a global pixel diff, because opening a folder window changes only a few
percent of the screen when it looks similar to its parent (both are white
GEM windows) — the same order as a plain selection. A genuine program
icon (~1.0) at the clicked spot means the folder opened; the selected
(inverted) folder at the same spot only scores ~0.86 and counts as not
opened, so the click is retried. If the whole window changes and no GEM
icon is left, the game started directly from that click and the chain
reports success. The drive click is only repeated while the screen does
not change at all (the click never opened the window) — once its window
is open, clicking DISKSTATION again is pointless and is skipped. Between
the steps it waits `click_retry.step_wait` (default 5 s). Window icons
match their templates near 1.0, so `click_retry.window_icon_min_score`
(default 0.80) rejects the flat-region false positives that appear on
white window areas while still accepting the program icon with the GEM
arrow on it (~0.84).

**Hidden icons (grow / scroll).** A window can show fewer icons than the
folder contains, hiding the program behind a scrollbar. An already-open
window (no drive click) or a drive window without a visible PRG icon is
**grown first**; when an opened folder window later shows no program or
folder icon at all, the retry also **grows** it by single clicking its
"full size" box (its glyph centre in the
title bar, just left of the right border — a few pixels right of centre
misses the gadget; the mono profile opens folder views at ~half width) and
then **scrolls down** by clicking the vertical scrollbar's down arrow, up
to `click_retry.scroll_attempts` (default 4) times (the colour profile
opens wide windows that show only the first rows). Where the first box
click is ignored until the window is activated (headless SDL setups), it
falls back to a menu-bar click followed by two box clicks (the first
dismisses the menu, the second grows); this fallback only runs when the
first click did not change the screen. Both gadget positions are detected
from the window frame (`find_fullsize_xy` / `find_scroll_down_xy`), not
hard coded. This also stops an opened folder whose icons do not match (a
child window that looks like its parent) from being mistaken for a game
that started.

The attempt is recorded once per entry. `click_retried: true` marks that a
retry ran, and a new `click_result` field records how it ended:

- `click-icon-prg` — successful `prg` click (program started),
- `click-icon-drive` — successful `drive`-strategy chain (DISKSTATION A
  and/or an already-open window -> ... -> program started),
- `click-failed` — the strategy ran but no program start was confirmed,
- `click-not-needed` — the probe was already a game/other screen, no click
  was sent.

Success is judged by the click chain itself (the screen changes after the
program double click), not by the image classifier, so titles whose start
screen is not recognized as `game` (e.g. a 3-colour GEM dialog) still count
as a successful click. `--retry-desktop --force` allows a second attempt.

Each parallel worker runs on its own Xvfb display, so
`run --retry-desktop --jobs N` can safely click several titles at once.
Within a display the click sequence is serialized with a global lock and
raises its own Hatari window first; Hatari 2.4.1 has no `mousemove` control
command, which is why the real X pointer (XTest via `xdotool`) is used for
positioning.

### Candidate retention (`keep_candidates`)

When a previous preview is replaced, it is kept as an additional candidate
(`_cNN`) instead of being overwritten, and every intermediate click-chain
screenshot (drive window, folder window, program window) is kept as a
candidate too, so the path to a successful click stays traceable.

Entries that end as **`no_usable_shots`** keep their captures the same
way — the `black` shots the classifier rejected and the near-duplicates
the pHash pass would drop included, because nothing was usable and the
raw grabs are exactly what needs manual review. The **last** capture in
time order becomes the preview (copied to the canonical `<base>.png`, and
this happens even when `keep_candidates` is off); the earlier ones stay as
the `candidates` list (`_c01`, `_c02`, ... in capture order) and are
disjoint from the preview. No metadata JSON is written for such an entry.
A preview left over from an earlier `done`/`desktop` run of the same entry
is renamed to the next `_cNN` (the new last capture takes the
`<base>.png` slot) and that run's stale metadata JSON is deleted. Review
these entries in the desktop app or the gallery: status filter **no
usable shots**, then open the lightbox (`Enter` / click) to step through
the candidates; `M` swaps the shown candidate into the preview slot.

Candidate retention itself is gated on `keep_candidates` (default
`true`); with `false` such an entry keeps `candidates: []` but still gets
its preview. Note that dark shots are only classified `black` when they
are *also* structureless (`black_std_content_min` in `analyze_image`,
SPEC §8.1) — a dark crack intro on black survives and makes the entry
`done`.

### Exact duplicate candidates (`cleanup-duplicates`)

Repeated captures and the click chain can leave several candidates that show
exactly the same pixels. `cleanup-duplicates` is an offline pass (no Hatari)
that removes those duplicates per entry:

- Every candidate is decoded and compared by a **pixel-exact** signature
  (width, height and SHA-256 of the RGBA pixel data), never by pHash. PNGs
  with different compression or ancillary chunks but identical pixels count
  as duplicates; perceptually similar shots are left alone.
- The preview is the first image in the comparison order, so it is never
  deleted. A candidate that is pixel-identical to the preview is removed too;
  `--candidates-only` restricts the comparison to the candidates themselves.
- The first occurrence in the `candidates` list is kept, later identical
  files are deleted. The index entry and, when present, the per-entry
  metadata JSON get the shortened `candidates` list. Candidate names are not
  renumbered, so gaps in the `_cNN` series are normal after a cleanup.
- Missing or unreadable files are skipped and reported, never deleted. The
  preview, `status`, `kind` and `shots` history stay untouched, so the pass
  is also safe for `done` entries.
- `--dry-run` only reports; `--only <substring>` limits the pass; `--list`
  prints the removed names per entry. The output-dir lock is acquired, so it
  cannot run while a scan is active.
- While the pass is running it prints a compact progress line at most every
  10 seconds (`scanned/total`, changed entries, removed/would-remove files and
  the current entry), so even a long NAS pass shows that it is still working.

### Promoting application windows (`promote-app-screens`)

Utils often boot to a GEM desktop and show the actual application only in a
window after a successful desktop click retry. The mono classifier still
labels that window `desktop`/`textscreen` because it uses only two colors.
The offline `promote-app-screens` pass (no Hatari) fixes those entries:

- It checks **every** `status: desktop` entry with candidates, not only
  successful click retries. This also catches apps whose click was reported
  as `click-failed` but whose screenshot is still a valid application.
- It scans the candidate list **backwards** and skips everything that is
  not the application:
  - TTP command-line dialog (see below),
  - GEM drive/folder (file) window, detected via the fixed `A:\` title-path
    crop (`assets/gem-file-window.png`),
  - blank/black screens (`analyze_image` kind `black`),
  - the plain TOS desktop (known mono TOS 1.04 pHash).
  The last remaining candidate is promoted. There is no hard-coded candidate
  number: the app screen is `_c01`, `_c02` or `_c03` depending on the entry,
  and full-screen text applications are supported too.
- The chosen image is swapped with the preview exactly like the app's `M`
  curation: it becomes `<base>.png`, the old preview takes the chosen
  candidate's name (nothing is deleted). The index/metadata become
  `status: done` and `kind: game` (override with `--kind`).
- **TTP launchers are not apps.** A `.TTP` program opens GEM's
  "ANWENDUNG ÖFFNEN" command-line dialog (Name/Parameter/OK/ABBRUCH),
  which is also an open window. The dialog is detected by template
  matching (`assets/ttp-dialog-title.png` and
  `assets/ttp-dialog-buttons.png`, German TOS 1.04). An entry with a TTP
  candidate but no real app candidate is **not** promoted; it is reset to
  `status: desktop` / `kind: desktop`, so it no longer appears as
  `desktop textscreen`.
- `--dry-run` reports only, `--list` prints the chosen candidate per entry,
  `--only <substring>` limits the pass, and `--candidate N` (1-based) can
  promote a specific candidate for special cases (bypassing all filters).
- The summary reports `promoted`, `TTP reset`, `no app`, and skipped
  `file`/`blank`/`desktop` candidates. After a run,
  `cleanup-duplicates --scope utils` removes duplicates created by the swap.
  The file-window and plain-desktop templates are tuned to the German
  mono TOS 1.04 layout (`A:\` drive path).

### Drive-LED white screens (`--drive-led false`, `cleanup-drive-led`)

When the statusbar is hidden, Hatari paints a small green floppy drive LED
in the top-right corner. Titles that produce no game output (manuals, box
scans, raw dumps, and some data disks) therefore became a blank white
screen with only that green LED. The generator now always passes
`--drive-led false`, so new screenshots no longer contain it.

`analyze_image` reports a `drive_led` boolean (white background plus a green
block in the top-right corner) and `cleanup-drive-led` removes the old
affected images:

- preview is LED-white: the preview PNG, its LED-white candidates and the
  metadata JSON are deleted, the index entry is reset and flagged
  `drive_led: true`; bootable entries (a disk/program image in the ZIP) also
  get `drive_led_refetch: true`;
- only some candidates are LED-white: just those candidate PNGs are deleted,
  the preview, JSON and status stay untouched.

Nothing is ever deleted unless the detector identifies it as LED-white,
and entries with `status: done` are never touched at all: `done` is final
(see "Entry kinds" below), so a real game shot or a manual curation
decision can never be reset by this pass. `--dry-run` reports the counts
without changing anything; `--only
<substring>` limits the pass. The `drive_led_refetch` flag marks the entries
that a later pass should re-capture with the LED disabled:

```bash
tools/screenshot-gen/run.sh run --retry-drive-led   # re-capture with --drive-led false
```

`run --retry-drive-led` selects exactly the `status: desktop` entries that
carry `drive_led_refetch` and ignores the other desktop entries, so a plain
`run` never touches them by accident. When such an entry finally yields a
usable preview, `process_entry` clears `drive_led` and `drive_led_refetch`
again — the flag is a one-shot marker, not a permanent label.

A refetch that still shows nothing (uniform black **or** uniform white —
both are classified `black`) ends as `no_usable_shots`; its last shot
becomes the preview and the earlier ones are kept as `_cNN` candidates
(see "Candidate retention"). That is expected for titles whose disk really
produces no output: the blank LED-white placeholder of the old runs is
gone (fresh shots never carry an LED), and the entry can still be picked
up later with `run --retry-no-usable` (e.g. with longer timepoints).

Entries that were reset this way but contain **no** bootable disk/program
image (manuals, box scans, raw dumps, data-only ZIPs) can never produce a
game screenshot. They stay `status: desktop` with `kind: no_game_image`
instead of being re-captured endlessly.

### Entry kinds (`game`, `desktop`, `textscreen`, `darkscreen`)

Every processed entry carries a `kind` in the index and in its metadata
JSON:

- `game` — a real game screenshot was captured (status `done`).
- `desktop` — a genuine TOS desktop: the title never auto-started (status
  `desktop`).
- `textscreen` — a crack intro / text screen on a light background
  (`white_frac >= filters.textscreen_min_white`), i.e. a screen that only
  *looks* like a desktop to the coarse classifier (status `desktop`).
- `darkscreen` — the same on a darker or colored background (grey, blue,
  pink, split screens), everything that is neither green desktop nor
  light-background text (status `desktop`).
- `no_game_image` — the ZIP contains no bootable disk/program image, so no
  game screenshot is possible at all (status `desktop`, no preview). These
  entries are only produced by the `cleanup-drive-led` reset and are skipped
  by `run --retry-drive-led`.

The three desktop sub-kinds keep `status: desktop`, so `detect`,
`run --retry-desktop`, resume behavior and all index consumers behave
exactly as before — only `kind` tells them apart.

New captures are classified directly by `run`. Existing entries are
refined by the offline pass:

```bash
tools/screenshot-gen/run.sh reclassify --dry-run          # counts only
tools/screenshot-gen/run.sh reclassify                    # update index + JSON
tools/screenshot-gen/run.sh reclassify --list darkscreen  # print those paths
tools/screenshot-gen/run.sh reclassify --only Arkanoid    # restrict the pass
```

`--list` prints the entry paths of the given kind (honors `--only`), so the
categories can be reviewed directly. Entries without a preview PNG (the
drive-LED resets) cannot be classified, are skipped and reported as
`no preview`. Thresholds: `filters.desktop_green_frac_min` (0.02),
`filters.textscreen_min_white` (0.5) and `filters.white_pixel_min` (230).

### Status × kind combinations

The pipeline only ever writes these pairs: `done` + `game`, `desktop` +
`desktop` / `textscreen` / `darkscreen` / `null`, and `null` for every
other status (`no_usable_shots`, `skipped_disk_n`, `error`, `pending`,
`interrupted`, `timeout`).

The desktop app's manual curation (`C`) additionally writes `done` +
`textscreen` / `darkscreen` (and `desktop` + a sub-kind). **Never assume
`done` means `game`.** Such a pair is stable by design: every selector in
this tool (`run`, `detect`, `reclassify`, all `--retry-*`) works on
`status == desktop`, and `cleanup-drive-led` skips `done` explicitly.
Reversely, the app's `desktop text` / `desktop black` status filters are
strictly `status: desktop`, so a curated entry that moves to `done` leaves
those filters and shows up as a normal `done` card with its kind as text.
The full matrix is in `docs/SPEC-screenshot-generator.md` §10.5.

### Excluded directories

Some game folders contain sub-directories that never hold Hatari disk
images: `Boxscan`/`Box Scan` (box scans), `Manual` (manuals) and `Kryoflux`
(flux dumps, usually under `RAW`). These are listed in the config key
`exclude_dirs` (default `kryoflux`, `boxscan`, `manual`) and are never
entered during the index scan, so nothing inside them is indexed. Matching
is case-insensitive and ignores spaces/underscores/dashes, at any depth.
A scope may add its own list via `scopes.<name>.exclude_dirs` (merged with
the global list) — the `magazine` scope uses this for `dupes`.

After changing `exclude_dirs`, run `index` to rebuild the index (removed
entries are dropped automatically) and then `prune` to delete their
leftover logs and empty output directories.

## Monitor selection (Mono / Color)

Monitor mode is resolved per entry, in this order:

1. **Gameinfo `screen_format` rules** from `MARCER_DATA_DIR/games-<scope>.json`
   (read-only, optional). The game folder is matched below the scope tree,
   so ZIPs in `Original/` and other sub-directories still use their game
   folder's values.
   - **utils** (`screen_format_monitor.utils`): an explicit color hint
     (`Not Mono`, `Low`, `Mid`, `Medium`, `Color`/`Colour`) forces color;
     an explicit mono hint (`Mono`, `High`) forces mono; blank values and
     pure notes (`Modified`, `Translated`, `Serie`, `Crashes`, …) default to
     **mono**. Entries whose folder is missing from a successfully loaded
     `games-utils.json` also default to **mono** (utils-only). This is the
     archive's "mono unless noted" convention.
   - **pd** (`screen_format_monitor.pd`): mono only when **all** variants of
     the folder say `High` (pure high-resolution folders). Mixed values such
     as `High + Low` or `Med + High` stay color.
2. **Folder suffix** (`mono_dir_suffix`, default `"Mono"`): a game folder
   ending in `Mono` (e.g. `Abalone - Mono`) is mono when no gameinfo rule
   applies.
3. Otherwise color.

Mono boots Hatari with `--mono --tos-res high` (monochrome, forced
640x400); the decision and its source are logged per entry, and the
resulting `monitor: mono`/`color` is recorded in the index entry and the
metadata JSON. Missing `MARCER_DATA_DIR` or `games-<scope>.json` is not an
error: the suffix rule is used as fallback. The utils "missing folder"
default only applies when the gameinfo file was loaded successfully; an
entirely missing file does not force utils to mono.

The rules only affect **future captures**. Already finished entries
(`done`, `desktop`, `no_usable_shots`) are skipped by a normal `run`; use an
explicit `run --force --only …` if you want to recapture old entries.
See SPEC-screenshot-generator §4.6 for the exact precedence.

## Config

Defaults live in `shotgen.py`. Override via `config.example.json` (copy and
adjust) or `config.local.json` (git-ignored). Time points are 10, 25 and 45
seconds after Hatari start. Output mirrors the source tree under
`MARCER_OUT_DIR`, one preview PNG plus optional candidate PNGs and a metadata
JSON per entry. `screen_format_monitor` holds the per-scope gameinfo monitor
rules described under "Monitor selection".

Scope configuration:

```json
{
  "scope_default": "cracked",
  "scopes": {
    "cracked": { "trees": ["Title Sorted/Cracked Games - Title Sorted"] },
    "utils":   { "trees": ["Title Sorted/Utilitys - Title Sorted"] },
    "pd":      { "trees": ["Title Sorted/PD Games - Title Sorted"] },
    "magazine": { "trees": ["Bonus/Magazine Cover Disks"],
                  "exclude_dirs": ["dupes"], "boot": "auto" },
    "falcon":   { "trees": ["Falcon 030/Title Sorted"],
                  "index": "index-falcon.json",
                  "tos_default": "4.04",
                  "profile": { "name": "falcon", "machine": "falcon",
                               "memsize": "14", "monitor": "rgb",
                               "extra_args": ["--dsp", "emu",
                                              "--cpuclock", "16"] } }
  },
  "mono_dir_suffix": "Mono",
  "screen_format_monitor": {
    "utils": {
      "default": "mono",
      "color_hints": ["not mono", "low", "mid", "medium", "color", "colour"],
      "mono_hints": ["mono", "high"]
    },
    "pd": { "mono_if_all": ["high"] }
  }
}
```

The index file name defaults to `index.json` for the default scope and
`index-<name>.json` for every other scope (set `"index"` in a scope to
override). A config without any `scopes` entry falls back to the legacy
`scope_trees` list (single implicit `cracked` scope). Note: list-valued
keys like a scope's `trees` are **replaced as a whole** by a
`config.local.json` override, not merged element-wise.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
