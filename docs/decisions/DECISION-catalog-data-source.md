# DECISION: Catalog Data Source (Marcer GameDVD)

Why the catalog consumers use an **index/gameinfo-only** universe without a
filesystem scan, and what that implies for local/foreign ZIP layouts.
Decision date: 2026-10-17.

**Related documents:**
- [`DECISION-app-architecture.md`](DECISION-app-architecture.md) — app split and shared data layer
- [`SPEC-screenshot-generator.md`](../specs/SPEC-screenshot-generator.md) — index schema and `layer` field
- [`SPEC-desktop.md`](../specs/SPEC-desktop.md) — catalog/missing-ZIP behavior
- [`ANALYSIS-game-data.md`](../analysis/ANALYSIS-game-data.md) — `games-*.json` schema

---

## 1. Problem / Starting Point

The archive is published as read-only artifacts (screenshot index + PNG tree,
gameinfo JSON) on top of two overlay game trees (`RootDirectory` + optional
`PatchDirectory`). Two questions arose when the artifacts were generated against
a **different** local ZIP layout:

1. What happens when a user's ZIPs are all in `ROOT` (no/different patch layer)?
2. What happens to ZIPs that exist on disk but are in neither index nor
   gameinfo?

## 2. Decision

**The catalog universe is built exclusively from the per-section screenshot
indices plus gameinfo — without any filesystem scan.**

- Cracked cards: `index.json` entries grouped by `(letter, folder)` and joined
  with `games-cracked.json`.
- `pd`/`utils`: the **union** of their index groups and gameinfo-only folders
  (metadata-only cards).
- `magazine`: `index-magazine.json` only, one card per issue (filename parser).
- `falcon`: `index-falcon.json` only, grouped by `(letter, folder)`.

No source tree is walked while building the universe. The filesystem is
consulted **lazily and per entry**, never as a full scan: ZIP existence and
pd/utils folder ZIP resolution touch the disk on demand and cache the result
for the controller's lifetime.

## 3. Consequences

### 3.1 The displayed layer comes from the local filesystem

`ROOT` / `PATCH` / `BOTH` on cards, in the detail panel and in the lightbox come
from the actual local files, not from the published index `layer` field. The
grid reads an asynchronous cache and requests a bounded background folder scan,
so tile building never blocks on a network mount. The published `layer` field
is still used by the overlay folder browser, where the entry already comes from
the local overlay.

### 3.2 Launching prefers the local patch copy

The launch path uses the patch copy whenever a patch directory is configured
**and** the file exists, regardless of the published layer; otherwise it falls
back to `RootDirectory/<rel>`. This matches the launcher rule and keeps reused
artifacts launchable when the local layout differs from the publisher's.

### 3.3 MISSING detection is filesystem-based and layer-independent

Both layers are checked, so locally present ZIPs are never falsely flagged
`MISSING`; a per-variant/card badge reflects a genuinely absent file in **both**
layers.

### 3.4 ZIPs in neither index nor gameinfo are invisible in the catalog

Such a ZIP never becomes a card — reloading does not help; the artifacts must
be regenerated (`shotgen index`, `gameinfo-gen extract`). It is only reachable
in the **overlay folder browser** (`T`), the one mode that scans the trees.
Gameinfo-only pd/utils cards show as dimmed placeholders without
preview/status/kind.
