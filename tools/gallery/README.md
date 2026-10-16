# Gallery Webapp

Dynamic replacement for the former static `shotgen html` gallery (removed):
browses the
screenshot archive together with the game metadata as a searchable,
filterable card grid with lightbox, keyboard control and deep links.
See [`SPEC-gallery-webapp.md`](../../docs/SPEC-gallery-webapp.md) for the full
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

- **Sections**: tabs for games (cracked) / pd / utils (when
  `MARCER_DATA_DIR` is set).
- **Filters**: status preset, search, letter nav, publisher/crew/cracker/
  language/year facets, RAW/PASTI/Boxscan/TOS tri-state flags, and one
  combined sort dropdown (`name asc` … `crew desc`). The URL always
  reflects the current list state (shareable).
- **Statistics bar**: `X / Y with screenshot` (both games), per-status
  segments as `done <games> (<zips> zips)` (the `pending` segment and
  filter count cards whose **any** ZIP is pending), `info N folders`,
  `N without info` and the tool version right-aligned.
- **Multi-variant grid**: without an active crew/cracker filter, cards with
  several screenshots show up to four variant thumbnails (best first:
  status tier, then `kind: game`); a card with exactly **one** game shot
  shows that shot large instead of the 2×2 grid. Clicking a thumb opens
  that ZIP in the lightbox.
- **Crew/cracker focus**: picking a crew or cracker shows each card's
  screenshot for that group's ZIP, even when the variant has no screenshot
  yet (cracker takes precedence when both are set). Matching is fuzzy
  (`&`/`+` = `and`, and a token fallback for typos/missing connectives like
  "Hotline & MCA" ↔ "Hotline MCA"); when no ZIP can be identified the card
  shows a hint plus up to four screenshots of the folder's other variants.
- **Lightbox**: integer-upscaled screenshot, variant filmstrip (click or
  `↑`/`↓`; variants with a screenshot are listed first), candidate images,
  header badges (layer, status histogram, year), metadata +
  release-variant table with the open ZIP highlighted, and **clickable
  crew/cracker groups** (Game info values and release-variant rows jump to
  that group's ZIP), deep link `?entry=<rel>`.
- **Deep links**: `?entry=…` jumps to the card's page and opens it;
  closing the lightbox keeps the list state.
- **Help**: `?` opens the keyboard overview; any key closes it.
- **Favicon**: GEM desktop drawer/drive icon on the Atari ST green
  (`static/favicon.svg`, pixel-traced from `local/drawer.png`).

| Context | Keys |
|---|---|
| Grid | `←` `→` `↑` `↓` move · `Enter`/`Space` open · `PgUp`/`PgDn` page · `Home`/`End` first/last · `/` search · `?` help · `Esc` clear focus |
| Lightbox | `←` `→` previous/next card · `↑` `↓` variant (screenshots first) · `PgUp`/`PgDn` image · `Esc` close (also backdrop click) · click a crew/cracker group to jump to its ZIP |

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
