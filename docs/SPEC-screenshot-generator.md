# SPEC: Screenshot Generator (Marcer GameDVD)

Behavioral specification for an offline screenshot generation tool for the Marcer
GameDVD archive. The tool boots every selected ZIP in the Hatari emulator on a
virtual display, captures screenshots at defined points in time, filters unusable
images and stores one good preview image (plus optional candidates) per entry.

This document is written in the style of the existing `SPEC.md` (numbered
sections, technology-neutral where possible, conformance checklist at the end).
Paths to real data are never written down literally. They come exclusively from
the git-ignored local file `local/paths.env` (see section 11).

**Status of verified facts:** everything marked *(verified)* was tested on the
development machine against Hatari 2.4.1. Everything else is marked
*(untested)* and must be confirmed during implementation.

---

## 1. Goal and Non-Goals

### 1.1 Goal

For every ZIP entry in scope (section 4.4):

1. Boot the ZIP in Hatari on a fixed virtual X display.
2. Capture screenshots at configurable time points.
3. Filter out unusable images (black, empty, duplicates).
4. Detect screenshots that only show the TOS desktop and flag them
   (kind `desktop`, see section 8.4), refined into the sub-kinds
   `textscreen` and `darkscreen` (section 8.4.1).
5. For `desktop` entries: optionally locate the GEM program icon in the
   existing preview offline (`detect`), boot once more and click the icon
   once to start the program (`run --retry-desktop`, section 7.4).
6. Select the best remaining image as preview and store it, mirroring the
   source tree, together with a metadata JSON file.
7. Be resumable, log per entry, and never modify the NAS data.

### 1.2 Non-goals

- No modification, move or delete of anything under `MARCER_ROOT_DIR` or
  `MARCER_PATCH_DIR`. Read access only.
- No downloads of ROMs, disk images or anything else.
- No parallel runs of the tool process (one run per `MARCER_OUT_DIR`;
  within a run, `run --jobs N` is allowed, section 5).
- No in-launcher screenshot display in this stage (section 12 is a future stage).
- No keyboard key injection and no `--auto` autostart (still a future stage,
  section 15 milestone M7). The implemented desktop click retry (section 7.4)
  covers exactly one icon double click, nothing more.
- No screenshots for PD games, utilities, tools, Falcon titles, Bonus or
  anything outside the scope trees (section 4.4).

---

## 2. Environment Check Results

Checked on the development machine (read-only or with explicit approval):

| Component | Status | Version / Detail | Action needed |
|---|---|---|---|
| OS | ok | Linux x86_64, kernel 7.0.0-38, 4 cores | none |
| RAM | ok, tight | 9.5 GB total, about 2.7 GB available | run only one instance |
| Free disk (local) | ok | about 10 GB on `/` | staging only, cleanup after each entry |
| Desktop session | none | TTY only, no X11 or Wayland session | Xvfb is mandatory |
| NAS | ok | mounted via NFS, both data paths reachable | keep timeouts, avoid volume-wide scans |
| .NET SDK | ok | 10.0.112, `apps/marcer_console/build.sh` verified working | none (not used by this tool) |
| Hatari | ok | 2.4.1 from apt | none |
| Hatari options | verified | `--screenshot-dir`, `--crop`, `--statusbar`, `--cmd-fifo`, `--run-vbls`, `--benchmark`, `--disk-a` (accepts ZIP), `--tos`, `--machine`, `--sound off`, `--fast-boot`, `--confirm-quit`, `--zoom`, `--protect-floppy` all exist in 2.4.1 | none |
| Hatari `--screenshot-format` | missing | option does not exist in 2.4.1 (format comes from config, default PNG verified) | do not use this flag |
| Hatari `hatari-event mousemove` | missing | 2.4.1 supports only `doubleclick`, `rightdown`, `rightup`, `keypress/keydown/keyup` (control.c verified); `mousemove` exists in newer versions only | mouse positioning via xdotool instead |
| TOS ROM | ok | TOS 1.04 German image, 196607 bytes, provided in `local/` (git-ignored) | reference via `MARCER_TOS_IMG` |
| Xvfb | ok | installed, fixed display `:99` verified working | none |
| xdotool | ok | installed, **required** for the desktop click retry (section 7.4) | none |
| ImageMagick | ok | `import` and `convert` available | fallback grabs and analysis |
| ffmpeg | ok | available | not required for MVP |
| Python | ok | 3.12.3, repo `.venv` already exists | install Pillow, imagehash, numpy into `.venv` |
| unzip | ok | available | ZIP content listing |
| Smoke test | verified | see below | none |

### 2.1 Smoke test result (verified)

Setup: one small real ZIP (single `.msa` inside) copied from
`MARCER_ROOT_DIR` to a local temp directory, Xvfb on fixed display `:99`,
Hatari started with TOS from `MARCER_TOS_IMG`, options
`--statusbar off --crop on --sound off --confirm-quit off --zoom 1
--machine st --fast-boot on`, `--screenshot-dir` pointing to a local output dir,
`--cmd-fifo` for remote control.

Results:

- Hatari booted the ZIP from drive A directly. No unpacking needed for
  single-image ZIPs.
- Command `hatari-shortcut screenshot` written to the FIFO produced
  `grab0001.png` in `--screenshot-dir`. Format PNG, size 832x552, about 4.5 KB.
  Log line: `Screen dump saved to: ...` *(verified)*.
- The captured image showed the TOS desktop (3 unique colors), because 14
  seconds wall time were not enough for the game to load. This confirms:
  time points must be configurable per profile and the desktop must be
  detected (section 8.4).
- Plain `screenshot` (without the `hatari-` prefix) is rejected by the FIFO in
  2.4.1. Supported FIFO commands: `hatari-debug`, `hatari-event`,
  `hatari-option`, `hatari-enable/disable/toggle`, `hatari-path`,
  `hatari-shortcut`, `hatari-stop`, `hatari-cont` *(verified)*.

### 2.1.1 Batch pilot (10 entries, verified)

Ten random ZIPs from both scope trees were processed with the base profile and
time points 10s, 25s, 45s (30 screenshots):

- 10/10 entries booted Hatari and produced all three screenshots.
- 4/10 showed game content (crack intros or loaders) within 45s:
  one already at 10s, one between 10s and 25s, one between 25s and 45s,
  one at 10s and staying.
- 6/10 stayed on the TOS desktop for the full 45s. Visual check confirmed a
  German TOS desktop with the drive A window open, showing the game PRGs
  (for example `XEVIOUS.PRG`) without auto-start. More waiting does not help;
  these entries need milestone M7 (key injection or `--auto`).
- Desktop screenshots consistently had 3 unique colors, confirming the
  classification heuristic of section 8.4 on real data.
- Median runtime per entry was dominated by the fixed 45s schedule plus about
  3s overhead (copy, start, kill).

### 2.2 Missing packages (not yet installed, approval required)

| Package | Purpose | Install command |
|---|---|---|
| Pillow | image analysis, cropping | `.venv/bin/pip install Pillow` |
| imagehash | perceptual hash for duplicate detection | `.venv/bin/pip install imagehash` |
| numpy | entropy and color statistics | `.venv/bin/pip install numpy` |

All installs go into the repo virtual environment only, never global pip.

---

