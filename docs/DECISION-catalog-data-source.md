# DECISION: Catalog Data Source (Marcer GameDVD)

Records what the catalog consumers (Flutter desktop app, gallery webapp) use as
their data source, why the catalog is **index/gameinfo-only** (no filesystem
scan), and what that implies for local/foreign ZIP layouts. Follows the style of
`DECISION-app-architecture.md`. Decision date: 2026-10-17.

**Related documents:**
- [`DECISION-app-architecture.md`](DECISION-app-architecture.md) — app split, shared read-only data layer
- [`SPEC-screenshot-generator.md`](SPEC-screenshot-generator.md) — `index.json` / `index-<name>.json` schema and the `layer` field
- [`SPEC-gallery-webapp.md`](SPEC-gallery-webapp.md) — gallery model, the design reference for the desktop catalog
- [`ANALYSIS-game-data.md`](ANALYSIS-game-data.md) — `games-*.json` schema, the `layers` field, matching rules
- [`apps/marcer_desktop/README.md`](../apps/marcer_desktop/README.md) — user-facing "Missing ZIPs" section
- [`apps/marcer_desktop/packages/marcer_catalog/`](../apps/marcer_desktop/packages/marcer_catalog/) — the shared Dart data layer

---

## 1. Problem / Starting Point

The archive is published as a set of **read-only artifacts** (screenshot index +
PNG tree, gameinfo JSON) on top of an overlay of two game trees (`RootDirectory`
+ optional `PatchDirectory`). The catalog consumers never scan the game trees;
they rebuild the catalog from the artifacts alone.

Two questions follow from that, raised while reusing an index/gameinfo generated
against a **different** local ZIP layout:

1. What happens when the same index/gameinfo are consumed by a user whose ZIPs
   are all in `ROOT` (no or a different patch layer)?
2. What happens to ZIPs that physically exist in `ROOT`/`PATCH` but are in
   **neither** the index nor gameinfo?

## 2. Decision

**The catalog universe is built exclusively from the per-section screenshot
indices plus gameinfo — without any filesystem scan.**

- Cracked cards come from `index.json` entries grouped by `(letter, folder)` and
  joined with `games-cracked.json` (index-only).
- `pd`/`utils` cards are the **union** of their index groups and gameinfo-only
  folders (metadata-only cards, no screenshots).
- `magazine` cards come from `index-magazine.json` only (index-only, no
  gameinfo): one card per magazine issue, grouped by a filename parser.
- `falcon` cards come from `index-falcon.json` only (index-only, no
  gameinfo), grouped by `(letter, folder)` like the cracked view.
- No source tree is walked while building the universe.

References: `CatalogUniverse.build` / `CatalogBundle.loadSync` in
`packages/marcer_catalog/lib/src/catalog_universe.dart`. The gallery webapp
follows the same model (`tools/gallery/gallery.py`).

The filesystem is only consulted **lazily and per entry**, never as a full scan:
ZIP existence (`zipExists`) and pd/utils folder ZIP resolution (`variantsOfCard`)
touch the disk on demand and cache the result for the controller's lifetime
(`CatalogController.zipExists` / `variantsOfCard` in
`apps/marcer_desktop/lib/catalog_controller.dart`).

## 3. Consequences

### 3.1 The displayed layer is resolved from the local filesystem
`ROOT` / `PATCH` / `BOTH` on catalog cards, in the detail panel and in the
lightbox come from the actual local files, not from the index/gameinfo
`layer` field. `CatalogController.zipLayer` checks `RootDirectory` and
`PatchDirectory` per ZIP; `variantLayer`/`cardLayer` aggregate the result and
collapse mixed variants to `BOTH`. The grid reads the asynchronous
`cachedCardLayer` cache and requests a bounded background folder scan
(`ensureCardScanned`), so tile building never blocks on a network mount.

The published `layer` field is still retained in the data model and is used
by the overlay folder browser, where the entry itself already comes from the
local overlay.

### 3.2 Launching prefers the local patch copy
The launch path uses the patch copy whenever a patch directory is configured
**and** the file exists, regardless of the published layer; otherwise it
falls back to `RootDirectory/<rel>` (`CatalogController.zipPathForVariant`).
This matches SPEC R14 and keeps reused index/gameinfo data launchable when the
consumer's local ZIP layout differs from the publisher's.

### 3.3 MISSING detection is filesystem-based and layer-independent
`zipLayer` checks both `RootDirectory` and `PatchDirectory`, so locally
present ZIPs are never falsely flagged `MISSING`; per-variant/card `MISSING`
reflects a genuinely absent file in **both** layers. The grid uses the cached
async scan, while launch/favorites use the synchronous helper for the single
card being acted on.

### 3.4 ZIPs in neither index nor gameinfo are invisible in the catalog
A ZIP that exists in `ROOT`/`PATCH` but is absent from both the index and
gameinfo never becomes a card — reloading does not help; the artifact must be
regenerated (`shotgen index`, `gameinfo-gen extract`). It is only reachable in
the **overlay folder browser** (`T`), which is the one mode that scans the trees
(`packages/marcer_catalog/lib/src/overlay.dart:29-59`,
`lib/src/entry.dart:34-41`).

Gameinfo-only `pd`/`utils` cards show as dimmed placeholder tiles without
preview, status or kind (`GameCard` placeholder path in `card.dart` /
`card_grid.dart`), so an untracked ZIP added to the catalog would inherit the
same second-class appearance unless it is indexed for screenshots too.

## 4. Deferred / Follow-up Ideas

Recorded 2026-10-17; decided to keep the current behavior for now.

1. **Local index / filesystem sync (idea).** Build a per-user local index (or an
   on-demand tree scan) so the catalog can surface ZIPs that are missing from
   the artifacts. Local layer resolution and the patch-first launch path are
   already implemented (§3.1–§3.3). Natural docking points exist in the lazy FS
   helpers (`zipExists`, `variantsOfCard`, `zipLayer`). Trade-off: without a
   screenshot such cards are thin placeholder tiles (§3.4) and match no
   status/facet filter, so the value is limited — the overlay browser already
   covers "browse what is really there". Deferred until a concrete need
   justifies the added scanning/consistency cost.
2. **"N ZIPs not indexed" counter (idea).** A lighter-weight completeness hint
   (count only, no per-ZIP cards) could point users at unindexed files without
   changing the catalog model.

## 5. Conformance Notes

- Catalog consumers stay **read-only** towards `RootDirectory`, `PatchDirectory`,
  `<ScreenshotDirectory>` and `<GameinfoDirectory>` (same rule as the launcher
  and `shotgen`; `DECISION-app-architecture.md` §7), except for the desktop app's
  explicit manual-curation write path (`index.json` + mirror meta under
  `shotgen.lock`, `lib/index_editor.dart`).
- Missing `index.json` / gameinfo must degrade gracefully (empty states with a
  notice, never a crash).
- A behavioral change to the catalog data source (e.g. adding the §4 local
  index) must update this document, `apps/marcer_desktop/README.md` and
  `AGENTS.md`.

---

## License

Licensed under the [MIT License](../LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
