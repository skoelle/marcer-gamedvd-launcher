# Marcer GameDVD Launcher

A performant, consistent console launcher for the Hatari emulator on Windows. Control is entirely via keyboard—using only the arrow keys, Enter, Backspace, ESC, PageUp, and PageDown, you can browse your game archive quickly and comfortably. Navigation is strictly limited to the configured root directory. ZIPs are seamlessly launched via Hatari. Thanks to overlay/patch mode, a consistent color scheme, and robust cursor/scroll logic, even the largest archives or deeply nested directory trees are handled smoothly and reliably.

## Features
- **Overlay/Patch Union:** Recursively merges main and patch directory at every level. Each object/name is shown only once (patch takes precedence).
- **Dynamic, practical color scheme with layer labels:**

    | Entry                  | Label     | ConsoleColor | Meaning
    |------------------------|-----------|--------------|---------------------------------------------|
    | Folder in both         | `[BOTH]`  | Yellow       | Directory in both layers (patch/main)
    | Patch-only folder      | `[PTCH]`  | DarkYellow   | Directory only in patch layer
    | Main-only folder       | `[ROOT]`  | Gray         | Directory only in main layer
    | ZIP in both            | `[BOTH]`  | Green        | ZIP archive in both layers
    | Main-only ZIP          | `[ROOT]`  | DarkGreen    | ZIP archive only in main layer
    | Patch-only ZIP         | `[PTCH]`  | Magenta      | ZIP archive only in patch layer

## Roadmap

### Released Features
- **Favorites/bookmark system:**
  - Press `*` on a ZIP to toggle it as a favorite. Favorites are shown in a virtual `Favorites` folder at the top of the root listing when any favorites exist.
  - Favorites are persisted in `favorites.txt` in the configured `PatchDirectory`, or next to the EXE if no patch directory is set.

### Planned Features
- **ZIP database & metadata extraction** (from version 2.0)
  - Builds a database (e.g. as a local file), stores all known ZIPs
  - Enables full-text search, filters, later analysis
- **Search/filter (quicksearch) over ZIPs** (from v2.0, via database)
  - Fast name search inside launcher, with history
- **History/list of recently launched games** (from v2.0, via database)
  - Automatic access to recently played titles
- **Overlay hot swap** (from version 3.0)
  - Overlay/patch folder can be switched at runtime, instant comparison

**More ideas will be added iteratively!**

---

**Display Performance Note:**
- The current rendering logic follows state-of-the-art principles for performant C# console apps:
  - Minimal redraw: Only the truly changed line is redrawn, never the whole screen.
  - No Console.Clear or full redraw on cursor movement—just targeted SetCursorPosition and Write.
  - This method (per StackOverflow, Spectre.Console, Terminal.Gui, etc.) is optimal for smooth navigation in large lists.
  - Further performance can be gained with shadow buffers/string-diffs per line, but currently there's no practical performance issue.
- Thus, display performance is at “best practice” level for .NET TUIs.
  - Long file names and narrow console widths are handled defensively: MenuRenderer truncates file names so that each rendered line is exactly Console.WindowWidth characters long. This prevents Console.Write from overflowing the line and avoids visual artifacts when names are longer than the available width.

---
### Features we will NOT implement
- User-configurable key bindings (keymap)
- Display & import of screenshots/cover images
- Music/Sound player integration (YM/MOD/SND, etc.)
- Persistent UI settings, window size management (not relevant in console mode)

## Operation and Display

- **Consistent navigation & controls:**
    - Arrow up/down: move selection (always visible)
    - Arrow right: open folder / launch ZIP with Hatari (same as Enter)
    - Arrow left: exactly one level up (same as Backspace)
    - Enter: open folder / launch ZIP with Hatari (patch variant always preferred if present)
    - Backspace: exactly one level up (never exceeds root)
    - ESC or Q: exit the program immediately
    - PageUp/PageDown: jump exactly one screen full (window height - 1)
    - `*`: toggle favorite on selected ZIP
    - Display always one line less than console height; no overflow/cut-off
- **Cursor position saving per directory:**
    - The last position/selection of each directory is retained, even after Backspace
- **Robust, smooth redraw:**
    - Optimized full redraw on scrolling/paging
    - Minimal redraw on cursor move
- **Minimal resource usage (handles huge trees efficiently)**
- **Navigation can NEVER leave the configured root**

