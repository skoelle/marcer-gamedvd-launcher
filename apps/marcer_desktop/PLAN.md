# PLAN: Marcer GameDVD Desktop App (Flutter, Surface A)

Status: **Phase 0 + Phase 3 core done (2026-10-11)** — Flutter 3.47.7 stable in
`~/flutter`, `marcer_catalog` skeleton (12 `dart test`), master-detail UI
implemented: filter bar (search, layer, screenshots, publisher, year), overlay
folder tree with lazy expansion + virtual Favorites folder, entry list with
SPEC §9.1 line format / §10 keyboard bindings / §9.3 colors, detail panel
(preview + candidates + gameinfo metadata), help overlay (§9.4 text),
favorites persistence (§11, R25/R26), status bar with degradation notices.
`flutter test` (4) + `flutter analyze` clean.
Next: manual run validation, then Phase 1 completion and Phase 5 (launch).
Written 2026-10-11.
Governing decision: [`DECISION-app-architecture.md`](../../DECISION-app-architecture.md)
(Desktop app = Flutter, one project, two surfaces; this file covers **Surface A**).

**Related documents:**
- [`SPEC.md`](../../SPEC.md) — technology-neutral launcher spec (overlay rules, navigation, launch)
- [`ANALYSIS-game-data.md`](../../ANALYSIS-game-data.md) — gameinfo JSON schema and matching rules
- [`SPEC-screenshot-generator.md`](../../SPEC-screenshot-generator.md) — `index.json` + PNG layout
- [`SPEC-gallery-webapp.md`](../../SPEC-gallery-webapp.md) — reference for join rules and API payload shapes

---

## 0. Decided Scope (2026-10-11)

| Topic | Decision |
|---|---|
| Project location | **Subdirectory of this repo**: `apps/marcer_desktop/` |
| List model | **Hybrid**: overlay folder tree (SPEC §7) + filtered ZIP list + detail panel (Playnite-like) |
| Config | **Own `desktop.config.json`** schema (decoupled from `launcher.config.json`) |
| MVP scope | **Data layer + read-only UI** — no Hatari launch yet, no couch mode |

Rejected for the MVP (explicitly deferred, see §6): flat catalog-only UI (breaks SPEC
tree navigation), reusing `launcher.config.json`, launching games from the UI.

---

## 1. Phase 0 — Toolchain & Project Skeleton

1. **Flutter SDK install** (not present on this machine yet): stable channel via git
   clone to **`~/flutter`** (decided 2026-10-11; shallow clone, `flutter upgrade` for
   updates), `flutter config --enable-linux-desktop`, `flutter doctor` sanity check.
   Windows/macOS desktop targets are enabled later for the release matrix.
2. **Project structure** inside the repo:

   ```
   apps/marcer_desktop/
     pubspec.yaml                  # Flutter app (linux/windows/macos enabled)
     run.sh                        # repo tool pattern: source local/paths.env, flutter run
     desktop.config.example.json   # committed
     desktop.config.json           # git-ignored (real config)
     packages/
       marcer_catalog/             # pure Dart package (NO Flutter dependency)
         pubspec.yaml
         lib/
           overlay.dart            # SPEC §7 overlay merge
           gameinfo.dart           # ANALYSIS §4 join
           screenshot_index.dart   # index.json lookup + preview path resolution
           config.dart             # desktop.config.json schema
           catalog.dart            # facade assembling all of the above
         test/                     # unit tests with fixture trees
   ```

   `marcer_catalog` must stay Flutter-free so it is unit-testable with plain `dart test`
   and reusable by the future couch surface (Surface B).

---

## 2. Phase 1 — `marcer_catalog` (data layer)

Reimplementation of the spec contract in Dart (the project's established
"spec as contract, reimplementation as a feature" pattern):

- **Overlay merge** exactly per `SPEC.md` §7 (R11–R17):
  - recursive at every level, union of dir names and ZIP names compared
    case-insensitively, each name once;
  - directories first, then `.zip` files (case-insensitive suffix), both groups
    sorted case-insensitively ascending;
  - hidden entries and `@eaDir`-style junk ignored;
  - effective path = patch path when `InPatch` else root path (patch wins);
  - absolute paths / `..` sanitized; never escape `RootDirectory` / `PatchDirectory`;
  - `Parent` at root = silent no-op; FS errors = empty list + error surface, no crash.
- **Gameinfo join** per `ANALYSIS-game-data.md` §4.2: split `index.json` rel path into
  parts → `letter = parts[2]`, `folder = parts[3]` (0-based), join to
  `games-cracked.json` (+ optionally `games-pd.json`, `games-utils.json`).
- **Screenshot index lookup**:
  - load `<OutDirectory>/index.json` (`version` + `entries` map keyed by rel zip path);
  - **gotcha:** on disk `preview` and `candidates[]` are *basenames* — the real PNG is
    `OutDirectory + "/" + dirname(rel) + "/" + preview` (same rule as
    `tools/gallery/gallery.py::_full_png`);
  - status aggregation / primary preview selection mirrored from the gallery spec
    (`done → desktop → no_usable_shots → interrupted → pending → skipped_disk_n`).
- **Graceful degradation** (DECISION §7): missing `index.json`, missing `Data/` dir or
  missing trees → empty states with a notice, never a crash.
