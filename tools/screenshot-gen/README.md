# Screenshot Generator

Generates preview screenshots for the Marcer GameDVD archive by booting each
ZIP in Hatari on a virtual X display. See
[`SPEC-screenshot-generator.md`](../../SPEC-screenshot-generator.md) for the
full specification.

## Requirements

- Hatari (verified with 2.4.1), Xvfb, Python 3 with the repo `.venv`
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
tools/screenshot-gen/run.sh html           # build gallery index.html
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

## Config

Defaults live in `shotgen.py`. Override via `config.example.json` (copy and
adjust) or `config.local.json` (git-ignored). Time points are 10, 25 and 45
seconds after Hatari start. Output mirrors the source tree under
`MARCER_OUT_DIR`, one preview PNG plus optional candidate PNGs and a metadata
JSON per entry.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