## Usage
1. Edit `launcher.config.example.json` to set your `RootDirectory`, optional `PatchDirectory` and the `Hatari` settings, then copy it to `launcher.config.json` for local use. Relative paths are resolved against the EXE folder (build output).
2. **Windows:** Build via `build.cmd`.
3. **Linux:** Build via `build.sh` (run `chmod +x build.sh` first to make it executable).
4. **Always start using `start.cmd`.**
5. In the console, all subfolders and ZIPs in root (and recursively below) will be shown; other file types/hidden files are always ignored.
6. Complete navigation/control with arrow keys, Enter, Backspace, ESC, PgUp/PgDn, as described above.
7. **IMPORTANT:** Navigation/scroll/backspace:
    - Backspace never escapes the root
    - In root, Backspace has no effect
    - Empty directories are reported (display stays stable)
8. **Overlay/patch logic:**
    - If a ZIP/folder exists in both patch and main, always the patch version opens/launches
    - All navigation is relative to root path—for consistent experience

## System Requirements
- **Windows:** .NET Desktop Runtime 10 or later, Hatari Emulator with configured CFG
- **Linux:** .NET Runtime 10 or later, Hatari Emulator with configured CFG (Wine/compatible version)

## Configuration

The application reads settings from `launcher.config.json` (the local, user-specific file). A template `launcher.config.example.json` is shipped with the release — copy it to `launcher.config.json` and adjust the paths for your environment.

Example `launcher.config.example.json`:

```json
{
  "RootDirectory": "C:\\Games\\Hatari\\ROMS",
  "PatchDirectory": "C:\\Games\\Hatari\\PATCH",
  "Hatari": {
    "Executable": "C:\\Tools\\hatari\\hatari.exe",
    "ConfigFile": "C:\\Tools\\hatari\\hatari-st.cfg",
    "ArgsTemplate": "-c \"{cfg}\" --disk-a \"{zip}\""
  }
}
```

Fields:
- RootDirectory: Absolute (or relative) path to the game root. Navigation must never leave this root directory.
- PatchDirectory: Optional overlay/patch directory (merged with the main root at runtime).
- Hatari.Executable: Full path to `hatari.exe`.
- Hatari.ConfigFile: Full path to the Hatari configuration file.
- Hatari.ArgsTemplate: Argument template used to start Hatari. Use `{cfg}` for the Hatari config file path and `{zip}` for the ZIP file to launch.

Notes:
- Relative paths are resolved relative to the EXE directory (AppContext.BaseDirectory). This makes behavior consistent when running from the build output folder.
 - Hatari.Executable is validated at startup: the file must exist and have an .exe extension. Relative paths for Hatari settings are resolved against the EXE folder.
- `Hatari.ArgsTemplate` must contain at least the `{zip}` placeholder. Example: `-c "{cfg}" --disk-a "{zip}"`.
- The program performs a straight string substitution of `{cfg}` and `{zip}`; it does not add additional quoting logic. Therefore include quotes around placeholders in the template if your paths contain spaces (as in the example).
- `launcher.config.example.json` is copied to the output directory by the csproj (`CopyToOutputDirectory=PreserveNewest`).
- After modifying `launcher.config.json`, restart the application for changes to take effect.

## Release Workflow

Releases are automated via GitHub Actions. When a tag matching `v*` is pushed, the workflow (`.github/workflows/release.yml`) automatically:
1. Builds platform-specific artifacts (Windows, Linux, macOS)
2. Generates release notes from git log
3. Creates a GitHub Release with all ZIPs attached

**To create a release:**
1. Ensure `README.md` and `AGENTS.md` are up to date.
2. Commit all changes.
3. Create and push a tag: `git tag v{version} && git push origin v{version}`.
4. The GitHub Action handles the rest.

**Local builds** (for development/testing):
- **Windows:** `build.cmd`
- **Linux/macOS:** `build.sh` (run `chmod +x build.sh` first)

## Community

This launcher was built for the [Marcer GameDVD](https://www.facebook.com/groups/360493904888475/) community on Facebook. If you have questions, suggestions, or want to discuss Hatari and Atari ST gaming, join the group!

## Notes
- Full requirements, features and build rules are always up to date in `AGENTS.md`.
- After every code or feature change and every release, README.md and AGENTS.md must be reviewed and kept up to date.
- For every release, release notes **must** be present listing all changes and bugfixes; this is required by AGENTS.md!