## 3. Repo Integration

### 3.1 Decision

**Recommendation: standalone Python 3 script** in a new directory
`tools/screenshot-gen/` inside this repository, run via the repo `.venv`.

Rationale:

- The pipeline is image processing and process orchestration. Python has the
  mature libraries for this (Pillow, imagehash, numpy).
- The launcher is a released end-user application. Adding a batch tool to it
  would couple release cycles, force a C# build for a server-side task, and
  violate the launcher scope (SPEC.md section 1.3, out of scope).
- The repo policy (build only via `apps/marcer_console/build.sh`) applies to the C#
  launcher. A Python tool does not conflict with it.
- The merge logic from SPEC.md section 7 is small and fully specified. The
  Python tool reimplements it 1:1 (same rules, same ordering) instead of
  shelling out to the C# code. The spec is the contract.

### 3.2 Alternatives considered

| Option | Pros | Cons | Decision |
|---|---|---|---|
| Python script in `tools/` | best image libs, independent release, easy iteration | logic duplicated from C# | chosen |
| Extend the C# launcher with a CLI mode | single code base | couples release, poor image tooling in .NET, harder headless operation | rejected |
| C# standalone console tool | reuses merge code directly | image analysis libraries weaker, slower iteration | rejected |
| Shell scripts | minimal deps | unmaintainable at this complexity | rejected |

### 3.3 Layout

```
tools/screenshot-gen/
  README.md            short usage, points to this spec
  shotgen.py           entry point (CLI)
  <modules>            index, hatari control, filters, profiles
  config.example.json  tool settings template (no paths inside)
  profiles/            Hatari profile definitions (section 6)
```

Output, index, state and logs go to `MARCER_OUT_DIR` (section 10), never into
the repository working tree.

---

## 4. Input: Entry Resolution and Index

### 4.1 Merge logic (same rules as the launcher)

The tool presents root and patch layers as one overlay, exactly like the
launcher (SPEC.md section 7):

- Only files ending in `.zip` (case-insensitive) are entries.
- Hidden entries are ignored. Additionally, any directory whose name starts
  with `@` is ignored (Synology metadata folders such as `@eaDir` are not
  hidden on NFS but must never be treated as content).
- Name matching is case-insensitive. If the same relative path exists in both
  layers — including spellings that differ only in case (e.g. root
  `Crossbow - Medway boys.zip` vs. patch `Crossbow - Medway Boys.zip`) — the
  patch copy wins, the entry source is `BOTH`, and the **patch spelling is the
  canonical entry identity**: index key, relative path and all output file
  names use it. A root-only spelling that differs only in case never becomes a
  second index entry (it would only produce a duplicate capture whose second
  write is renamed by a case-insensitive NAS, section 10.2). Curated state of
  the overridden spelling is carried over when file size and mtime match.
- Entries not in scope trees are skipped entirely (section 4.4).

### 4.2 Index cache

The NAS is slow. A full recursive walk over the whole volume must never happen
blindly. Instead:

- The tool maintains `index.json` in `MARCER_OUT_DIR`.
- The index lists, per entry: relative path (from the layer root), name, layer
  flags (ROOT, PATCH, BOTH), file size, and the last processing status.
- A full index scan only walks the two scope trees (section 4.4), with a
  configurable per-directory timeout and progress logging. Default full scan
  timeout budget is generous (minutes are acceptable for a full scan, hours are
  not).
- Incremental mode (default): only scan scope trees, compare with the stored
  index, report new or changed entries (size or mtime differs).

### 4.3 Relative path

The relative path of an entry (for example
`Title Sorted/Cracked Games - Title Sorted/A/Arkanoid/Arkanoid - Skid 1.0.zip`)
is the identity of the entry everywhere: index key, output mirror, metadata
file, launcher integration later.

### 4.4 Scope (user decision, fixed for now)

Only one tree is in scope:

- `<root>/Title Sorted/Cracked Games - Title Sorted` (also merged with its
  patch counterpart)

Explicitly out of scope for now:

- All `PD Games` trees
- All `Utilitys` trees
- `Bonus`, `Tools`, `Falcon 030`
- All `Crew Sorted` trees
- Everything else

Within the scope tree, sub-directories that never hold Hatari disk images are
excluded too (config `exclude_dirs`, section 11.2): `Boxscan`/`Box Scan` (box
scans), `Manual` (manuals/PDFs) and `Kryoflux` (flux dumps, usually under
`RAW`). The scanner never enters them, so their ZIPs never reach the index.
Matching is case-insensitive, ignores spaces/underscores/dashes, and applies
at any depth. After changing the list, run `index` (dropped entries are
removed automatically) and `prune` (section 5) to clean leftovers.

Scope is defined in the tool config (section 11.2) as a list of relative tree
paths, so extending later is a config change, not a code change.

### 4.5 Multi-disk sets (user decision)

- Only disk 1 of a multi-disk set is processed. ZIPs whose names match
  configurable disk-2-plus patterns (default: case-insensitive regex covering
  `disk 2`, `disk 3`, `disk b`, `side b`, and similar) are skipped and marked
  `skipped_disk_n` in the index.
- Crack-variants inside one game folder are **not** multi-disk sets. Every
  crack ZIP gets its own screenshots, because crack intros differ
  (user decision).

---

## 5. Pipeline

```
[1] load config + env (paths.env)
        |
[2] load or refresh index  (bounded scan of scope trees only)
        |
[3] select pending entries (status != done, or --force;
         with --retry-desktop: only status == desktop with a stored
         icon hit that has not been clicked yet, section 7.4;
         with --retry-no-usable: only status == no_usable_shots;
         with --retry-drive-led: only status == desktop with the
         drive_led_refetch flag set and kind != no_game_image, section 8.7)
        |
[4] per entry:
      a. copy ZIP from NAS to local staging dir     (NAS is read-only)
      b. create entry work dir + cmd FIFO
      c. start Xvfb (fixed display) if not running
      d. start Hatari (profile args, staged ZIP, screenshot-dir, cmd-fifo)
      e. wait configured time points, send screenshot command per point
      f. stop Hatari via process group kill after last point or timeout
      g. collect screenshots, compute metrics (section 8)
      h. classify (black / desktop / game, drive_led), detect duplicates
         (section 8), then split the entry kind `desktop` into the
         sub-kinds `desktop` / `textscreen` / `darkscreen` (section 8.4.1)
      i. select best preview image (section 8.5)
      j. write preview PNG + metadata JSON to mirrored output path
      k. update index entry, append log
      l. clean staging dir for this entry
        |
[5] write run summary (counts, failures, durations)
```

Step [4] runs serially by default. With `run --jobs N` up to N entries are
processed in parallel: every worker owns its staging dir, log file, Hatari
process group and its own Xvfb display (`:99`, `:100`, ...; assigned
automatically). Screenshots themselves are framebuffer-internal, but the
desktop click retry (section 7.4) needs the real X pointer and focus, which
one shared display cannot provide for two Hatari instances. Entry mutation
and every index save are serialized under a single lock, so parallel
workers can never overwrite each other's updates. The output-dir lock
still allows only one tool process per `MARCER_OUT_DIR`.

