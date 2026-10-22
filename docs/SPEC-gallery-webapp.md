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
5. Cover all metadata catalogs: cracked games (with screenshots), PD
   games and utilities (metadata-only, without screenshots) plus the
   filename-only magazine cover disks section.
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
  visible when the user reloads (the server revalidates the section indices
  on each API request, see section 8.4). There is no polling, push or
  WebSocket.
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
| `MARCER_OUT_DIR` | **yes** | screenshot output root: section indices + mirrored PNG tree |
| `MARCER_DATA_DIR` | no | game metadata: `games-cracked.json`, `games-pd.json`, `games-utils.json`, `manifest.json` |
| `MARCER_ROOT_DIR` | no | not read by this app (listed for completeness) |
| `MARCER_PATCH_DIR` | no | not read by this app (listed for completeness) |

Rules:

- Missing or unreadable `MARCER_OUT_DIR` → the app refuses to start with a
  clear message (same policy as `shotgen`).
- Missing or unreadable `MARCER_DATA_DIR` → app starts in **screenshots-only
  mode**: gallery, status filters and screenshot features work; metadata
  facets and hover info are hidden and `/api/meta` reports
  `gameinfo: false` (section 4.6). The PD/Utils views remain available
  whenever their own indices exist (index-backed cards without metadata).
- Variable values never appear in committed files, logs or documentation
  (same rule as SPEC-screenshot-generator.md section 11).

### 2.2 Screenshot indices (`<OUT>/index.json`, `index-pd.json`, `index-utils.json`, `index-magazine.json`)

*(verified, measured 2026-10-11; per-section split 2026-10-16; magazine 2026-10-22)*

- Four files with identical structure, one per section:
  `index.json` (cracked, back-compat name), `index-pd.json` (PD games),
  `index-utils.json` (utilities) and `index-magazine.json` (magazine cover
  disks, index-only without gameinfo). Missing cracked `index.json` refuses
  startup (section 2.1); missing pd/utils/magazine indices yield empty
  sections (pd/utils cards then come from gameinfo only). Per-section mtimes
  are reported in `/api/meta` (section 5.2).
- Cracked `index.json`: size ≈ 12 MB, parsed in ≈ 0.16 s *(verified)*.
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

- `games-pd.json` / `games-utils.json` are shown in their own views
  (section 6.8). Each section has its **own screenshot index**
  (`index-pd.json` / `index-utils.json`, section 2.2), so a card is the
  **union** of:
  1. its index entries grouped by `(letter, folder)` — carrying status
     counts, screenshots, variants and previews exactly like the cracked
     view (section 4.4), joined with gameinfo when available; and
  2. gameinfo folders **without** an index entry — metadata-only cards
     (placeholder image area, like the old `ph` placeholder), the former
     behaviour.
- When a section's index is absent (or gameinfo is unavailable), the
  respective half simply contributes nothing: pd/utils degrade to
  gameinfo-only metadata cards, and — index available but no gameinfo —
  to status/preview cards without metadata.
- Join key, grouping and status aggregation rules are identical to the
  cracked view (sections 4.2/4.4); `kind_fields`/`kind_filters` (section
  6.8) still restrict which metadata facets apply per section.

### 4.4 Status aggregation for grouped cards

A game folder aggregates the statuses of its ZIPs:

- `display_status` (drives the badge and status filtering), first match wins:
  `done` → `desktop` → `no_usable_shots` → `interrupted` → `pending` →
  `skipped_disk_n`.
- `screenshots` (bool): at least one variant has any preview (including
  `no_usable_shots`, which keeps its last capture, section 8.5 of
  `SPEC-screenshot-generator.md`).
- `count_done`, `count_pending` etc. are included in the card payload for
  the lightbox and statistics.
- The card's primary preview = the first (by sorted `rel`) variant preview
  with `status` `done` **and `kind` `game`**, else the first with
  `status` `done`, else the first with `status` `desktop`, else the first
  variant with any preview (desktop-app parity: a real game shot wins over
  e.g. a `textscreen`; a `no_usable_shots` preview is shown when it is the
  only image; within a tier the sorted-`rel` order decides).
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
  facets or sorting by metadata; the PD/Utils views still work when their
  section indices exist (cards without metadata).
- `/api/meta` reports per-source availability so the UI can hide controls.
- A corrupt `manifest.json` never fails startup; it only disables the
  coverage figures.
