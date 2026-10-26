# ANALYSIS: AtariLegend Metadata Source

Analysis of the weekly **AtariLegend** database dumps and how the Marcer
GameDVD archive can consume them. Companion to
[`ANALYSIS-game-data.md`](ANALYSIS-game-data.md) (the XLS/gameinfo source) and
the tool [`tools/atarilegend-gen`](../tools/atarilegend-gen/README.md).

**Status:** verified on 2026-10-17 against the `2026-10-11` dump (read-only).

---

## 1. Source

| Property | Value |
|---|---|
| URL | `https://www.atarilegend.com/data/database-dumps/` |
| Files | `YYYY-MM-DD.sql.gz` (MariaDB dump), `YYYY-MM-DD-users-ddl.sql.gz`, `YYYY-MM-DD-images.zip` |
| Cadence | weekly (Sundays) |
| Size | `.sql.gz` ~4.6 MB → ~22 MB raw; `images.zip` ~9.4 GB |
| Contents | MariaDB 10.11 dump of the AtariLegend database **minus the `users` table** (user accounts are exported as schema only) |
| License | **CC BY-NC-SA 4.0** — non-commercial, share-alike; never redistributed in this repo or the app release |

The dump is parsed with the Python standard library only.

## 2. What is in the dump

**113 tables, ~246,642 rows.** Beyond the game catalog it also contains the
whole AtariLegend website content (articles, interviews, news, magazine
indices, menu disks, SNDH music, …).

### 2.1 Game metadata most valuable to this project

| Attribute | Table(s) | Games covered |
|---|---|---|
| Genre | `genres`, `game_genre` | 4,579 (74 %) |
| Developer / company | `companies`, `game_developer` | 3,670 (59 %) |
| People + roles (Programming/Music/Graphics/…) | `individuals`, `game_individual`, `individual_roles` | 3,999 (64 %) |
| Release date (full) | `game_releases.date` | 6,022 (97 %) |
| Release type / license / status | `game_releases` | – |
| Publisher vs Developer vs Distributor, release country | `game_releases`, `game_release_distributor`, `game_release_location`, `locations` | – |
| Box scans (front/back/goodie) | `game_release_scans` | 1,670 (27 %) |
| Screenshots | `game_screenshot`, `screenshots` | 5,851 (94 %) |
| Facts / cheats | `game_facts` | 374 (6 %) |
| Magazine references (issue/page/score) | `magazine_indices`, `magazine_issues`, `magazines` | 913 (15 %) |
| Votes / reviews | `game_votes`, `reviews` | 887 / 127 |
| Series / original system / progress | `game_series`, `ports`, `game_progress_systems` | 625 / 206 / 17 |
| Engine / programming language / controls / RAM / resolution | `game_engine`, `game_programming_language`, `game_control`, `memories`, `resolutions` | 3–21 % |
| Copy/disk protection, TOS incompatibilities, HD-installable | … | sparse |
| AKA names (multilingual), videos, galleries, biographies | `game_akas`, `game_videos`, `game_galleries`, `companies`/`individuals.profile` | 1–4 % |

### 2.2 What AtariLegend adds over gameinfo

The XLS/gameinfo source (`games-*.json`) already provides title, publisher,
cracker, crew, language, disk count, dump flags (raw/pasti/boxscan), TOS/bad
notes, version, licence and screen format. AtariLegend **adds**: genre,
developer, original credits (people + roles), a full release date, structured
release type/license/status, country/distributor, box scans and its own
screenshots, magazine scores, user votes/reviews and facts/cheats — fields the
archive does not otherwise have.

## 3. Matching archive folders ↔ AtariLegend games

The join key is the **game title**. `tools/atarilegend-gen match` normalizes a
name index built from `games.name` + `game_akas` + `game_releases.name` +
`game_release_akas`, then matches each screenshot-index folder
(`(kind, letter, folder)`) in stages:

1. **exact** — normalized equality (NFKD, casefold, punctuation, article
   inversion `Tale, A` → `tale`, articles stripped)
2. **prefix** — one key is a word-prefix of the other (longest wins)
3. **fuzzy** — `difflib` ratio ≥ `fuzzy_cutoff` (default 0.90), blocked by the
   first 3 characters

Measured against the `2026-10-11` dump:

