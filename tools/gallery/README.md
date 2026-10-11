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

## Features & Keyboard

- **Sections**: tabs for Cracked Games / PD Games / Utilities (when
  `MARCER_DATA_DIR` is set).
- **Filters**: status preset, search, letter nav, publisher/crew/language/
  year facets, RAW/PASTI/Boxscan/TOS tri-state flags, sort + order.
  The URL always reflects the current list state (shareable).
- **Crew focus**: picking a crew shows each card's screenshot for that
  crew's ZIP, even when the variant has no screenshot yet. Matching is
  fuzzy (`&`/`+` = `and`, and a token fallback for typos/missing
  connectives like "Hotline & MCA" ↔ "Hotline MCA"); when no ZIP can be
  identified the card shows a hint plus up to four screenshots of the
  folder's other variants.
- **Lightbox**: integer-upscaled screenshot, variant filmstrip (click or
  `↑`/`↓`), candidate images, metadata + release-variant table with the
  open ZIP highlighted, deep link `?entry=<rel>`.
- **Deep links**: `?entry=…` jumps to the card's page and opens it;
  closing the lightbox keeps the list state.

| Context | Keys |
|---|---|
| Grid | `←` `→` `↑` `↓` move · `Enter`/`Space` open · `PgUp`/`PgDn` page · `Home`/`End` first/last · `/` search · `Esc` clear focus |
| Lightbox | `←` `→` previous/next card · `↑` `↓` variant · `PgUp`/`PgDn` image · `Esc` close (also backdrop click) |

## Troubleshooting

- `MARCER_OUT_DIR missing` → set it in `local/paths.env`.
- `index.json not found` → run the screenshot generator's `index` command.
- `MARCER_DATA_DIR not a directory` → warning only; the app runs in
  screenshots-only mode (no facets/hover metadata, PD/Utils tabs hidden).
- Stale data → reload the page (mtime revalidation runs per request).

## Config

Defaults live in `gallery.py`. Override via `config.example.json` (copy to
`config.local.json` and adjust, git-ignored) or CLI flags. Data paths are
never configured here — they come from `local/paths.env` via `run.sh`.

Keys: `host`, `port`, `page_size`, `show_candidates` (grid candidate
strip on/off), `default_status` (initial status preset), and
`image_cache_seconds` (HTTP cache for PNGs). `show_candidates` and
`default_status` are delivered to the frontend via `/api/meta`.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
