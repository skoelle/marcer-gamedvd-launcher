# SPEC: Screenshot Generator (Marcer GameDVD)

Behavioral specification for an offline screenshot generation tool for the Marcer
GameDVD archive. The tool boots every selected ZIP in the Hatari emulator on a
virtual display, captures screenshots at defined points in time, filters unusable
images and stores one good preview image (plus optional candidates) per entry.

This document is written in the style of the existing `SPEC.md` (numbered
sections, technology-neutral where possible, conformance checklist at the end).
Paths to real data are never written down literally. They come exclusively from
the git-ignored local file `local/paths.env` (see section 11).

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
  section 7.3). The implemented desktop click retry (section 7.4)
  covers exactly one icon double click, nothing more.
- No screenshots outside the selected scope's trees (section 4.4): PD
  games, tools, Falcon titles, Bonus and everything else stay out of
  scope. Utilities (`Utilitys`) are processed only in their own opt-in
  scope (section 4.4), never by the default scope.

---

## 2. Environment and Tooling

The tool targets a Linux host and requires:

| Component | Purpose |
|---|---|
| Xvfb / X11 display | one virtual display per parallel worker |
| Hatari | emulator; `--screenshot-dir`, `--statusbar`, `--crop`, `--cmd-fifo`, `--run-vbls`, `--disk-a` (accepts ZIP), `--tos`, `--machine`, `--sound off`, `--fast-boot`, `--confirm-quit`, `--zoom`, `--protect-floppy` |
| xdotool | pointer positioning and the desktop click retry (Hatari has no `mousemove` control command) |
| ImageMagick | fallback screen grabs and image analysis |
| Python 3 + Pillow, imagehash, numpy | image analysis, cropping, duplicate detection, entropy/color statistics; installed in the repo `.venv` only |

Screenshot format comes from the Hatari config (PNG). One tool process runs per
`MARCER_OUT_DIR`; parallel workers are allowed within a run (section 5).

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
- **Directory spellings are canonicalised as well.** The merge matches whole
  relative paths case-insensitively, not just file names — the same rule the
  launcher applies recursively at every level (SPEC.md R11, R12, R14): if a
  directory exists in both layers under a spelling that differs only in case,
  the patch spelling wins for **every** file below it — including files that
  exist only in the root layer (root `…/a New Game/*.zip` below patch
  `…/a new Game/`). Without this rule a root-only file would keep the root
  folder spelling next to a patch-only file's patch folder spelling, so the
  tool would emit **two case-variant output directories** (mirror and logs)
  which a case-insensitive NAS or sync client renames into
  `…_DiskStation_…CaseConflict` siblings mid-run (section 10.2).
- Canonicalisation only affects output paths. The source is still read from
  the file's own layer using that layer's spelling: where canonicalising
  changed the folder name, the index stores the layer spelling in `src_rel`
  and the run resolves `src_zip = <layer root>/src_rel` (falling back to `rel`
  for entries without the field). `rel` stays the single identity for index
  key, mirror and logs.
- Entries outside the selected scope's trees are skipped entirely
  (section 4.4).

### 4.2 Index cache

The NAS is slow. A full recursive walk over the whole volume must never happen
blindly. Instead:

- The tool maintains **one index file per scope** in `MARCER_OUT_DIR`: the
  default scope's file is `index.json` (screenshot state read by the gallery
  and desktop app; the desktop catalog universe comes from
  `gameinfo/full-index.json.gz`),
  every other scope uses `index-<name>.json` (section 4.4). A scope never
  reads or writes another scope's index file, so processing one scope can
  neither corrupt nor bloat the state of another.
- The index lists, per entry: relative path (from the layer root), name, layer
  flags (ROOT, PATCH, BOTH), file size, and the last processing status. When
  output canonicalisation rewrote the folder spelling (section 4.1), the entry
  additionally carries `src_rel` — the spelling the file has under its own
  layer root; otherwise that field is absent.
- A full index scan only walks the trees of the selected scope (section 4.4),
  with a configurable per-directory timeout and progress logging. Default full
  scan timeout budget is generous (minutes are acceptable for a full scan,
  hours are not).
- Incremental mode (default): only scan the selected scope's trees, compare
  with the stored index, report new or changed entries (size or mtime
  differs). Entries of the index that are no longer seen by the scan are
  removed from **that scope's index file only**.

### 4.3 Relative path

The relative path of an entry (for example
`Title Sorted/Cracked Games - Title Sorted/A/Arkanoid/Arkanoid - Skid 1.0.zip`)
is the identity of the entry everywhere: index key, output mirror, metadata
file, launcher integration later.

### 4.4 Scopes (user decision)

The tool processes **one scope per invocation**. A scope is a named group of
relative tree paths plus its own index file (section 4.2). Configuration:

- `scope_default`: the scope used when no `--scope` flag is given.
- `scopes`: a map of scope name → tree list (plus an optional
  `exclude_dirs` list merged with the global one). The default scope's index
  file is always `index.json`; every other scope uses `index-<name>.json`,
  unless the scope spec sets an explicit `index` key. A config without any
  `scopes` entry falls back to the legacy `scope_trees` list (one implicit
  `cracked` scope writing `index.json`).

Defined scopes:

- `cracked` (default): `Title Sorted/Cracked Games - Title Sorted` (merged
  with its patch counterpart).
- `utils` (opt-in via `--scope utils`):
  `Title Sorted/Utilitys - Title Sorted` (merged with its patch counterpart).
- `pd` (opt-in via `--scope pd`):
  `Title Sorted/PD Games - Title Sorted` (merged with its patch counterpart).
- `magazine` (opt-in via `--scope magazine`):
  `Bonus/Magazine Cover Disks`, index `index-magazine.json`, scope-local
  `exclude_dirs: ["dupes"]` so the per-magazine `Dupes/` dump folders are
  skipped (section 4.4.1). Verified 2026-10-22: 229 indexed ZIPs, 1
  `skipped_disk_n`.
- `falcon` (opt-in via `--scope falcon`):
  `Falcon 030/Title Sorted`, index `index-falcon.json`, own TOS 4.04
  (`MARCER_TOS404_IMG`) and a per-scope profile (`machine falcon`, 14 MB,
  `--dsp emu`, Videl RGB, CPU 16 MHz). Falcon titles are mostly GEMDOS
  hard-disk archives and are extracted + autostarted with `-d`/`--auto`
  (section 4.4.2). Verified 2026-10-22: 706 indexed ZIPs.

Every subcommand (`index`, `run`, `detect`, `reclassify`,
`cleanup-drive-led`, `cleanup-duplicates`, `cleanup-boot-logo`,
`promote-app-screens`, `prune`)
takes `--scope` and works exclusively on the selected scope's trees, index
file and output subtree. There is deliberately
**no "all scopes" mode**: running two scopes means running the command
twice. This keeps each index file small, keeps per-entry index rewrites
cheap, and means an experimental scope can never disturb the curated state
of the default one. *(The utils scope with a separate `index-utils.json` was
verified 2026-10-16: 12,429 indexed ZIPs, pilot run of 50 entries with
`--jobs 8`.)*

Explicitly out of scope for now (no scope defined):

- `Bonus` (except the `magazine` scope), `Tools`, the `Falcon 030/Crew
  Sorted` and `Falcon 030/Misc` trees