| Section | Folders | exact | prefix | fuzzy | unmatched | hit rate |
|---|---|---|---|---|---|---|
| cracked | 3,287 | 2,187 | 403 | 234 | 463 | **85.9 %** |
| pd | 4,207 | 1,689 | 1,149 | 149 | 1,220 | **71.0 %** |
| utils | 3,941 | 52 | 198 | 12 | 3,679 | **6.6 %** |

4,589 of 6,204 AtariLegend games are reachable from the archive. `pd` is
partly covered; `utils` barely (AtariLegend has no utility catalog). The
remaining cracked misses are mostly educational/localized titles genuinely
absent from AtariLegend.

The match is resolved **once** and stored as `(kind, letter, folder) →
al_game_id`. The tool resolves it at build time (for the reference `index`); the
**app** resolves it at runtime from the downloaded dump (no shipped mapping),
then only does cheap exact lookups.

## 4. Storage & artifacts

The app **must not ship AtariLegend data** (license, §10). It therefore obtains
the dump at runtime and keeps only a small **derived** cache it builds itself.
There are two artifact roles:

| Artifact | Where | Purpose |
|---|---|---|
| `atarilegend.sqlite` (113 tables, ~30 MB) | `MARCER_ATARILEGEND_DIR` (tool) | **Tool-side analysis only** (SQL queries, coverage). Not used by the app. |
| `atarilegend-index.json` (small) | tool reference / app cache | The runtime index: `(kind\|letter\|folder) → al_game_id` + per-game **developer/author/genre** facets. |
| `detail-<slug>.json` | tool fixtures | The assembled detail payload (reference / diff harness). |

**App-side cache format:** a compact JSON index built once from the dump
(no SQLite in the app). Rebuilt when a new dump is fetched.

### 4.1 Tool SQLite layout (`MARCER_ATARILEGEND_DIR/atarilegend.sqlite`)

- one table per dump table (same names/columns; `int → INTEGER`,
  `decimal/float → REAL`, else `TEXT`; NULLs kept)
- indexes reconstructed from the dump `PRIMARY KEY`/`KEY`/`UNIQUE` clauses
- `folders` — `section, letter, folder, al_game_id, al_game_name, matched_via,
  confidence`
- `_meta` — `schema_version, generated_at, generator, source_file,
  source_sha256, dump_date, tables, matched_folders, matched_atarilegend_games`
- `_table_stats` — `table_name, columns, rows`

## 5. AtariLegend URL / asset conventions

The DB stores **only numeric ids + `imgext`**, never a path or full URL. Asset
files live in the separately published `images.zip` and are served as
`…/storage/images/<category>/<id>.<ext>`. Verified against Buggy Boy
(`game_id 22`):

| Asset | Table(s) | Stored as | Derived URL |
|---|---|---|---|
| Screenshot | `screenshots(id, imgext)` + `game_screenshot(game_id, screenshot_id)` | `id` + `imgext` (`png`) | `…/games/<slug>/screenshot-<id>.<imgext>` |
| Box scan | `game_release_scans(id, game_release_id, type, imgext, notes)` | `id` + `type` (`Box front`/`Box back`/`Goodie`/`Other`) + `imgext` (`jpg`) | `…/storage/images/game_release_scans/<id>.<imgext>` |
| Company logo | `companies(id, name, profile, imgext)` | `imgext` | `…/storage/images/company_logos/<id>.<imgext>` |
| Person image | `individuals(id, name, profile, imgext, email)` | `imgext` | `…/storage/images/<category>/<id>.<imgext>` |
| Menu screenshot | `menu_disk_screenshots` | `imgext` | `…/storage/images/menu_screenshots/<id>.<imgext>` |
| Game page | `games(id, name, slug, …)` | `slug` | `…/games/<slug>` |
| Review | `reviews(id, game_id, …)` | `id` | `…/reviews/<id>` |
| Magazine | `magazine_indices` + `magazine_issues` + `magazines` | ids | `…/magazines/<magazine_id>#magazine-issue-<issue_id>`; scan at `magazine_issues.archiveorg_url` |
| Music | `sndhs` + `game_sndh(game_id, sndh_id)` + `sndh_archives(id, download_url)` | archive-path key | `sndh_archives.download_url` (e.g. `sndh.atari.org/…/*.zip`) |

