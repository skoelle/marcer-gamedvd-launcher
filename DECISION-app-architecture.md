# DECISION: App Architecture (Marcer GameDVD)

Records the technology decision for the planned UI applications around the
Marcer GameDVD archive. Follows the style of `ANALYSIS-game-data.md` and
`SPEC-screenshot-generator.md`. Decision date: 2026-10-11.

**Related documents:**
- [`SPEC.md`](SPEC.md) — technology-neutral launcher spec (UI-agnostic core, R1)
- [`ANALYSIS-game-data.md`](ANALYSIS-game-data.md) — game metadata sources, desktop app idea (M4)
- [`SPEC-screenshot-generator.md`](SPEC-screenshot-generator.md) — screenshot pipeline and `index.json` artifacts
- [`tools/screenshot-gen/shotgen.py`](tools/screenshot-gen/shotgen.py) — former static HTML gallery (`html` command, removed; replaced by `tools/gallery`) — the speed problem this decision addresses
- [`tools/gallery/`](tools/gallery/README.md) — implemented gallery webapp, see [`SPEC-gallery-webapp.md`](SPEC-gallery-webapp.md)

---

## 1. Problem / Starting Point

The static HTML gallery built by `shotgen html` does not scale: with 22,938
index entries (~4,400 previews today, growing) it writes a multi-megabyte
single-page `index.html` whose full DOM and image set get slower with every
screenshot run. A dynamic replacement is wanted, in (roughly) the same design,
plus a longer-term vision of richer frontends.

Three distinct UI worlds are envisioned, each with different interaction
models:

1. **Gallery web app** — browse the screenshot archive like a gallery
   (card grid, filter by kind, search, full-size view). The "small variant",
   runs in a browser, no installation.
2. **Inventory browser** (desktop app) — dense list-based catalog browsing
   over the game trees with a game-info detail sidebar, full keyboard control,
   "looks like a real desktop app" (master-detail). Consumes the gameinfo
   data of `ANALYSIS-game-data.md` and the screenshot previews.
3. **Couch launcher** (the long-term "heart's project") — fullscreen 10-foot
   UI for the TV: big tiles, cover art/screenshots as backgrounds, navigation
   and launching via joystick/gamepad. Same data as (2), completely different
   presentation.

## 2. Decision

**Two applications, two technologies:**

| App | Technology | Scope |
|---|---|---|
| **Desktop app** (inventory browser now, couch launcher later) | **Flutter** (one project, **two surfaces**) | Surface A (now): windowed master-detail inventory browser, full keyboard control. Surface B (later): fullscreen couch mode with gamepad — switched to once everything is configured; exact switch mechanism to be decided when reached. |
| **Gallery web app** | **HTML/CSS/JS frontend + small local Python server** | Dynamic gallery replacing `shotgen html`: server-side pagination, search/filter, full-size view of original PNGs. Same visual design as the former static gallery. Runs locally/LAN only. |

Explicitly rejected alternatives:

- **Electron / Tauri for the desktop app** — would share UI code with the web
  gallery, but the two UIs are intentionally different (gallery ≠ master-detail
  ≠ couch), so there is no UI to share. Would add a third language/runtime
  (JS/Rust) beside Dart and Python without buying synergy. (Tauri is a good
  lean shell in general; the gamepad story relies on the young
  `tauri-plugin-gamepad` polyfill because system WebViews — WKWebView,
  WebKitGTK — have Gamepad API gaps. Electron ships Chromium and is gamepad-safe
  but costs ~100 MB install / higher RAM. Both were weighed and not chosen.)
- **Avalonia / Blazor (.NET) for the desktop app** — attractive for reusing
  the C# launcher core, but the couch/inventory UIs would be written in XAML
  with manual gamepad interop, and no UI is shared with the gallery either.
  The C# console launcher stays untouched; its core remains governed by
  `SPEC.md` (R1) and is not a reason to force the new apps into .NET.
- **Flutter web for the gallery** — canvas-based renderer, multi-MB payload,
  and the existing HTML/CSS gallery design would be lost.
- **Three separate apps (Electron + Flutter + Web)** — rejected in favor of the
  two-surface Flutter approach, which keeps one language and one data layer
  for both desktop UIs.

## 3. Rationale for Flutter (desktop app)

- Virtualized lists (`ListView.builder`) handle the full catalog (~23k
  entries) without special effort.
- Strong keyboard/focus system: arrow keys, Enter, shortcuts are first-class —
  matches the "full keyboard control" requirement for Surface A and maps
  naturally to D-pad navigation for Surface B later.