- All `Crew Sorted` trees
- Everything else

Within a scope's trees, sub-directories that never hold Hatari disk images
are excluded too (config `exclude_dirs`, section 11.2): `Boxscan`/`Box Scan`
(box scans), `Manual` (manuals/PDFs) and `Kryoflux` (flux dumps, usually
under `RAW`). The scanner never enters them, so their ZIPs never reach the
index. Matching is case-insensitive, ignores spaces/underscores/dashes, and
applies at any depth. A scope may extend the list via its own
`exclude_dirs` key (merged with the global one; used by `magazine` for
`dupes`). After changing the list, run `index` (dropped entries
are removed automatically) and `prune` (section 5) to clean leftovers.

Scope is defined in the tool config (section 11.2), so extending later is a
config change, not a code change. Note for UI consumers: the gallery and
desktop app read `index.json` (cracked), `index-pd.json`, `index-utils.json`,
`index-magazine.json` (section 4.4.1) and `index-falcon.json` (section
4.4.2) for screenshot state; the desktop app merges them over
`gameinfo/full-index.json.gz` (ZIP universe + hashes). Any further scope index
file is invisible to them until a future join step.

#### 4.4.1 Magazine cover disks (`magazine` scope)

`Bonus/Magazine Cover Disks` holds five magazine collections (ST Action,
ST Computer, Start Micro, The One, Zero) with no metadata at all — all
information lives in the file name. The `magazine` scope indexes them into
`index-magazine.json` (229 ZIPs, verified 2026-10-22). The per-magazine
`Dupes/` sub-folders are skipped via the scope-local `exclude_dirs:
["dupes"]`; the ZIPs directly in the magazine folder (including ` (2)`/`(3)`
copies) are indexed normally. No gameinfo or `screen_format` rules apply
(the monitor defaults to color).

The UIs group the index entries into **one card per magazine issue** using a
filename parser (`packages/marcer_catalog/lib/src/magazine.dart`,
`tools/gallery/gallery.py` `_magazine_key`): multiple disks and ` (2)`
copies become variants of the same issue, the card title is derived from the
file name (`ST Action 41`, `ST Computer 1995-02`, `Zero Issue 16`), and a
four-digit year is extracted where present. The magazine folder name is used
as the card's letter facet (magazine filter). This yields 209 cards
(47 ST Action, 84 ST Computer, 33 Start Micro, 22 The One, 23 Zero).

The scope uses `boot: "auto"`: cover disks that are **GEMDOS file
collections** (not floppy images), e.g. all ST Computer issues
(`1990_01/BASEFIND/…`, `1995_02/ELEKTROL.EX/ELEX.PRG`), are extracted and
their largest boot program autostarted with `-d` + `--auto` (floppy drives
off). Floppy-image disks (ST Action, The One, Zero, Start Micro) keep
`--disk-a`.

#### 4.4.2 Falcon 030 (`falcon` scope)

`Falcon 030/Title Sorted` holds Falcon 030 titles (706 indexed ZIPs, verified
2026-10-22). They are a different machine: the scope uses its own profile
(`machine falcon`, 14 MB ST RAM, `--dsp emu`, Videl `--monitor rgb`, CPU
16 MHz) and its own TOS 4.04 (`MARCER_TOS404_IMG`), never the ST profile/TOS.

Most Falcon titles are **GEMDOS hard-disk archives** (a `.PRG`/`.TOS`/`.TTP`/
`.APP` boot file plus data files), not floppy images. `process_entry`
therefore extracts such a ZIP into the staging directory and boots Hatari
with `-d <dir>` + `--auto C:\<PROG>` and both floppy drives disabled
(`--drive-a off --drive-b off`) — without that Falcon TOS 4.04 raises a modal
"Drive A: is not responding" dialog that blocks the autostart. The boot pick
prefers a stem match, then a stem containment match, then a numbered
multi-part set's lowest part (`AAZOHM1.TOS` before 2/3), else the largest;
STZip self-extracting archives are deprioritized. ZIPs holding only floppy
image(s) use `--disk-a`; with two images (disk A/B) the first two are
extracted and mounted as `--disk-a`/`--disk-b`. The ST mono logic is skipped
for the Videl profile. The scope uses its own timepoints `[15, 30, 60]`
(the TOS desktop is still visible at 10 s, games appear at 30/60 s).

TOS 4.04 keeps its **boot screens** visible at the early timepoints — in
practice at 15 s and 30 s; the actual game/desktop only appears at 60 s.
Two static stages occur: the white screen with the black Atari logo in the
upper-left and a plain Videl stage (solid green area plus white, no dark
content). Both carry no information about the ZIP. The capture pipeline
recognizes them (section 8.1) and never uses them as preview or candidate;
`cleanup-boot-logo` (section 8.8.1) removes shots captured before that rule
existed.

The UIs group the index entries with the generic `(letter, folder)` rule
(`Falcon 030/Title Sorted/<letter>/<game>`); no gameinfo/AtariLegend join is
performed. The section is index-only.

### 4.5 Multi-disk sets (user decision)

- Only disk 1 of a multi-disk set is processed. ZIPs whose names match
  configurable disk-2-plus patterns (default: case-insensitive regex covering
  `disk 2`, `disk 3`, `disk b`, `side b`, and similar) are skipped and marked
  `skipped_disk_n` in the index.
- Crack-variants inside one game folder are **not** multi-disk sets. Every
  crack ZIP gets its own screenshots, because crack intros differ
  (user decision).

### 4.6 Monitor selection (Mono / Color, user decision)

Monitor mode is resolved per entry before Hatari starts. The precedence is:

1. **Gameinfo `screen_format` rules** (optional, read-only) from
   `MARCER_DATA_DIR/gameinfo/games-<scope>.json`. The entry is matched by its
   `(letter, folder)` key below the selected scope tree (same grouping as
   the gallery/desktop join); sub-directories such as `Original/` therefore
   still use their game folder's values. Rules live in the config key
   `screen_format_monitor`:
   - `utils` (default: `default: mono`, `color_hints: [not mono, low, mid,
     medium, color, colour]`, `mono_hints: [mono, high]`): any color hint
     forces color, otherwise any mono hint forces mono, otherwise the entry
     defaults to **mono** (blank values and pure notes such as `Modified`,
     `Translated`, `Serie`, `Crashes`). An entry whose folder is missing
     from a successfully loaded `games-utils.json` also defaults to mono
     (`screen_format:missing-default`); this is the archive's "mono unless
     noted" convention for utilities.
   - `pd` (default: `mono_if_all: [high]`): mono only when **every** variant
     of the folder says `High` (pure high-resolution folder). Mixed values
     such as `High` + `Low`, `Med + High` or `Low-High` stay color; there is
     no per-ZIP variant matching inside a mixed folder.
2. **Folder suffix** (config `mono_dir_suffix`, default `"Mono"`): a game
   folder ending in `Mono` (e.g. `Abalone - Mono`) is mono when no gameinfo
   rule matched. The check uses the game folder below the scope tree, not
   the ZIP's immediate parent, so `Original/` sub-directories work too. The
   folder `1000 Bornes - Col and Mon` does not match (ends with `Mon`).
3. Otherwise color.