Real (stored) URLs exist only in `links.url` (external website directory),
`sndh_archives.download_url` and `magazine_issues.archiveorg_url`/`alternate_url`.
Everything self-referential is derived from `slug`/`id`.

**Music:** not an image. `game_sndh.sndh_id` is an archive-path key into
`sndhs` (title, composer, ripper, subtunes, year). The `.sndh` binary is **not**
in the dump/`images.zip`; it lives in the SNDH archive ZIP referenced by
`sndh_archives.download_url`. IDs can appear with/without a leading `/`
(duplicates across archives).

## 6. Minimal runtime table set

Only these tables are needed at runtime (the app can ignore the rest):

- **Matching:** `games`, `game_akas`, `game_releases`, `game_release_akas`
- **Filters (developer/author/genre):** `genres`, `game_genre`, `game_developer`,
  `companies`, `developer_roles`, `game_individual`, `individuals`,
  `individual_roles`
- **Details:** the above plus `screenshots`, `game_screenshot`,
  `game_release_scans`, `sndhs`, `game_sndh`, `sndh_archives`, `reviews`,
  `magazine_indices`, `magazine_issues`, `magazines`, `game_videos`,
  `game_facts`, `game_series`, `ports`, `game_progress_systems`, and the
  `game_release_*` cross tables for languages/location/memory/resolution/
  protections/crews.

## 7. Detail payload schema