Besides `index`, `run` and `detect`, the tool has the `cleanup-drive-led`
subcommand (section 8.7), a standalone offline pass that removes old
drive-LED white screenshots and cleans the index, the `reclassify`
subcommand (section 8.4.1), an offline pass that refines the entry kind of
`desktop` entries, and the `prune`
subcommand, which deletes `logs/<rel>.log` files and empty mirror
directories of index entries that no longer exist (used after directory
exclusions, section 4.4).

---

## 6. Hatari Configuration and Profiles

### 6.1 Reuse of the launcher mechanism

The launcher starts Hatari with an argument template containing `{zip}` and
`{cfg}` (SPEC.md section 12). The generator uses the same two-placeholder
concept:

- `{zip}` is the staged local copy of the entry ZIP (never the NAS path).
- `{cfg}` is the profile config file for the current profile (section 6.3).

The launcher's bundled `MarcerGameDvd-Hatari.cfg` is the conceptual base for
the `st` profile, but it is **not** used 1:1: it is an end-user config
(statusbar on, sound on, crop off, confirm-quit on), which is wrong for
screenshots. The generator ships its own profile files with screenshot-oriented
settings.

### 6.2 Base profile `st` (default)

Command line (verified options, Hatari 2.4.1):

```
hatari
  --tos <MARCER_TOS_IMG>
  --machine st
  --memsize 1
  --sound off
  --statusbar off
  --drive-led false
  --crop on
  --fast-boot on
  --confirm-quit off
  --zoom 1
  --disk-a <staged zip>
  --screenshot-dir <entry work dir>
  --cmd-fifo <entry work dir>/hatari.fifo
  --log-file <entry log>
  --log-level info
```

Notes:

- `--zoom 1` yields an 832x552 window in the smoke test *(verified)*. Larger
  previews may use `--zoom 2` (untested with respect to timing impact).
- `--crop on` removes the statusbar from captures *(verified option exists,
  effect not yet visually confirmed)*.
- `--drive-led false` hides the floppy drive LED overlay that Hatari
  otherwise draws in the top-right corner when the statusbar is hidden.
  Without it, titles with no game output (manuals, box scans, raw dumps,
  data disks) produced a blank white screen with just that green LED
  *(verified; see section 8.7)*.
- `--sound off` speeds up emulation *(option verified, effect untested)*.
- `--fast-boot on` speeds up boot. A fallback profile `st-nofastboot`
  disables it for titles that break with it (untested whether any exist).
- TOS is TOS 1.04 via `MARCER_TOS_IMG`. EmuTOS is not used.

### 6.3 Profile mechanism

- Profiles are files in `tools/screenshot-gen/profiles/`.
- A profile defines: machine type, TOS source (env var), RAM, monitor,
  borders, zoom, fast-boot, extra CLI args, time points list, and optional
  per-entry key injection steps (future).
- Profile selection: default `st`. A future config map can assign profiles by
  path pattern (for example Falcon trees). No special profiles are needed for
  the current scope.
- The Falcon case (`Falcon 030` tree, Falcon machine, Falcon TOS) is out of
  scope now. It is listed as a future extension because EmuTOS has weak Falcon
  support and Falcon TOS is not available in this environment (risk R4).

### 6.4 Screenshot timing configuration

- Default time points (wall-clock seconds after Hatari start): `10, 25, 45`.
  All configurable per profile.
- Rationale: tuned in a 10-entry batch pilot (section 2.1) and confirmed by
  the user. Fast titles (crack intros) already show content at 10s, slower
  loaders appear between 25s and 45s. Titles that never auto-start stay on
  the desktop regardless of waiting longer (user decision: accept and flag,
  do not wait beyond 45s; auto-start handling is M7).
- Alternative considered: `--run-vbls` (exists in 2.4.1, *(verified)*) gives
  deterministic emulation-time exits, but only one end state per run and it is
  tied to `--benchmark` fast-forward behavior, which changes what the screen
  shows compared to real-time playback. Not used in the MVP *(untested)*.

---

## 7. Screenshot Strategy

### 7.1 Capture method (priority order)

1. **Primary (verified):** write `hatari-shortcut screenshot` to the cmd FIFO
   at each time point. Hatari saves `grabNNNN.png` into `--screenshot-dir`.
2. **Fallback 1 (untested):** `hatari-debug screenshot` via FIFO (debugger
   command).
3. **Fallback 2 (untested):** send the keyboard shortcut with xdotool to the
   Hatari X window (AltGr+G, from the launcher config shortcut table).
4. **Fallback 3 (untested):** grab the root window of the fixed Xvfb display
   with ImageMagick `import`. Quality is worst (captures window decorations
   and borders) and is only a last resort.

The method is selectable in the tool config. The tool logs which method was
used per screenshot.

### 7.2 Window and display

- Xvfb with a fixed display number (default `:99`, override via
  `MARCER_DISPLAY`). Never `xvfb-run -a`, because a separate screenshot
  process cannot know the auto-selected display.
- Screen size 1024x768x24 *(verified sufficient for 832x552 output)*.
- The tool starts Xvfb itself if the display is not alive, and stops it on
  exit unless it was already running (external management).

### 7.3 Key injection (future extension, not MVP)

Some titles do not auto-boot and stay on the TOS desktop or a loader prompt
(observed in the smoke test). Keyboard key injection and `--auto` autostart
are **much later** work (M7) and remain out of scope. The implemented
alternative is the icon click retry of section 7.4.

### 7.4 Desktop click retry (implemented, verified)

For entries whose first run ended as kind `desktop`, the program icon on the
GEM desktop can be clicked once so the title actually starts. This is a two
phase workflow:

**Phase 1: `detect` (offline, no Hatari).**

- Runs over all index entries with `status: desktop` (takes the existing
  preview PNG, falls back to candidates). No boot, CPU only. An optional
  `--only <substring>` filter restricts the run (same semantics as `run`).
- Matches `assets/icon-prg.png` (tight crop of the standard GEM program
  icon) and `assets/icon-drive.png` (DISKSTATION drive icon) with zero-mean
  normalized cross correlation (FFT, numpy/scipy). The inverted template is
  tried as well so inverted (selected) icons still match. Template geometry
  is 60x54 px (program icon) and 64x60 px (drive icon) at the verified
  832x552 capture size.
- Strategy choice: a real program icon always wins; otherwise a drive icon
  selects the drive strategy. Hit: entry gets
  `click` = `{strategy, sx, sy, score, source}` and `icon_found: true`.
  Score threshold default 0.5 (config `click_retry.icon_min_score`); true
  positives scored 0.53 to 1.0 in the pilot *(verified)*, a drive icon
  reaches 1.0.
- Miss: entry gets `icon_found: false` and is never booted by the retry
  (catches crack intros and other non-GEM screens misclassified as
  desktop). `detect --force` redoes both cases.
- The command takes the output-dir lock, so it cannot run concurrently with
  `run`.

**Phase 2: `run --retry-desktop` (Hatari).**

Pending filter: `status == desktop` and a stored `click` and not
`click_retried` (`--force` allows a second attempt). Per entry:

1. Boot as usual, but the first capture timepoint is
   `click_retry.probe_time` (default 10 s) only.
2. Analyze the probe screenshot. If it is **not** desktop (game or black):
   no click, mark `click_retried` and `click_result: click-not-needed`, and
   continue the normal capture timepoints (the probe shot already covers its
   timepoint).
