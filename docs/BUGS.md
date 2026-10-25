# Known Bugs & Issues

## Critical Bugs

_No open critical bugs._

## Medium Bugs

_No open medium bugs._

## Documentation Inconsistencies

_No open documentation inconsistencies._

## Code Quality / Minor

_No open code quality issues._

---

## Fixed / Non-Issues (Verified)

| Item | Status | Notes |
|------|--------|-------|
| `demo.sh` location | ✅ OK | Exists at repo root, README link correct |
| Magic strings centralized | ✅ Done | `FavoritesRootName`, `DefaultFileName`, `DefaultTitle` |
| Scroll fractions as constants | ✅ Done | `BottomScrollFraction`, `TopScrollFraction` |
| `AvailableLines` helper | ✅ Done | `ProgramHelpers.AvailableLines` |
| Colors configurable | ✅ Done | `Colors` section in config |
| Win32 constants documented | ✅ Done | Marked "intentionally hardcoded" |
| `Hatari.ConfigFile` optional with bundled fallback | ✅ Done | Empty ConfigFile falls back to bundled `MarcerGameDvd-Hatari.cfg` |
| `FavoritesService.Save()` swallow comment | ✅ Done | Explains intentional behavior |
| `UIErrorService` no-rethrow doc | ✅ Done | Explains design decision |
| ArgsTemplate `{cfg}` empty ConfigFile fallback | ✅ Done | `HatariLauncher.Launch()` falls back to bundled config |
| `MenuRenderer.RedrawEntry()` resize bounds check | ✅ Done | Row validated against `availableLines` + `Console.WindowHeight`, catch in `WriteConsoleLine` |
| `HatariLauncher` ArgsTemplate validation | ✅ Done | Constructor validates both `{zip}` and `{cfg}` placeholders |
| ZIP launch file existence check | ✅ Done | `File.Exists` defense-in-depth in `InputController` |
| `RightArrow`/`LeftArrow` in AGENTS.md | ✅ Done | Added to key bindings |
| `OverlayDirectoryBrowser` path traversal | ✅ Non-issue | `..` segments filtered at entry, `IsSubPathOf` as additional safety net |
| `ShowConsoleMessage` params overload | ✅ Done | Added convenience overload with flat argument list |
| shotgen: index pointed at vanished mirror files (Play and Read – Atari Legend) | ✅ Fixed | The `…CaseConflict` rename had moved the mirrored preview/candidate/metadata away from the indexed path; files restored from the conflict folder (md5-verified) and the mirror tree re-keyed to the canonical `…a new Game` spelling |
| Desktop: **Download folder** fetched only a subfolder (or the wrong magazine dir) | ✅ Fixed | `cardFolderRel` fell back to the **first ZIP's parent** when the section tree was undiscovered (e.g. empty `RootDirectory`, the exact download-missing case) and for magazine cards; the alphabetically first ZIP is often nested (`Original/`, `STX/`), so only that competitor directory was pulled. Fix: resolve `<tree>/<letter>/<folder>` from the index rels (case-insensitive letter/folder pair, cached section-tree prefix as fallback; magazine = issue prefix, 4 segments when nested / 3 when flat); gallery `_folder_rel` uses the same rule. Variant order (desktop + gallery) now lists direct-folder ZIPs before subfolder ZIPs |
| shotgen: 3 entries stuck at `status: error` (Play and Read – family curriculum, 2× Prisma STX) | ✅ Fixed | Root cause: the merge was case-insensitive only per **file**, so root-only files kept the root folder spelling (`…a New Game`) next to patch-only files under the patch spelling (`…a new Game`) → two case-variant output directories in mirror and logs → sync client renamed them into `…_DiskStation_…CaseConflict` siblings mid-run → copy failed. Fix: directory-level canonicalisation (patch wins per folder) plus `src_rel` for reading the source under its own layer spelling (`shotgen.py`, commit `67bf948`); repair: index re-keyed, `prune` (29 logs, 673 empty dirs), 3 entries re-run → all `done`, no new CaseConflict folders |

---

## Priority Recommendation

All identified issues have been resolved. See the Fixed table above for details.