A gameinfo rule wins over a conflicting suffix. Missing `MARCER_DATA_DIR`
or `MARCER_DATA_DIR/gameinfo/games-<scope>.json` is not an error: the pass
logs a warning and uses
the suffix rule. The utils missing-folder default only applies when the
gameinfo file was loaded successfully; a completely missing file does not
force utils to mono. The per-entry log records
`monitor <mode> (<source>)` (e.g. `screen_format:high`,
`screen_format:default`, `screen_format:missing-default`,
`folder-suffix`).

Mono boots Hatari with `--mono --tos-res high`: monochrome monitor plus
explicitly forced ST high resolution 640x400. The flags are appended
entry-level on top of the selected profile's arguments; `monitor`
(`mono` | `color`) is stored in the index entry and the metadata JSON. The
capture pipeline, timepoints and filters are unchanged (screenshots are
640x400 for mono entries).

The rules apply to **future captures** only. A normal `run` still skips
finished entries (`done`, `desktop`, `no_usable_shots`); existing captures
are not recaptured automatically. `run --force --only <substring>` can
recapture selected entries explicitly. Applies in every scope (the rules
are config keys, not pipeline branches).

---

## 5. Pipeline

```
[1] load config + env (paths.env)
        |
[2] load or refresh index  (bounded scan of the selected scope's trees only)
        |
[3] select pending entries (status != done, or --force;
         with --retry-desktop: only status == desktop with a stored
         icon hit that has not been clicked yet, section 7.4;
         with --retry-no-usable: only status == no_usable_shots (skipping
         a TOS version already in tos_tried unless --force);
         with --retry-drive-led: only status == desktop with the
         drive_led_refetch flag set and kind != no_game_image, section 8.7;
         --tos <version> overrides the TOS image for the whole run, e.g.
         --retry-no-usable --tos 1.02, section 7.5)
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
still allows only one tool process per `MARCER_OUT_DIR`. Before a run the
tool creates `tmp_dir`, terminates orphaned `hatari`/`Xvfb` processes left
behind by an earlier crash (matched by the tool's `tmp_dir` path in the
Hatari command line and by the tool's display range for Xvfb, independent
of their parent process, since a crashed/OOM-killed run leaves helpers
re-parented to a subreaper) and removes `entry-*` staging dirs older than
`resource_limits.stale_stage_hours`. `--jobs` is capped from
`/proc/meminfo` `MemAvailable` **plus** `SwapFree` using
`resource_limits.per_job_mb` and `min_free_mb`; the run aborts when less
than `min_disk_free_mb` (checked for both the output and staging
filesystem) or `min_free_mb` of RAM is available. Because a worker
(thread + its Hatari child) settles at 0.6-0.8 GB during the click retry,
`per_job_mb` defaults to 800: a too-low estimate let `--jobs 8` overcommit
a small machine and the kernel OOM-killer reaped the whole process (not a
single thread). The FFT-based template matching additionally keeps its
peak memory flat (float32 image cache, one reused image FFT, prefix-sum
window statistics) and a per-process RSS ceiling
(`resource_limits.mem_guard_fraction` × `per_job_mb`, via
`configure_mem_guard`) aborts a stalled match with a `MemoryGuardTripped`
error instead of growing until the kernel kills the run; the worker
releases the FFT working set with a `gc.collect()` after every entry.
A long parallel run also used to grow without bound in **glibc malloc
arenas** (one mmap'd arena per thread) even though the Python heap stayed
flat — tracemalloc reported flat tracked memory and a flat gc-object count
while RSS climbed until the OOM killer reaped the process. `run.sh` caps
that with `MALLOC_ARENA_MAX=2` (exported before the interpreter starts)
and each worker thread calls `malloc_trim(0)` after every entry to return
the released blocks to the OS.

Besides `index`, `run` and `detect`, the tool has the `cleanup-drive-led`
subcommand (section 8.7), a standalone offline pass that removes old
drive-LED white screenshots and cleans the index, the
`cleanup-duplicates` subcommand (section 8.8), an offline pass that removes
pixel-exact duplicate candidates and updates the index/metadata, the
`cleanup-boot-logo` subcommand (section 8.8.1), an offline pass that removes
the static Falcon boot-logo candidates, the
`promote-app-screens` subcommand (section 8.9), an offline pass that
promotes an open application-window candidate of a successful desktop retry
to the preview, the `reclassify` subcommand (section 8.4.1), an offline
pass that refines the
entry kind of `desktop` entries, and the `prune`
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
- Profile selection: default `st`; a scope may override individual profile
  keys (`scopes.<name>.profile`, deep-merged) and its TOS
  (`scopes.<name>.tos_default`).
- The `falcon` scope uses a `falcon` profile (`machine falcon`, 14 MB, DSP
  emu, Videl RGB, CPU 16 MHz) and TOS 4.04 (`MARCER_TOS404_IMG`); its
  GEMDOS titles are extracted and autostarted (section 4.4.2).

### 6.4 Screenshot timing configuration

- Default time points (wall-clock seconds after Hatari start): `10, 25, 45`.
  All configurable per profile.
- Rationale: tuned against real captures. Fast titles (crack intros) already
  show content at 10s, slower loaders appear between 25s and 45s. Titles that
  never auto-start stay on the desktop regardless of waiting longer (accept and
  flag, do not wait beyond 45s; auto-start handling is M7).
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
(observed in the smoke test). Keyboard key injection remains **much later**
work (M7); `--auto` autostart is implemented for GEMDOS archives and floppy
images via the auto retry (section 7.4). The other alternative is the icon
click retry of section 7.4.

### 7.4 Desktop retry (implemented, verified)

**Click-free alternative (`run --retry-desktop-auto`).** Instead of clicking,
the image/archive is scanned before boot:

- GEMDOS archives (Falcon, magazine ST-Computer) are extracted and the
  largest program autostarted with `-d` + `--auto C:\…`.
- Floppy `.msa`/`.st` images are decoded (MSA track lengths + RLE), `.stx`
  (Pasti) images are reconstructed from their per-track sector payloads
  (`RSY\0`, track/sector headers, fuzzy masks), and the FAT12 directory is
  read. A BPB `reserved sectors` value of 0 (common in old MSA formatter/
  crack output) is normalized to the usual 1, because TOS/GEMDOS still
  places the FAT after the boot sector; without this the FAT/root lookup is
  one sector early and every directory entry is missed. A disk's own
  `AUTO/` program wins, else the largest launchable
  `.PRG`/`.TOS`/`.TTP`/`.APP`; Hatari gets
  `--disk-a <image> --auto "A:\<path>"` (drive B included for a second
  image). Self-extracting archives (LZH/STZip SFX, which only unpack onto the
  write-protected disk) are skipped. The cluster-chain walk stops at the
  first repeated cluster (hard cap 4096) and directory recursion is bounded
  (depth 32 plus a visited-set), because damaged disks can contain a cyclic
  FAT chain or a sub-directory pointing back to an ancestor; without these
  guards the scan looped forever and grew the process until the OOM killer
  reaped it (observed with the STX "Fleetstreet Publisher Fonts" disk).
- `.ipf`/non-DOS/empty images, copy-protected `.stx` without a usable boot
  sector/FAT and SFX-only disks yield no candidate: the entry is marked
  `auto_retried` / `auto_result: no_program` and stays `desktop` (the click
  retry below remains for those). No `xdotool`/`detect` run is required.

**Icon click retry (`detect` + `run --retry-desktop`).**

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
- **Multi-scale match.** Color captures render the GEM screen 2x (the
  templates were cut from them), so their icons are twice as large as those
  in native mono high-res captures (`--mono --tos-res high`, 640x400 at 1x,
  section 4.6). Every template is therefore tried at the 1x scale and as a
  0.5x variant; the 0.5x variant is binarized (>=128 -> white) so only the
  black/white structure matches — the drive template's green fill
  (0,238,0) would otherwise correlate poorly against the dithered mono
  background. The best-scoring variant wins, but a smaller scale must beat
  the larger one by a margin (0.02) before it takes over, so a weak 1x
  false positive on a color screen keeps its established pixel. The winning
  scale is stored as `scale` in the `click` object (1.0 or 0.5).
  *(verified: mono drive icons match at scale 0.5, score ~0.83)*.
- Strategy choice: a real program icon always wins; otherwise a drive icon
  selects the drive strategy. Hit: entry gets
  `click` = `{strategy, sx, sy, score, scale, source}` and
  `icon_found: true`.
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
- `click-icon-drive` — the `drive` strategy confirmed a program start
  (via DISKSTATION A and/or an already-open window),
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

**Strategy `drive`** (desktop only shows drive icons, e.g. Bank It). The
standard path is:

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

An already-open window is detected with `find_fullsize_xy` (title-bar
"full size" gadget) or, as a fallback, `find_scroll_down_xy` (vertical
scrollbar); plain desktop icon grids match neither. If a window is open,
the drive click is skipped and that window is enlarged before scanning.
Otherwise `DISKSTATION A` is double clicked, wait
`click_retry.step_wait` for the window, and the program icon is checked
first; only when it is absent is the window enlarged and scanned for the
program icon, then the folder icon, then scrolled. Then the chain walks
into the window up to `click_retry.drive_max_depth` levels
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
arrow on it (~0.84). The same bar applies to the 0.5x mono variant: its
genuine icons still score ~1.0, while a folder only matches the program
template at ~0.73 and is rejected there in favour of its own (much
stronger, ~0.90) folder match.
*(verified: Bank It - Hotline starts via drive -> folder -> PRG; 10th
Frame - Tsunoo Rhilty v2 and 10th Frame - Elsi via drive -> folder ->
PRG; mono drive -> folder -> PRG chain executes at scale 0.5.)*

**TTP command-line dialogs.** A double click on a `.TTP` launcher opens
GEM's "ANWENDUNG ÖFFNEN" dialog instead of starting the application. The
chain checks every program click with `is_ttp_dialog` (title/button
templates, section 8.9). When it matches, it single clicks `ABBRUCH`
(`assets/ttp-dialog-abort.png`), waits for the dialog to close and tries
the next program icon in the same window (`click_retry.max_icon_attempts`,
default 8). It does not backtrack to other folders. Cancellation is
retried up to `click_retry.ttp_cancel_attempts` (default 2); if the
dialog stays open the chain aborts with `click-failed`. If every program
icon is a TTP or never starts, the result is `click-failed` (no new
`click_result` value). The single-icon `prg` strategy also cancels the
dialog, but has no other stored icon to try.

**Revealing hidden icons** (`click_retry.enlarge_window`, plus
`click_retry.scroll_attempts`). A window can show fewer icons than the
folder contains, hiding the program behind a scrollbar. Two position
independent steps are tried before the drive window is written off and
before an opened folder is misread as a directly started game (a folder
window that looks like its parent changes too few pixels for the diff test
and, with no matchable icon, was previously taken for a game). The gadget
positions are detected from the window frame (`find_fullsize_xy`,
`find_scroll_down_xy`), not hard coded, because both the window placement
and the GEM gadget rendering differ between disks and monitor modes:

1. **Grow** the window by single clicking its **"full size" box**. The box
   glyph sits in the title bar just left of the window's right border; the
   click must land on the glyph's centre (a few pixels to the right, nearer
   the border, misses the gadget), so the centre is detected from the dark
   glyph block rather than a fixed offset. The mono high-res profile opens
   folder views at about half width, pushing the program's column behind a
   horizontal scrollbar; growing reveals it.
2. **Scroll down** by clicking the **vertical scrollbar's down arrow**
   (innermost right column, just above the window's bottom border), up to
   `scroll_attempts` (default 4) times. The colour profile opens wide
   windows that show only the first icon rows, hiding the rest below.

Both gadgets react to a *single* click; Hatari 2.4.1 has no single-click
control command (section 7.4 mechanics), so an *instant* XTest click is
sent (holding the button on the title bar is read as a window move).
Where the first box click is ignored until the GEM window has been
activated (observed in a headless SDL setup, where the opened window is not
the active one), the retry falls back to clicking the menu bar once and
then the box twice — the first click dismisses the menu, the second grows.
The fallback only runs when the first box click did not change the screen,
so setups where the box already works are unaffected.
*(verified: mono `Box - Mono` / `Brainbox - Mono` grow directly and
graduate to `done`; colour `Bootiful Babe` (cracked) and `Der Motor v1.1`
grow via the fallback, revealing `BOOTIFUL.PRG` / `MOTOR.PRG`.)*

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

### 7.5 TOS override and the `no_usable_shots` TOS retry (user decision)

Many old Atari titles never boot under TOS 1.04 but run fine under
TOS 1.02. Such a title hangs on a black screen, so every capture is
classified `black` (section 8.1) and the entry ends as
`no_usable_shots` even though it is a working game.

- **TOS map.** The config maps a version label to the environment
  variable holding its ROM image (section 11.2 `tos_images`): `1.04`
  (default, `MARCER_TOS_IMG`) and `1.02` (`MARCER_TOS102_IMG`). The
  alternative image is resolved lazily, so a run that does not use it
  does not require its variable to be set.
- **`run --tos <version>`.** Boots every pending entry with the given
  version instead of `tos_default`. The override combines with any
  selection flag, so the intended use is
  `run --retry-no-usable --tos 1.02` — only `no_usable_shots` entries,
  booted with TOS 1.02.
- **Marker.** A capture that succeeds with a non-default TOS records the
  version in the index entry (`tos`, section 10.4) and metadata
  (`tos`, section 10.3): `"tos": "1.02"`. The field is **sparse**:
  absent means the default TOS. Consumers (gallery, desktop app) show a
  `TOS 1.02` marker and preselect the matching Hatari launch variant.
- **Failed attempts.** A 1.02 run that still yields no usable shot keeps
  `status: no_usable_shots` and records the version in the `tos_tried`
  list (section 10.4), so a later `run --retry-no-usable --tos 1.02`
  skips it (`--force` retries anyway). On a successful capture `tos_tried`
  is cleared.
- `--tos` accepts any version label defined in `tos_images`; an unknown
  label aborts with a clear message. A missing ROM image aborts with the
  usual `require_env` message.

---

## 8. Image Filtering and Selection

All thresholds are configurable in the tool config with these defaults.

### 8.1 Reject: black or empty images

- A shot is `black` when its standard deviation is below threshold
  (default 1.0 on 0..255 scale) — that is, a *uniform* image at any
  brightness: the classic black "no video output" screen as well as the
  blank white screen.
- A very dark shot (mean luminance below threshold, default 0.02) only
  counts as `black` while it is also structureless, i.e. its standard
  deviation stays below `black_std_content_min` (default 6.0). A dark
  crack intro that draws text on black easily falls under a mean of 0.02
  while keeping a std in the tens, so it survives as a `game` shot.
- Rationale: games that failed to boot, or shots taken before the first
  video output — those screens are uniform. Darkness alone is not proof
  of a missing picture: the darkest accepted previews in the live index
  sit just above mean 0.02 with std >= 12.9, i.e. real content on black.
- **Falcon boot screens (Falcon scope only).** The static TOS 4.04 boot
  screens (section 4.4.2) are rejected like a black shot: they are not
  content of the ZIP and must never become the preview or a candidate.
  Two stages are recognized:
  - **Atari logo:** pHash match against the known logo screen
    (`filters.falcon_boot_logo_phash`, default max distance 2), with a
    geometry fallback for a changed crop/zoom: at least 98 % white
    pixels, at most 2 colours, and all dark pixels confined to the
    upper-left area (max 30 % width / 45 % height, dark pixel fraction
    <= 2 %).
  - **Plain Videl stage:** at most 2 colours, at least 20 % green and
    20 % near-white pixels covering at least 95 % of the image, and no
    dark pixels at all (`filters.falcon_boot_logo_green_min`,
    `filters.falcon_boot_logo_stage_white_min`).

  Only the **leading** non-black captures are checked, so a later
  2-colour green/white game screen is never discarded as a boot screen.
  Rejected shots are recorded in the metadata `shots` history with
  `boot_logo: true` and `dropped: "boot_logo"`, but are excluded before
  dedup and preview selection. An entry whose only captures are boot
  screens therefore ends as `no_usable_shots` without storing a boot
  screen as its preview; its candidates exclude the boot-screen grabs as
  well.

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
  `no_usable_shots` and `kind` stays `null`; no metadata JSON is written
  (section 10.3). The last capture in time order still becomes the
  preview: it is copied to the canonical `<base>.png`, independent of
  `keep_candidates`, so the entry shows an image whenever at least one
  shot was captured. With `keep_candidates` set, every *earlier*
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
all captured shots are kept in capture order — including those the
classifier rejected as `black` (section 8.1) and near-duplicates the pHash
pass would drop (section 8.2) — because nothing was usable and the raw
grabs are exactly what needs manual review. The **last** grab becomes the
preview (copied to `<base>.png`, section 8.5); the earlier grabs are the
`_c01`, `_c02`, ... candidates, disjoint from the preview. A preview left
over from an earlier successful run of the same entry is renamed to the
next free `_cNN` (it stays a candidate and can be promoted back with the
manual `M` swap), the new last grab takes the `<base>.png` slot, and the
metadata JSON of that earlier run is deleted (its `status`, `shots` and
`preview` metadata no longer describe the entry). Consumers must treat
`no_usable_shots` with a preview and its candidates as a normal,
supported state and must not infer `preview: null` from the status.
Candidate retention stays gated on `keep_candidates` (with `false`:
`candidates` stays empty), while the preview itself is written regardless
of that flag. Retained candidates are not guaranteed to be pixel-distinct:
the click chain and reruns can add exact duplicates. The offline
`cleanup-duplicates` pass (section 8.8) removes them without touching the
preview.

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
uniform white; both are classified `black` in section 8.1 because of
their near-zero pixel standard deviation) ends as `no_usable_shots` — the
old blank LED-white placeholder is gone and the entry remains reachable
via `run --retry-no-usable`. Such shots follow the general
`no_usable_shots` rules: the last shot becomes the preview and the
earlier ones are kept as `_cNN` candidates with `keep_candidates`
(section 8.6). Since the refetch runs with `--drive-led false`, none of
these images can carry the LED again, so `cleanup-drive-led` never resets
such an entry (only a legacy LED-white preview would still trigger that
reset and return the entry to `status: desktop`, section above).

Reset entries whose ZIP contains **no** bootable disk/program image
(manuals, box scans, raw dumps, data-only ZIPs) can never produce a game
screenshot. They stay `status: desktop` with `kind: no_game_image`
instead of being re-captured endlessly, and are skipped by
`run --retry-drive-led`. Bootability uses the same extension set as
`cleanup-drive-led` (`.stx`, `.msa`, `.st`, `.dim`, `.ipf`, `.prg`,
`.stt`, `.pckd`, `.pkd`).

### 8.8 Pixel-exact duplicate candidate cleanup (`cleanup-duplicates`)

Repeated captures, the click chain and older runs can leave several
candidates of one entry that show exactly the same pixels. The offline
subcommand `cleanup-duplicates` (no Hatari) removes those duplicates per
entry:

- **Comparison is pixel-exact, never perceptual.** Each existing preview
  and candidate PNG is decoded and reduced to
  `(width, height, sha256(RGBA pixels))`. Two files with the same
  signature show identical pixels even when their PNG compression or
  ancillary chunks differ; pHash distance is not used and perceptually
  similar but distinct shots are never removed.
- **Order and retention.** The preview is the first image in the
  comparison order (unless `--candidates-only` is given), so it is never
  deleted. Within the `candidates` list the first occurrence is kept and
  every later file with an already-seen pixel signature is removed. A
  candidate identical to the preview is therefore removed by default;
  `--candidates-only` ignores the preview and compares only candidates
  against each other.
- **State updates.** The entry's `candidates` list in the scope index and,
  when a metadata JSON exists, that JSON's `candidates` field are updated.
  Candidate names are not renumbered, so gaps in the `_cNN` series are a
  normal, supported state for all index consumers. The preview, `status`,
  `kind`, `tos`, click fields and the metadata `shots` capture history stay
  untouched; because only exact duplicates are removed, `done` entries
  (manual curation) are safe too.
- **Safety.** Missing or unreadable files are skipped and reported, never
  deleted. `--dry-run` only reports the counts, `--only <substring>`
  limits the pass, and `--list` prints the removed names per entry. The
  output-dir lock is taken, so the pass cannot run while a scan is active.
  Ctrl+C stops the pass and still saves the already-applied index changes.
- **Progress.** The pass prints a compact progress line at most every
  10 seconds: scanned/total entries with percentage, changed entries,
  removed (or would-remove in `--dry-run`) files with their size, and the
  current entry. It is checked between candidates and entries, so long NAS
  passes visibly keep working without flooding the output.

### 8.8.1 Falcon boot-logo cleanup (`cleanup-boot-logo`)

New Falcon captures reject the static TOS 4.04 boot screens (Atari logo
and plain green Videl stage) during analysis (section 8.1). The offline
subcommand `cleanup-boot-logo` (no Hatari) cleans entries captured before
that rule existed:

- It only runs on a scope whose effective profile has
  `machine: falcon`; other scopes print a hint and do nothing.
- Every preview and `_cNN` candidate is checked with the same detector.
  Candidate matches are deleted and removed from the scope index and the
  metadata `candidates` list; names are not renumbered (gaps are allowed,
  section 8.8).
- The preview is normally a real shot and therefore never matches. If it
  does, the best-scoring non-logo candidate is promoted in place (its file
  becomes `<base>.png`, the old preview file is overwritten) and
  `status`/`kind`/`preview_is_desktop` are recomputed from that candidate.
  Without a non-logo candidate the logo preview is kept and reported
  instead of leaving the entry without an image.
- Missing/unreadable files are skipped and reported. `--dry-run` only
  reports, `--list` prints the removed candidate names per entry,
  `--only <substring>` limits the pass, and the output-dir lock is taken.

### 8.9 Promote application-window candidates (`promote-app-screens`)

Utils frequently boot to a GEM desktop and show the real application only
in a window after a successful desktop click retry. The mono classifier
still labels such a window `desktop` / `textscreen` because it has only two
colors. The offline subcommand `promote-app-screens` (no Hatari) turns the
existing candidates into a proper preview:

- **Scope:** every entry with `status: desktop` and candidates, regardless
  of `click_result` (a `click-failed` retry can still contain a valid app
  screen, e.g. ALT).
- **Selection:** scan the `candidates` list backwards and skip everything
  that is not an application screen:
  - TTP command-line dialog (see below),
  - GEM drive/folder (file) window, detected with the fixed `A:\`
    title-path template `assets/gem-file-window.png`,
  - blank/black screens (`analyze_image` kind `black`),
  - plain TOS desktop (known mono TOS 1.04 pHash `ffbf9c9c9c888088`).
  The last remaining candidate is promoted. No fixed candidate number is
  used: the app screen is `_c01`, `_c02` or `_c03` depending on the entry,
  and full-screen text applications (e.g. Atoric) are supported too.
- **TTP launchers:** double-clicking a `.TTP` program opens GEM's
  "ANWENDUNG ÖFFNEN" command-line dialog (Name/Parameter/OK/ABBRUCH),
  which is also an open window. `is_ttp_dialog` template-matches the fixed
  title/button rows (`assets/ttp-dialog-title.png`,
  `assets/ttp-dialog-buttons.png`, German TOS 1.04). An entry with a TTP
  candidate but no real app candidate is not promoted: it is reset to
  `status: desktop` / `kind: desktop` (no longer `textscreen`).
  `--candidate N` bypasses all filters for an explicit manual choice.
- **Swap:** chosen candidate becomes `<base>.png`; the old preview is
  renamed to the chosen candidate's name. Nothing is deleted (same fixed
  filenames/behaviour as the desktop app's `M` curation).
- **State:** index entry and metadata JSON get `status: done`,
  `kind: game` (overridable with `--kind textscreen|darkscreen`), and
  `preview_is_desktop: false`; `preview` and `candidates` keep their names.
- **Options:** `--dry-run`, `--only <substring>`, `--list` (print chosen
  candidate per entry), `--candidate N` (1-based, special cases), `--kind`.
- **Limits:** the file-window template is tuned to the German mono TOS
  1.04 `A:\` drive path; other drive letters or an English TOS image need
  their own templates. Entries without any remaining app candidate are
  counted as `no app` and stay `desktop`. A following
  `cleanup-duplicates` pass removes exact duplicates created by the swap.
- The output-dir lock is taken; Ctrl+C saves already-applied index changes.

---

## 9. Robustness

- **One run, one instance:** the tool refuses to start a second concurrent
  run (lock file in `MARCER_OUT_DIR`). Within a run, `run --jobs N`
  processes up to N entries in parallel (default: 1 = serial); every
  worker runs its own Hatari process group, staging dir and Xvfb display.
  All index mutations and saves are serialized under a single lock. The
  staging root (`tmp_dir`, default `/tmp/marcer-shotgen`) is created on
  demand; orphaned `hatari`/`Xvfb` helpers of a crashed run and stale
  `entry-*` dirs are cleaned at start. Requested jobs are capped from
  `MemAvailable` + `SwapFree` (`resource_limits`) and a per-process RSS
  guard aborts a stalled template match; a run with insufficient RAM or
  disk space exits with a clear error instead of being OOM-killed. The
  process also caps glibc malloc arenas (`MALLOC_ARENA_MAX=2`, set by
  `run.sh`) and calls `malloc_trim(0)` per entry so a long parallel run
  does not grow its arenas until the OOM killer reaps it. The FAT12 scan
  guards against cyclic cluster chains and directory recursion (section
  7.x): a damaged disk that loops used to grow the process until the OOM
  killer reaped it; the chain walk stops at the first repeat, directory
  recursion is depth- and visited-bounded, and the decoders honour
  `STOP_EVENT`.
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
- **Graceful interrupt:** the first Ctrl+C asks workers to finish their
  current entry, writes the index, and exits non-zero. A second Ctrl+C
  forces an immediate exit (the PID lock remains stale and is replaced on
  the next start). FIFO writes use non-blocking `O_WRONLY|O_NONBLOCK`, so a
  crashed/exited Hatari (no FIFO reader) fails the command instead of
  blocking a worker forever; a dead Hatari is reaped during the entry
  teardown.

---

## 10. Output

### 10.1 Location and layout (user decision)

Root: `MARCER_OUT_DIR` (on the NAS, next to the patch data, see section 11).

The output mirrors the source tree of the entry relative to its layer root:

```
$MARCER_OUT_DIR/
  index.json              <- default scope (cracked)
  index-utils.json        <- utils scope (--scope utils)
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

