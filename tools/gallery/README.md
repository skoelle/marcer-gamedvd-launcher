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
  - `MARCER_OUT_DIR` (required): screenshot output with the section
    indices (`index.json`, `index-pd.json`, `index-utils.json`,
    `index-magazine.json`, `index-falcon.json`) + PNGs
  - `MARCER_DATA_DIR` (optional): data directory; gameinfo files are read from
    `MARCER_DATA_DIR/gameinfo/`: `games-*.json` from `tools/gameinfo-gen`
    (adds metadata facets and hover info to the index-backed cards) plus the
    optional `crews.json`/`crew-images.json` from `tools/crew-analysis` for
    the Crews tab
  - `MARCER_ROOT_DIR` / `MARCER_PATCH_DIR` (optional): overlay trees for
    metadata-only boxscan/manual counts in the lightbox (read-only; no media
    is served, extracted or downloaded)

## Usage

```bash
tools/gallery/run.sh                 # http://0.0.0.0:8764/ (LAN-reachable)
tools/gallery/run.sh --port 9000     # other port
tools/gallery/run.sh --host 127.0.0.1  # loopback only
```

The app itself has no authentication or TLS — anyone who can reach the bind
address can browse the archive. Use `--host 127.0.0.1` (or a firewall) if
that is not desired. For community deployments, bind to loopback and put the
app behind a reverse proxy with **Basic Auth and TLS**; the proxy must
protect `/`, `/api/*` (including `/api/local-assets`), `/img/*` and
`/static/*`.

The server revalidates the section indices and the metadata files on each
API request (mtime check), so a page reload shows the latest screenshot-run
results. There is no live refresh/polling in v1.

## Tests

Backend filter/card helpers use stdlib `unittest` only:

```bash
.venv/bin/python -m unittest discover -s tools/gallery -p 'test_*.py'
```

## Features & Keyboard

- **Sections**: tabs for games (cracked) / pd / utils / magazines / falcon /
  crews (a tab appears when its index or gameinfo data exists; `crews`
  requires `crews.json`). Each game section joins its own screenshot index
  with the matching `games-*.json`; the `magazines` and `falcon` sections
  are index-only (`index-magazine.json`, `index-falcon.json`; no gameinfo).
- **Filters**: status preset (including the strict `desktop text` /
  `desktop black` ZIP-level presets), search, letter nav, publisher/crew/
  cracker/language/year facets, RAW/PASTI/Boxscan tri-state flags, TOS/Bad
  (also available in `pd`), and one combined sort dropdown
  (`name asc` … `crew desc`). The URL always reflects the current list
  state (shareable).
- **Statistics bar**: section-aware — `N folders`, `M with screenshot`
  (both games/cards), per-status segments as `done <games> (<zips> zips)`
  (the `pending` segment and filter count cards whose **any** ZIP is
  pending), `gameinfo N folders` (cracked), `N without gameinfo` and the
  tool version right-aligned.
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
- **Lightbox**: integer-upscaled screenshot (downscaled proportionally when
  it does not fit the available area), variant filmstrip (click or
  `↑`/`↓`; variants with a screenshot are listed first), candidate images,
  header badges (layer, status histogram, year), metadata with **This ZIP**
  (including the `Kind` row) before the release-variant table, the open ZIP
  highlighted, and **clickable crew/cracker groups** (Game info values and
  release-variant rows jump to that group's ZIP), deep link `?entry=<rel>`.
- **Crews**: the last tab lists the top 128 non-excluded groups from
  `crews.json` with curated/release previews and a `crew`/`cracker` badge;
  search covers group names, aliases and all release fields. Clicking a crew
  card opens the release browser: screenshot grid + compact release panel,
  search/sort, arrow/PgUp/PgDn/Home/End navigation, and `Enter`/double-click
  opens the selected release in the normal game lightbox (no launch/play
  button).
- **Local asset metadata**: the lightbox side panel shows boxscan/manual
  counts and edition/manual labels for the selected card when
  `MARCER_ROOT_DIR` is configured. It reads directory listings and ZIP
  central directories only — no scan/PDF bytes, no extraction, no downloads
  and no play/open controls.
- **Deep links**: `?entry=…` jumps to the card's page and opens it;
  closing the lightbox keeps the list state.
- **Help**: `?` opens the keyboard overview; any key closes it.
- **Hover info**: hovering a card for ≥ 400 ms shows the metadata panel —
  mouse-only: touch/mobile devices never show it (no hover info on mobile),
  and sticky `:hover` highlights are likewise disabled there. The same
  metadata always lives in the lightbox side panel.
- **Favicon**: GEM desktop drawer/drive icon on the Atari ST green
  (`static/favicon.svg`, pixel-traced from `local/drawer.png`).

| Context | Keys |
|---|---|
| Grid | `←` `→` `↑` `↓` move · `Enter`/`Space` open · `PgUp`/`PgDn` page · `Home`/`End` first/last · `/` search · `?` help · `Esc` clear focus |
| Lightbox | `←` `→` previous/next card · `↑` `↓` variant (screenshots first) · `PgUp`/`PgDn` image · `Esc` close (also backdrop click) · click a crew/cracker group to jump to its ZIP |
| Crew browser | `←` `→` `↑` `↓` move · `PgUp`/`PgDn` page · `Home`/`End` first/last · `Enter` open game lightbox · `/` filter releases · `Esc` clear filter / close |

## Troubleshooting

- `MARCER_OUT_DIR missing` → set it in `local/paths.env`.
- `index.json not found` → run the screenshot generator's `index` command.
- `MARCER_DATA_DIR not a directory` or
  `MARCER_DATA_DIR/gameinfo not found` → warning only; the app runs in
  screenshots-only mode (no facets/hover metadata; the pd/utils/magazine/
  falcon tabs still appear when their own indices exist).
- `MARCER_ROOT_DIR not a directory` → warning only; boxscan/manual metadata
  is disabled. An empty/missing `MARCER_PATCH_DIR` just disables the patch
  layer for that metadata.
- `crews.json not found` → the Crews tab is hidden; run
  `tools/crew-analysis/run.sh` to generate it in `MARCER_DATA_DIR/gameinfo`.
- Stale data → reload the page (mtime revalidation runs per request).

## Config

Defaults live in `gallery.py`. Override via `config.example.json` (copy to
`config.local.json` and adjust, git-ignored) or CLI flags. Data paths are
never configured here — they come from `local/paths.env` via `run.sh`.

Keys: `host`, `port`, `page_size`, `show_candidates` (grid candidate
strip on/off), `default_status` (initial status preset),
`image_cache_seconds` (HTTP cache for PNGs) and
`local_assets_cache_seconds` (metadata discovery cache for boxscans/
manuals, default 60). `show_candidates`, `default_status` and
`local_assets` are delivered to the frontend via `/api/meta`.

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
