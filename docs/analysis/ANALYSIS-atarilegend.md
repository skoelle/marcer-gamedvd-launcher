# ANALYSIS: AtariLegend Metadata Source

Analysis of the weekly **AtariLegend** database dumps and how the Marcer
GameDVD archive consumes them. Companion to
[`ANALYSIS-game-data.md`](ANALYSIS-game-data.md) (the XLS/gameinfo source) and
the tool [`tools/atarilegend-gen`](../../tools/atarilegend-gen/README.md).
Consumer behavior is specified in [`SPEC-desktop.md`](../specs/SPEC-desktop.md).

**Status:** verified read-only against a real weekly dump. Counts are
order-of-magnitude and grow over time.

---

## 1. Source

| Property | Value |
|---|---|
| URL | `https://www.atarilegend.com/data/database-dumps/` |
| Files | `YYYY-MM-DD.sql.gz` (MariaDB dump), `YYYY-MM-DD-users-ddl.sql.gz`, `YYYY-MM-DD-images.zip` |
| Cadence | weekly (Sundays) |
| Size | `.sql.gz` ~4.6 MB → ~22 MB raw; `images.zip` ~9.4 GB |
| Contents | MariaDB dump of the AtariLegend database **minus the `users` table** (accounts are schema only) |
| License | **CC BY-NC-SA 4.0** — non-commercial, share-alike; never redistributed |

The dump is parsed with the Python standard library (tool) and a Dart port
(app); only the tables in section 6 are needed.

## 2. What is in the dump

The dump has 100+ tables and far more than the game catalog (articles,
interviews, news, magazine indices, menu disks, SNDH music, …).

### 2.1 Game metadata most valuable to this project

| Attribute | Table(s) | Coverage |
|---|---|---|
| Genre | `genres`, `game_genre` | ~74 % |
| Developer / company | `companies`, `game_developer` | ~59 % |
| People + roles (Programming/Music/Graphics/…) | `individuals`, `game_individual`, `individual_roles` | ~64 % |
| Release date (full) | `game_releases.date` | ~97 % |
| Release type / license / status | `game_releases` | – |
| Publisher vs Developer vs Distributor, release country | `game_releases`, `game_release_distributor`, `game_release_location`, `locations` | – |
| Box scans (front/back/goodie) | `game_release_scans` | ~27 % |
| Screenshots | `game_screenshot`, `screenshots` | ~94 % |
| Facts / cheats | `game_facts` | ~6 % |
| Magazine references (issue/page/score) | `magazine_indices`, `magazine_issues`, `magazines` | ~15 % |
| Votes / reviews | `game_votes`, `reviews` | sparse |
| Series / original system / progress | `game_series`, `ports`, `game_progress_systems` | sparse |
| Engine / language / controls / RAM / resolution | `game_engine`, `game_programming_language`, `game_control`, `memories`, `resolutions` | 3–21 % |
| AKA names, videos, galleries, biographies | `game_akas`, `game_videos`, `game_galleries`, `companies`/`individuals.profile` | 1–4 % |

### 2.2 What AtariLegend adds over gameinfo

The XLS/gameinfo source already provides title, publisher, cracker, crew,
language, disk count, dump flags, TOS/bad notes, version, licence and screen
format. AtariLegend **adds**: genre, developer, original credits (people +
roles), full release date, structured release type/license/status,
country/distributor, box scans and its own screenshots, magazine scores, user
votes/reviews and facts/cheats.

## 3. Matching archive folders ↔ AtariLegend games

The join key is the **game title**. The tool normalizes a name index built from
`games.name` + `game_akas` + `game_releases.name` + `game_release_akas`, then
matches each screenshot-index folder `(kind, letter, folder)` in stages:

1. **exact** — normalized equality (NFKD, casefold, punctuation, article
   inversion `Tale, A` → `tale`, articles stripped)
2. **prefix** — one key is a word-prefix of the other (longest wins)
3. **fuzzy** — `difflib` ratio ≥ `fuzzy_cutoff` (default 0.90), blocked by the
   first 3 characters