1. The overlay merge (section 4.1) gives every game — and every directory —
   exactly one canonical spelling (the patch one), so the mirror never holds a
   `<base>.png` / `<base>.json` pair for two entries whose names differ only in
   case, and never two sibling directories that differ only in case. Two
   case-variant sibling directories are what a syncing client renames into
   `…_DiskStation_<date>_UploadPathCaseConflict/` and
   `…_UploadDBCaseConflict/` folders in the mirror and the log tree; while a
   run is writing into such a pair the client moves files away underneath it,
   which surfaces as `status: error` entries whose log ends mid-capture and
   whose `last_run` is the only trace (the run has no stored failure reason).
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
  "monitor": "color",
  "tos": "1.04",
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
`darkscreen`, `no_game_image` (and `null` for an entry that has no
preview, e.g. after a drive-LED reset, and for every `no_usable_shots`
entry — that status never carries a kind, section 8.5). `status` stays
`desktop` for all three desktop sub-kinds. `monitor` is `mono` when the
entry was booted in mono mode (section 4.6), otherwise `color`. `tos` is
the version label the entry was booted with (`1.04`, `1.02`, …; section
7.5); it is always written in the metadata. A rejected Falcon boot screen
(section 8.1) stays in the `shots` history with `boot_logo: true` and
`dropped: "boot_logo"`; it never appears as preview or candidate.