3. If it shows the desktop, run the click strategy (below), then restart
   the capture timepoints from the click moment.
4. Record the attempt (`click_retried: true`, `clicked: true/false`,
   `click_result`) in index and metadata, restart the capture timepoints
   (`click_retry.timepoints_after_click`, default `10, 25, 45`) from the
   click moment, with the entry budget `click_retry.entry_timeout_s`
   (default 120 s).
5. The old desktop preview is not overwritten silently: with
   `keep_candidates` it is renamed to the next free `_cNN` candidate name
   before the new preview is written. Every intermediate click-chain
   screenshot (drive window, folder window, program window) is kept as an
   additional `_cNN` candidate as well, so the path to a successful click
   stays traceable even on success.

`click_result` records how the retry ended and is independent of the pixel
classifier (so a title whose start screen is not `game`-like, e.g. a
3-colour GEM dialog, still counts as a successful click):

- `click-icon-prg` — `prg` click confirmed a program start,
- `click-icon-drive` — `drive` click confirmed a program start,
- `click-failed` — the strategy ran but no program start was confirmed,
- `click-not-needed` — the probe was already non-desktop.

**Click mechanics (shared by all strategies).** Find the running Hatari X
window via xdotool. When the worker knows its Hatari process id (parallel
mode), it resolves its own window with `search --pid <pid>` (fallback:
`getwindowpid` on the candidates, then the size match). Then it raises the
window, moves the real X pointer (XTest) to window origin + icon screenshot
pixel (scaled by window/screenshot size ratio, both are 832x552 in the base
profile), and sends the double click through Hatari's own
`hatari-event doubleclick` control command over the FIFO. Sending the click
through the emulator input path is far more reliable than XTest clicks,
which GEM often only registers as a single selection *(verified)*. After
the double click the pointer is parked on the empty part of the window
title bar (screenshot row y=182, well away from the icon grid) before the
next screenshot is taken: GEM draws its mouse arrow into the framebuffer,
and an arrow left on the clicked icon would cover the icon of the
following window (the same grid cell, e.g. the program icon directly
below a folder icon) and destroy the template match. The park must not be
near the window/screen edge: a warp to the border (e.g. the bottom-right
corner) makes Hatari's relative mouse handling drift — the GEM cursor no
longer matches the X pointer and every later click misses the icon
*(verified live: tens of pixels of drift after such a warp, while a
park inside the window keeps the cursor aligned)*. The arrow overlap
threshold `click_retry.window_icon_min_score` (default 0.80) additionally
tolerates the cursor when it does end up on an icon.

**Strategy `prg`** (desktop shows the program icon): one double click on
the icon. If the screen does not change, retry up to
`click_retry.prg_attempts` (default 3) *(verified: Bank It)*.

**Strategy `drive`** (desktop only shows drive icons, e.g. Bank It):
double click `DISKSTATION A`, wait `click_retry.step_wait` for the window,
then walk into the window up to `click_retry.drive_max_depth` levels
(default 2, enough for the verified `DISKSTATION A` -> folder `BANK_IT`
-> `BANKIT.PRG` case): every window is scanned for the program icon first
(`assets/icon-prg.png`, the same icon as on the desktop) and double
clicked as soon as it is found; only when no program icon is present is
the folder icon (`assets/icon-folder.png`, 59x52 px) double clicked to
descend, after which the window is scanned for a program icon again. The
folder click is verified and retried up to
`click_retry.folder_attempts` (default 3), because GEM sometimes only
registers the first press as a selection *(verified live)*. A plain
global pixel diff cannot tell a selection from an open here: opening a
folder changes only a few percent of the screen when the folder window
looks similar to its parent (both are white GEM windows, ~1.2%), the same
order as a selection. The folder click is therefore classified with the
icon templates: a genuine program icon (score ~1.0) appearing at the
clicked spot means the folder opened, while the still-selected (inverted)
folder at the same spot only scores as a weak program match (~0.86) and
counts as not opened. When the whole window changes and no GEM icon is
left afterwards, the game started directly from the click and the chain
reports success (this covers folders whose content is a single program
that starts on the same double click). The
drive click is only repeated while the screen does not change at all
(`click_retry.drive_attempts`, the click never opened the window); once
its window is open, DISKSTATION is never clicked again, because a second
double click would only bring up the same window. Between the steps it
waits `click_retry.step_wait` (default 5 s: opening a folder window and
reading the disk takes longer than the drive window, and a grab taken too
early shows a half-drawn window with no recognizable icon). Window icons
match their templates near 1.0, so `click_retry.window_icon_min_score`
(default 0.80) rejects the flat-region false positives (~0.55) seen on
white window areas while still accepting the program icon with the GEM
arrow on it (~0.84).
*(verified: Bank It - Hotline starts via drive -> folder -> PRG; 10th
Frame - Tsunoo Rhilty v2 and 10th Frame - Elsi via drive -> folder ->
PRG.)*

Notes:

- Hatari 2.4.1 has no `mousemove` control command (section 2), therefore
  the pointer is positioned through XTest via `xdotool` and only the window
  geometry mapping is needed; the FIFO handles both screenshots and the
  `doubleclick` event.
- Each parallel worker runs on its own Xvfb display (section 5). Hatari's
  SDL only processes mouse motion and focus for its own window, and two
  instances on one display fight over the single X pointer, so the retry
  needs one display per worker. Within a display the whole click sequence
  (find window, raise, focus, move, click) is serialized under a global
  lock and always raises/focuses its own window first. The window is
  resolved by process id (section 7.4 mechanics), which also makes one
  display robust when it is reused serially.
- `run --retry-desktop` refuses to start when `xdotool` is not in PATH.
- An entry that stays `desktop` after the click (program did not start or
  is not game-like for the classifier) keeps `click_retried: true` and is
  not retried again automatically; the updated preview and candidates
  show the newer state.

---

## 8. Image Filtering and Selection

All thresholds are configurable in the tool config with these defaults.

### 8.1 Reject: black or empty images

- Mean luminance below threshold (default 0.02) or standard deviation below
  threshold (default 1.0 on 0..255 scale) marks the shot as `black`.
- Rationale: games that failed to boot, or shots taken before the first video
  output.

### 8.2 Reject: near-duplicates

- Perceptual hash (pHash) over all surviving candidates of one entry.
- If two candidates have Hamming distance below threshold (default 6), the
  later one is dropped as duplicate.
- Cross-entry duplicate detection is **not** performed in the MVP (many crack
  intros legitimately share visuals).

### 8.3 Score remaining candidates

Score = weighted sum (weights configurable) of:

- Shannon entropy of the luminance histogram (detail, default weight 0.4)
- Unique color count, capped (colorfulness, default weight 0.3)
- Edge density via simple gradient magnitude (structure, default weight 0.3)

### 8.4 Detect and flag TOS desktop screenshots (user requirement)

A screenshot that shows only the TOS desktop is not a useful preview, but the
information matters (it means the title did not auto-start). Such shots are
**kept and flagged**, never silently dropped.

Heuristic (all thresholds configurable):

- unique color count <= `desktop_max_colors` (default 5)
- and either the mean brightness is at least `desktop_min_mean` (default
  0.5) or the desktop green fraction is at least `desktop_green_frac_min`
  (default 0.02)