- Mature gamepad support on all three desktop platforms via the `gamepads`
  package (Windows: GameInput, macOS: GCController, Linux: joystick + SDL
  mapping DB, plus web).
- One language/toolchain for both desktop surfaces; shared Dart package
  (see section 5) is inherited by the couch launcher when it is built.
- Native rendering, animation and kiosk/fullscreen support fit the couch use
  case; GitHub Actions matrix (win/mac/linux) is well established for Flutter.

## 4. Rationale for Python + HTML (gallery web app)

- The current gallery design is already HTML/CSS — it is reused (colors,
  card grid, filter bar, badges) with server-side pagination and lazy image
  loading instead of one giant DOM.
- The server is small: read-only API over `index.json` (filtered, paginated),
  serve the mirrored PNG tree, watch `index.json` mtime for cheap live refresh
  during screenshot runs.
- Python lives in the existing repo `.venv` and shares the data conventions
  with `tools/screenshot-gen` and the future `tools/gameinfo-gen` (both
  Python). No new runtime enters the repo (no npm, no Rust).
- LAN bind by default (`0.0.0.0`); no auth, no remote exposure story
  beyond the local network.

## 5. Shared data layer

All apps are strictly **read-only consumers** of the same artifacts:

| Source | Consumers |
|---|---|
| `MARCER_ROOT_DIR` + `MARCER_PATCH_DIR` overlay trees | desktop app, web app, console launcher |
| `<OUT>/index.json` + mirrored PNGs (`SPEC-screenshot-generator.md`) | desktop app, web app |
| `MARCER_DATA_DIR`/`games-*.json` (`ANALYSIS-game-data.md`) | desktop app, console launcher (M2), gallery webapp (runtime join) |

Implementation strategy for the overlay merge and catalog joins:

- `SPEC.md` section 7 (overlay rules) and `ANALYSIS-game-data.md` section 3
  (matching) stay the technology-neutral contract.
- The logic is implemented per platform as already established: C# (console
  launcher), Python (`shotgen.py`, future web-app server and `gameinfo-gen`),
  **Dart** (new shared package for both Flutter surfaces, e.g.
  `marcer_catalog`: overlay merge, gameinfo join, screenshot index lookup,
  config/paths loading).
- Triple implementation is accepted: it is the project's established pattern
  (spec as contract, reimplementation as a feature), not an accident.

## 6. Status and Follow-Ups

- **Decided (this document):** app split, technologies, shared-data strategy.
- **Implemented:** gallery webapp (`tools/gallery`, `SPEC-gallery-webapp.md`)
  — stdlib Python server + HTML/CSS/JS frontend; the static `shotgen html`
  gallery has been removed.
- **Decided 2026-10-11 (follow-up):** Flutter desktop app lives in this
  repository at `apps/marcer_desktop/` (pure-Dart data layer in
  `apps/marcer_desktop/packages/marcer_catalog/`), Flutter stable SDK in
  `~/flutter`, own `desktop.config.json` with absolute paths (committed as
  `apps/marcer_desktop/desktop.config.example.json`). Phased plan:
  `apps/marcer_desktop/PLAN.md` (Phase 0 scaffold done).
- **Not yet decided / deferred:**
  - When Surface B (couch mode) is added, how the mode switch is presented
    (config flag, CLI arg, or runtime switch).
  - Whether the gallery server and a future tool share a common
    module layout under `tools/`.
  - Packaging/release strategy for the Flutter app → **resolved 2026-10-11**:
    independent `desktop-v*` tag workflow (`.github/workflows/desktop-release.yml`,
    matrix linux/macos/windows) plus path-based CI; launcher stays on `v*`.
- **Flutter desktop app:** Phase 0 scaffold written (2026-10-11); UI and
  launch still to come per `apps/marcer_desktop/PLAN.md`.

## 7. Conformance Notes for Future Implementations

- Neither app may write to `MARCER_ROOT_DIR`, `MARCER_PATCH_DIR`,
  `<OUT>/`, or `<PATCH>/Data/` (read-only consumers; same safety rules as the
  launcher and `shotgen`).
- The gallery web app binds to the local network (`0.0.0.0` by default,
  no auth) and serves no path outside
  the configured data roots.
- The Flutter desktop app must degrade gracefully when `index.json` or
  `<PATCH>/Data/` are absent (show empty states, never crash).
- Behavioral changes to navigation, overlay semantics or metadata schema
  require updating `SPEC.md` / `ANALYSIS-game-data.md` first; this decision
  document only records technology choices.

---

## License

Licensed under the [MIT License](LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