The file is written only for entries that end as `done` or `desktop`.
An entry ending as `no_usable_shots` (section 8.5) can have a preview but
never a metadata JSON; when such an entry is reprocessed, a JSON left over
from an earlier `done`/`desktop` run is deleted, since its `status`,
`shots` and `preview` metadata no longer describe the entry.

### 10.4 Index JSON

Array or object map keyed by entry relative path with: `status`, `kind`
(`game` | `desktop` | `textscreen` | `darkscreen` | `no_game_image` | null,
sections 8 and 8.4.1),
`size`, `mtime`, `profile`, `monitor` (`mono` | `color`, section 4.6),
`last_run`, `preview` (relative PNG name, or
null when no image exists at all), `candidates` (list of `_cNN` names,
disjoint from the preview, section 8.6; after `cleanup-duplicates` the
names may contain gaps, section 8.8), and for the
click retry (section 7.4): `click` (hit object `{strategy, sx, sy, score,
scale, source}` or absent), `icon_found` (true/false after `detect`),
`click_retried` (true after an attempt), `click_result`
(`click-icon-prg` | `click-icon-drive` | `click-failed` |
`click-not-needed` | null). For the TOS override (section 7.5): `tos`
(the non-default TOS version that produced a successful capture, e.g.
`"1.02"`; **absent** = default TOS) and `tos_tried` (list of non-default
versions already attempted on a still-`no_usable_shots` entry, so a repeat
`--retry-no-usable --tos <version>` skips them; cleared on success). For
drive-LED cleanup (section 8.7): `drive_led`
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
- **`no_usable_shots` may carry a preview** (sections 8.5/8.6): the status
  means "no *usable* screenshot was produced", not "no image exists".
  `kind` stays `null` while `preview` points at the last captured shot and
  `candidates` holds the earlier ones. Never infer `preview: null` from
  this status (nor `status` from `preview` being set).

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
| `MARCER_DATA_DIR` | no | data directory; gameinfo files are read from `MARCER_DATA_DIR/gameinfo/games-<scope>.json`, enables the `screen_format` monitor rules (section 4.6) |
| `MARCER_TOS_IMG` | yes | default TOS 1.04 ROM image for Hatari |
| `MARCER_TOS102_IMG` | no | TOS 1.02 ROM image, required only by `run --tos 1.02` (section 7.5) |
| `MARCER_HATARI_BIN` | no | Hatari executable, default `hatari` from PATH |
| `MARCER_DISPLAY` | no | fixed X display number, default `:99` |

