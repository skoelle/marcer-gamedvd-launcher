# Known Bugs & Issues

## Critical Bugs

### 1. ArgsTemplate `{cfg}` placeholder not handled when ConfigFile is empty
**Location**: `HatariLauncher.cs:36`
**Problem**: If `Hatari.ConfigFile` is empty string (allowed per config) but `ArgsTemplate` contains `{cfg}`, the replacement produces `-c "" --disk-a "path"` which Hatari may reject.
**Fix**: Conditionally remove `-c "{cfg}"` when `_cfgPath` is empty, or validate template matches config.

### 2. `MenuRenderer.RedrawEntry()` potential crash on console resize
**Location**: `MenuRenderer.cs:67-98`
**Problem**: If console resizes smaller since last draw, `row` parameter may exceed new `availableLines`. The `else` branch writes directly via `WriteConsoleLine` without bounds checking against actual console height, risking `ArgumentOutOfRangeException` on `Console.SetCursorPosition`.
**Fix**: Validate `row < Console.WindowHeight` before writing, or clamp to valid range.

## Medium Bugs

### 3. `HatariLauncher` constructor doesn't validate `ArgsTemplate`
**Location**: `HatariLauncher.cs:12-24`
**Problem**: Constructor validates `exePath` existence but allows empty/null `argsTemplate`. `Launch()` will fail at runtime with empty string replace. Defense-in-depth validation missing.
**Fix**: Add `if (string.IsNullOrWhiteSpace(argsTemplate) || !argsTemplate.Contains("{zip}")) throw ...;`

### 4. ZIP launch doesn't validate file exists on disk
**Location**: `InputController.cs:185-196`
**Problem**: `PatchPath` or `RootPath` used directly without checking `File.Exists()`. Overlay logic should prevent this, but no defense-in-depth.
**Fix**: Validate `File.Exists(zipToLaunch)` before calling `_hatariLauncher.Launch()`.

## Documentation Inconsistencies

### 5. `Hatari.ConfigFile` required status unclear
**Location**: `README.md:96` vs `LauncherApp.cs:67-68`
**Conflict**: README marks `Hatari.ConfigFile` as required (✅). Code allows empty string and only validates if non-empty. If template uses `{cfg}` but ConfigFile empty → broken args.
**Resolution**: ConfigFile is now optional. When empty, the bundled `MarcerGameDvd-Hatari.cfg` (shipped in the release) is used automatically. README updated to reflect this. ✅ Fixed

### 6. `RightArrow` key binding missing from AGENTS.md requirements
**Location**: `AGENTS.md:57-58` vs `InputController.cs:172-173`
**Conflict**: AGENTS.md lists only Arrow up/down, Enter, Backspace, ESC, PageUp/Down, `?`. Code also handles `ConsoleKey.RightArrow` as alias for Enter (open folder/launch ZIP). README correctly documents it.
**Resolution**: Update AGENTS.md to include RightArrow.

### 7. `ShowModalUntilReturnReleased` race condition on resize
**Location**: `ProgramHelpers.cs:62-98`
**Problem**: Captures `lastRow = AvailableLines` at start. If console resizes during the modal wait loop, the clear writes to stale row position.
**Fix**: Re-read `AvailableLines` before clearing, or lock console during modal (not easily possible).

## Code Quality / Minor

### 8. `ProgramHelpers.ShowConsoleMessage` signature could use `params`
**Location**: `ProgramHelpers.cs:110`
**Current**: `public static void ShowConsoleMessage(string[] lines, ...)`
**Called as**: `ShowConsoleMessage([...], ...)` (collection expression)
**Suggestion**: Change to `params string[] lines` for more idiomatic usage.

### 9. `OverlayDirectoryBrowser` patch path computation order
**Location**: `OverlayDirectoryBrowser.cs:47-50`
**Observation**: Path traversal protection (`IsSubPathOf`) runs after `Path.Combine` but before `Directory.Exists`. Logic appears correct, but worth verifying with `rel` containing `..` when patch layer enabled.

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

---

## Priority Recommendation

1. **Fix #1 (ArgsTemplate `{cfg}`)** - Breaks launch when ConfigFile empty
2. **Fix #2 (RedrawEntry bounds)** - Potential crash on resize
3. **Fix #3 (HatariLauncher validation)** - Defense in depth
4. **Fix #4 (ZIP path validation)** - User-facing robustness
5. **Sync #5 & #6 (docs)** - Requirements accuracy