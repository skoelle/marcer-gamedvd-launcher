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

---

## Priority Recommendation

All identified issues have been resolved. See the Fixed table above for details.