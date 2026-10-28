---
applyTo: '**'
---

## Component Map

This file holds repo-wide policy and the build/release rules below. Behavioral
details live in the linked documents; keep this map current when components are
added or removed. The documentation taxonomy is described in
[`docs/README.md`](docs/README.md).

| Component | Code | Contract / reference |
|---|---|---|
| Console launcher (legacy) | `apps/marcer_console/` | [`docs/specs/SPEC-launcher.md`](docs/specs/SPEC-launcher.md) |
| Desktop app (Flutter) | `apps/marcer_desktop/` | [`docs/specs/SPEC-desktop.md`](docs/specs/SPEC-desktop.md) |
| Desktop data layer | `apps/marcer_desktop/packages/marcer_catalog/` | SPEC-desktop + [`ANALYSIS-game-data.md`](docs/analysis/ANALYSIS-game-data.md) |
| Gallery webapp | `tools/gallery/` | [`docs/specs/SPEC-gallery-webapp.md`](docs/specs/SPEC-gallery-webapp.md) |
| Screenshot generator | `tools/screenshot-gen/` | [`docs/specs/SPEC-screenshot-generator.md`](docs/specs/SPEC-screenshot-generator.md) |
| Gameinfo extractor | `tools/gameinfo-gen/` | [`ANALYSIS-game-data.md`](docs/analysis/ANALYSIS-game-data.md) |
| Crew analysis | `tools/crew-analysis/` | [`ANALYSIS-crews.md`](docs/analysis/ANALYSIS-crews.md) |
| AtariLegend import | `tools/atarilegend-gen/` | [`ANALYSIS-atarilegend.md`](docs/analysis/ANALYSIS-atarilegend.md) |
| Full catalog index | `tools/full-index-gen/` | [`PLAN-docker-pipeline.md`](docs/plans/PLAN-docker-pipeline.md), [`ANALYSIS-piratefinder.md`](docs/analysis/ANALYSIS-piratefinder.md) |
| Shared pipeline helpers | `tools/_lib/` | Section trees/overlay scan (`catalog_sections.py`) + disk-image hashing (`zip_hashes.py`) |
| Archive sync / asset publish / manifest | `tools/archive-sync/`, `tools/asset-publish/`, `tools/asset-manifest/` | [`docs/plans/PLAN-docker-pipeline.md`](docs/plans/PLAN-docker-pipeline.md) + each tool README |

Catalog data flow: `tools/full-index-gen` scans the game trees (no screenshot
index) and writes `<MARCER_DATA_DIR>/gameinfo/full-index.json.gz` — the ZIP
universe plus per-member disk-image hashes. It ships in the gameinfo asset, so
new ZIPs appear in the desktop app immediately (without screenshots). The
screenshot index (`index*.json`) remains the screenshot-state authority and is
merged into the full index by the app. `tools/piratefinder-gen` was retired;
its reusable ZIP hashing moved to `tools/_lib/zip_hashes.py`.

**No absolute local paths in published artifacts.** Gameinfo/screenshot assets
must only contain relative rel paths and logical names. Absolute paths belong
exclusively in git-ignored `local/` audits (e.g.
`local/crew-analysis/crew-ranking.json`); `crews.json` carries a path-free
`source` block.

Architecture decisions: [`docs/decisions/`](docs/decisions/). The backlog is
[`docs/IDEAS.md`](docs/IDEAS.md); the user-facing overview is
[`README.md`](README.md). Tool usage/build details live in each
`tools/*/README.md`.

Specifications: [`docs/specs/SPEC-launcher.md`](docs/specs/SPEC-launcher.md) and
[`docs/specs/SPEC-desktop.md`](docs/specs/SPEC-desktop.md) are the behavioral
contracts. Behavioral changes must be reflected there and in `README.md` in the
same change.

**Note for Automated Tests/CI:**
The console launcher cannot be executed or tested via `apps/marcer_console/start.cmd` from this environment (build system, automation agent) since no Windows console environment is present. For release workflows and developer validation, it is ALWAYS required to do a manual test run via `apps/marcer_console/start.cmd` (Windows) or `apps/marcer_console/start.sh` (Linux/macOS) per documentation and policy before delivery.

