# Screenshot Generator

Generates preview screenshots for the Marcer GameDVD archive by booting each
ZIP in Hatari on a virtual X display. See
[`SPEC-screenshot-generator.md`](../../SPEC-screenshot-generator.md) for the
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

# Desktop entries (game never started): find the GEM program icon in the
# existing desktop previews, then boot once more and click it:
tools/screenshot-gen/run.sh detect         # offline icon detection (no Hatari)
tools/screenshot-gen/run.sh run --retry-desktop   # click + capture (one attempt)
```

Interrupt with Ctrl+C at any time. Progress is saved after every entry.
A later `run` skips completed entries and retries failed or timed out ones.

By default entries are processed one at a time. `--jobs N` runs N workers
in parallel; each worker boots its own Hatari instance in the shared Xvfb
display and needs roughly 220 MB RAM and ~35% of one CPU core. All index
writes are serialized under a lock, so parallel workers never overwrite
each other's updates, and Ctrl+C stops every worker after its current
entry. Keep total CPU below ~90%, otherwise the wall-clock screenshot
timepoints may drift. `--jobs 1` (the default) is the classic serial
behavior.

### Desktop click retry (`detect` + `run --retry-desktop`)

Some ZIPs boot to the GEM desktop because the program icon was never
clicked. `detect` runs fully offline over all `desktop` entries: it
matches a template of the standard GEM program icon
(`assets/icon-prg.png`) against each existing preview PNG (FFT
normalized cross correlation, also tries the inverted/selected icon).
Hits are stored as `click` (screenshot pixel of the icon center plus
score) in the index; misses are marked `icon_found: false` and are never
booted again (`detect --force` redoes them).

`run --retry-desktop` then selects only entries with `status: desktop`
and a stored `click` that have not been clicked yet (`click_retried`).
Per entry it boots Hatari, takes one probe screenshot at
`click_retry.probe_time` (default 10 s) and:

- if it shows the desktop: positions the X pointer on the icon via
  `xdotool` (window geometry of the running Hatari instance) and sends a
  fast double click (30 ms apart; slower clicks only select the icon in
  GEM), then restarts the normal capture timepoints
  (`click_retry.timepoints_after_click`) from that moment;
- if a game (or any non-desktop screen) is already running: no click,
  capture continues normally.

The attempt is recorded once per entry (`click_retried: true`,
`clicked: true/false` in index and metadata JSON); `--retry-desktop
--force` allows a second attempt. When a previous desktop preview is
replaced by a game screenshot, the old PNG is kept as an additional
candidate (`_cNN`) instead of being overwritten. Parallel workers share
one X display, so the click sequence itself is serialized with a global
lock and raises its own Hatari window first. Hatari 2.4.1 has no
`mousemove` control command, which is why the real X pointer (XTest via
`xdotool`) is used.

## Config

Defaults live in `shotgen.py`. Override via `config.example.json` (copy and
adjust) or `config.local.json` (git-ignored). Time points are 10, 25 and 45
seconds after Hatari start. Output mirrors the source tree under
`MARCER_OUT_DIR`, one preview PNG plus optional candidate PNGs and a metadata
JSON per entry.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