The tool refuses to start if a required variable is missing or a path is not
readable (output dir must be writable). Variable names only appear in this
document, never their values.

Proposed additions to `local/paths.env` (values supplied by the user, not by
this spec):

```
MARCER_OUT_DIR=...
MARCER_DATA_DIR=...   # optional, data directory (gameinfo/ subfolder)
MARCER_TOS_IMG=...
MARCER_TOS102_IMG=...
MARCER_HATARI_BIN=...
MARCER_DISPLAY=...
```

### 11.2 Tool config file

`tools/screenshot-gen/config.example.json` (committed, contains no paths):
`scope_default` + `scopes` (per scope: tree list, optional index file name,
optional scope-local `exclude_dirs` merged with the global list, optional
scope-local `tos_default`, `timepoints`, `boot` (`auto` = detect GEMDOS vs
floppy per ZIP, sections 4.4.1/4.4.2) and an optional `profile`
deep-merged over the
global one; the
default scope maps to `index.json`, every other scope to
`index-<name>.json`, section 4.4; legacy `scope_trees` is still accepted
when no `scopes` entry exists), `mono_dir_suffix` (folder suffix that
triggers `--mono --tos-res high`, section 4.6), `screen_format_monitor`
(per-scope gameinfo rules that win over the suffix, section 4.6),
`tos_default` +
`tos_images` (version label → environment variable of its ROM image,
section 7.5; includes `4.04` for the Falcon scope), `tmp_dir` +
`resource_limits` (`per_job_mb`, `min_free_mb`, `min_disk_free_mb`,
`stale_stage_hours`, `mem_guard_fraction`; section 9), `exclude_dirs`
(sub-directory names never
scanned, section 4.4), time points, timeouts, filter thresholds (the
black/empty thresholds `black_mean_max`, `black_std_max`,
`black_std_content_min` of section 8.1 and the desktop sub-kind thresholds
`textscreen_min_white` and `white_pixel_min`, section 8.4.1), profile map,
disk-skip patterns, `keep_candidates`. A local override
`config.local.json` (git-ignored) may exist for machine-specific tweaks;
note that list-valued keys (like a scope's `trees`) are replaced as a whole
by a local override, not merged element-wise.

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
4. **Falcon titles** use TOS 4.04 (`MARCER_TOS404_IMG`, downloaded from the
   same source as the ST TOS) and the `falcon` scope (section 4.4.2).
5. **NFS latency** for output writes (thousands of small PNG and JSON files).
   Mitigation: mirrored tree, per-entry writes, no global transactions needed.
6. **Hatari version drift.** Verified against 2.4.1. Newer versions rename or
   add FIFO commands. The tool must detect unknown FIFO responses (the help
   text on unrecognized commands) and log them.
7. **RAM pressure** (about 2.7 GB free). One instance only, no parallelism.
8. **Zip internals.** Multi-image ZIPs: which image Hatari mounts is
   *(untested)*. The tool records `zip_contents` in metadata so anomalies are
   visible. Single-image ZIPs are the verified case.
9. **`status: error` carries no failure reason.** The index stores only the
   status, so a failed entry has to be diagnosed from its log and
   `last_run`. A stored error detail (copy failure, worker exception, FIFO
   timeout) is a candidate hardening step.
10. **Case-conflict siblings are only found manually.** Canonicalisation
    (section 4.1) prevents new ones, and `drop_case_variants` prevents the
    per-file variant, but folders renamed by an external sync client are
    currently only found by inspecting the tree; `prune` clears their
    leftover logs and empty directories. A dedicated check/repair path is a
    candidate.

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

- Sample 20 ZIPs across the selected scope's trees in both layers, spread
  over several letters and game folders, including at least one entry that
  exists only in patch, and one that exists in both layers *(if such entries
  exist within scope; the pilot scan will confirm)*.
- Process the pilot with the default profile and time points.
- Evaluate:
  - boot success rate (at least one `game` shot)
  - desktop detection correctness (manually inspect flags)
  - duplicate filter sanity (no two identical previews)
  - runtime per entry (median and worst case)
  - output tree correctness (mirror structure, metadata completeness)

### 14.1.1 Utils scope pilot (verified 2026-10-16)

- `index --scope utils`: 12,429 entries written to `index-utils.json`
  (11,129 pending, 1,300 `skipped_disk_n`); `index.json` (cracked)
  untouched *(verified)*.
- `run --scope utils --limit 50 --jobs 8`: 50 entries in ~6 minutes,
  48 ended `desktop` (plain TOS desktop / program menus; expected for
  utilities that do not auto-boot — candidates for `detect` +
  `run --retry-desktop`), 2 `no_usable_shots` (black at all timepoints)
  *(verified)*. Gallery unchanged; the desktop app now merges
  `gameinfo/full-index.json.gz`, so only its screenshot state comes from
  `index.json` *(verified 2026-10-16; full-index merge added 2026-10-28)*.

### 14.1.2 PD scope + mono pilot (verified 2026-10-16)

- `index --scope pd`: 6,097 entries written to `index-pd.json` (5,979
  pending, 118 `skipped_disk_n`); `index.json` (cracked) and
  `index-utils.json` byte-identical afterwards *(verified)*.
- `run --scope pd --limit 16 --jobs 4`: 16 entries in 3.4 min — 15
  `desktop`, 1 `done`. Every `… - Mono` folder (6 of the 16) logged
  `mono directory (<name>): --mono --tos-res high` and produced 640x400
  screenshots; `1000 Bornes - Col and Mon` correctly stayed color.
  Index entries and metadata carry `monitor: mono` *(verified)*.
- The mono previews show genuine ST-high GEM screens (e.g. the mono
  desktop of `123 Jumble - Mono`). Most pd entries end `desktop` (program
  menus / GEM desktop without auto-boot) — expected for the pilot window,
  same shape as the utils pilot; follow-up is `detect` + click retry.
  The color-click-retry templates (`icon-prg.png`, `icon-drive.png`) were
  cut from the 2x-scaled color screens, so at 1x they do **not** match the
  half-sized icons of native mono captures (initial `detect` found 0/6 mono
  icons). Detection therefore tries a 0.5x binarized variant as well
  (section 7.4); with it a 25-entry mono sample recovers 24/25 drive hits
  at scale 0.5, score ~0.83, and the color sample keeps its strategies
  unchanged *(verified offline)*.

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
- Mono (`monitor: mono`, section 4.6): the 2x color templates do not match
  the half-sized mono icons at 1x, so `detect` tries a 0.5x binarized
  variant (section 7.4). A 25-entry mono desktop sample recovers 24/25
  `drive` hits at scale 0.5 (score ~0.83, pixel 36,36 = floppy A), while a
  25-entry color sample keeps all its strategies and, with the 0.02 margin,
  its 1x pixels *(verified offline)*. A live `run --retry-desktop` on
  `Defend the Earth 2 - Mono` executes the full chain — drive double click
  at the scale-0.5 hit, window scan finds the program icon at scale 0.5
  and double clicks it, `click_result` is recorded; the title itself ends
  `desktop`/`textscreen` because its disk has no auto-startable game
  *(verified live)*.

### 14.4 Full run

- Process all in-scope entries. Expected duration is unknown until the pilot
  gives a median per-entry time; the run must be resumable at any point.
- Final report: counts by status and kind, list of failures with reasons.

---

## 15. Conformance Checklist

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
      only `.zip` entries), for file names **and** directory spellings: the
      merge decides case-insensitively per whole relative path and emits one
      canonical output folder per directory (section 4.1).
