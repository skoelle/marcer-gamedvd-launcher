---
applyTo: '**'
---

## Module Overview (Marcer GameDVD Launcher)

The implementation is split into focused modules (files) under the `HatariZipLauncher/` folder. Keep this section up to date when files are added, removed or responsibilities change.

- HatariZipLauncher/Program.cs: Minimal entry point. Sets console title and starts the application by creating `LauncherApp`.
- HatariZipLauncher/LauncherApp.cs: Application lifecycle host — loads configuration, initializes components and runs the main directory navigation loop (contains `AppHost` internal class).
- HatariZipLauncher/AppConfiguration.cs: POCO configuration classes (`AppConfig`, `AppHatariConfig`) used to deserialize `launcher.config.json`.
- HatariZipLauncher/ProgramHelpers.cs: Small shared helpers (resolve relative paths, centralized console message helper) used across modules.
- HatariZipLauncher/OverlayDirectoryBrowser.cs: Filesystem overlay and browsing logic — merges root and patch directories, enumerates folders and ZIPs, protects against path traversal and ensures navigation cannot leave the configured roots.
- HatariZipLauncher/NavigationController.cs: Encapsulates selection, scrolling and relative-path navigation logic (cursor, page up/down, per-directory remembered selection/state).
- HatariZipLauncher/MenuRenderer.cs: Console rendering logic — efficient per-line redraw, double-buffering and color selection according to overlay rules.
- HatariZipLauncher/HatariLauncher.cs: Responsible for validating the Hatari executable and starting Hatari with the configured argument template (replaces `{cfg}` and `{zip}`).
- HatariZipLauncher/UIErrorService.cs: Centralized UI error presentation using the console message helper.

Note: This overview is intentionally concise. For behavioral changes (navigation, color scheme, launch command or config schema), update this file (agents.md) and README.md as required by project policy.
**Note for Automated Tests/CI:**
The Launcher cannot be executed or tested via `start.cmd` from this environment (build system, automation agent) since no Windows console environment is present. For release workflows and developer validation, it is ALWAYS required to do a manual test run via start.cmd per documentation and policy before delivery.

**Release Process (automated via GitHub Actions):**
- Pushing a tag (`v*`) triggers the GitHub Action workflow (`.github/workflows/release.yml`).
- The workflow builds platform-specific artifacts (Windows, Linux, macOS), generates release notes from git log, and creates a GitHub Release with all ZIPs attached.
- Developer steps for a release:
   1. Ensure `README.md` and `agents.md` are up to date.
   2. Commit all changes.
   3. Create and push a tag: `git tag v{version} && git push origin v{version}`.
   4. The GitHub Action handles the rest (build, ZIP, release notes, GitHub Release).
- Local release artifacts in `release/` are optional and no longer required for the release process.


Additional policy:
- README.md must be written in English. Any functional change that affects usage, configuration, or behavior MUST update README.md in English immediately after the change. If there are consequential changes to developer-facing policies, build steps, or requirements, `agents.md` must be updated as well.

Developer note: Visual Studio Solution
- A Visual Studio solution file exists at the repository root: `marcer-gamedvd-launcher.sln`. Developers may open this solution in Visual Studio to work on the project, debug and build from the IDE. The solution references `HatariZipLauncher\HatariZipLauncher.csproj` and includes Debug and Release configurations. Use `build.cmd` (Windows) or `build.sh` (Linux) and `start.cmd` for consistent command-line builds/releases as described elsewhere in this document.

With this, it is ensured that binary/release files never end up in git, and the release process is always traceable and performed exclusively manually in the web interface.

# Requirements for the Marcer GameDVD Launcher (agents.md)

## Basic Function / Purpose
The console launcher is meant for browsing a games directory and can launch ZIP files with the Hatari emulator under Windows. Control is exclusively via keyboard in the console window.

## Detailed Requirements

### Navigation and Display Principles
- Start directory (root):
  The configured RootDirectory from launcher.config.json
  It must NEVER be possible to navigate outside this directory.
- Only display subfolders and ZIP files; ignore other file types and hidden files.
- Navigation and control exclusively with these keys:
  - Arrow down/up: scroll by single entries
  - Enter: open folder or launch ZIP with Hatari
  - Backspace: jump to parent directory (never outside root)
  - ESC: exit the program
  - PageUp/PageDown: jump by one page up/down through the file list