Classification result per shot: `game`, `desktop`, or `black`. An entry whose
all shots are `desktop` gets entry kind `desktop` in metadata and index. An
entry with at least one `game` shot gets kind `game` even if desktop shots
also exist (desktop shots are then only candidates of last resort).

### 8.4.1 Desktop sub-kinds: `textscreen` and `darkscreen` (user requirement)

The coarse entry kind `desktop` mixes three visually very different
situations, which must be distinguishable in the index:

| kind | meaning |
|---|---|
| `desktop` | a real TOS desktop (green work surface, windows, icons) |
| `textscreen` | a crack intro / text screen on a **light** background (near-white, i.e. the TOS 238 grey) |
| `darkscreen` | a text screen on a **darker or colored** background (grey 136/204, blue, pink, split screens) |

A fifth kind, `no_game_image`, is not derived from pixels: it marks a
drive-LED reset entry (section 8.7) whose ZIP contains no bootable
disk/program image. `run` and `reclassify` never assign it (they cannot
produce a preview for such an entry); it is set by the offline marking
pass and skipped by `run --retry-drive-led`.

Refinement of the chosen entry kind (applied to `pick` after selection,
section 8.5, and only when that kind is `desktop`):

- `green_frac >= desktop_green_frac_min` (default 0.02) → `desktop`
- else `white_frac >= textscreen_min_white` (default 0.5) → `textscreen`
- else → `darkscreen`

`white_frac` is the share of pixels whose red, green and blue components
are all at least `white_pixel_min` (default 230); it is measured on the
full-resolution preview, `green_frac` on the 64x64 sample as in section 8.4.
Both thresholds are configurable.

Verified on the live index: the 40 real TOS desktops start at
`green_frac` 0.0242, the non-GEM screens end at 0.0017; the light-background
screens start at `white_frac` 0.7600, the dark/colored ones end at 0.0350
(0.5 therefore sits in a wide, unambiguous gap).

**Status is not affected.** All three sub-kinds keep entry `status:
desktop`, so `detect` (section 7.4), `run --retry-desktop`, resume/skip
behavior and every consumer of the index status (desktop app, gallery) are
unchanged. Only `kind` (index and metadata JSON) changes, plus
`preview_is_desktop`, which is `true` for all three (the shot never shows
a game). Manual curation may later move such an entry to `status: done`
while keeping `kind: textscreen` / `darkscreen` — a legal combination that
no pass of this tool rewrites (section 10.5).

Entries without a preview PNG (the drive-LED resets of section 8.7 and
entries whose preview file is missing) cannot be classified and keep their
current `kind`.

**Offline pass `reclassify`.** Refines the `kind` of all existing
`status: desktop` entries by re-analyzing their preview. Options:
`--dry-run` (report only), `--only <substring>`, `--list <kind>` (print the
matching entry paths, restricted by `--only`). It takes the output-dir lock,
writes the index after every 500 entries, and updates the per-entry
metadata JSON (`kind`, `preview_is_desktop`) when it exists.

### 8.5 Select preview

- Prefer the highest-scoring `game` shot.
- If none exists, fall back to the highest-scoring `desktop` shot, and set
  `preview_is_desktop: true` in metadata (also for the refined kinds
  `textscreen` and `darkscreen`, section 8.4.1).
- If nothing exists (all black or Hatari produced no files), status is
  `no_usable_shots`, `preview` and `kind` stay `null`, and no metadata
  JSON is written (section 10.3). With `keep_candidates` set, every
  captured shot is retained as a `_cNN` candidate for manual review —
  black ones included and unfiltered (section 8.6).

### 8.6 Optional candidate retention

Config flag `keep_candidates` (default true in the MVP, later false):
store all non-duplicate candidates next to the preview with suffixes
`_c01`, `_c02`, and so on. When a new run replaces an existing preview
file (for example a desktop shot replaced by a game shot after the click
retry), the previous file is kept as an additional `_cNN` candidate
instead of being overwritten.

Retention also covers entries that end as `no_usable_shots` (section 8.5):
there *all* captured shots are kept as `_cNN` candidates in capture order —
including those the classifier rejected as `black` (section 8.2) and
near-duplicates the pHash pass would drop (section 8.2) — because nothing
was usable and the raw grabs are exactly what needs manual review. A
preview left over from an earlier successful run of the same entry is
renamed to the next free `_cNN` instead of becoming an unreferenced file,
and the metadata JSON of that earlier run is deleted (its status/preview
reference no longer holds). Consumers must treat `no_usable_shots` with
`preview: null` and a non-empty `candidates` list as a normal, supported
state. With `keep_candidates` false none of this retention happens:
`candidates` stays empty for such entries.

### 8.7 Drive-LED white screens (detection and cleanup)

With `--statusbar off` Hatari draws a floppy drive LED overlay in the
top-right corner. Titles that produce no game output (manuals, box scans,
raw dumps, and some data disks) therefore became a blank white screen with
only that green LED. The generator now always passes `--drive-led false`
(section 6), so new captures are clean.

`analyze_image` also reports a boolean `drive_led`: a predominantly white
background plus a green block in the top-right corner (at 832x552 the LED
is x806..825, y6..14, 180 green pixels; the test uses relative bounds so it
scales). It carries no game content.

`cleanup-drive-led` (section 5) cleans old affected images:

- preview is LED-white: the preview PNG, its LED-white candidates and the
  metadata JSON are deleted; the index entry is reset (`preview`/`kind`/
  `click*` cleared, `status: desktop`) and flagged `drive_led: true`.
  Bootable entries (a disk/program image in the ZIP) additionally get
  `drive_led_refetch: true` so a later pass can re-capture them with the
  LED disabled.
- only some candidates are LED-white: only those candidate PNGs are
  deleted; the preview, metadata JSON and status are left untouched and no
  flag is set.
- entries with `status: done` are **never touched**: `done` is final
  (section 10.5) — a real game shot or a manual curation decision must not
  be reset, even if its preview were ever classified as LED-white.

Only files the detector identifies as LED-white are ever deleted. A
`--dry-run` reports the counts and changes nothing; `--only <substring>`
limits the pass. Live run *(verified)*: 1787 entries touched, 1150
preview-white (163 bootable -> `drive_led_refetch`), 639 candidate-only;
0 LED-white previews/candidates remained afterwards.

`run --retry-drive-led` (section 5) re-captures exactly those reset
entries with `--drive-led false`. When such an entry finally yields a
usable preview, `process_entry` clears `drive_led` and
`drive_led_refetch` again — the flag is a one-shot marker, not a
permanent label. A refetch that still shows nothing (uniform black *or*
uniform white; both are classified `black` in section 8.4 because of
their near-zero pixel standard deviation) ends as `no_usable_shots` with
no preview — the old blank LED-white placeholder is gone, the entry
remains reachable via `run --retry-no-usable`, and with `keep_candidates`
set the shots of that refetch are kept as `_cNN` candidates (section 8.6).

