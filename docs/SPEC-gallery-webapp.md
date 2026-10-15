# SPEC: Gallery Webapp (Marcer GameDVD)

Behavioral specification for a dynamic gallery web application that replaces
the static HTML gallery produced by `shotgen html`. It presents the screenshot
archive of `tools/screenshot-gen` together with the game metadata produced by
tools/gameinfo-gen as one browsable, searchable, keyboard-friendly catalog
with the same visual design as the current static gallery.

This document is written in the style of `SPEC.md` and
`SPEC-screenshot-generator.md` (numbered sections, technology decisions
recorded, conformance checklist at the end). All absolute paths are symbolic
and resolved exclusively from the git-ignored `local/paths.env` (see section 2.1).

**Status of verified facts:** everything marked *(verified)* was measured on
the development machine on 2026-10-11 against the real data directories.
Everything else is *(untested)* and must be confirmed during implementation.

**Related documents:**
- [`SPEC.md`](SPEC.md) — launcher specification (overlay rules, section 7)
- [`SPEC-screenshot-generator.md`](SPEC-screenshot-generator.md) — screenshot pipeline, `index.json` schema
- [`ANALYSIS-game-data.md`](ANALYSIS-game-data.md) — game metadata sources and data model
- [`DECISION-app-architecture.md`](DECISION-app-architecture.md) — why this app is Python + HTML (decision record)
- [`tools/screenshot-gen/shotgen.py`](../tools/screenshot-gen/shotgen.py) — former static gallery (`html` command, `GALLERY_TEMPLATE`) — the design reference this spec replaced; both removed in M6

---

## 1. Goal and Non-Goals

### 1.1 Goal

1. Serve an interactive gallery over the screenshot archive and the game
   metadata files: card grid with the existing dark visual design, server-side
   pagination, full-text search, structured filters, sorting, and a statistics
   bar.
2. Show game metadata for every entry (hover info panel, detail view in the
   lightbox), including per-variant (per crack/release) information.
3. Provide a lightbox with the full-size original screenshot, the candidate
   screenshots (`_cNN.png`), and a variant switcher for games with multiple
   ZIPs.
4. Offer full keyboard control of the grid and the lightbox, plus deep links
   (`?entry=…`) that open a specific entry directly.
5. Cover all three metadata catalogs: cracked games (with screenshots), PD
   games and utilities (metadata-only, without screenshots).
6. Be fast with the full catalog (tens of thousands of entries) and run
   locally from the repository tooling (`.venv`, `run.sh`, `local/paths.env`).

### 1.2 Non-Goals

- **No writes** anywhere: not to the game trees, not to `MARCER_OUT_DIR`,
  not to `MARCER_DATA_DIR`, not to the repository working tree. The app is a
  strictly read-only consumer.
- **LAN bind by default.** Default bind is `0.0.0.0` so the app is
  reachable from other devices on the local network. There is no
  authentication, no TLS, no public deployment story; loopback-only binds
  are available via config/CLI (`--host 127.0.0.1`).
- **No live refresh in v1.** Changes made by a running `shotgen run` become
  visible when the user reloads (the server revalidates `index.json` on each
  API request, see section 8.4). There is no polling, push or WebSocket.
- **No thumbnails.** Original PNGs are served as-is (user decision); lazy
  loading and pagination keep the load manageable.
- **No game launching** and no replacement of the console launcher (SPEC.md)
  or the future desktop app (DECISION-app-architecture.md).
- **No user accounts, no write-back** (no favorites, no annotations), no
  configuration UI (config file only).
- No modification of `tools/screenshot-gen` beyond removing the `html`
  subcommand at the end of the migration (milestone M6, section 11).

---

## 2. Data Sources

### 2.1 Environment variables (only source for paths)

Read from `local/paths.env` (git-ignored), exactly like the other tools:

| Variable | Required | Meaning |
|---|---|---|
| `MARCER_OUT_DIR` | **yes** | screenshot output root: `index.json` + mirrored PNG tree |
| `MARCER_DATA_DIR` | no | game metadata: `games-cracked.json`, `games-pd.json`, `games-utils.json`, `manifest.json` |
| `MARCER_ROOT_DIR` | no | not read by this app (listed for completeness) |
| `MARCER_PATCH_DIR` | no | not read by this app (listed for completeness) |

Rules:

- Missing or unreadable `MARCER_OUT_DIR` → the app refuses to start with a
  clear message (same policy as `shotgen`).
- Missing or unreadable `MARCER_DATA_DIR` → app starts in **screenshots-only
  mode**: gallery, status filters and screenshot features work; metadata
  facets, hover info and the PD/Utils views are hidden and `/api/meta`
  reports `gameinfo: false` (section 4.6).
- Variable values never appear in committed files, logs or documentation
  (same rule as SPEC-screenshot-generator.md section 11).

### 2.2 Screenshot index (`<OUT>/index.json`)

*(verified, measured 2026-10-11)*

- Size ≈ 12 MB, parsed in ≈ 0.16 s *(verified)*.
- Structure `{ "version": …, "entries": { "<rel zip path>": {…} } }`;
  22,938 entries *(verified)*.