- The file list always shows exactly as many lines as fit the screen – ALWAYS **one line less** than the console height (`Console.WindowHeight - 1`). This avoids overflow at the bottom and ensures the selection never enters the non-visible area.
  Rationale: writing to the very last console line can cause the Windows console to auto-scroll or produce visual jumps when the cursor reaches the bottom row. Reserving one line prevents unintended scrolling/flicker and keeps the selection cursor strictly within the visible area.
  Maintenance: when changing rendering or navigation logic, always compute the displayed page size as `availableLines = Console.WindowHeight - 1` and keep this value consistent across MenuRenderer, NavigationController and any other code that references the console height.
- There is no information line/path display.
- Cursor and scroll logic:
  - The selection cursor must always remain in the visible area.
  - If the list is longer than the visible window, scrolling is necessary (cursor moves to bottom/top third as you move through).
- The program may be started in the root directory; all subfolders/ZIPs should be accessible from there.

### Launching a Game
- If Enter is pressed on a ZIP, Hatari is called with the configured executable, config file, and the full path to the ZIP file as arguments.

### Error Handling & Edge Cases
- Paths with special characters or spaces must work robustly.
- It must NEVER be possible for navigation logic to leave the configured root folder.
- Empty directories must be displayed correctly (or reported correctly).
- In the root directory, Backspace must have no effect (no error, do not leave the program).
- Navigation (Backspace, Enter, etc.) must remain robust even for very deep or large directory trees.
 - Hatari.Executable is validated during startup: the path is resolved (relative to the EXE directory when applicable) and must point to an existing .exe file. If validation fails the program must present a clear error and exit.

### Miscellaneous
- Optional: Build and start scripts (build.cmd / build.sh / start.cmd) are present, adapt as needed.
 - For ALL builds, tests, and releases, ONLY the platform build script may be used: `build.cmd` (Windows) or `build.sh` (Linux). Direct `dotnet build`/`dotnet run` calls are NOT allowed, as they can lead to version/runtime conflicts. The application must always be started and tested using `start.cmd`.
 - After making any code changes that affect behavior or touch source files, run the platform build script (`build.cmd` on Windows, `build.sh` on Linux) and ensure the build completes successfully before committing. Additionally, perform a manual functional test using `start.cmd` on a Windows machine prior to pushing a release.
- The console window can have any number of lines; display/navigation must adapt dynamically.
- After each build for a release, the entire build output directory (`bin/Release/net10.0/`) must be zipped in the `release/` directory, and the ZIP must be uploaded as a release asset in Gitea.
- For every release, a Release Notes file must be maintained that summarizes all changes, bugfixes, and new features in that version; Release Notes must be provided with the release asset.

 - **IMPORTANT:** With any functional change to the launcher, BOTH this file (agents.md) AND the README.md must always be updated and kept current. Immediately after, a successful build must be executed. This is mandatory for all development on the project.


---

## Layer/Overlay Mode

### Overlay Logic
- The display always combines the contents of the game root ("main directory") and patch directory.
- There is always exactly one overlay browser – at every level, both sources are combined.
- Each folder/file is only shown once per name:
    - If a folder/ZIP exists in both layers, the patch version takes precedence for launching/navigation.
- ZIP start/open always uses the patch file path if present, otherwise from root.
- Navigation combines both layers **recursively** at every sublevel. Navigation/Backspace is always relative.

Note on PatchDirectory semantics:
- PatchDirectory is optional. If the configuration contains no PatchDirectory or it is empty, the application treats this as "no patch layer" and will not consult any patch paths. In other words: an empty or missing PatchDirectory will not implicitly point to the EXE or any other folder — the overlay layer is simply disabled.

Implementation note (input flushing):
- To avoid undesired key-repeat / input "afterglow" when the user holds navigation keys, the application performs a best-effort flush of the console input buffer after navigation events. This is implemented by ProgramHelpers.FlushInputBuffer(), which uses the Win32 FlushConsoleInputBuffer API on Windows. This behaviour is intentional and required to provide a responsive navigation experience.

### Color Scheme
- Folder in both layers: **ConsoleColor.Yellow**
- Folder only in patch layer: **ConsoleColor.DarkYellow**
- Folder only in main layer: **ConsoleColor.Gray**
- ZIP in both layers: **ConsoleColor.Green**
- ZIP only in main layer: **ConsoleColor.DarkGreen**
- ZIP only in patch layer: **ConsoleColor.Magenta**

Note: The ConsoleColor mapping above is authoritative for the application. If you change color values in code (MenuRenderer/GetColorForEntry), update this section to keep documentation and implementation in sync.

### Navigation
- Navigation is always based strictly on the **relative path from root** and is consistent on all levels (Backspace always moves up one level, Enter always moves one level deeper, regardless of which layer).

---
