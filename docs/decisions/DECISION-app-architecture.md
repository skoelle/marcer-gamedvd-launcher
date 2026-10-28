# DECISION: App Architecture (Marcer GameDVD)

Why the project uses two UI applications with different technologies.
Decision date: 2026-10-11.

**Related documents:**
- [`SPEC-launcher.md`](../specs/SPEC-launcher.md) — launcher behavior
- [`SPEC-desktop.md`](../specs/SPEC-desktop.md) — desktop app behavior
- [`SPEC-gallery-webapp.md`](../specs/SPEC-gallery-webapp.md) — gallery behavior
- [`ANALYSIS-game-data.md`](../analysis/ANALYSIS-game-data.md) — gameinfo artifacts

---

## 1. Problem / Starting Point

The static HTML gallery built by the former `shotgen html` command did not
scale: one giant `index.html` with tens of thousands of entries and images got
slower with every screenshot run. A dynamic replacement was needed, plus a
longer-term vision of richer frontends.

Three UI worlds were envisioned:

1. **Gallery web app** — browse the screenshot archive in a browser, no
   installation.
2. **Inventory browser** (desktop) — gallery-style catalog grid over the game
   trees with a detail sidebar and full keyboard control.
3. **Couch launcher** (long-term) — fullscreen 10-foot UI with gamepad
   navigation and launching.

## 2. Decision

**Two applications, two technologies:**

| App | Technology | Scope |
|---|---|---|
| **Desktop app** (inventory browser now, couch launcher later) | **Flutter** (one project, two surfaces) | Surface A (now): windowed master-detail inventory browser. Surface B (later): fullscreen couch mode with gamepad. |
| **Gallery web app** | **HTML/CSS/JS frontend + small local Python server** | Dynamic gallery replacing `shotgen html`: server-side pagination, search/filter, full-size PNGs. Runs locally/LAN only. |

Rejected alternatives:

- **Electron / Tauri** — no UI to share with the web gallery, adds a third
  runtime (JS/Rust) beside Dart and Python, and the gamepad story is weaker.
- **Avalonia / Blazor (.NET)** — would reuse the C# launcher core but requires
  XAML and manual gamepad interop; no UI shared with the gallery either.
- **Flutter web for the gallery** — canvas renderer, multi-MB payload, loses the
  existing HTML/CSS design.
- **Three separate apps** — rejected in favor of one Flutter project with two
  surfaces and one data layer.

## 3. Rationale

**Flutter for the desktop app:** virtualized lists handle the full catalog
without special effort; the strong keyboard/focus system maps to D-pad
navigation; mature gamepad support via `gamepads` on all three platforms; one
toolchain for both surfaces; native rendering/fullscreen fits the couch use
case; established Windows/macOS/Linux CI.

**Python + HTML for the gallery:** the existing HTML/CSS design (colors, card
grid, filter bar, badges) is reused; the server is a small read-only API over
the index with pagination and lazy images; Python lives in the existing repo
`.venv`; no npm/Rust runtime enters the repo.

## 4. Shared Data Layer

All apps are strictly **read-only consumers** of the same artifacts:

| Source | Consumers |
|---|---|
| `MARCER_ROOT_DIR` + `MARCER_PATCH_DIR` overlay trees | desktop app, web app, console launcher |
| `<OUT>/index.json` + mirrored PNGs | desktop app, web app |
| `MARCER_DATA_DIR/gameinfo/games-*.json` | desktop app, console launcher, gallery webapp |

The overlay merge and catalog joins are implemented per platform: C# (console
launcher), Python (`shotgen.py`, gallery server, `gameinfo-gen`) and **Dart**
(`marcer_catalog`: overlay merge, gameinfo join, screenshot index lookup,
config). Triple implementation is accepted: the spec is the contract and each
implementation is a feature, not an accident.

## 5. Status

- Gallery webapp implemented (`tools/gallery`); the static `shotgen html`
  gallery was removed.
- Flutter desktop app lives at `apps/marcer_desktop/` with its pure-Dart data
  layer in `packages/marcer_catalog/`. Releases use the independent `desktop-v*`
  workflow; the console launcher stays on `v*`.
- Surface B (couch mode) and its switch mechanism are future work.