Reset entries whose ZIP contains **no** bootable disk/program image
(manuals, box scans, raw dumps, data-only ZIPs) can never produce a game
screenshot. They stay `status: desktop` with `kind: no_game_image`
instead of being re-captured endlessly, and are skipped by
`run --retry-drive-led`. Bootability uses the same extension set as
`cleanup-drive-led` (`.stx`, `.msa`, `.st`, `.dim`, `.ipf`, `.prg`,
`.stt`, `.pckd`, `.pkd`).

---

## 9. Robustness

- **One run, one instance:** the tool refuses to start a second concurrent
  run (lock file in `MARCER_OUT_DIR`). Within a run, `run --jobs N`
  processes up to N entries in parallel (default: 1 = serial); every
  worker runs its own Hatari process group and staging dir, sharing one
  Xvfb display. All index mutations and saves are serialized under a
  single lock.
- **Process groups:** Hatari and Xvfb are started with their own session
  (`setsid` semantics, in Python `start_new_session=True`). Timeouts kill the
  whole group (`killpg`). Never rely on terminating a single PID from a
  shell-launched tree.
- **Per-entry timeout:** default 90 seconds wall clock, configurable. On
  timeout: kill group, mark entry `timeout`, continue with next entry.
- **Xvfb lifecycle:** start if display not present, keep alive across entries
  (restart per entry is too slow), stop on tool exit if the tool started it.
- **Resume:** index plus per-entry metadata are the state. Entries with final
  status (`done`, `desktop`, `no_usable_shots`) are skipped on rerun.
  `no_usable_shots` is not retried automatically; use `run
  --retry-no-usable` to reprocess it explicitly. `--force` reprocesses
  everything. Interrupted entries without metadata are retried.
- **Logging:** one log file per entry (Hatari stdout and tool events) plus a
  run summary. Logs live under `MARCER_OUT_DIR/logs/`, mirrored by entry
  relative path.
- **NAS safety:** data paths are opened read-only. The ZIP is copied to a
  local staging directory before emulation, and the staging copy is deleted
  after the entry. Hatari never reads from the NAS directly
  *(the smoke test used a local copy, this is the proven path)*.
- **Write safety:** the tool only writes under `MARCER_OUT_DIR` and the local
  staging directory. It never writes to `MARCER_ROOT_DIR`,
  `MARCER_PATCH_DIR`, or the repository working tree.
- **Graceful interrupt:** Ctrl+C finishes the current entry per worker,
  writes the index, and exits non-zero.

---

## 10. Output

### 10.1 Location and layout (user decision)

Root: `MARCER_OUT_DIR` (on the NAS, next to the patch data, see section 11).

The output mirrors the source tree of the entry relative to its layer root:

```
$MARCER_OUT_DIR/
  index.json
  logs/
    Title Sorted/Cracked Games - Title Sorted/A/Arkanoid/<zip>.log
  Title Sorted/Cracked Games - Title Sorted/A/Arkanoid/
    Arkanoid - Skid 1.0.png
    Arkanoid - Skid 1.0.json
    Arkanoid - Other Crack.zip -> Arkanoid - Other Crack.png / .json
```

Rationale: a flat root would contain thousands of files (user feedback).
Mirroring keeps paths short, groups by game, and matches how the launcher
would look up a preview later (section 12).

### 10.2 File naming

- Preview: `<zip basename without .zip>.png`
- Metadata: same base name with `.json`
- Candidates (if kept): `<base>_c01.png` and so on
- Characters that are unsafe on common file systems (`:`, `?`, `*`) are
  replaced with `_`. The original name is preserved in metadata.

**Case-insensitive mirrors (Synology SMB).** The output mirror may live on a
case-insensitive share. Two rules keep it conflict-free:

1. The overlay merge (section 4.1) gives every game exactly one canonical
   spelling (the patch one), so the mirror never holds a `<base>.png` /
   `<base>.json` pair for two entries whose names differ only in case.
2. Before writing a preview, candidate or metadata file, the tool deletes
   stale files in the same mirror directory whose names match the target
   **only** by case (`drop_case_variants`). They belong to a merged-away
   spelling; writing over them would make the NAS silently rename the new
   file to `<base>_DiskStation_<date>_Upload…CaseConflict.png`.

Legacy `…CaseConflict.png` / `…CaseConflict.json` files from the time when
case-differing spellings were indexed twice are still read correctly:
metadata is loaded via a fallback (`metadata_path`): canonical name first,
otherwise the single `<base>*CaseConflict.json` in that directory. The index
`preview` field points at the actual file name, so consumers never need to
know the rule. After such duplicates have been merged (section 4.1), their
old files are orphans: nothing in the index references them, and they are
deleted by the one-off data repair that accompanies the merge change
(`prune` only removes orphaned logs and now-empty directories).

### 10.3 Metadata JSON (per entry)

```json
{
  "spec_version": "1",
  "entry": "Title Sorted/Cracked Games - Title Sorted/0-9/10th Frame/10th Frame - Masters.zip",
  "name": "10th Frame - Masters.zip",
  "source_layer": "BOTH",
  "source_size": 181107,
  "profile": "st",
  "machine": "st",
  "tos": "TOS104GE.IMG",
  "status": "done",
  "kind": "game",
  "preview_is_desktop": false,
  "preview": "10th Frame - Masters.png",
  "click": null,
  "click_retried": false,
  "click_result": null,
  "capture_method": "cmd-fifo",
  "shots": [
    {
      "file": "10th Frame - Masters.png",
      "t_seconds": 15,
      "classification": "game",
      "entropy": 4.12,
      "unique_colors": 42,
      "phash": "1a2b3c4d5e6f7a8b",
      "score": 0.71
    }
  ],
  "zip_contents": ["10th Frame - Masters.msa"],
  "started_at": "2026-10-10T23:16:00Z",
  "duration_s": 28.4,
  "tool_version": "0.1.0"
}
```

Allowed values for `kind` (section 8): `game`, `desktop`, `textscreen`,
`darkscreen`, `no_game_image` (and `null` for an entry that has no preview,
e.g. after a drive-LED reset). `status` stays `desktop` for all three
desktop sub-kinds.

The file is written only for entries that end as `done` or `desktop`.
An entry ending as `no_usable_shots` (section 8.5) has no metadata JSON;
when such an entry is reprocessed, a JSON left over from an earlier
`done`/`desktop` run is deleted, since neither its `status` nor its
`preview` reference holds any longer.

### 10.4 Index JSON

Array or object map keyed by entry relative path with: `status`, `kind`
(`game` | `desktop` | `textscreen` | `darkscreen` | `no_game_image` | null,
sections 8 and 8.4.1),
`size`, `mtime`, `profile`, `last_run`, `preview` (relative PNG name, or
null when there is no preview), `candidates` (list of `_cNN` names,
possibly non-empty even while `preview` is null, section 8.6), and for the
click retry (section 7.4): `click` (hit object `{strategy, sx, sy, score,
source}` or absent), `icon_found` (true/false after `detect`),
`click_retried` (true after an attempt), `click_result`
(`click-icon-prg` | `click-icon-drive` | `click-failed` |
`click-not-needed` | null). For drive-LED cleanup (section 8.7): `drive_led`
(true when a blank LED-white preview/candidate was found and removed) and
`drive_led_refetch` (true when a bootable `drive_led` entry should be
re-captured later; cleared again by `run --retry-drive-led` once that entry
produces a usable preview). Updated after every entry so an
interrupted run loses at most one entry of work.

