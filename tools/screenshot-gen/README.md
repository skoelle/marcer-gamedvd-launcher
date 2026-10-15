# Screenshot Generator

Generates preview screenshots for the Marcer GameDVD archive by booting each
ZIP in Hatari on a virtual X display. See
[`SPEC-screenshot-generator.md`](../../docs/SPEC-screenshot-generator.md) for the
full specification.

## Requirements

- Hatari (verified with 2.4.1), Xvfb, `xdotool` (for the desktop click
  retry), Python 3 with the repo `.venv`
  (`Pillow`, `imagehash`, `numpy`, `scipy`)
- Environment in `local/paths.env` (git-ignored):
  `MARCER_ROOT_DIR`, `MARCER_PATCH_DIR`, `MARCER_OUT_DIR`, `MARCER_TOS_IMG`

## Usage

```bash
tools/screenshot-gen/run.sh index          # build/refresh the zip index
tools/screenshot-gen/run.sh run            # process pending entries
tools/screenshot-gen/run.sh run --hours 8  # night run with time budget
tools/screenshot-gen/run.sh run --limit 3  # small test batch
tools/screenshot-gen/run.sh run --only Xevious   # only matching paths
tools/screenshot-gen/run.sh run --jobs 8   # parallel workers (e.g. night runs)
tools/screenshot-gen/run.sh run --retry-no-usable   # only no_usable_shots again

# Desktop entries (game never started): find the GEM program icon in the
# existing desktop previews, then boot once more and click it:
tools/screenshot-gen/run.sh detect         # offline icon detection (no Hatari)
tools/screenshot-gen/run.sh run --retry-desktop   # click + capture (one attempt)

# Remove blank white previews that only show Hatari's drive-LED overlay:
tools/screenshot-gen/run.sh cleanup-drive-led --dry-run   # report only
tools/screenshot-gen/run.sh cleanup-drive-led             # delete + flag
tools/screenshot-gen/run.sh run --retry-drive-led         # refetch the flagged bootable ones

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
A later `run` skips completed entries (`done`, `desktop`, `no_usable_shots`)
and retries unfinished or failed ones (`pending`, `interrupted`, `timeout`,
`error`). The `no_usable_shots` entries are not retried by a normal run;
repeat them explicitly with `run --retry-no-usable`.

Root and patch layers are merged case-insensitively, like in the console
launcher: if the two layers hold the same ZIP under names that differ only
in case (e.g. `Crossbow - Medway boys.zip` vs. `Crossbow - Medway Boys.zip`),
they are **one** entry — the patch spelling wins, including for the preview
file name (see SPEC-screenshot-generator §4.1 and §10.2).

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

### Desktop click retry (`detect` + `run --retry-desktop`)

Some ZIPs boot to the GEM desktop because the program icon was never
clicked. `detect` runs fully offline over all `desktop` entries: it
matches templates of the standard GEM icons (`assets/icon-prg.png` for a
program icon, `assets/icon-drive.png` for a DISKSTATION drive icon)
against each existing preview PNG (FFT normalized cross correlation, also
tries the inverted/selected icon). Hits are stored as `click` (strategy,
screenshot pixel of the icon center, score) in the index; misses are
marked `icon_found: false` and are never booted again (`detect --force`
redoes them).

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
`click_retry.window_icon_min_score` (0.80) tolerates the arrow if it does
end up on an icon.

- `prg` — the desktop already shows the program icon: one double click
  starts the game.
- `drive` — the desktop only shows drive icons: double click
  `DISKSTATION A`, wait `click_retry.step_wait` for the window, then walk
  into the window (bounded by `click_retry.drive_max_depth`, default 2):
  the window is scanned for the program icon first
  (`assets/icon-prg.png`, the same icon as on the desktop) and double
  clicked right away when it is present; only when no program icon is
  found is the folder icon (`assets/icon-folder.png`) double clicked to
  descend, and the window is scanned for a program icon again.

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

The attempt is recorded once per entry. `click_retried: true` marks that a
retry ran, and a new `click_result` field records how it ended:

- `click-icon-prg` — successful `prg` click (program started),
- `click-icon-drive` — successful `drive` click (DISKSTATION A -> ... ->
  program started),
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

After changing `exclude_dirs`, run `index` to rebuild the index (removed
entries are dropped automatically) and then `prune` to delete their
leftover logs and empty output directories.

## Config

Defaults live in `shotgen.py`. Override via `config.example.json` (copy and
adjust) or `config.local.json` (git-ignored). Time points are 10, 25 and 45
seconds after Hatari start. Output mirrors the source tree under
`MARCER_OUT_DIR`, one preview PNG plus optional candidate PNGs and a metadata
JSON per entry.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
