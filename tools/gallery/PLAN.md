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

- [ ] `gallery.py`: CLI (`--host`, `--port`), config load
      (`config.example.json` + `config.local.json`), ThreadingHTTPServer +
      minimal router (`/`, `/static/`, `/api/meta`, `/img/` stubs)
- [ ] Data loaders: `load_index()` (index.json), `load_gameinfo()`
      (games-*.json + manifest, optional), mtime revalidation hook
- [ ] `/api/meta` returning index counts + status counts (+ gameinfo
      availability/sections when present)
- [ ] `static/index.html` shell + `style.css` (GALLERY_TEMPLATE palette)
      + `app.js` stub (fetch `/api/meta`, render header/stats line)
- [ ] `run.sh` (sources `local/paths.env`, repo `.venv` python)
- [ ] `config.example.json` (no paths inside) + `README.md` stub
- [ ] Verify: SPEC §10.1 (start/stop, missing OUT_DIR error, degraded
      mode without DATA_DIR)

## M2 — List API + Grid (SPEC §11 M2)

- [ ] Join per SPEC §4.1–4.2 (grouped cards: letter/folder, aggregation,
      primary preview)
- [ ] `/api/entries`: `section=cracked`, `status=with_screenshot`
      default, `offset`/`limit`, stable total order (name then rel)
- [ ] Grid rendering: cards (badge, name, preview, lazy images), page
      pagination prev/next + page indicator
- [ ] Visual parity pass vs. static `shotgen html` gallery
- [ ] Verify: SPEC §10.2 (side-by-side), §10.5 sort stability basics

## M3 — Discovery (SPEC §11 M3)

- [ ] Search `q` (field set per SPEC §5.3)
- [ ] Facets/filters: status presets, letter nav, publisher/crew/
      language/year, flag tri-states, tos
- [ ] Sorting (`name`/`year`/`publisher`/`cracker`/`crew` × asc/desc)
- [ ] Statistics bar (global counts + current result count)
- [ ] URL query-string state (replaceState)
- [ ] Verify: SPEC §10.3–10.5

## M4 — Metadata views (SPEC §11 M4)

- [ ] Hover info panels (delay, keyboard focus, no-info fallback)
- [ ] PD/Utils tabs (metadata cards, placeholder image area)
- [ ] Variant grouping polish (variant count chip, layer label)
- [ ] Screenshots-only degradation (hidden controls, meta flags)
- [ ] Verify: SPEC §10.6 + degraded mode from §10.1

## M5 — Lightbox, keyboard, deep links (SPEC §11 M5)

- [ ] Lightbox: preview, candidate strip, variant switcher, metadata
      table, prev/next within page, Esc/backdrop close
- [ ] Grid keyboard model (arrows, Enter/Space, PgUp/PgDn, Home/End, `/`)
- [ ] Deep links: `?entry=` single-card fetch + open; browser Back
      closes lightbox first (pushState/replaceState)
- [ ] Verify: SPEC §10.7–10.9

## M6 — Migration & docs (SPEC §11 M6)

- [ ] Remove `html` subcommand + `GALLERY_TEMPLATE` from
      `tools/screenshot-gen/shotgen.py` (pointer message to gallery)
- [ ] Update `tools/screenshot-gen/README.md`, `tools/gallery/README.md`
- [ ] Root `README.md` (usage) + `AGENTS.md` (tools overview)
- [ ] Sync `ANALYSIS-game-data.md` §5.1 + `DECISION-app-architecture.md` §5
      with `MARCER_DATA_DIR`
- [ ] Verify: SPEC §10 full pass + §12 P4

---

## Amendment Log

| Date | Finding | Spec change | Where |
|---|---|---|---|
| — | — | — | — |