### 10.5 Status × kind combinations

Not every pairing of `status` and `kind` occurs; consumers must not infer
one field from the other.

**Pipeline-generated (fixed by construction):**

| status | kind values it can ever have |
|---|---|
| `done` | `game` |
| `desktop` | `desktop`, `textscreen`, `darkscreen`, `null` (no preview: drive-LED reset, missing preview file) |
| `no_usable_shots` | `null` |
| `skipped_disk_n` | `null` |
| `error` | `null` |
| `pending`, `interrupted`, `timeout` | `null` (transient states; a completed run leaves none behind) |

**Manually curated (desktop app `C` dialog, written to index + metadata
JSON under the `shotgen.lock`):**

| status | kind values offered |
|---|---|
| `done` | `game`, `textscreen`, `darkscreen` |
| `desktop` | `desktop`, `textscreen`, `darkscreen` |
| `no_usable_shots`, `interrupted`, `pending`, `skipped_disk_n` | `null` |

Rules:

- **Never assume `done ⇒ kind game`.** `done` with `textscreen` /
  `darkscreen` is a legal state created only by manual curation (it is
  currently empty, but must be treated as valid). `done` with
  `no_game_image` is not offered by the dialog and must not be written.
- **`status: done` is final for this tool.** `run`, `detect`, `reclassify`
  and all `--retry-*` selections key on `status == desktop`, and
  `cleanup-drive-led` skips `done` entries explicitly (section 8.7), so a
  curated kind survives every later pass. `status: desktop` stays
  re-classifiable by `run` and `reclassify`.
- The desktop app's `desktop text` / `desktop black` status filters are
  deliberately **strict `status: desktop`**: an entry curated to `done`
  leaves those filters and appears as a regular `done` card/variant whose
  kind is shown as text (variant table / detail view).
- Display order (`kStatusOrder` in the desktop app, `STATUS_ORDER` in the
  gallery) depends on `status` only; `kind` is always an independent label.

---

## 11. Configuration and Secrets

### 11.1 Environment variables (only source for paths)

All from `local/paths.env` (git-ignored, never committed, never written into
specs, logs or examples):

| Variable | Required | Meaning |
|---|---|---|
| `MARCER_ROOT_DIR` | yes | game root layer, read-only |
| `MARCER_PATCH_DIR` | yes | patch layer, read-only (empty disables patch layer) |
| `MARCER_OUT_DIR` | yes | output root for screenshots, index, logs |
| `MARCER_TOS_IMG` | yes | TOS ROM image for Hatari |
| `MARCER_HATARI_BIN` | no | Hatari executable, default `hatari` from PATH |
| `MARCER_DISPLAY` | no | fixed X display number, default `:99` |

The tool refuses to start if a required variable is missing or a path is not
readable (output dir must be writable). Variable names only appear in this
document, never their values.

Proposed additions to `local/paths.env` (values supplied by the user, not by
this spec):

```
MARCER_OUT_DIR=...
MARCER_TOS_IMG=...
MARCER_HATARI_BIN=...
MARCER_DISPLAY=...
```

### 11.2 Tool config file

`tools/screenshot-gen/config.example.json` (committed, contains no paths):
scope trees, `exclude_dirs` (sub-directory names never scanned, section
4.4), time points, timeouts, filter thresholds (including the desktop
sub-kind thresholds `textscreen_min_white` and `white_pixel_min`, section
8.4.1), profile map, disk-skip patterns, `keep_candidates`. A local override
`config.local.json` (git-ignored) may exist for machine-specific tweaks.

### 11.3 Secrets

There are none. No credentials are used. NAS access is via existing mounts.

---

## 12. Launcher Integration (Future Stage)

Not part of this stage. Recorded so later work has a direction:

- The launcher could show a preview image for the selected entry, or generate
  a static HTML gallery from `MARCER_OUT_DIR`.
- Lookup key: the entry relative path equals the metadata `entry` field.
- Required changes later (proposal only, not applied now):
  - `SPEC.md`: extend rendering section with optional preview column or
    external gallery reference.
  - `README.md`: document preview feature and the generator tool.
  - `AGENTS.md`: add module overview entry, note the `tools/` directory.
  - Launcher config: optional `PreviewDirectory` field, resolved like other
    paths.

---

## 13. Risks and Open Questions

Risks:

1. **Boot time variance.** Fixed wall-clock time points will miss the action
   for slow titles and catch loaders for fast ones. Mitigation: configurable
   time points, desktop detection, later per-entry tuning from metadata.
   Pilot data: 4/10 titles showed content within 45s, 6/10 never auto-started.
2. **Titles that never auto-start.** Known case, currently surfaced as kind
   `desktop`. The desktop click retry (section 7.4) starts titles whose
   desktop shows the standard GEM program icon; titles without a matching
   icon (or where the click does not start the program) remain flagged.
   Keyboard key injection and `--auto` remain M7.
3. **Disk-2-plus skip patterns** may false-positive on game names that contain
   the word `disk`. Patterns must stay conservative and configurable.
4. **Falcon titles** need Falcon TOS, which is not available here. Falcon
   stays out of scope until a legal Falcon TOS image is provided.
5. **NFS latency** for output writes (thousands of small PNG and JSON files).
   Mitigation: mirrored tree, per-entry writes, no global transactions needed.
6. **Hatari version drift.** Verified against 2.4.1. Newer versions rename or
   add FIFO commands. The tool must detect unknown FIFO responses (the help
   text on unrecognized commands) and log them.
7. **RAM pressure** (about 2.7 GB free). One instance only, no parallelism.
8. **Zip internals.** Multi-image ZIPs: which image Hatari mounts is
   *(untested)*. The tool records `zip_contents` in metadata so anomalies are
   visible. Single-image ZIPs are the verified case.

Open questions (for the user, answer when convenient):

1. Should `keep_candidates` stay true for the first full run (more disk usage,
   better later analysis), or false (minimal output)?
2. Preview zoom: keep `--zoom 1` (832x552, small files) or `--zoom 2`
   (larger, sharper previews, more disk)?
3. Should the index and logs live inside `MARCER_OUT_DIR` (as specced), or in
   a separate state directory to keep the screenshot tree clean for later
   browsing?

Resolved decisions:

- Time points `10, 25, 45` confirmed by the user after the batch pilot.

---

## 14. Test Plan

### 14.1 Pilot run (20 entries)

- Sample 20 ZIPs across both scope trees, spread over several letters and
  game folders, including at least one entry that exists only in patch, and
  one that exists in both layers *(if such entries exist within scope; the
  pilot scan will confirm)*.
- Process the pilot with the default profile and time points.
- Evaluate:
  - boot success rate (at least one `game` shot)
  - desktop detection correctness (manually inspect flags)
  - duplicate filter sanity (no two identical previews)
  - runtime per entry (median and worst case)
  - output tree correctness (mirror structure, metadata completeness)

### 14.2 Adjustment

- Tune time points and thresholds based on pilot data.
- Re-run the pilot with `--force` and compare success rate.

### 14.3 Click retry pilot (verified)

- `detect` on the live index: true positive scores 0.53..1.0, non-GEM
  screens (e.g. crack intros) correctly marked `icon_found: false`
  *(verified)*.
