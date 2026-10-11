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
registers far more reliably than XTest clicks.

- `prg` — the desktop already shows the program icon: one double click
  starts the game.
- `drive` — the desktop only shows drive icons: double click
  `DISKSTATION A`, wait `click_retry.step_wait` for the window, then walk
  into the window (bounded by `click_retry.drive_max_depth`, default 2):
  double click a folder icon (`assets/icon-folder.png`) to descend, or the
  program icon (`assets/icon-prg-win.png`) to start the game.

Both strategies retry a click when it did not take effect
(`click_retry.drive_attempts` / `click_retry.prg_attempts`): the drive
click is repeated until a window icon appears, and the program click is
repeated until the screen actually changes. Window icons match their
templates near 1.0, so `click_retry.window_icon_min_score` (default 0.85)
rejects the flat-region false positives that appear on a plain desktop.

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

When a previous preview is replaced, it is kept as an additional candidate
(`_cNN`) instead of being overwritten, and every intermediate click-chain
screenshot (drive window, folder window, program window) is kept as a
candidate too, so the path to a successful click stays traceable.

Each parallel worker runs on its own Xvfb display, so
`run --retry-desktop --jobs N` can safely click several titles at once.
Within a display the click sequence is serialized with a global lock and
raises its own Hatari window first; Hatari 2.4.1 has no `mousemove` control
command, which is why the real X pointer (XTest via `xdotool`) is used for
positioning.

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

Nothing is ever deleted unless the detector identifies it as LED-white.
`--dry-run` reports the counts without changing anything; `--only
<substring>` limits the pass. The `drive_led_refetch` flag marks the entries
that a later pass should re-capture with the LED disabled.

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
