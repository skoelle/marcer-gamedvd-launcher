# Documentation

Design, specification and analysis documents for the Marcer GameDVD project.
The per-app/per-tool READMEs stay next to their code.

## Document types

Each document has exactly one job. Keep it that way:

| Type | Answers | Must not contain |
|---|---|---|
| **SPEC** (`specs/`) | How does the shipped behavior work? The contract for reimplementation. | History, roadmaps, status logs. |
| **ANALYSIS** (`analysis/`) | What is the external data reality (sources, schema, quirks)? | UI behavior, implementation status, done-lists. |
| **DECISION** (`decisions/`) | Why was a technology/architecture chosen? | Deferred ideas (→ `IDEAS.md`), conformance checklists (→ SPEC). |
| **PLAN** (`plans/`) | What work remains? | Completed phases, dated changelogs. |
| **GUIDE** (`guides/`) | How does a user install and configure the app? | Internal design rationale. |
| **Backlog** (`IDEAS.md`) | What is planned, deferred or rejected? | Implementation details. |

Rules:
- One fact has one home. Behavior lives in a SPEC, not in ANALYSIS or a
  decision record.
- No historical verification logs, dated snapshots or "done" checklists in
  ANALYSIS/DECISION; Git history keeps the past.
- Counts in ANALYSIS are order-of-magnitude, never a contract.
- Conformance checklists belong only in SPECs. Behavior changes update the
  relevant SPEC and the root `README.md` in the same change.

## Guides

| File | What it covers |
|---|---|
| [`GETTING-STARTED.md`](guides/GETTING-STARTED.md) | First start, directories, `ftp-sync`, FTP settings, catalog-data downloads, Hatari/TOS, macOS, troubleshooting. |
| [`IDEAS.md`](IDEAS.md) | Living backlog: planned, deferred and explicitly rejected ideas. |

## Plans

| File | What it covers |
|---|---|
| [`PLAN-docker-pipeline.md`](plans/PLAN-docker-pipeline.md) | Server automation: archive sync, change detection, gameinfo/crews/index, asset packaging/upload and the `latest.json` pointer. |

## Specs

| File | What it describes |
|---|---|
| [`SPEC-launcher.md`](specs/SPEC-launcher.md) | **Console launcher** — overlay/patch rules, navigation, rendering, colors, launch, favorites. |
| [`SPEC-desktop.md`](specs/SPEC-desktop.md) | **Desktop app** (`apps/marcer_desktop`) — catalog grid, filters, lightbox, favorites, launch, box scans/manuals, data downloads, self-update, macOS. |
| [`SPEC-gallery-webapp.md`](specs/SPEC-gallery-webapp.md) | **Gallery webapp** (`tools/gallery`) — filter/sort/search model, API payloads, grid/lightbox UI. |
| [`SPEC-screenshot-generator.md`](specs/SPEC-screenshot-generator.md) | **Screenshot pipeline** (`tools/screenshot-gen`) — Hatari automation and the per-scope `index.json` / `index-<name>.json` + PNG artifacts. |

## Analysis

| File | What it contains |
|---|---|
| [`ANALYSIS-game-data.md`](analysis/ANALYSIS-game-data.md) | XLS metadata sources, matching rules, `games-*.json` schema. |
| [`ANALYSIS-crews.md`](analysis/ANALYSIS-crews.md) | Crew ranking: data sources, attribution/alias rules, `crews.json`/`crew-images.json`. |
| [`ANALYSIS-atarilegend.md`](analysis/ANALYSIS-atarilegend.md) | Weekly AtariLegend dumps: contents, folder↔game matching, asset/URL conventions, runtime schema, licensing. |
| [`ANALYSIS-piratefinder.md`](analysis/ANALYSIS-piratefinder.md) | PirateFinder catalogue: schema, import, hash/title matching, crew/menu-disk metadata, limitations. |
| [`ANALYSIS-boxscan-manual-assets.md`](analysis/ANALYSIS-boxscan-manual-assets.md) | `Boxscan/` and `Manual/` folders: location, naming variants, ZIP/loose-file structure, edge cases. |

## Decisions

| File | What it records |
|---|---|
| [`DECISION-app-architecture.md`](decisions/DECISION-app-architecture.md) | Why the desktop app is Flutter and the gallery is Python + HTML. |
| [`DECISION-catalog-data-source.md`](decisions/DECISION-catalog-data-source.md) | Why the catalog is index/gameinfo-only without a filesystem scan. |
| [`DECISION-hatari-download.md`](decisions/DECISION-hatari-download.md) | How the desktop app downloads/installs Hatari. |
| [`DECISION-macos-distribution.md`](decisions/DECISION-macos-distribution.md) | Why the app is not sandboxed and how translocation/notarization are handled. |

## Housekeeping

| Path | What it contains |
|---|---|
| `images/` | Screenshots embedded in the root README (`catalog.png`, `lightbox.png`). |

---

The user-facing overview is the root [`README.md`](../README.md); build rules and
project policy are in [`AGENTS.md`](../AGENTS.md).