- [ ] I2 Directories starting with `@` and hidden entries are ignored.
- [ ] I3 Only the trees of the selected scope (section 4.4, `--scope`,
      default `scope_default`) are processed, and the `exclude_dirs`
      sub-directories (Boxscan/Manual/Kryoflux) are never scanned.
- [ ] I4 Disk-2-plus ZIPs are skipped and marked; crack variants are all
      processed.
- [ ] I5 The index is persistent, incremental, and bounded (no unbounded
      volume-wide scans); each scope has its own index file, and a
      subcommand never reads or writes another scope's index.

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
      `click`/`icon_found`; each template is matched at the 1x color scale
      and as a 0.5x binarized variant (mono high-res) with a 0.02 margin in
      favor of the larger scale; misses are never booted.
- [ ] P7 `run --retry-desktop` boots only unclicked entries with a stored
      hit and runs the strategy: `prg` double clicks the program icon;
      `drive` first checks the probe for an already-open GEM window
      (`find_fullsize_xy`/`find_scroll_down_xy`), skips the drive click and
      enlarges that window if present, otherwise opens DISKSTATION A, checks
      the program icon first and then enlarges/scans PRG -> folder -> scroll.
      It descends up to `click_retry.drive_max_depth` levels (folder icons)
      to the program icon. A TTP command dialog after a program click is
      cancelled via ABBRUCH and the next program icon in the same window is
      tried (bounded by `click_retry.max_icon_attempts`,
      `click_retry.ttp_cancel_attempts`). Clicks use
      `hatari-event doubleclick` over the FIFO, are retried when they do not
      take effect, restart the capture timepoints,
      and the attempt is recorded (`click_retried`, `clicked`,
      `click_result`). Each worker resolves its own Hatari window by process
      id, so `--jobs N` is safe, and all intermediate chain screenshots are
      kept as `_cNN` candidates. With `click_retry.enlarge_window`, a window
      that shows no program/folder icon is grown (its "full size" box) and
      then scrolled down (`click_retry.scroll_attempts` times, its scrollbar
      down arrow) so hidden icons become visible; both gadget positions are
      detected from the window frame.
