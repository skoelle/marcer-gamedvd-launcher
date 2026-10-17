# Documentation

Design and specification documents for the Marcer GameDVD project. These are the
technology-neutral contracts and records that the apps and tools implement; the
per-app/per-tool READMEs stay next to their code.

## Specs

| File | What it describes |
|---|---|
| [`SPEC.md`](SPEC.md) | **Launcher behavior** — overlay/patch rules, navigation, rendering, colors, launch, favorites. The contract for reimplementing the launcher in any language/UI. |
| [`SPEC-gallery-webapp.md`](SPEC-gallery-webapp.md) | **Gallery webapp** (`tools/gallery`) — filter/sort/search model, API payloads, grid/lightbox UI. The design reference for the desktop catalog. |
| [`SPEC-screenshot-generator.md`](SPEC-screenshot-generator.md) | **Screenshot pipeline** (`tools/screenshot-gen`) — Hatari automation and the per-scope `index.json` / `index-<name>.json` + PNG artifact (the default scope's `index.json` is the one consumed by both UIs). |

## Analysis & decisions

| File | What it contains |
|---|---|
| [`ANALYSIS-game-data.md`](ANALYSIS-game-data.md) | Analysis of the external game metadata (XLS workbooks): data model, matching rules, `games-*.json` schema, roadmap. |
| [`ANALYSIS-boxscan-manual-structure.md`](ANALYSIS-boxscan-manual-structure.md) | Analysis of the `Boxscan/` and `Manual/` companion folders: location, naming variants, ZIP/loose-file structure, edge cases, requirements for a UI consumer (Flutter desktop). |
| [`DECISION-app-architecture.md`](DECISION-app-architecture.md) | Why the desktop app is Flutter, the gallery webapp is Python + HTML, and the couch surface is planned. |
| [`DECISION-catalog-data-source.md`](DECISION-catalog-data-source.md) | Why the catalog is built from the screenshot index + gameinfo without a filesystem scan; published vs. local layer, untracked ZIPs, and the deferred "local index" idea. |

## Housekeeping

| File | What it contains |
|---|---|
| [`BUGS.md`](BUGS.md) | Known issues and their resolution status. |
| `images/` | Screenshots embedded in the root `README.md` (`catalog.png`, `lightbox.png`). |

---

The user-facing overview is the root [`README.md`](../README.md); build rules and
project policy are in [`AGENTS.md`](../AGENTS.md). Behavioral changes must be
reflected in the relevant spec here.