**Release Process (automated via GitHub Actions):**
- Monorepo with **one tag scheme per app**, so each app is released independently:
  - Console launcher (`apps/marcer_console/`): tag `v*` → `.github/workflows/release.yml` → `MarcerGameDvdConsole-v…-{win,linux,osx}-x64.zip` (GitHub Release title: `Marcer Console vX.Y.Z`).
  - Flutter desktop (`apps/marcer_desktop/`): tag `desktop-v*` → `.github/workflows/desktop-release.yml` → `MarcerDesktop-v…-{win,linux,osx}-x64.zip`.
- Each workflow triggers only on its own tag prefix (`v*` never matches `desktop-v*` and vice versa), so releasing one app never rebuilds the other. Release notes are matched with the same prefix (`git describe --match`). Desktop release notes automatically append a tag-specific link to `docs/guides/GETTING-STARTED.md`.
- Desktop Linux builds are pinned to `ubuntu-24.04` (the 22.04 runner retires 2027-04-17 and `ubuntu-latest` moves to 26.04); the Windows ZIP bundles the Visual C++ runtime DLLs (`msvcp140`, `vcruntime140`, `vcruntime140_1`).
- Path-based CI (build + test on `main`/PRs, **no release**): `.github/workflows/ci-launcher.yml` (`apps/marcer_console/**`), `.github/workflows/ci-desktop.yml` (`apps/marcer_desktop/**`) — GitHub does not evaluate `paths` for tag pushes, so path filtering is only used for CI, never for releases.
- Developer steps for a release:
   1. Ensure `README.md` and `AGENTS.md` are up to date.
   2. Commit all changes.
   3. Create and push a tag: `git tag v{version} && git push origin v{version}` (or `git tag desktop-v{version} && git push origin desktop-v{version}`).
   4. The matching GitHub Action handles the rest (build, ZIP, release notes, GitHub Release).
- The `/create-release` command supports both apps: `/create-release 1.0.0` (launcher) and `/create-release desktop 0.1.0` (desktop).
- Local release artifacts in `release/` are optional and no longer required for the release process.

# Requirements for the Marcer GameDVD Launcher (AGENTS.md)

## Basic Function / Purpose
The console launcher is meant for browsing a games directory and can launch ZIP files with the Hatari emulator. It runs on Windows, Linux, and macOS. Control is exclusively via keyboard in the console window.

## Detailed Requirements

### Navigation and Display Principles
- Start directory (root):
  The configured RootDirectory from launcher.config.json
  It must NEVER be possible to navigate outside this directory.
- Only display subfolders and ZIP files; ignore other file types and hidden files.
- Navigation and control exclusively with these keys:
  - Arrow down/up: scroll by single entries
  - Enter / RightArrow: open folder or launch ZIP with Hatari
  - Backspace / LeftArrow: jump to parent directory (never outside root)
  - ESC: exit the program
  - PageUp/PageDown: jump by one page up/down through the file list
  - `?`: show a help box with key bindings
- The file list always shows exactly as many lines as fit the screen – ALWAYS **one line less** than the console height (`Console.WindowHeight - 1`). This avoids overflow at the bottom and ensures the selection never enters the non-visible area.
  Rationale: writing to the very last console line can cause the Windows console to auto-scroll or produce visual jumps when the cursor reaches the bottom row. Reserving one line prevents unintended scrolling/flicker and keeps the selection cursor strictly within the visible area.
   Maintenance: when changing rendering or navigation logic, always compute the displayed page size as `availableLines = ProgramHelpers.AvailableLines` (which resolves to `Console.WindowHeight - 1`) and keep this value consistent across MenuRenderer, NavigationController and any other code that references the console height.
- There is no information line/path display.
- Cursor and scroll logic:
  - The selection cursor must always remain in the visible area.
  - If the list is longer than the visible window, scrolling is necessary (cursor moves to bottom/top third as you move through).
- The program may be started in the root directory; all subfolders/ZIPs should be accessible from there.

### Launching a Game
- If Enter is pressed on a ZIP, Hatari is called with the configured executable, config file, and the full path to the ZIP file as arguments.
- `Hatari.ConfigFile` is optional. When empty, the bundled `MarcerGameDvd-Hatari.cfg` (shipped with the launcher) is used automatically. The bundled config never starts in fullscreen (`bFullScreen = FALSE`) and uses the SDL renderer with desktop resolution (`bUseSdlRenderer`, `bKeepResolution = TRUE`) so the `F11` fullscreen toggle centers the image and preserves its aspect ratio with black letterbox bars instead of stretching it or drawing it in the top-left corner.