- A missing/corrupt pd/utils index simply empties that half of the section
  (cards then come from gameinfo only); a missing cracked `index.json`
  refuses startup (section 2.1).

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
  "index": {
    "cracked": { "entries": 22938, "mtime": 1780000000 },
    "pd":      { "entries": 2846,  "mtime": 1780000000 },
    "utils":   { "entries": 7689,  "mtime": 1780000000 },
    "magazine":{ "entries": 229,   "mtime": 1780000000 }
  },
  "status_counts": {
    "cracked": { "done": 1467, "desktop": 2947, "pending": 14827, "...": 0 },
    "pd":      { "...": 0 },
    "utils":   { "...": 0 },
    "magazine":{ "pending": 228, "skipped_disk_n": 1 }
  },
  "game_status_counts": {
    "cracked": { "done": 881, "desktop": 400, "pending": 1500, "...": 0 },
    "pd":      { "...": 0 },
    "utils":   { "...": 0 },
    "magazine":{ "pending": 209 }
  },
  "status_labels": { "done": "done (game)", "with_screenshot": "with screenshot", "...": "..." },
  "sections": {
    "cracked": { "games": 3108, "cards": 3108, "with_screenshot": 881, "no_info": 615 },
    "pd":      { "games": 1901, "cards": 1901, "with_screenshot": 0,   "no_info": 0 },
    "utils":   { "games": 3546, "cards": 3546, "with_screenshot": 0,   "no_info": 0 },
    "magazine":{ "games": 0,    "cards": 209,  "with_screenshot": 0,   "no_info": 209 }
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
              "crackers": ["..."], "letters": ["..."] },
    "magazine": { "years": ["1994", "..."],
                  "letters": ["ST Action", "ST Computer", "..."] }
  },
  "show_candidates": true,
  "default_status": "with_screenshot",
  "generated_at": "…",
  "tool_version": "0.1.0"
}
```

- `index`, `status_counts`, `game_status_counts` and `sections` are **per
  section** maps keyed by `cracked`/`pd`/`utils`/`magazine`; the statistics
  bar and footer read the entry for the active section (`desktop-app parity`,
  where the status bar is section-aware). `magazine` has no gameinfo, so its
  `games` count is `0` and `no_info` equals its card count.
- `facets` are computed once at startup from the metadata files and are
  **per section** (`facets[section]`, section 6.8) — the frontend reads
  `facets[state.section]`. Absent values (e.g. `crews`/`crackers` for `pd`)
  are omitted when the field does not apply to that section. `facets` is
  absent when `gameinfo` is false.
- `status_counts[section]` always reflects that section's raw index (not the
  current filter) — it feeds the statistics bar; `status_labels` maps status
  keys to the human labels used in the status filter.
- `game_status_counts[section]` counts the section's **cards** per
  aggregated `display_status`, except `pending`, which uses the any-variant
  rule of section 5.3 so the statistics-bar segment equals the pending
  filter's result count (desktop-app parity). Without gameinfo the
  statistics bar ignores it and shows the ZIP-level counts only.
- `sections[section]` additionally carries `cards` and `with_screenshot`
  (cards, index-backed) and `no_info` (cards without gameinfo), which the
  statistics bar uses for the `M / N with screenshot` and `N without info`
  segments; the cracked `coverage.matched_folders` figure stays
  cracked-only.
- `coverage` comes from `manifest.json` if available.
- `show_candidates` / `default_status` mirror the effective config
  (section 9): the frontend disables the card candidate strip when
  `show_candidates` is false and uses `default_status` as the initial
  status preset for the cracked section (pd/utils default to `any`; URL
  parameters always win).

### 5.3 `/api/entries`

Query parameters (all optional, defaults in parentheses):

| Parameter | Values | Applies to |
|---|---|---|
| `section` | `cracked` (default) \| `pd` \| `utils` \| `magazine` | view selection |
| `status` | `any` \| `with_screenshot` \| `done` \| `desktop` \| `no_usable_shots` \| `interrupted` \| `pending` \| `skipped_disk_n` | all (default `with_screenshot` for `cracked`, `any` for `pd`/`utils`/`magazine`) |
| `q` | free text | all |
| `letter` | `0-9` … `Z` (or facet value) \| `any` (default) | all (magazine: magazine name) |
| `publisher`, `crew`, `cracker`, `language`, `year` | facet value \| `any` (default) | cracked (+pd/utils where the field exists; magazine: `year` only) |
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
- `status=with_screenshot` is the **default** for `cracked` so the grid shows
  the 4,414 screenshot cards first; `pd`/`utils` default to `any` (their
  metadata-only cards have no screenshot). `status=any` shows the full
  archive (including `pending` placeholders) — the statistics bar always
  shows the active section's counts.
- `status=pending` matches a card when **any** of its ZIPs is `pending`
  (not the `display_status` aggregate: a folder with a `done` ZIP plus a
  `pending` ZIP is shown as `done` **and** as `pending`; the aggregated
  rule would hide it from the pending view). All other concrete statuses
  match the aggregated `display_status` (desktop-app parity).
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
          "kind": "game",
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
- Each variant carries the raw `kind` of its index entry (`game`,
  `textscreen`, `darkscreen`, …; empty string when the entry has none) —
  the frontend needs it for the preview/thumbnail preference rules
  (sections 4.4 and 6.3).
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
- Cards ~220 px wide in a wrapping flex grid, downscaled with the browser's
  high-quality resampling (`image-rendering: auto`) so shrunken 832x552
  screenshots stay smooth like in the desktop app; nearest-neighbor
  (`image-rendering: pixelated`) is reserved for the integer-scaled lightbox
  main image. `loading="lazy"` on all images.
- New components (statistics bar, facet controls, letter nav, hover panel,
  lightbox) are styled consistently with the same palette and border/radius
  language.

The app is responsive enough for desktop use (primary target); below ~700 px
the grid shrinks to fewer columns. No mobile-first work is required *(user
decision: local desktop browser)*. Touch/mobile is explicitly excluded from
hover-only affordances: the hover info panel and sticky `:hover` highlights
never appear on touch devices (section 6.4) — tapping a card only opens the
lightbox, whose side panel carries the same metadata.

### 6.2 Page structure (top to bottom)

1. **Header**: title + statistics bar (section 6.7).
2. **Section tabs**: `games` (cracked) | `pd` | `utils` | `magazines`
   (a tab is hidden when its section has no cards; labels match the desktop
   app's section tabs).
3. **Control bar**: search input, status select, facet filters
   (publisher/crew/cracker/language/year/flags/tos), one **combined
   sort+order dropdown** with the ten entries `<key> asc|desc`
   (`name`/`year`/`publisher`/`cracker`/`crew`, e.g. `year desc` — the
   URL keeps the separate `sort`/`order` parameters), letter navigation
   row (A–Z + `0-9` + `Any`).
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
  to **four** variant screenshots in a 2×2 grid (best first: status tier
  `done`, then `desktop`, then the rest; **within a tier `kind` `game`
  before other kinds**, then variant order — desktop `thumbIndices`).
  Exception: when exactly **one** shown thumb is a `done` game shot, the
  card shows that game screenshot large instead of the 2×2 grid (the
  desktop app's single game-shot card). Clicking a thumb opens the
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

- The panel is a **mouse-only affordance**: on touch/mobile devices the
  media query `(hover: hover) and (pointer: fine)` does not match and the
  panel is **never shown** — a tap must not raise an info overlay (mobile
  parity: no hover info). Sticky `:hover` highlight styles throughout the
  UI are gated behind `@media (hover: hover)` for the same reason; keyboard
  focus styles (`:focus-visible`, `.kbd-focus`) are unaffected.
- Hovering a card (≥ 400 ms delay; **mouse hover only** — keyboard focus
  does not raise the panel) shows a
  non-interactive panel with the joined metadata: title, publisher, cracker,
  crew, language, year, disks, dump flags (RAW/PASTI/Boxscan), TOS/bad note,
  special flag/note — the fields of ANALYSIS-game-data.md §5.3.
- Without gameinfo: panel shows relative path, status, layer and file size.
- Panels never cover the whole grid; they disappear on mouse leave, key
  press and when the grid scrolls under them. Full details always live in
  the lightbox.

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
  - **Display order**: variants **with a screenshot first** (stable), then
    the preview-less ones — only the rendered order and the `↑`/`↓`
    navigation follow this; the underlying variant index (URL, side panel,
    `↑`/`↓` target mapping) is unchanged (desktop-app parity).
  - **Header badges** under the title line: layer (`ROOT`/`PATCH`/`BOTH`),
    a `TOS <version>` badge when the shown variant carries a non-default
    `tos` (e.g. `1.02`; section 7.5 of the generator spec), a status
    histogram of the folder (`2× done  1× pending`) and the year when
    known. The grid card gets the same `TOS 1.02` chip and the "This ZIP"
    table a `TOS` row.
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
  - **Clickable crew/cracker groups**: the `Cracked by`/`Crew` values of
    the Game info table and the release-variant rows are links; clicking
    one switches the lightbox to **that group's ZIP** of the current card
    (same fuzzy matcher as the crew/cracker focus, section 5.3, applied
    client-side). No matching ZIP → variant 0. Clicking a group does
    **not** change the list filters.
- Navigation: `←`/`→` move to the previous/next **card of the current page**
  (v1 limit: within the loaded page; the next card opens on its first
  filmstrip entry), `↑`/`↓` switch variant **in filmstrip order**, `PgUp`/
  `PgDn` switch image (preview/candidates), `Esc` closes, click on the
  backdrop closes.
- Status/step indicator (e.g. `3 / 60  ·  variant 2 / 3` — the variant
  part only when the folder has more than one ZIP; the variant number is
  the **filmstrip position** of the selected ZIP).

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
| `?` | open the keyboard help overlay (grid focused; `?` typed into the search input stays in the input) |
| `Esc` in search input | clear search and return focus to grid |

- The help overlay closes on **any subsequent key** (auto-repeat is
  ignored so a held key does not flicker it) or on a click on its
  backdrop.
- All interactive elements are reachable by Tab as well; focus is always
  visible (outline consistent with the selection colors of SPEC.md).
- Mouse-only operation must remain fully equivalent.

### 6.7 Statistics bar

Shown in the header, sourced from `/api/meta`; all counts are for the
**active section** (desktop-app parity — the status bar is section-aware):

- `X / Y with screenshot` where **both counts are games (cards)** (`Y` is
  the section's card count), then one segment per status formatted as
  `done <games> (<zips> zips)` — games from `game_status_counts[section]`
  (the `pending` segment uses the any-variant rule so it equals the pending
  filter's result count), ZIPs from `status_counts[section]`; segments with
  zero games and zero ZIPs are omitted. In screenshots-only mode (no join)
  only the raw ZIP counts are shown (`done 1467`).
- Gameinfo coverage is shown as `info <matched> folders` (cracked only)
  plus `<no_info> without info` (cards without gameinfo, per section).
- The tool version (`gallery <x.y.z>`) is shown **right-aligned** at the
  end of the statistics bar; the footer line keeps only the data
  freshness (the active section's index mtime, gameinfo `generated_at`).
- Current result count of the active filters (`total` of the last
  `/api/entries` response) is shown next to the controls.

### 6.8 Section views

| Tab | Source | Cards | Notes |
|---|---|---|---|
| games | join of `index.json` + `games-cracked.json` | grouped, with previews | default view (label `games`, section key `cracked`) |
| pd | `index-pd.json` ∪ `games-pd.json` | index groups with previews + metadata-only leftovers (placeholder image) | status filter (default `any`) |
| utils | `index-utils.json` ∪ `games-utils.json` | index groups with previews + metadata-only leftovers (placeholder image) | status filter (default `any`) |
| magazines | `index-magazine.json` (index-only, no gameinfo) | one card per magazine issue (filename-derived title/year, variants = disks + copies) | status filter (default `any`); `letter` = magazine name, `year` from the file name |

- Letter navigation, search, sorting, the status filter and the
  publisher/language/year facets work in all sections; the remaining
  flag/tos/crew/cracker filters only where `SECTION_CONTROLS` lists them.
- The `magazines` section (section key `magazine`, `Bonus/Magazine Cover
  Disks`) has no metadata: its cards come from `index-magazine.json` grouped
  per issue by a filename parser (`ST Action 41`, `ST Computer 1995-02`,
  `Zero Issue 16`), mirroring `packages/marcer_catalog/lib/src/magazine.dart`.
- Switching tabs preserves `q`, `sort`, `order`, `letter` where applicable,
  resets incompatible filters and falls the status filter back to the
  section default (`with_screenshot` for cracked, `any` for pd/utils/magazine).

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
4. **Status presets**: `with_screenshot` (default for cracked; `any` for
   pd/utils), `done`, `desktop`, … as listed in section 5.2; `pending`
   matches a card when **any** of its ZIPs is pending (section 5.3). The
   statistics bar always shows the active section's numbers.
5. **Sorting**: `name` (default, case-insensitive), `year` (numeric, `unknown`
   last), `publisher`, `cracker` (=`cracked_by`), `crew` (alphabetical,
   empty values last), `order` `asc|desc`; ties broken by name then `rel`
   (stable pagination). The UI exposes key and order as one combined
   dropdown (`<key> asc|desc`), while the API and the URL keep the two
   parameters.
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

- The server `stat`s the three section indices (and the metadata files) on
  API requests; if an mtime changed, the affected dataset is reloaded once
  before answering (reload ≈ 0.16 s for the index *(verified)*, happens
  only on change).
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
- `default_status`: initial status preset of the **cracked** status filter
  (delivered via `/api/meta`; pd/utils default to `any`; a `status` URL
  parameter always wins).
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
13. **Desktop-parity display rules**: a folder with a `done` `textscreen`
    plus a later `done` `game` ZIP previews the **game** shot; a 2×2 thumb
    grid never shows exactly one `done` thumb (that card shows the game
    shot large); `status=pending` lists a `done`+`pending` folder;
    `done <games> (<zips> zips)` segments match the dropdown counts.
    The **pd/utils** views show index-backed cards with previews unioned
    with gameinfo-only metadata cards, their statistics bar uses the
    per-section counts, and their status filter defaults to `any`.
14. **Lightbox order/groups**: filmstrip lists screenshot variants first
    and `↑`/`↓` follows that order; the variant counter shows the
    filmstrip position; a crew/cracker link in Game info and a
    release-variant row both switch to that group's ZIP (unknown group →
    variant 0); header shows layer + status histogram + year badges.
15. **Help**: `?` opens the overlay, the next key closes it, `?` typed
    into the search input stays in the input.
16. **Touch/no-hover**: with a touch-only pointer (DevTools device
    emulation or a phone on the LAN) a tap on a card opens the lightbox
    and **never** raises the hover info panel; thumbnail/filmstrip/candidate
    taps leave no sticky `:hover` highlight. With a mouse the panel still
    appears after ≥ 400 ms, vanishes on mouse leave, key press and scroll,
    and `:focus-visible`/keyboard focus styling keeps working.

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
- [x] D3 Status aggregation and primary preview follow section 4.4
      (preview prefers `done` + `kind: game`).
- [x] D4 Year extraction follows section 4.5 (`unknown` handling).
- [x] D5 Variant payloads carry `kind`; `game_status_counts` follows the
      any-variant `pending` rule (sections 5.2/5.3), and `status=pending`
      matches per ZIP, not via `display_status`.

**API**
- [x] A1 All endpoints of section 5 exist with the documented parameters.
- [x] A2 Pagination is stable (total order, section 5.3) — no duplicate or
      skipped cards across consecutive pages.
- [x] A3 `entry` returns a single card with `position`.
- [x] A4 Errors follow section 5.5 (400/404/503), JSON error bodies.

**UI**
- [x] U1 Visual design matches the `GALLERY_TEMPLATE` language (colors,
      cards, badges, lazy images).
- [x] U2 All section 6.6 keys work in the grid (including `?` help) and all
      lightbox keys (6.5) work.
- [x] U3 Hover panels and lightbox show the gameinfo fields (or path info
      without gameinfo).
- [x] U4 Deep links `?entry=` and list-state params behave per section 6.9
      (combined sort dropdown still writes `sort`+`order`).
- [x] U5 Statistics bar shows the section 6.7 format (games/ZIPs segments,
      `… without info`, right-aligned version) plus the current result
      count.
- [x] U6 PD/Utils sections render metadata cards without previews and are
      labelled `pd`/`utils`.
- [x] U7 Card thumbs follow the section 6.3 ordering, with the single
      game-shot exception.
- [x] U8 Lightbox filmstrip order (screenshots first), header badges and
      clickable crew/cracker groups follow section 6.5.
- [ ] U9 No hover info on touch/mobile: panel gated behind
      `(hover: hover) and (pointer: fine)`, sticky `:hover` highlights
      behind `@media (hover: hover)`, panel dismissed on key press/scroll
      (section 6.4); keyboard focus styles unaffected.

**Process**
- [x] P1 Zero new packages in the repo `.venv` (stdlib only).
- [x] P2 `run.sh` sources `local/paths.env` and uses the repo `.venv`.
- [x] P3 Full manual test pass (section 10) completed before delivery.
- [x] P4 `shotgen html` removed and all docs listed in M6 updated.

---

## License

Licensed under the [MIT License](../LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
