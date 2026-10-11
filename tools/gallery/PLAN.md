# PLAN: Gallery Webapp — Execution Checklist

Purpose: track implementation progress only. The contract is
[`SPEC-gallery-webapp.md`](../../SPEC-gallery-webapp.md) — behavior, API,
test plan and conformance checklist live there.

Rules:

- Do not duplicate spec content here (no API tables, no schemas, no paths).
- Behavioral discoveries that need a spec decision go into the
  Amendment Log below **and** into the spec as an amendment.
- Check boxes off as milestones land; keep one checkbox per concrete step.

---

## M1 — Skeleton (SPEC §11 M1)

- [x] `gallery.py`: CLI (`--host`, `--port`), config load
      (`config.example.json` + `config.local.json`), ThreadingHTTPServer +
      minimal router (`/`, `/static/`, `/api/meta`, `/img/` stubs)
- [x] Data loaders: `load_index()` (index.json), `load_gameinfo()`
      (games-*.json + manifest, optional), mtime revalidation hook
- [x] `/api/meta` returning index counts + status counts (+ gameinfo
      availability/sections when present)
- [x] `static/index.html` shell + `style.css` (GALLERY_TEMPLATE palette)
      + `app.js` stub (fetch `/api/meta`, render header/stats line)
- [x] `run.sh` (sources `local/paths.env`, repo `.venv` python)
- [x] `config.example.json` (no paths inside) + `README.md` stub
- [x] Verify: SPEC §10.1 (start/stop, missing OUT_DIR error, degraded
      mode without DATA_DIR)

## M2 — List API + Grid (SPEC §11 M2)

- [x] Join per SPEC §4.1–4.2 (grouped cards: letter/folder, aggregation,
      primary preview)
- [x] `/api/entries`: `section=cracked`, `status=with_screenshot`
      default, `offset`/`limit`, stable total order (name then rel)
- [x] Grid rendering: cards (badge, name, preview, lazy images), page
      pagination prev/next + page indicator
- [x] Visual parity pass vs. static `shotgen html` gallery
- [x] Verify: SPEC §10.2 (side-by-side), §10.5 sort stability basics

## M3 — Discovery (SPEC §11 M3)

- [x] Search `q` (field set per SPEC §5.3)
- [x] Facets/filters: status presets, letter nav, publisher/crew/
      language/year, flag tri-states, tos
- [x] Sorting (`name`/`year`/`publisher`/`cracker`/`crew` × asc/desc)
- [x] Statistics bar (global counts + current result count)
- [x] URL query-string state (replaceState)
- [x] Verify: SPEC §10.3–10.5

## M4 — Metadata views (SPEC §11 M4)

- [x] Hover info panels (delay, keyboard focus, no-info fallback)
- [x] PD/Utils tabs (metadata cards, placeholder image area)
- [x] Variant grouping polish (variant count chip, layer label)
- [x] Screenshots-only degradation (hidden controls, meta flags)
- [x] Verify: SPEC §10.6 + degraded mode from §10.1

## M5 — Lightbox, keyboard, deep links (SPEC §11 M5)

- [x] Lightbox: preview, candidate strip, variant switcher, metadata
      table, prev/next within page, Esc/backdrop close
- [x] Grid keyboard model (arrows, Enter/Space, PgUp/PgDn, Home/End, `/`)
- [x] Deep links: `?entry=` single-card fetch + open; browser Back
      closes lightbox first (pushState/replaceState)
- [x] Verify: SPEC §10.7–10.9

## M6 — Migration & docs (SPEC §11 M6)

- [x] Remove `html` subcommand + `GALLERY_TEMPLATE` from
      `tools/screenshot-gen/shotgen.py` (pointer message to gallery)
- [x] Update `tools/screenshot-gen/README.md`, `tools/gallery/README.md`
- [x] Root `README.md` (usage) + `AGENTS.md` (tools overview)
- [x] Sync `ANALYSIS-game-data.md` §5.1 + `DECISION-app-architecture.md` §5
      with `MARCER_DATA_DIR`
- [x] Verify: SPEC §10 full pass + §12 P4

---

## Amendment Log

| Date | Finding | Spec change | Where |
|---|---|---|---|
| 2026-10-11 | Crew filter must focus the matching ZIP variant (screenshot + lightbox), even when empty | §5.3 crew focus / `focus_variant`; §7.3 | gallery.py, app.js |
| 2026-10-11 | Lightbox UX polish: filmstrip-only variant switcher (no tabs), candidate strip fixed min-height, wider side panel (380px), Year nowrap, selected release variant highlighted in info table | §6.5 | app.js, style.css |
| 2026-10-11 | Cleanup pass: plumbed `show_candidates`/`default_status` config to the frontend via `/api/meta`; deep links jump to the card's real page (sorted `position` from the entry API); variant step indicator; SIGTERM handler; spec alignment (§5.2 per-section facets, §6.3 single-variant card strip, §6.6 clamp keys, §6.9 page jump, +N badge); README features/keyboard/troubleshooting | §5.2, §6.3, §6.5, §6.6, §6.9, §9 | gallery.py, app.js |