Hit rates are roughly 86 % for cracked, 71 % for pd and 7 % for utils
(AtariLegend has no utility catalog). Most cracked misses are educational or
localized titles genuinely absent from AtariLegend. The match is resolved once
and stored as `(kind, letter, folder) → al_game_id`; the app resolves it at
runtime from the downloaded dump (no shipped mapping), then only does cheap
exact lookups.

## 4. Storage & artifacts

The app **must not ship AtariLegend data** (license, §8). It obtains the dump at
runtime and keeps only a small derived cache it builds itself.

| Artifact | Where | Purpose |
|---|---|---|
| `atarilegend.sqlite` (100+ tables) | `MARCER_ATARILEGEND_DIR` (tool) | **Tool-side analysis only** (SQL queries, coverage). Not used by the app. |
| `atarilegend-index.json` (small) | tool reference / app cache | Runtime index: `(kind\|letter\|folder) → al_game_id` + per-game developer/author/genre facets. |
| `detail-<slug>.json` | tool fixtures | Assembled detail payload (reference / diff harness). |

**App-side cache:** compact JSON built once from the dump (no SQLite in the
app), rebuilt when a new dump is fetched. It is split into
`atarilegend.json` (metadata) and `atarilegend-texts.json` (reviews, comments,
magazines; loaded lazily).

### 4.1 Tool SQLite layout

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
`…/storage/images/<category>/<id>.<ext>`.

| Asset | Table(s) | Stored as | Derived URL |
|---|---|---|---|
| Screenshot | `screenshots(id, imgext)` + `game_screenshot` | `id` + `imgext` | `…/games/<slug>/screenshot-<id>.<imgext>` |
| Box scan | `game_release_scans(id, game_release_id, type, imgext, notes)` | `id` + `type` + `imgext` | `…/storage/images/game_release_scans/<id>.<imgext>` |
| Company logo | `companies(id, name, profile, imgext)` | `imgext` | `…/storage/images/company_logos/<id>.<imgext>` |
| Person image | `individuals(…)` | `imgext` | `…/storage/images/<category>/<id>.<imgext>` |
| Menu screenshot | `menu_disk_screenshots` | `imgext` | `…/storage/images/menu_screenshots/<id>.<imgext>` |
| Game page | `games(id, name, slug, …)` | `slug` | `…/games/<slug>` |
| Review | `reviews(id, game_id, …)` | `id` | `…/reviews/<id>` |
| Magazine | `magazine_indices` + `magazine_issues` + `magazines` | ids | `…/magazines/<magazine_id>#magazine-issue-<issue_id>`; scan via `magazine_issues.archiveorg_url` |
| Music | `sndhs` + `game_sndh` + `sndh_archives` | archive-path key | `sndh_archives.download_url` |

Real (stored) URLs exist only in `links.url`, `sndh_archives.download_url` and
`magazine_issues.archiveorg_url`/`alternate_url`. Everything self-referential is
derived from `slug`/`id`.

**Music:** not an image. `game_sndh.sndh_id` is an archive-path key into
`sndhs`; the `.sndh` binary is not in the dump/`images.zip` but in the SNDH
archive ZIP referenced by `sndh_archives.download_url`.

## 6. Minimal runtime table set

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

The `detail` command (and the app's dialog) assembles:

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

## 8. Licensing

AtariLegend content is **CC BY-NC-SA 4.0** (non-commercial, share-alike). The
dump and every derived artifact (SQLite, index, detail, fixtures) are
**runtime data only** and are **never committed to the repository or bundled
into the app release**; the app downloads and derives them locally. Attribution
is documented here and in the tool README.

## 9. Tool

`tools/atarilegend-gen` provides `fetch` (resolve + download the newest
`YYYY-MM-DD.sql.gz`), `extract` (full SQLite mirror + folder match),
`match`, `index` (compact runtime index), `detail` (assembled payload for one
game), `fixtures` and `report`. Paths come from `local/paths.env`
(`MARCER_ATARILEGEND_DIR`, `MARCER_OUT_DIR`). See
[`tools/atarilegend-gen/README.md`](../../tools/atarilegend-gen/README.md).