- Entry fields *(verified)*: `rel`, `name`, `status`, `kind`, `layer`,
  `preview`, `candidates`, `size`, `mtime`, `last_run`, `capture_method`,
  `duration_s`, `zip_contents`.
- Status values and counts *(verified)*:

  | status | count | meaning |
  |---|---:|---|
  | `pending` | 14,827 | not processed yet |
  | `skipped_disk_n` | 3,113 | disk-2-plus pattern skipped |
  | `desktop` | 2,947 | preview exists, desktop-only shots |
  | `done` | 1,467 | preview exists, game shots |
  | `no_usable_shots` | 572 | processed, no usable screenshot |
  | `interrupted` | 12 | run interrupted |

- `kind` maps to status for display purposes: `game` ⇔ `done`,
  `desktop` ⇔ `desktop` (same mapping as `shotgen html`).
- 1,164 entries carry `candidates` *(verified)* — the lightbox must show them.
- `no_usable_shots` entries produced from now on also carry a preview (the
  last capture) plus the earlier ones as `_cNN` candidates
  (SPEC-screenshot-generator 8.5/8.6); older ones may still have neither —
  consumers must handle both shapes.
- Entry `rel` shape *(verified)*: `Title Sorted/<tree>/<Letter>/<Folder>[/<VariantDir>]/<file>.zip`.
  Variant ZIPs may live in a subfolder of the game folder.

### 2.3 Game metadata (`<DATA>/games-*.json`)

*(verified, measured 2026-10-11)*

| File | games[] | variants[] | kind |
|---|---:|---:|---|
| `games-cracked.json` | 3,108 | 10,870 | `cracked` |
| `games-pd.json` | 1,901 | 2,846 | `pd` |
| `games-utils.json` | 3,546 | 7,689 | `utils` |

- Envelope per ANALYSIS-game-data.md §5.3: `schema_version`, `kind`,
  `source`, `generated_at`, `games[]` with `folder`, `letter`, `layers`,
  `matched_via`, `matched_title`, `variants[]`.
- Variant fields: `title`, `publisher`, `cracked_by`, `crew`, `intro_code`,
  `special_flag`, `language`, `disks`, `raw_dump`, `pasti_dump`, `boxscan`,
  `release`, `tos_bad`, `special_note` (cracked; kind-specific fields for
  pd/utils, e.g. `version`, `licence`).
- `manifest.json` (generator `tools/gameinfo-gen`, counts, source mtimes)
  is used for the statistics/coverage display and staleness hint only.
- `release` value shapes in cracked data *(verified)*: 6,640 empty,
  3,386 `YYYY`, 748 `DD-MM-YYYY`, 27 other `MM-YYYY`-like — year
  extraction must therefore be rule-based (section 4.5).

### 2.4 Design reference

The visual design derives from the former `GALLERY_TEMPLATE` static gallery
(dark theme `#14181c`, card grid, badges, filter bar) that this app replaced;
the template was deleted together with `shotgen html` in M6. The web app
reuses this design language 1:1 for existing elements (palette and layout are
frozen in `tools/gallery/static/style.css`) and extends it with the new
components (section 6).

---

## 3. Repo Integration

### 3.1 Decision

**Standalone Python application in `tools/gallery/`, standard library only,
run with the repository `.venv` via `run.sh`.**

Rationale (summarized from DECISION-app-architecture.md §4):

- Single-user local-network app serving JSON, static files and PNGs — the
  stdlib `http.server` / `ThreadingHTTPServer` covers this without adding
  any package to the `.venv`.
- Python matches the sibling tools (`shotgen.py`, `gameinfo.py`) and their
  conventions (`run.sh`, `config.example.json`, `local/paths.env`).
- The join/filter workload (≈23k entries, ≈8.5k metadata games) is a
  pure in-memory operation; *(untested)* target budgets in section 8.5.