The `detail` command (and the app's button) assembles:

```jsonc
{
  "game":   { "id": 22, "name": "Buggy Boy", "slug": "buggy-boy", "url": "…/games/buggy-boy" },
  "akas":   ["Speed Buggy"],
  "genres": ["Simulation", "Driving"],
  "series": null, "port": "Arcade", "progress": null,
  "players": { "same_machine": null, "multiple_machines": null, … },
  "developers": [ { "name": "Taito", "role": "Arcade", "logo_url": "…/company_logos/163.png" } ],
  "authors":    [ { "name": "Jas C Brooke", "role": "Music" } ],
  "engine": [], "programming_language": [], "controls": [], "sound_hardware": [],
  "releases": [ { "id": 22, "date": "1987-01-01", "type": null, "license": "Commercial",
                  "publisher": "Elite", "distributor": [], "locations": [], "languages": [],
                  "memory_minimum": [], "resolutions": [], "copy_protection": [],
                  "disk_protection": [], "tos_incompatible": [], "crews": [],
                  "boxscans": [ { "id": 34, "type": "Box front", "imgext": "jpg", "url": "…" } ] } ],
  "screenshots": [ { "id": 24, "imgext": "png", "url": "…/screenshot-24.png" } ],
  "music":  [ { "title": "Buggy Boy", "composer": "Jas C Brooke", "subtunes": 6,
                "download_url": "https://sndh.atari.org/files/sndh45lf.zip" } ],
  "reviews":   [ { "id": 67, "url": "…/reviews/67", "graphics": 8, "sound": 7, "gameplay": 9, "overall": 8 } ],
  "magazines": [ { "magazine": "ST Magazine", "issue": 21, "page": 142, "archive_url": "…" } ],
  "videos": [ … ], "facts": [ … ]
}
```

## 8. App integration

- **Fetch:** download `YYYY-MM-DD.sql.gz` (resolve the newest date from the
  directory listing) — the app already uses `dart:io` `HttpClient`.
- **Decompress:** `dart:io` `gzip.decode(bytes)` (`GZipCodec`, cross-platform
  incl. **Windows**) or `package:archive` `GZipDecoder` (pure Dart; the app
  already depends on `archive`). 4.6 MB → 22 MB in memory is trivial.
- **Parse:** port the stdlib SQL-tuple parser (§ tool); only the §6 tables are
  needed. This is the main new Dart code.
- **Cache:** build the compact `index` JSON once; keep details on demand
  (assemble from the parsed tables, or fetch/parse on the detail button).
- **Filters:** developer, author and genre become new dropdowns fed by the
  index facets; matching is `(kind, letter, folder) → al_game_id`.
- **Detail button:** "AtariLegend details" opens the assembled payload
  (info + screenshots/boxscans/music/reviews/magazines + derived URLs).

## 9. Licensing

AtariLegend content is **CC BY-NC-SA 4.0** (non-commercial, share-alike).
The dump and every derived artifact (SQLite, index, detail, fixtures) are
**runtime data only** and are **never committed to the repository or bundled
into the app release**; the app downloads and derives them locally. Attribution
is documented here and in the tool README.

## 10. Tool: `tools/atarilegend-gen`

| Command | Purpose |
|---|---|
| `fetch` | resolve + download the newest `YYYY-MM-DD.sql.gz` (idempotent) |
| `extract` | full SQLite mirror + `folders` match (tool-side analysis) |
| `match` | match report (`atarilegend-match.json`/`.txt`) |
| `index` | compact runtime index (folders + developer/author/genre facets) |
| `detail` | assembled detail payload for one game (`--slug`/`--game-id`/`--folder`) |
| `fixtures` | `detail-<slug>.json` for a fixed game set (diff harness) |
| `report` | row inventory of the relevant tables |

Paths come exclusively from `local/paths.env`: `MARCER_ATARILEGEND_DIR`
(output/artifact/cache) and `MARCER_OUT_DIR` (screenshot index for the match).

## 11. Roadmap / next steps

| Milestone | Content |
|---|---|
| M0 (done) | `fetch` / `match` / `report` + this analysis |
| M1 (done) | `extract` → full-dump SQLite (tool analysis) |
| M2 (done) | `index` / `detail` / `fixtures` reference outputs |
| M3.1 (done) | Desktop app `AtariLegend data` row + **Download AtariLegend data** button (writes into `<GameinfoDirectory>/atarilegend`, no separate path field): fetch the newest `.sql.gz`, gunzip, parse in a background isolate, write the compact `atarilegend.json` (schema **v5**: id/name/slug, year, publisher, genres, conversion/original system, developers/authors **with roles**, aliases incl. `game_release_akas`, screenshot/boxscan references, review/comment/magazine counts, **community score** and **publisher/developer logo references**) plus the separate lazy **`atarilegend-texts.json`** (reviews/comments/magazines), delete the dump. Older caches still load but warn "outdated". |
| M3.2 (done) | App loads the cache and matches each card's **folder** incl. aliases (exact → prefix → fuzzy, ≈84 % cracked); a teal **AtariLegend** button in the sidebar/lightbox *Game info* heading opens an in-app dialog (cached metadata) with an "Open on atarilegend.com" browser link |
| M3.3 (done) | App UI: **Genre** (after the status dropdown) and **Developers** (after Publisher) filter dropdowns fed by the cache; the Publisher facet matches gameinfo **and** AtariLegend (case-insensitive merge). An author filter is not implemented (authors shown in the dialog only) |
| M3.4 (done) | **Web images** in the AtariLegend dialog: Boxscans (thumbnail row) + Screenshots (thumbnail grid) shown **simultaneously** (no hero), hotlinked from atarilegend.com (derived URLs, `Image.network`, no disk cache); click → full-size viewer (`←/→`, `Esc`, zoom) |
| M3.5 (done) | **Magazines / Reviews / Comments** in the tabbed AtariLegend dialog — **Info** (metadata/credits + Boxscans/Screenshots), **Reviews (N)**, **Magazines (N)**, **Comments (N)** (counts from the metadata cache). A second artifact **`atarilegend-texts.json`** (~1.2 MB) holds reviews (scores + review comments), game comments and magazine references; it is loaded **lazily** on the first text tab. Reviews render BBCode (`[b]/[i]/[u]/[url]`, unknown tags stripped); magazines link to archive.org; the dump has no `users` table, so no author names. |
| M3.6 (done) | Info header: **community score** far right (`game_votes` average, normalized `/4*5`) and the **publisher + developer logos** side by side in the middle (`companies.imgext` → `…/storage/images/company_logos/<id>.<ext>`, hotlinked) |
| M3.7 (done) | **Applied dump date** visible in the settings row (`installed · dump YYYY-MM-DD`, from the cache header with `source.dump_date`/`source.file`/`generated_at` fallbacks) and an **AtariLegend** row in the Catalog data dialog with a **manual** Check button (no automatic check, no startup request); a newer remote dump offers Install/Update with progress/Cancel and reloads the catalog |
| M4 | Standalone `images.zip` processing (separate, large) — not needed for the hotlinked web images above |
| M5 | Weekly automation of fetch + app cache refresh |

Open questions: when the app cache is rebuilt (startup check vs manual); how
much of the detail is computed eagerly vs on the button.