- **Read-only guarantee**: the package never writes to `RootDirectory`,
  `PatchDirectory`, `<OutDirectory>` or `<DataDirectory>`.
- **Unit tests**: small fixture trees covering overlay rules (BOTH/ROOT/PTCH flags,
  patch precedence, case-insensitive dedup, traversal attempts), join resolution,
  preview path resolution, and degradation when artifacts are absent.

---

## 3. Phase 2 — `desktop.config.json`

Own schema (decided), committed only as `desktop.config.example.json`; the real file is
git-ignored (same policy as `launcher.config.json`).

```json
{
  "RootDirectory": "",
  "PatchDirectory": "",
  "OutDirectory": "",
  "DataDirectory": "",
  "Hatari": {
    "Executable": "",
    "ConfigFile": "",
    "ArgsTemplate": "-c \"{cfg}\" --disk-a \"{zip}\""
  },
  "Window": { "width": 1280, "height": 800 }
}
```

- Field names follow the `SPEC.md` §5 style.
- **Absolute paths** in the config (decided 2026-10-11); relative paths, if used
  anywhere, resolve against the application directory (R10, same rule as the console app).
- `Hatari` is part of the schema but **unused in the MVP** (launch = Phase 5+).
- `OutDirectory` (screenshot archive) and `DataDirectory` (gameinfo JSONs) are desktop-only
  fields; `DataDirectory` default convention is `<PatchDirectory>/../Data`
  (per `ANALYSIS-game-data.md` §5.5) when left empty.
- `run.sh` still sources `local/paths.env` for developer convenience, but only to
  **seed/print** a working `desktop.config.json` on first run — the app itself reads
  only the config file.

---

## 4. Phase 3 — Desktop UI (Surface A, read-only) — **implemented 2026-10-11**

Playnite-inspired master-detail layout, hybrid model:

- **Top bar:** quick filter dropdowns (section/category, publisher, year, language,
  layer, screenshot status) + text search field.
- **Left:** overlay folder tree per `SPEC.md` §7 with `Enter`/`Backspace` semantics,
  layer labels `BOTH`/`ROOT`/`PTCH`, virtual `Favorites` folder per `SPEC.md` §11
  (stored in `favorites.txt`, keyed by effective path).
- **Center:** virtualized list (`ListView.builder`) of the selected folder's ZIPs, or of
  the filtered set — with layer label + color per `SPEC.md` §9.3.
- **Right:** detail panel — large preview screenshot, candidate gallery, metadata
  (title, publisher, crew, language, disks, release, flags, `matched_via`).
- **Keyboard:** identical bindings to `SPEC.md` §10 (arrows, PageUp/PageDown, Enter,
  Backspace, `*` toggle favorite, `?` help overlay, ESC/Q quit); mouse input additionally
  allowed (R8). Full keyboard control is a hard requirement for this surface.
- **Colors/rendering:** dark Playnite-like theme, but layer/selection colors follow the
  `SPEC.md` §9.3 mapping as the configurable baseline.
- **No launching in the MVP.**

---

## 5. Phase 4 — Docs, policy, housekeeping (mandatory with any functional change)

- `DECISION-app-architecture.md` §6: record the decided project layout
  (subdirectory `apps/marcer_desktop/`).
- `AGENTS.md` + `README.md`: **done 2026-10-11** (Apps section added; build/run
  via `apps/marcer_desktop/run.sh`; `scripts/build.sh` / `scripts/start.sh`
  remain exclusive to the C# console launcher).
- `.gitignore`: **done 2026-10-11** (`desktop.config.json`, Flutter artifacts
  `.dart_tool/`, `build/`). App `pubspec.lock` is committed (reproducible app
  builds); package lock file is ignored via `**/pubspec.lock`? — no: only
  `.dart_tool/`/`build/` are ignored, package lock stays untracked until first
  commit decides (open, low priority).
- Do **not** touch `tools/gallery/` (parallel webapp work) or the C# launcher sources.
- Conformance note from DECISION §7: behavioral changes to overlay semantics or metadata
  schema go into `SPEC.md` / `ANALYSIS-game-data.md` **first**.

---

## 6. Later (explicitly out of MVP scope)

- **Hatari launch** per `SPEC.md` §12: `{cfg}`/`{zip}` substitution, bundled-config
  fallback, blocking "running" modal, vanished-ZIP error handling (C25–C27).
- **Surface B — couch mode:** fullscreen 10-foot UI, big tiles with screenshot/cover
  backgrounds, predefined filter presets (instead of dropdowns), gamepad navigation via
  the `gamepads` package; mode switch mechanism (config flag / CLI arg / runtime switch)
  to be decided when reached.
- **Release pipeline:** GitHub Actions matrix (win/mac/linux) mirroring
  `.github/workflows/release.yml`.
- Optional: pre-joined `catalog.json` (ANALYSIS M6) instead of runtime join.

---

## 7. Open Questions

Resolved 2026-10-11:
1. ~~Flutter SDK install location~~ → **`~/flutter` git clone (stable)**.
2. ~~Path sourcing~~ → **absolute paths in `desktop.config.json`** (see §3).

Still open:
3. Does the hybrid list show raw ZIP entries per folder, or joined *game* records
   (folder-level grouping like the gallery cards) inside a folder? Affects Phase 3
   layout detail.
4. Window/state persistence (size, last folder, splitter positions) — MVP or later?

---

## License

Licensed under the [MIT License](../../LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