Alternatives considered and rejected: FastAPI/uvicorn (two new packages for
no functional gain on localhost), Node/Express (new toolchain in a
C#+Python repo), Electron/Tauri (this app is browser-only by design).

### 3.2 Layout

```
tools/gallery/
  README.md            usage, points to this spec
  run.sh               loads local/paths.env, runs with repo .venv python
  gallery.py           entry point (server + API + data loading)
  static/
    index.html         app shell
    app.js             frontend logic (grid, filters, lightbox, keyboard)
    style.css          design (based on GALLERY_TEMPLATE)
    favicon.svg        GEM drawer/drive favicon (traced from local/drawer.png)
  config.example.json  committed defaults (no paths inside)
  config.local.json    optional, git-ignored machine overrides
```

Frontend dependencies: **none** — plain HTML/CSS/JavaScript, no bundler, no
npm, no CDN references (the app must work fully offline).

### 3.3 Running

```bash
tools/gallery/run.sh                 # start with defaults (0.0.0.0:8764)
tools/gallery/run.sh --port 9000     # override port
tools/gallery/run.sh --host 127.0.0.1  # loopback only
```

`run.sh` sources `local/paths.env` like the sibling tools and executes
`.venv/bin/python tools/gallery/gallery.py`. Ctrl+C shuts the server down
cleanly (no state to persist — the app owns no state).

---

## 4. Data Model and Join

### 4.1 Card grouping (one card = one game folder)

The display unit in the cracked view is the **game folder**, not the
individual ZIP *(user decision: variant grouping)*:

- One card = one `folder` (+ `letter`), showing: the best preview screenshot
  across its ZIPs, an aggregated status badge, the number of variants
  (ZIPs), the joined game metadata, and a hover info panel.
- Each card carries its `variants[]`: for every ZIP of the folder the
  relative path, status, layer, preview path and candidate list — this is
  what the lightbox consumes.
- Cards without any gameinfo match are still shown (status badge only,
  hover shows path/status info).

Rationale: the archive contains multi-crack folders (e.g. Arkanoid with 30
variants); per-ZIP cards made the old gallery repetitive and would defeat
the metadata join.

### 4.2 Join rules (cracked)

For every `index.json` entry with `rel` split into path parts:

- `letter = parts[2]`, `folder = parts[3]` — everything below (variant
  subfolders, ZIP file name) is ignored for the join.
- Join key = `(letter, folder)` against `games-cracked.json`
  (`games[]` keyed by the same pair).
- *(verified)* With these rules, 22,323 of 22,938 index entries (97 %)
  resolve to a gameinfo record; 615 entries have no metadata and are shown
  as cards without info.
- Entries whose `rel` has fewer than 5 parts or whose tree is not the
  cracked scope tree are handled defensively: shown, not joined.

### 4.3 PD and utilities views

- `games-pd.json` and `games-utils.json` are displayed in their own views
  (section 6.8) as metadata cards **without screenshots** (placeholder image
  area, like the old `ph` placeholder).
- Their folder names exist as directories in the game trees, but the
  screenshot index does not cover them (scope decision in
  SPEC-screenshot-generator.md section 4.4) — no join is attempted, no
  preview is shown. If `index.json` entries for these trees ever appear,
  the same join rule applies opportunistically *(untested, defensive)*.

### 4.4 Status aggregation for grouped cards

A game folder aggregates the statuses of its ZIPs:

- `display_status` (drives the badge and status filtering), first match wins:
  `done` → `desktop` → `no_usable_shots` → `interrupted` → `pending` →
  `skipped_disk_n`.
- `screenshots` (bool): at least one variant has `status` `done` or
  `desktop` with a preview.
- `count_done`, `count_pending` etc. are included in the card payload for
  the lightbox and statistics.
- The card's primary preview = the first (by sorted `rel`) variant preview
  with `status` `done`, else `desktop`.
- `layer` for a grouped card: the single layer value if all its ZIPs share
  one (`ROOT` or `PATCH`), otherwise `BOTH` (overlay semantics of
  SPEC.md section 7 — one logical game, present in one or both layers).

### 4.5 Year extraction

- `year = 4-digit group of a regex \d{4}` found in a variant's `release`
  value; if none is found → `unknown`.
- A game folder gets `year` = the smallest year across variants (else
  `unknown`). Sorting puts `unknown` last in both directions *(user-facing
  rule, section 7.4)*.

### 4.6 Degradation (no game metadata)

When `MARCER_DATA_DIR` is missing/unreadable or any `games-*.json` is
absent/corrupt:

- The cracked (screenshots) view works without hover metadata, metadata
  facets, sorting by metadata or the PD/Utils views.
- `/api/meta` reports per-source availability so the UI can hide controls.
- A corrupt `manifest.json` never fails startup; it only disables the
  coverage figures.

---

## 5. HTTP API

All endpoints are `GET`, responses are UTF-8 JSON unless noted. Unknown
parameters are ignored; invalid parameter values yield `400` with a JSON
error body `{ "error": "<message>" }`.

### 5.1 Endpoints

| Endpoint | Purpose |
|---|---|
| `/` | serves `static/index.html` |
| `/static/<file>` | serves `app.js`, `style.css`, `favicon.svg` (fixed file set, no listing) |
| `/api/meta` | statistics, facets, availability, ordering info |
| `/api/entries` | filtered/sorted/paginated cards (section 5.3) |
| `/img/<rel path>` | original preview/candidate PNG (section 5.4) |

### 5.2 `/api/meta`

```json
{
  "gameinfo": true,
  "index": { "entries": 22938, "mtime": 1780000000 },
  "status_counts": { "done": 1467, "desktop": 2947, "pending": 14827, "...": 0 },
  "status_labels": { "done": "done (game)", "with_screenshot": "with screenshot", "...": "..." },
  "sections": {
    "cracked": { "games": 3108, "cards": 3108, "with_screenshot": 881, "no_info": 615 },
    "pd":      { "games": 1901 },
    "utils":   { "games": 3546 }
  },
  "coverage": { "matched_folders": 3108, "unmatched_folders": 181 },
  "facets": {
    "cracked": {
      "publishers": ["Ocean", "..."],
      "crews": ["Medway Boys", "..."],
      "crackers": ["D-Bug", "..."],
      "languages": ["English", "..."],
      "years": ["1987", "..."],
      "letters": ["0-9", "A", "..."]
    },
    "pd":   { "publishers": ["..."], "letters": ["..."] },
    "utils":{ "publishers": ["..."], "crews": ["..."],
              "crackers": ["..."], "letters": ["..."] }
  },
  "show_candidates": true,
  "default_status": "with_screenshot",
  "generated_at": "…",
  "tool_version": "0.1.0"
}
```

- `facets` are computed once at startup from the metadata files and are
  **per section** (`facets[section]`, section 6.8) — the frontend reads
  `facets[state.section]`. Absent values (e.g. `crews`/`crackers` for `pd`)
  are omitted when the field does not apply to that section. `facets` is
  absent when `gameinfo` is false.
- `status_counts` always reflects the raw index (not the current filter) —
  it feeds the statistics bar; `status_labels` maps status keys to the
  human labels used in the status filter.
- `coverage` comes from `manifest.json` if available.
- `show_candidates` / `default_status` mirror the effective config
  (section 9): the frontend disables the card candidate strip when
  `show_candidates` is false and uses `default_status` as the initial
  status preset (URL parameters always win).

### 5.3 `/api/entries`

Query parameters (all optional, defaults in parentheses):

| Parameter | Values | Applies to |
|---|---|---|
| `section` | `cracked` (default) \| `pd` \| `utils` | view selection |
| `status` | `any` \| `with_screenshot` (default) \| `done` \| `desktop` \| `no_usable_shots` \| `interrupted` \| `pending` \| `skipped_disk_n` | cracked |
| `q` | free text | all |
| `letter` | `0-9` … `Z` (or facet value) \| `any` (default) | all |
| `publisher`, `crew`, `cracker`, `language`, `year` | facet value \| `any` (default) | cracked (+pd/utils where the field exists) |
| `raw`, `pasti`, `boxscan` | `any` (default) \| `yes` \| `no` | cracked |
| `tos` | `any` (default) \| `has` (only entries with a `tos_bad` note) | cracked |
| `sort` | `name` (default) \| `year` \| `publisher` \| `cracker` \| `crew` | all |
| `order` | `asc` (default) \| `desc` | all |
| `offset`, `limit` | integers (`limit` default 60, max 200) | all |
| `entry` | exact ZIP `rel` path | single-card lookup for deep links |

Semantics:

- All active filters combine with **AND**; within one facet the card matches
  if **any variant** matches.
- `q` is a case-insensitive substring match over the concatenated fields:
  folder, all variant titles, ZIP names and relative paths, publisher,
  cracked_by, crew, intro_code, language, special_flag, special_note,
  tos_bad (and pd/utils equivalents). Empty `q` = no text filter.
- `status=with_screenshot` is the **default** so the grid shows the 4,414
  screenshot cards first; `status=any` shows the full archive (including
  `pending` placeholders) — the statistics bar always shows global counts.
- `entry` returns exactly one card (regardless of filters/pagination) with
  an additional `position` field: the card's index in the filtered list
  under the requested `sort`/`order` (defaults `name`/`asc`), or `null`
  if filtered out. The frontend uses it to jump to the card's real page.
- **Crew/cracker focus:** when `crew=<value>` or `cracker=<value>` is active
  and the section supports the facet, each returned card carries
  `focus_variant` (index into `variants`, or `-1` when no ZIP could be
  identified for that value). When both are active **cracker takes
  precedence**. The card's `preview` and `display_status` then reflect that
  focused variant — **even if it has no screenshot** (empty preview →
  placeholder). This overrides `status=with_screenshot` for focused cards:
  they always appear. Matching is tried in increasing fuzziness: (1) the
  normalized value (lowercased, `&`/`+` treated as `and`, whitespace
  collapsed) is a substring of the normalized ZIP name; (2) *(crew only)* a
  gameinfo variant with that crew whose `cracked_by` appears in a ZIP name;
  (3) token subset — all tokens (alphanumeric, stopwords like
  `and`/`the`/`co` removed) appear in the ZIP name, tolerating typos or a
  missing connective such as "Hotline & MCA" vs. "Hotline MCA". Among
  multiple matches the first with a screenshot preview wins. When
  `focus_variant` is `-1` (value known at gameinfo level but no ZIP in the
  folder), the card stays visible and the frontend presents a fallback
  (section 6.3).
- Sorting is a **total order**: primary key per `sort`, ties always broken
  by lowercased name, then by `rel`. This guarantees stable pagination (no
  duplicates or gaps across pages) *(requirement, section 8.5)*.

Response:

```json
{
  "total": 3108,
  "offset": 0,
  "limit": 60,
  "sort": "name", "order": "asc",
  "cards": [
    {
      "id": "0-9/10th Frame",
      "name": "10th Frame",
      "letter": "0-9",
      "folder": "10th Frame",
      "display_status": "done",
      "screenshots": true,
      "status_counts": { "done": 2, "pending": 0 },
      "layer": "BOTH",
      "year": "1987",
      "preview": "Title Sorted/Cracked Games - Title Sorted/0-9/10th Frame/10th Frame - Pedro.png",
      "focus_variant": null,
      "variants": [
        {
          "rel": "Title Sorted/…/10th Frame/10th Frame - Pedro.zip",
          "name": "10th Frame - Pedro.zip",
          "status": "done",
          "layer": "ROOT",
          "preview": "Title Sorted/…/10th Frame/10th Frame - Pedro.png",
          "candidates": [ "Title Sorted/…/10th Frame/10th Frame - Pedro_c01.png" ]
        }
      ],
      "info": {
        "title": "10th Frame",
        "publisher": "Access",
        "cracked_by": "Zippy",
        "crew": "…",
        "language": "English",
        "disks": 1,
        "raw_dump": true, "pasti_dump": true, "boxscan": false,
        "release": "1987",
        "tos_bad": "", "special_flag": "", "special_note": "",
        "variants": [ { "…": "one row per XLS variant, same fields" } ]
      },
      "position": 0
    }
  ]
}
```

- `info` is absent when the folder has no gameinfo match or gameinfo is
  unavailable.
- `preview`/`candidates` are absent when no screenshot exists.
- Cards in `pd`/`utils` sections have `preview` absent and `info` present.

### 5.4 `/img/<rel path>`

- Serves PNG files below `MARCER_OUT_DIR` for `preview` and `candidates`
  paths returned by the API.
- Safety *(mandatory)*: after URL-decoding, the resolved real path
  (`os.path.realpath`) must be inside `MARCER_OUT_DIR`; otherwise `404`.
  Only `.png` files are served. No directory listing.
- Response headers *(untested)*: `Content-Type: image/png`,
  `Cache-Control: public, max-age=86400` (safe: PNGs are artifacts; a
  changed screenshot reappears after the cache window or with a hard reload).

### 5.5 Error behavior

| Condition | Response |
|---|---|
| missing/invalid parameter value | `400` + `{ "error": … }` |
| unknown route / non-PNG img / traversal attempt | `404` |
| `index.json` missing or unparseable at request time | `503` + error JSON (UI shows a clear banner, section 6.10) |
| metadata missing (but index fine) | `200`, degraded payload per section 4.6 |

---

## 6. UI and Interaction

### 6.1 Visual design

Reuses the former `GALLERY_TEMPLATE` design language unchanged for existing
elements *(palette frozen in `tools/gallery/static/style.css`)*:

- Background `#14181c`, text `#dde`, card `#1c2228`, headings `#9ad`,
  badge colors: game `#173`/`#cfc`, desktop `#331`/`#fd6`, failed
  `#411`/`#f88`, placeholder `#333`/`#aaa`.
- Cards ~220 px wide in a wrapping flex grid, `image-rendering: pixelated`
  for the pixel-art screenshots, `loading="lazy"` on all images.
- New components (statistics bar, facet controls, letter nav, hover panel,
  lightbox) are styled consistently with the same palette and border/radius
  language.

The app is responsive enough for desktop use (primary target); below ~700 px
the grid shrinks to fewer columns. No mobile-first work is required *(user
decision: local desktop browser)*.

### 6.2 Page structure (top to bottom)

1. **Header**: title + statistics bar (section 6.7).
2. **Section tabs**: `Screenshots` (cracked) | `PD Games` | `Utilities`
   (PD/Utils hidden in screenshots-only mode).
3. **Control bar**: search input, status select, facet filters
   (publisher/crew/cracker/language/year/flags/tos), sort select + order
   toggle, letter navigation row (A–Z + `0-9` + `Any`).
4. **Grid**: grouped cards (section 6.4), paginated.
5. **Pagination**: page indicator + prev/next + page-size-constant
   (`offset/limit`); keyboard PageUp/PageDown works on the grid (6.6).
6. **Footer**: data freshness line (index mtime, `generated_at` of
   `manifest.json`).

Filter/search/sort state is reflected in the URL query string
(`?q=…&status=…&sort=…`), so views are shareable and survive reload.
`?entry=<rel>` opens the lightbox on load (section 6.9).

### 6.3 Cards

- Badge: `display_status` with the colors above (done→`game` badge,
  desktop→`desktop`, everything else→`failed`-style badge showing the
  status label).
- Name: game folder name (`folder`), below the badge (as today).
- Variant count chip when a folder has more than one ZIP (e.g. `×3`).
- Preview image, or placeholder block when `screenshots` is false.
- **Multi-variant grid** (no focus): when no crew/cracker filter is active
  and the folder has **≥ 2 variants with a screenshot**, the card shows up
  to **four** variant screenshots in a 2×2 grid (best status first:
  `done`, then `desktop`, then the rest). Clicking a thumb opens the
  lightbox on that ZIP. Folders with a single screenshot keep the large
  single preview (+ candidate strip).
- **Crew/cracker focus fallback** (`focus_variant === -1`): when a
  crew/cracker filter matched the card via gameinfo but no ZIP in the
  folder could be identified, the card is not blank. Instead it shows a
  short hint (`no crew ZIP — other variants` / `no cracker ZIP — other
  variants`) plus up to **four small thumbnails** of the other variants
  that do have screenshots (2×2 grid); clicking a thumb opens the lightbox
  on that ZIP. When no variant has any screenshot, the plain placeholder
  is shown.
- Candidate strip (48 px thumbs, as today) when `show_candidates` is
  enabled and candidates exist — clicking a candidate opens the lightbox on
  that image. The strip is only shown on **single-variant** cards and is
  suppressed while a crew/cracker filter focuses the card (multi-variant
  cards carry the `×N` chip and use the lightbox filmstrip instead).
- `layer` label per card when available (`ROOT`/`PATCH`/`BOTH`, same
  semantics as SPEC.md section 7).

### 6.4 Hover info panel

- Hovering (≥ 400 ms delay, no delay on keyboard focus) a card shows a
  non-interactive panel with the joined metadata: title, publisher, cracker,
  crew, language, year, disks, dump flags (RAW/PASTI/Boxscan), TOS/bad note,
  special flag/note — the fields of ANALYSIS-game-data.md §5.3.
- Without gameinfo: panel shows relative path, status, layer and file size.
- Panels never cover the whole grid; they disappear on mouse leave / key
  press. Full details always live in the lightbox.

### 6.5 Lightbox

Opened by clicking a card or pressing Enter/Space on the focused card:

- Large original screenshot (first preview or selected candidate), letterbox
  on dark background, aspect ratio preserved. The main image is **upscaled
  only by integer factors** (1×, 2×, 3× … of the natural pixel size) so
  pixel-art stays crisp — fractional browser scaling is avoided.
- **Variant filmstrip** (sole variant switcher): one thumbnail per ZIP of
  the folder (preview or empty placeholder), horizontal scroll, active
  variant highlighted; hover shows the full ZIP name (native `title`
  tooltip) plus a short label under each thumb. Click switches the main
  image and metadata. Status underline: green = done, amber = desktop,
  gray = empty. When a variant has **more than one candidate** image
  (`candidates.length > 1`), a small blue `+N` count badge is shown at the
  bottom-right of its filmstrip thumbnail (above the name label).
- **Candidate strip**: preview + all `_cNN` images of the *selected*
  variant selectable. The strip always reserves a fixed height (~56 px)
  so the layout does not jump when candidates appear/disappear between
  variants.
- **Metadata table** (right-hand side panel, fixed width ~380 px): all
  fields of the selected variant's gameinfo entry, plus all XLS variants
  of the folder in a compact table (title, cracker, crew, year). The
  **Year column never wraps** (`white-space: nowrap`). The release
  variant that matches the currently selected ZIP (by cracker or crew
  name contained in the ZIP filename) is **highlighted** with a subtle
  background and bold text so the user always sees which XLS row the
  open ZIP corresponds to. With an active crew filter whose ZIP could not
  be identified (`focus_variant === -1`), the subtitle is prefixed with
  `crew ZIP not found — ` and the XLS row matching the crew (normalized
  `&`/`and` comparison) is highlighted instead.
- Navigation: `←`/`→` move to the previous/next **card of the current page**
  (v1 limit: within the loaded page), `↑`/`↓` switch variant, `PgUp`/`PgDn`
  switch image (preview/candidates), `Esc` closes, click on the backdrop
  closes.
- Status/step indicator (e.g. `3 / 60  ·  variant 2 / 3` — the variant
  part only when the folder has more than one ZIP).

### 6.6 Keyboard model

Grid focused (default after load unless the URL carries a search/entry
parameter):

| Key | Action |
|---|---|
| `←` `→` `↑` `↓` | move focus through the grid (one card / one row per press, clamped at the list edges) |
| `Enter` / `Space` | open lightbox for the focused card |
| `Esc` | close lightbox / clear focus |
| `PageUp` / `PageDown` | previous / next page |
| `Home` / `End` | first / last card of the page |
| `/` | focus the search input (any time) |
| `Esc` in search input | clear search and return focus to grid |

- All interactive elements are reachable by Tab as well; focus is always
  visible (outline consistent with the selection colors of SPEC.md).
- Mouse-only operation must remain fully equivalent.

### 6.7 Statistics bar

Shown in the header, sourced from `/api/meta`:

- Cracked view: counts by status (the six values of section 2.2) and
  `with screenshot / total`; gameinfo coverage (`matched / folders`).
- PD/Utils views: game counts + coverage from `manifest.json`.
- Current result count of the active filters (`total` of the last
  `/api/entries` response) is shown next to the controls.

### 6.8 Section views

| Tab | Source | Cards | Notes |
|---|---|---|---|
| Screenshots | join of `index.json` + `games-cracked.json` | grouped, with previews | default view |
| PD Games | `games-pd.json` | metadata cards, placeholder image | no screenshots |
| Utilities | `games-utils.json` | metadata cards, placeholder image | no screenshots |

- Letter navigation, search, sorting, publisher/language/year facets work in
  all three sections; status/flag/tos filters only in Screenshots.
- Switching tabs preserves `q`, `sort`, `order`, `letter` where applicable
  and resets incompatible filters (documented in the UI as a reset).

### 6.9 Deep links

- `?entry=<rel>`: the app loads, fetches that single card via
  `/api/entries?entry=…` (including the current sort/order/status so the
  backend can report the card's `position` in the filtered list), jumps to
  the page that contains the card and opens the lightbox at that variant.
  Closing keeps the user on the default list state (filters are untouched).
  If the card is not part of the current filter view, it is injected into
  the grid as a fallback so the lightbox still opens.
- `?q=…&status=…&section=…&letter=…&sort=…&order=…`: restored list state.
- Every filter change updates the query string via `history.replaceState`;
  opening/closing the lightbox uses `pushState` so browser Back closes the
  lightbox first *(untested, best effort)*.

### 6.10 Error and empty states

- Data source error (503): full-width banner with the error text and a
  retry button (re-fetch), no JS crash.
- No results: friendly empty-state block with a "clear filters" action.
- Missing gameinfo: controls for metadata facets hidden, small hint line in
  the footer (`gameinfo unavailable`).

---

## 7. Search, Filter and Sort Semantics (summary)

1. **Search (`q`)**: single substring, case-insensitive (Unicode-aware
   lowercase), matched against the field set of section 5.3; the card matches
   if any variant or the folder/path matches.
2. **Filters**: AND across different facets, OR (any-variant) within one
   facet; tri-state flags (`any|yes|no`).
3. **Crew/cracker focus** (`crew=<value>` / `cracker=<value>`): the grid
   shows the screenshot of the ZIP belonging to that value (`focus_variant`,
   section 5.3), even when that variant has no screenshot (placeholder);
   cracker takes precedence when both are set. When no ZIP can be
   identified (`focus_variant === -1`) the card shows a hint plus up to
   four screenshots of the folder's other variants (section 6.3). Clicking
   the card opens the lightbox on that variant.
4. **Status presets**: `with_screenshot` (default), `done`, `desktop`, … as
   listed in section 5.2; the statistics bar always shows global numbers.
5. **Sorting**: `name` (default, case-insensitive), `year` (numeric, `unknown`
   last), `publisher`, `cracker` (=`cracked_by`), `crew` (alphabetical,
   empty values last), `order` `asc|desc`; ties broken by name then `rel`
   (stable pagination).
6. **Letter navigation**: exact match on the card's `letter` facet value
   (`0-9` for the first bucket, `Any` disables the filter).

---

## 8. Robustness, Security, Performance

### 8.1 Read-only guarantee

The app opens all data sources read-only and writes nothing (no logs into
data dirs, no temp files outside the OS temp dir, no cache files). This
mirrors SPEC-screenshot-generator.md §9 write safety (S1/S2).

### 8.2 Path traversal protection

- `/img/` and `/static/` resolve via `os.path.realpath` and must be located
  under their allowed root; anything else → `404`.
- Encoded traversal attempts (`..%2f`, absolute paths, symlinks pointing
  outside) must be rejected *(security test in section 10)*.
- No endpoint reflects unvalidated path input into the file system.

### 8.3 Network exposure

- Default `host = 0.0.0.0` (LAN-reachable; no auth). Loopback-only binds
  are available via config/CLI flag (`--host 127.0.0.1`); a bind to a
  non-loopback address still prints a clear warning (no auth exists).
- No CORS headers for arbitrary origins; the app is same-origin only.

### 8.4 Data freshness (v1)

- The server `stat`s `index.json` (and the metadata files) on API requests;
  if an mtime changed, the affected dataset is reloaded once before
  answering (reload ≈ 0.16 s for the index *(verified)*, happens only on
  change).
- The UI does **not** poll; the user reloads the page to see new data.

### 8.5 Performance budgets *(targets, untested)*

| Metric | Budget |
|---|---|
| `/api/entries` with any filter (in-memory) | < 100 ms p95 |
| `/api/meta` after startup | < 50 ms |
| Initial document (HTML+CSS+JS) | < 500 KB |
| One page of JSON (`limit=60`, incl. variants/info) | < 400 KB |
| Steady-state memory (index + metadata + join) | < 300 MB |
| Images per page | 60 previews max, all `loading="lazy"` |

Design rules that keep the budgets: join/facets built once in memory,
no per-request full-file scans, pagination always server-side, `limit`
capped at 200.

### 8.6 Robustness

- Corrupt/missing individual metadata files degrade per source (4.6), never
  abort startup once `MARCER_OUT_DIR` is valid.
- Ctrl+C shuts down cleanly; SIGTERM likewise.
- Special characters (umlauts, spaces, `%`, `+`, parentheses) in folder
  names, search terms and image paths must round-trip correctly (tested in
  section 10).

---

## 9. Configuration

`config.example.json` (committed, contains no paths):

```json
{
  "host": "0.0.0.0",
  "port": 8764,
  "page_size": 60,
  "show_candidates": true,
  "default_status": "with_screenshot",
  "image_cache_seconds": 86400
}
```

- Defaults live in `gallery.py`; override via `config.local.json`
  (git-ignored) or CLI flags (`--host`, `--port`).
- `show_candidates`: enables/disables the candidate thumb strip on grid
  cards (delivered to the frontend via `/api/meta`). The lightbox strips
  are unaffected.
- `default_status`: initial status preset of the status filter (delivered
  via `/api/meta`; a `status` URL parameter always wins).
- Data paths are **never** configured here — `local/paths.env` only
  (same rule as the sibling tools).

---

## 10. Test Plan

Manual test pass (required before delivery, per AGENTS.md policy):

1. **Start/stop**: `run.sh`, `run.sh --port`, missing `MARCER_OUT_DIR`
   (clear error), missing `MARCER_DATA_DIR` (degraded mode).
2. **Baseline parity**: compare first pages against the static
   `shotgen html` gallery for the same data (cards, badges, colors, images).
3. **Search**: single word, multi word, case variants, umlauts, term that
   exists only in a ZIP file name, term matching only a publisher, no-hit
   query (empty state).
4. **Filters/facets**: each status preset; each tri-state flag; combined
   facets (AND); facet + search; letter `0-9`/`A`; clear-all.
5. **Sort**: every sort key × both orders; verify `unknown` year placement
   and stable order across pages (walk pages 1→2→3, no duplicates).
6. **Grouping**: a folder with many ZIPs shows one card with `×N`; lightbox
   variant switcher reaches all ZIPs; status badge equals aggregation rule.
7. **Lightbox**: preview, candidates, metadata table, `←`/`→` across the
   page, `Esc`, backdrop click, browser Back closes lightbox first.
8. **Keyboard**: full grid walk with arrows only, `/` focuses search,
   PageUp/PageDown paging, Home/End, focus always visible.
9. **Deep links**: `?entry=…` (with spaces/umlauts, URL-encoded),
   `?q=…&status=…`, Back/Forward behavior.
10. **Security**: `/img/../../etc/passwd`, `/img/..%2f..%2fetc/passwd`,
    absolute paths, symlink attempt → all `404`; non-PNG img → `404`;
    bind warning on default `0.0.0.0` (no auth on LAN).
11. **Freshness**: start server, run `shotgen run --limit 1`, reload page →
    new/updated card visible (section 8.4 reload path).
12. **Performance**: `/api/entries` timings on the full dataset with the
    default filter and with `status=any` (budget table, section 8.5).

---

## 11. Milestones

- **M1** Skeleton: `tools/gallery/` with `run.sh`, config, static shell,
  `/api/meta` + static serving. Checkable: page loads, stats visible.
- **M2** List API + grid: join (4.1–4.2), pagination, `with_screenshot`
  default, design parity with the old gallery. Checkable: side-by-side with
  `shotgen html`.
- **M3** Discovery: search, all facets/filters, sorting, letter nav,
  statistics bar, URL state. Checkable: section 10 items 3–5.
- **M4** Metadata views: hover panels, PD/Utils tabs, variant grouping
  completed, screenshots-only degradation. Checkable: items 6 + degraded
  mode.
- **M5** Lightbox + keyboard + deep links. Checkable: items 7–9.
- **M6** Migration & docs: remove `shotgen html` + `GALLERY_TEMPLATE` from
  `tools/screenshot-gen/shotgen.py` (keep `run.sh html` failing with a
  pointer to the new tool), update `tools/screenshot-gen/README.md`,
  `tools/gallery/README.md`, root `README.md` (usage) and `AGENTS.md`
  (tools overview), and sync `ANALYSIS-game-data.md` §5.1 +
  `DECISION-app-architecture.md` §5 with `MARCER_DATA_DIR`. Checkable:
  section 10 full pass + docs review.

---

## 12. Conformance Checklist

A conforming implementation satisfies all of the following.

**Safety**
- [x] S1 The app never writes to `MARCER_OUT_DIR`, `MARCER_DATA_DIR`, the
      game trees or the repository working tree.
- [x] S2 No path value from `local/paths.env` appears in committed files or
      documentation.
- [x] S3 `/img/` and `/static/` reject traversal (realpath containment,
      PNG-only), verified with the section 10 attacks.
- [x] S4 Default bind is `0.0.0.0`; non-loopback binds print a warning.

**Data**
- [x] D1 Join uses `parts[2]`/`parts[3]` only; entries without gameinfo are
      shown, never dropped.
- [x] D2 Without `MARCER_DATA_DIR` the app runs in screenshots-only mode
      (section 4.6).
- [x] D3 Status aggregation and primary preview follow section 4.4.
- [x] D4 Year extraction follows section 4.5 (`unknown` handling).

**API**
- [x] A1 All endpoints of section 5 exist with the documented parameters.
- [x] A2 Pagination is stable (total order, section 5.3) — no duplicate or
      skipped cards across consecutive pages.
- [x] A3 `entry` returns a single card with `position`.
- [x] A4 Errors follow section 5.5 (400/404/503), JSON error bodies.

**UI**
- [x] U1 Visual design matches the `GALLERY_TEMPLATE` language (colors,
      cards, badges, lazy images).
- [x] U2 All section 6.6 keys work in the grid; all lightbox keys (6.5)
      work.
- [x] U3 Hover panels and lightbox show the gameinfo fields (or path info
      without gameinfo).
- [x] U4 Deep links `?entry=` and list-state params behave per section 6.9.
- [x] U5 Statistics bar shows global counts and current result count.
- [x] U6 PD/Utils sections render metadata cards without previews.

**Process**
- [x] P1 Zero new packages in the repo `.venv` (stdlib only).
- [x] P2 `run.sh` sources `local/paths.env` and uses the repo `.venv`.
- [x] P3 Full manual test pass (section 10) completed before delivery.
- [x] P4 `shotgen html` removed and all docs listed in M6 updated.

---

## License

Licensed under the [MIT License](../LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