- [ ] P8 Monitor mode is resolved before boot: gameinfo `screen_format`
      rules (utils "mono unless noted", pd "all High") win over the
      case-insensitive `mono_dir_suffix` folder check; mono entries boot
      with `--mono --tos-res high`, and `monitor: mono` is recorded in index
      and metadata. Missing gameinfo falls back to the suffix. The rules
      affect future captures only; finished entries are not recaptured by a
      normal run (section 4.6).
- [ ] P9 `run --tos <version>` boots with the mapped ROM image; a successful
      non-default capture records `tos` (sparse, index + metadata), a failed
      one records the version in `tos_tried`; `run --retry-no-usable` skips a
      version already in `tos_tried` unless `--force` (section 7.5).

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
- [ ] F7 `cleanup-duplicates` removes only pixel-exact duplicate candidates
      (section 8.8), keeps the preview and the first occurrence, updates the
      index and metadata `candidates` lists, leaves missing/unreadable files
      alone and limits itself to the selected scope with `--only`/`--dry-run`.
- [ ] F7a Falcon boot screens (Atari logo and plain green Videl stage) are
      rejected before preview selection (section 8.1) and
      `cleanup-boot-logo` removes old boot-screen candidates on the Falcon
      scope, promoting a non-logo preview if one ever matched
      (section 8.8.1).
- [ ] F8 `promote-app-screens` examines every `desktop` entry with
      candidates (section 8.9), scans backwards and skips TTP dialogs, GEM
      file/drive windows, blank screens and the plain TOS desktop, then
      promotes the remaining app screen (window or full-screen text) and
      swaps it like the app's `M` curation. TTP-only entries are reset to
      `desktop`/`desktop`; `--dry-run`/`--only`/`--list`/`--candidate N`
      are supported.

**Output**
- [ ] O1 Output mirrors the source tree under `MARCER_OUT_DIR`.
- [ ] O2 Every entry processed to `done`/`desktop` has a preview PNG and a
      metadata JSON with the fields of section 10.3; an entry ending as
      `no_usable_shots` has a preview PNG when at least one shot was
      captured, but never a metadata JSON (sections 8.5 and 10.3).
- [ ] O3 The index is updated after every entry (crash loses at most one
      entry of work); with parallel jobs all updates are serialized under
      one lock.
- [ ] O4 The run is resumable without `--force`, and `--force` reprocesses.
- [ ] O5 A replaced preview file is kept as an additional `_cNN` candidate
      when `keep_candidates` is set (section 8.6).
- [ ] O6 An entry ending as `no_usable_shots` uses its last capture as the
      preview (`<base>.png`, independent of `keep_candidates`), keeps every
      earlier capture as a `_cNN` candidate when `keep_candidates` is set
      (black shots included, unfiltered), renames a preview left over from
      an earlier run to the next `_cNN` and deletes that run's stale
      metadata JSON (sections 8.5, 8.6, 10.3).

**Process**
- [ ] R1 Missing required environment variables abort with a clear message.
- [ ] R2 Ctrl+C leaves a consistent index and exits non-zero.
- [ ] R3 Python packages are installed only into the repo `.venv`.
- [ ] R4 `run --retry-desktop` aborts with a clear message when `xdotool`
      is not available in PATH.

---

## License

Licensed under the [MIT License](../../LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
