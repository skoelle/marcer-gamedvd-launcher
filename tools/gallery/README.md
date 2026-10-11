# Gallery Webapp

Dynamic replacement for the former static `shotgen html` gallery (removed):
browses the
screenshot archive together with the game metadata as a searchable,
filterable card grid with lightbox, keyboard control and deep links.
See [`SPEC-gallery-webapp.md`](../../SPEC-gallery-webapp.md) for the full
specification.

## Requirements

- Python 3 with the repo `.venv` (no extra packages — stdlib only)
- Environment in `local/paths.env` (git-ignored):
  - `MARCER_OUT_DIR` (required): screenshot output with `index.json` + PNGs
  - `MARCER_DATA_DIR` (optional): `games-*.json` from `tools/gameinfo-gen`
    (enables metadata facets, hover info, PD/Utils views)

## Usage

```bash
tools/gallery/run.sh                 # http://0.0.0.0:8764/ (LAN-reachable)
tools/gallery/run.sh --port 9000     # other port
tools/gallery/run.sh --host 127.0.0.1  # loopback only
```

There is no authentication or TLS — anyone who can reach the bind address
can browse the archive. Use `--host 127.0.0.1` (or a firewall) if that is
not desired.

The server revalidates `index.json` and the metadata files on each API
request (mtime check), so a page reload shows the latest screenshot-run
results. There is no live refresh/polling in v1.

## Config

Defaults live in `gallery.py`. Override via `config.example.json` (copy to
`config.local.json` and adjust, git-ignored) or CLI flags. Data paths are
never configured here — they come from `local/paths.env` via `run.sh`.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
