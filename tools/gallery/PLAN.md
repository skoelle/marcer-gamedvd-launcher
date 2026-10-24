# PLAN: Gallery Webapp — Execution Checklist

Purpose: track implementation progress only. The contract is
[`SPEC-gallery-webapp.md`](../../docs/SPEC-gallery-webapp.md) — behavior, API,
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
| 2026-10-11 | Crew↔ZIP matching made fuzzy: normalize `&`/`+`→`and`, then token-subset fallback (stopword-filtered) — fixes e.g. `Equinox & MDK`↔`Equinox and MDK`, `Hotline & MCA`↔`Hotline MCA`; when no ZIP matches (`focus_variant=-1`) the card shows a hint plus up to 4 other variant screenshots instead of a blank placeholder | §5.3 crew focus, §6.3 card fallback, §6.5 lightbox hint, §7.3 | gallery.py, app.js, style.css |
| 2026-10-11 | Added a **Cracker** facet/filter (from `cracked_by`, ~990 values for cracked) with the same focus behavior as crew — dropdown between Crew and Language, focus-variant matching (substring + token fallback), `-1` card fallback renamed generically; **cracker takes precedence over crew** when both are set | §5.2 facets/`crackers`, §5.3 params + focus, §6.1 control bar, §6.3 fallback, §7.3 | gallery.py, app.js, index.html |
| 2026-10-11 | Without an active crew/cracker filter, cards with ≥2 variant screenshots now show up to 4 variant thumbnails (best status first) instead of the single aggregated preview; clicking a thumb opens that ZIP in the lightbox. Single-screenshot folders keep the large preview. CSS classes `.crew-thumbs`/`.crew-miss` generalized to `.var-thumbs`/`.var-miss` | §6.3 cards | app.js, style.css |
| 2026-10-11 | Added a favicon: GEM desktop drawer/drive icon, pixel-traced from `local/drawer.png` (70x70, GEM palette `#eeeeee`/`#000000` on `#00ee00`, 222 merged rects) as `static/favicon.svg`; served via the `/static/` whitelist and linked from `index.html` | §4 static layout, §5.1 endpoint table | gallery.py, index.html, static/favicon.svg |
| 2026-10-16 | **No hover info on touch/mobile**: the hover info panel only activates when `(hover: hover) and (pointer: fine)` matches (touch taps synthesize `mouseover` and would otherwise raise the panel ~400 ms after every tap, potentially stuck behind the lightbox); all sticky `:hover` highlight rules moved behind `@media (hover: hover)` in place (cascade order kept, `.active` still wins over hover, `:focus-visible`/`.kbd-focus` untouched); panel now also dismissed on key press and grid scroll as the spec already required (previously mouse-leave only) | §6.1 touch exclusion, §6.4 hover panel, §10 test 16, §10.3 U9 | app.js, style.css |
| 2026-10-16 | **Downscaled screenshots look smooth again**: all shrinking contexts (card preview, card candidate strip, variant thumbs, filmstrip, lightbox candidate strip) switched from `image-rendering: pixelated` (nearest-neighbor → heavy aliasing on 832x552 → ~220px/48px) to the browser's high-quality resampling (`image-rendering: auto`), matching the desktop app's mipmap `FilterQuality.medium`; `pixelated` is kept only on the integer-scaled lightbox main image. `high-quality` was rejected (unsupported in all browsers per MDN) | §6.1 visual design | style.css |
| 2026-10-24 | **Desktop P0 parity**: added strict `desktop text`/`desktop black` ZIP-level status presets, `pd` TOS/Bad, the `Kind` row in "This ZIP", the desktop side-panel order (Game info → This ZIP → Release variants) and the desktop statistics-bar wording (`N folders`, `M with screenshot`, `gameinfo N folders`, `N without gameinfo`); gallery tool version bumped to `0.2.0` | §5.2, §5.3, §6.5, §6.7, §6.8, §7.4, §10, §12 | gallery.py, app.js, README.md, AGENTS.md, test_gallery.py |
| 2026-10-24 | **Metadata-only local assets**: lightbox shows boxscan edition/image counts and manual title/file counts plus edition/manual labels from `MARCER_ROOT_DIR`/`MARCER_PATCH_DIR`; discovery reads only directory listings and ZIP central directories (`infolist`), never member bytes, and there is no content/download endpoint; gallery tool version bumped to `0.3.0` | §1.2, §2.1, §5.1, §5.2, §5.5, §6.5, §9, §10, §12 | gallery.py, app.js, style.css, README.md, AGENTS.md, test_gallery.py |
