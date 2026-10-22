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

References: `CatalogUniverse.build` / `CatalogBundle.loadSync`
(`packages/marcer_catalog/lib/src/catalog_universe.dart:27-53`, `:314-345`);
cracked index-only (`:61`), pd/utils union (`:68`, `:75`, `:211-217`). The
gallery webapp follows the same model (`tools/gallery/gallery.py`).

The filesystem is only consulted **lazily and per entry**, never as a full scan:
ZIP existence (`zipExists`) and pd/utils folder ZIP resolution (`variantsOfCard`)
touch the disk on demand and cache the result for the controller's lifetime
(`apps/marcer_desktop/lib/catalog_controller.dart:491-575`).

## 3. Consequences

### 3.1 The displayed layer is the *published* layer, not the local one
`ROOT` / `PATCH` / `BOTH` on cards, in the detail panel and in the lightbox
comes from the index entry's `layer` (screenshot index) or the gameinfo `layers`
list — never from probing the local filesystem. Aggregation: a single distinct
layer is shown as-is, several collapse to `BOTH`
(`packages/marcer_catalog/lib/src/card.dart:345-347`, `:381-384`).

References: `card_grid.dart:390`, `detail_panel.dart:142`/`:196`,
`game_lightbox.dart:523`/`:573`, `game_info_panel.dart:345`.

### 3.2 Launching is robust regardless of the published layer
The launch path prefers the patch copy only when a patch directory is configured
**and** the variant's published layer is `PATCH`/`BOTH` **and** that file exists;
otherwise it falls back to `RootDirectory/<rel>`
(`apps/marcer_desktop/lib/catalog_controller.dart:479-487`).

So a consumer whose ZIPs all live in `ROOT` (empty/different patch layer) still
launches correctly from reused index/gameinfo data — the mismatching layer
**badges** are cosmetic only. (The reverse — published `ROOT` but the file is
physically in the patch layer — is not covered by this fallback.)

### 3.3 MISSING detection is filesystem-based and layer-independent
`zipExists` checks `RootDirectory` first, then `PatchDirectory`, ignoring the
published layer field (`catalog_controller.dart:503-510`), so locally present
ZIPs are never falsely flagged `MISSING`; per-variant/card `MISSING` reflects a
genuinely absent file in **both** layers.

The grid never performs those checks synchronously while building a tile: it
reads a cache (`cachedCardLayer`/`cachedCardMissing`) and requests a bounded
background folder scan (`ensureCardScanned` → async `Directory.list` per
folder, 6 workers, one listing instead of per-file `stat` calls, throttled
notify). The layer/`MISSING` badges therefore appear asynchronously. This keeps
scrolling smooth on slow/network mounts, where a cold per-file `exists` can
cost hundreds of milliseconds (see `apps/marcer_desktop/tool/benchmark.dart`);
the detail panel uses the same cache, while launch/favorites keep the
synchronous check for the single card being acted on.

### 3.4 ZIPs in neither index nor gameinfo are invisible in the catalog
A ZIP that exists in `ROOT`/`PATCH` but is absent from both the index and
gameinfo never becomes a card — reloading does not help; the artifact must be
regenerated (`shotgen index`, `gameinfo-gen extract`). It is only reachable in
the **overlay folder browser** (`T`), which is the one mode that scans the trees
(`packages/marcer_catalog/lib/src/overlay.dart:29-59`,
`lib/src/entry.dart:34-41`).

Gameinfo-only `pd`/`utils` cards show as dimmed placeholder tiles without
preview, status or kind (`card.dart:386-397`; `card_grid.dart:381-383`,
`:409`), so an untracked ZIP added to the catalog would inherit the same
second-class appearance unless it is indexed for screenshots too.

## 4. Deferred / Follow-up Ideas

Recorded 2026-10-17; decided to keep the current behavior for now.

1. **Local index / filesystem sync (idea).** Build a per-user local index (or an
   on-demand tree scan) so the catalog can (a) surface ZIPs missing from the
   artifacts, (b) report the *real* local layer instead of the published one,
   and (c) reconcile the launch path fully. Natural docking points already
   exist in the lazy FS helpers (`zipExists`, `variantsOfCard`, `zipLayer`).
   Trade-off: without a screenshot such cards are thin placeholder tiles
   (§3.4) and match no status/facet filter, so the value is limited — the
   overlay browser already covers "browse what is really there". Deferred until
   a concrete need justifies the added scanning/consistency cost.
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