### Error Handling & Edge Cases
- Paths with special characters or spaces must work robustly.
- It must NEVER be possible for navigation logic to leave the configured root folder.
- Empty directories must be displayed correctly (or reported correctly).
- In the root directory, Backspace must have no effect (no error, do not leave the program).
- Navigation (Backspace, Enter, etc.) must remain robust even for very deep or large directory trees.
  - Hatari.Executable is validated during startup: the path is resolved (relative to the EXE directory when applicable) and must point to an existing file. If validation fails the program must present a clear error and exit.

### Miscellaneous
- Build and start scripts live next to the console code: `apps/marcer_console/build.cmd` / `build.sh` / `start.cmd` / `start.sh` and must be used.
 - **Scope: these scripts and this build requirement apply ONLY to changes under `apps/marcer_console/`.** Changes to other apps (`apps/marcer_desktop/`) or to `tools/` do **not** require running the console build — use their own build/run paths (`apps/marcer_desktop/run.sh`, `tools/*/run.sh`).
 - **For ALL console builds and releases, ONLY the platform build script may be used:** `apps/marcer_console/build.cmd` (Windows) or `apps/marcer_console/build.sh` (Linux/macOS). Direct `dotnet build`/`dotnet run` calls are NOT allowed, as they can lead to version/runtime conflicts. The console application must always be started and tested using `apps/marcer_console/start.cmd` (Windows) or `apps/marcer_console/start.sh` (Linux/macOS).
 - **After making any code changes that affect behavior or touch source files under `apps/marcer_console/`, run the platform build script** (`apps/marcer_console/build.cmd` on Windows, `apps/marcer_console/build.sh` on Linux/macOS) and ensure the build completes successfully before committing. Additionally, perform a manual functional test on a Windows, Linux, or macOS machine prior to pushing a release.
- The console window can have any number of lines; display/navigation must adapt dynamically.
- For every release, a Release Notes file must be maintained that summarizes all changes, bugfixes, and new features in that version; Release Notes must be provided with the release asset.
- README.md must be written in English. Any functional change that affects usage, configuration, or behavior MUST update README.md in English immediately after the change. If there are consequential changes to developer-facing policies, build steps, or requirements, AGENTS.md must be updated as well.
- **IMPORTANT:** With any functional change to the launcher, BOTH this file (AGENTS.md) AND the README.md must always be updated and kept current. Immediately after, a successful build must be executed. This is mandatory for all development on the project.

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

### Color Scheme and Layer Labels
Each entry is displayed with a left label indicating its layer status:
- **`[BOTH]`**: Entry exists in both main and patch layer
- **`[ROOT]`**: Entry exists only in main (root) layer
- **`[PTCH]`**: Entry exists only in patch layer

Color mapping (now configurable via the `Colors` section in `launcher.config.json`; defaults shown below):
- Folder in both layers: **Yellow** (`[BOTH]`) → `FolderBoth`
- Folder only in patch layer: **DarkYellow** (`[PTCH]`) → `FolderPatchOnly`
- Folder only in main layer: **Gray** (`[ROOT]`) → `FolderRootOnly`
- ZIP in both layers: **Green** (`[BOTH]`) → `ZipBoth`
- ZIP only in main layer: **DarkGreen** (`[ROOT]`) → `ZipRootOnly`
- ZIP only in patch layer: **Magenta** (`[PTCH]`) → `ZipPatchOnly`
- Selected entry foreground: **Black** → `SelectedForeground`
- Selected entry background: **DarkCyan** → `SelectedBackground`
- Virtual entry (Favorites pseudo-folder): **White** → `VirtualEntry`

Note: Color values are resolved in `MenuRenderer` from the injected `AppColorConfig` (populated in `LauncherApp.LoadConfiguration` via `Enum.TryParse<ConsoleColor>` with default fallback). Invalid or missing values fall back to the defaults above. If you change default color values in `AppColorConfig`, update this section and the README color tables to keep documentation and implementation in sync.

### Navigation
- Navigation is always based strictly on the **relative path from root** and is consistent on all levels (Backspace always moves up one level, Enter always moves one level deeper, regardless of which layer).

---

## License

MIT License - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
- Full text in `LICENSE`
- License headers in all source code files