- `run --retry-desktop --only <1st Division Manager> --limit 1` on a
  copied index: probe `desktop`, double click at the detected `prg` icon,
  after-click timepoints produced launch screen, black and game shots,
  entry graduated `desktop` -> `done`, old preview preserved as `_c01`,
  metadata contains `click`/`click_retried`, `click_result:
  click-icon-prg` *(verified)*.
- `run --retry-desktop --only <Bank It - Hotline> --limit 1`: probe
  `desktop` with only drive icons -> `drive` strategy. Double click
  DISKSTATION A opened the `A:\BANK_IT.HAT\` window (folder `BANK_IT`),
  descending one level revealed `BANKIT.PRG`; the program double click
  started the game (BANK IT window) after the click retry kicked in. The
  index stored `click.strategy: drive` at the DISKSTATION A centre,
  `click_retried: true` and `click_result: click-icon-drive`; the newer
  screenshots and the intermediate chain shots were kept as preview and
  candidates *(verified)*.

### 14.4 Full run

- Process all in-scope entries. Expected duration is unknown until the pilot
  gives a median per-entry time; the run must be resumable at any point.
- Final report: counts by status and kind, list of failures with reasons.

---

## 15. Milestones

Each milestone is small, independently checkable, and ends with a working
state.

- **M0** Environment check and smoke test: done (sections 2.1, 2.2).
- **M1** This spec, reviewed and approved by the user.
- **M2** Install Python packages into `.venv`, create `tools/screenshot-gen/`
  skeleton with config example and profile files.
- **M3** Index builder: bounded scan of the two scope trees, writes
  `index.json`, prints counts. Checkable against manual counts.
- **M4** Single-entry pipeline: copy, run Hatari, capture via FIFO, classify,
  write preview and metadata for one hard-coded entry.
- **M5** Filters and selection: desktop detection, dedup, scoring, preview
  choice. Checkable against the smoke test image and pilot entries.
- **M6** Pilot run of 20 entries, evaluation, threshold tuning.
- **M7** (much later) Remaining auto-start handling for desktop titles the
  icon click retry cannot start: keyboard key injection or `--auto`
  (section 7.3). The icon click retry itself (section 7.4) is implemented
  and verified.
- **M8** (later) Full run over the whole scope.
- **M9** (later) Launcher or gallery integration (section 12).

---

## 16. Conformance Checklist

A conforming implementation satisfies all of the following.

**Safety**
- [ ] S1 The tool never writes to `MARCER_ROOT_DIR` or `MARCER_PATCH_DIR`.
- [ ] S2 No path value from `local/paths.env` appears in committed files,
      logs committed anywhere, or documentation.
- [ ] S3 The ZIP is staged locally before emulation and the staging copy is
      removed after the entry.
- [ ] S4 A lock file prevents a second tool run; within one run at most
      `--jobs` Hatari instances run in parallel (default: 1).

**Input**
- [ ] I1 Merge rules match SPEC.md section 7 (case-insensitive, patch wins,
      directories aside, only `.zip` entries).
- [ ] I2 Directories starting with `@` and hidden entries are ignored.
- [ ] I3 Only the scope trees of section 4.4 are processed, and the
      `exclude_dirs` sub-directories (Boxscan/Manual/Kryoflux) are never
      scanned.
- [ ] I4 Disk-2-plus ZIPs are skipped and marked; crack variants are all
      processed.
- [ ] I5 The index is persistent, incremental, and bounded (no unbounded
      volume-wide scans).

**Pipeline**
- [ ] P1 Each entry produces Hatari logs and per-shot metadata.
- [ ] P2 Screenshots are captured via `hatari-shortcut screenshot` over the
      cmd FIFO (verified method), with documented fallbacks.
- [ ] P3 Xvfb uses explicit display numbers, never auto-selection; with
      `--jobs N` each worker gets its own fixed display.
- [ ] P4 Hatari and Xvfb are killed via process group on timeout or exit.
- [ ] P5 Per-entry timeout is enforced and the run continues after it.
- [ ] P6 `detect` finds the GEM program or drive icon in existing desktop
      previews offline, selects the `prg`/`drive` strategy, stores
      `click`/`icon_found`; misses are never booted.
- [ ] P7 `run --retry-desktop` boots only unclicked entries with a stored
      hit and runs the strategy: `prg` double clicks the program icon,
      `drive` opens DISKSTATION A and descends up to
      `click_retry.drive_max_depth` levels (folder icons) to the program
      icon. Clicks use `hatari-event doubleclick` over the FIFO, are
      retried when they do not take effect, restart the capture timepoints,
      and the attempt is recorded (`click_retried`, `clicked`,
      `click_result`). Each worker resolves its own Hatari window by process
      id, so `--jobs N` is safe, and all intermediate chain screenshots are
      kept as `_cNN` candidates.

**Filtering**
- [ ] F1 Black or empty shots are rejected by configurable thresholds.
- [ ] F2 Near-duplicate shots within one entry are dropped via perceptual
      hash distance.
- [ ] F3 TOS desktop shots are detected, flagged as kind `desktop`, and kept
      (never silently dropped).
- [ ] F4 The preview is the best `game` shot, or a `desktop` shot with
      `preview_is_desktop: true` if no game shot exists.
- [ ] F5 Drive-LED white screens are detected (`drive_led`) and removed by
      `cleanup-drive-led`, which deletes only detector-confirmed LED-white
      files, never touches entries with `status: done` and flags the
      affected entries (section 8.7); the flagged bootable ones are
      re-captured by `run --retry-drive-led`, which clears
      the flags on success, and the non-bootable ones are marked
      `kind: no_game_image`.
- [ ] F6 The entry kind `desktop` is refined into `desktop` / `textscreen` /
      `darkscreen` (section 8.4.1) both in the pipeline and by the offline
      `reclassify` pass, while `status` stays `desktop`; entries without a
      preview are skipped and reported.

**Output**
- [ ] O1 Output mirrors the source tree under `MARCER_OUT_DIR`.
- [ ] O2 Every entry processed to `done`/`desktop` has a preview PNG and a
      metadata JSON with the fields of section 10.3; an entry ending as
      `no_usable_shots` has neither (sections 8.5 and 10.3).
- [ ] O3 The index is updated after every entry (crash loses at most one
      entry of work); with parallel jobs all updates are serialized under
      one lock.
- [ ] O4 The run is resumable without `--force`, and `--force` reprocesses.
- [ ] O5 A replaced preview file is kept as an additional `_cNN` candidate
      when `keep_candidates` is set (section 8.6).
- [ ] O6 An entry ending as `no_usable_shots` keeps every captured shot as
      a `_cNN` candidate when `keep_candidates` is set (black shots
      included, unfiltered), reports `preview: null`, renames a preview
      left over from an earlier run to the next `_cNN` and deletes that
      run's stale metadata JSON (sections 8.5, 8.6, 10.3).

**Process**
- [ ] R1 Missing required environment variables abort with a clear message.
- [ ] R2 Ctrl+C leaves a consistent index and exits non-zero.
- [ ] R3 Python packages are installed only into the repo `.venv`.
- [ ] R4 `run --retry-desktop` aborts with a clear message when `xdotool`
      is not available in PATH.

---

## License

Licensed under the [MIT License](../LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
