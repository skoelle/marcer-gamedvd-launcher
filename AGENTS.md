---
applyTo: '**'
---

## Module Overview (Marcer GameDVD Launcher)

The implementation is split into focused modules (files) under the `apps/marcer_console/` folder (the console launcher is now a legacy/secondary app; the primary application is the Flutter desktop app under `apps/marcer_desktop/`). Keep this section up to date when files are added, removed or responsibilities change.

- apps/marcer_console/Program.cs: Minimal entry point. Sets the console title (via `DefaultTitle` constant) and starts the application by creating `LauncherApp`.
- apps/marcer_console/LauncherApp.cs: Application lifecycle host — loads configuration, initializes components and runs the main directory navigation loop (contains `AppHost` internal class). Key-handling logic is delegated to `InputController`.
- apps/marcer_console/AppConfiguration.cs: POCO configuration classes (`AppConfig`, `AppHatariConfig`, `AppColorConfig`) used to deserialize `launcher.config.json`; color values resolved via `Enum.TryParse<ConsoleColor>` with default fallback.
- apps/marcer_console/ProgramHelpers.cs: Small shared helpers (resolve relative paths, centralized console message helper, input buffer flushing) used across modules.
- apps/marcer_console/OverlayDirectoryBrowser.cs: Filesystem overlay and browsing logic — merges root and patch directories, enumerates folders and ZIPs, protects against path traversal and ensures navigation cannot leave the configured roots.
- apps/marcer_console/NavigationController.cs: Encapsulates selection, scrolling and relative-path navigation logic (cursor, page up/down, per-directory remembered selection/state); uses named scroll-fraction constants.
- apps/marcer_console/MenuRenderer.cs: Console rendering logic — efficient per-line redraw, double-buffering, configurable color selection via injected `AppColorConfig`, and the help box overlay.
- apps/marcer_console/InputController.cs: Handles key events (arrow keys, Enter, Backspace, PageUp/Down, `*`, `?`, ESC, RightArrow) and the associated navigation/drawing logic; owns `ReloadGameEntries` and the virtual `Favorites` folder integration.
- apps/marcer_console/HatariLauncher.cs: Responsible for validating the Hatari executable and starting Hatari with the configured argument template (replaces `{cfg}` and `{zip}`). Exposes `DefaultConfigFile` constant (`MarcerGameDvd-Hatari.cfg`).
- apps/marcer_console/FavoritesService.cs: Manages the favorites/bookmark system — toggling favorites on ZIPs, persisting them to `favorites.txt` (via `DefaultFileName` constant), and providing the virtual `Favorites` folder view (via `FavoritesRootName` constant).
- apps/marcer_console/UIErrorService.cs: Centralized UI error presentation using the console message helper.

Tooling (Python, not part of the launcher build; paths via git-ignored `local/paths.env`, run via each tool's `run.sh` with the repo `.venv`):
- tools/gameinfo-gen/: Extracts game metadata from the GameDVD XLS workbooks into JSON under `MARCER_DATA_DIR` (see `docs/ANALYSIS-game-data.md`).
- tools/gallery/: Interactive gallery webapp over the screenshot archive joined with game metadata (see `docs/SPEC-gallery-webapp.md`); replaces the former static `shotgen html` gallery. Display rules are at parity with the desktop app (preview/thumb preference `done` + `kind: game` with the single game-shot card, per-section screenshot indices — cracked `index.json` plus `index-pd.json`/`index-utils.json`; pd/utils cards are the union of their index groups and gameinfo-only folders, with a status filter defaulting to `any` — `pending` filter/status segment over any ZIP, section-aware `done <games> (<zips> zips)` statistics with right-aligned version, combined sort+order dropdown, `?` help overlay, screenshot-first filmstrip with header badges and clickable crew/cracker groups, tab labels `games`/`pd`/`utils`, **no hover info on touch/mobile** — the hover info panel and sticky `:hover` highlights only activate on hover-capable pointers (`(hover: hover) and (pointer: fine)` / `@media (hover: hover)`).
- tools/asset-manifest/: Lists the newest `screenshots-*.zip` / `gameinfo-*.zip` on the Marcer FTP (read-only: connect + list, never uploads) and publishes a small `latest.json` pointer as a **GitHub release asset** on a fixed tag (`catalog-latest`, a prerelease so it never takes the "Latest" slot and never triggers a build), via `gh release upload --clobber` so it can be replaced anytime independently of `desktop-v*` releases; credentials + tag/repo come from the git-ignored `local/paths.env` (`MARCER_FTP_*`, `MARCER_RELEASE_TAG`, optional `MARCER_REPO`). Output schema: `schema`, `generated_at`, `remote`, `screenshots`/`gameinfo` `{archive,size[,sha256]}` (see `tools/asset-manifest/README.md`).
- tools/screenshot-gen/: Generates preview screenshots via Hatari on a virtual display and classifies them (entry `kind`: `game`, `desktop`, `textscreen`, `darkscreen`, `no_game_image`; offline `reclassify` pass; drive-LED resets re-captured via `run --retry-drive-led`; entries ending as `no_usable_shots` keep the earlier captures as `_cNN` candidates — gated on `keep_candidates` — and use the last capture as preview). Works in named **scopes**: one scope per invocation (`--scope`, default `scope_default` = cracked), each with its own tree list and index file — default scope → `index.json` (read by gallery/desktop), other scopes → `index-<name>.json` (e.g. opt-in `utils` scope `Title Sorted/Utilitys - Title Sorted` → `index-utils.json`, opt-in `pd` scope `Title Sorted/PD Games - Title Sorted` → `index-pd.json`); no "all scopes" mode (see `docs/SPEC-screenshot-generator.md` §4.4). Folders ending with `mono_dir_suffix` (default `Mono`, matched against the ZIP's parent directory) are booted with `--mono --tos-res high` and recorded as `monitor: mono` (§4.6).

Docs: `docs/` holds the specs, analysis and decision records (`SPEC.md`, `ANALYSIS-game-data.md`, `ANALYSIS-boxscan-manual-structure.md`, `DECISION-app-architecture.md`, `SPEC-gallery-webapp.md`, `SPEC-screenshot-generator.md`, `BUGS.md`; indexed by `docs/README.md`) plus `docs/images/` (screenshots linked from the README). `README.md` and `AGENTS.md` stay at the repo root.

Apps (Flutter desktop, not part of the C# launcher build; plan in `apps/marcer_desktop/PLAN.md`, decision in `docs/DECISION-app-architecture.md`):
- apps/marcer_desktop/: Flutter desktop app (Surface A inventory browser, later Surface B couch mode). Executable/app bundle `MarcerGameDVDLauncher` (Dart package name stays `marcer_desktop`); app icon generated from the gallery favicon via `tool/generate_icons.py`. Config via git-ignored `desktop.config.json`, searched in CWD → executable dir → (macOS) `.app` parent; window starts **maximized** via `window_manager` (`Window.maximized`, default true; `false` uses `Window.width/height`, centered); release ZIPs ship `desktop.config.example.json` and the bundled `MarcerGameDvd-Hatari.cfg`. An in-app **settings editor** (⚙ gear left of the Folders button, `lib/widgets/settings_dialog.dart`) edits all path fields (`RootDirectory`, `PatchDirectory`, `ScreenshotDirectory`, `GameinfoDirectory`, `Hatari.Executable`, `Hatari.ConfigFile`) with native file/dir pickers (`file_picker`) plus the free-text FTP fields (`Ftp.Host`, `Ftp.User`, `Ftp.Password`, `Ftp.RemoteBase`, `Ftp.AssetsRemote`), writes them back to the same `desktop.config.json` (`DesktopConfig.save`/`copyWith`) and reloads the catalog in place (`HomePage._applyConfig`). Both the editor and the **first-run setup page** (`lib/widgets/setup_page.dart`, shown when no config is found — it lists the searched `desktop.config.json` locations and the save target; an unreadable config gets an error page with a `Setup…` button) share `lib/widgets/settings_form.dart`, which validates every path live (green ✓ / red ✗ per field, no icon for empty optionals) and gates **Save** until all fields are valid (`RootDirectory` is the only required one; a filled-but-invalid optional also blocks). A new config is written to the first writable candidate of `configSaveDirs` (exe dir / macOS `.app` parent, CWD fallback) via `writeFirstWritable`. Run via `apps/marcer_desktop/run.sh` (needs Flutter SDK in `~/flutter` and the Linux desktop toolchain). Default view is the gallery-style catalog grid with a gallery-style detail sidebar; optional overlay folder browser (`T`). The catalog is index/gameinfo-only (no filesystem scan): ZIPs present locally but absent from the artifacts show only in the overlay browser (`T`), and the `ROOT`/`PATCH`/`BOTH` badges are resolved from the local filesystem, not the published index layer (see `docs/DECISION-catalog-data-source.md`). Loading is robust: a malformed/truncated `games-*.json` is skipped with a warning (never aborts the load), `CatalogController.init` catches failures and shows an error/Retry+Settings screen instead of an endless spinner, and when a section has no cards because the artifacts are missing a banner (`CatalogController.catalogDataNotice` → `main.dart`) points to the settings "Download from FTP" and the status filter `any`. Gallery-style global filters (facet dropdowns with type-to-filter) + card universe (`GameCard`/`CatalogFilter` in the catalog package), fuzzy crew/cracker focus (crew/cracker groups in the detail sidebar and lightbox info panel are clickable → open that group's ZIP), lightbox (integer scaling, filmstrip, variant table), favorites (`*` toggles the selected card's/ZIP's favorite in both views — for a card its single starred variant, else the launch ZIP; `FAVORITE` badges, per-thumb ★/☆ stars in the lightbox filmstrip, `★ Favorites` catalog filter listing favorites of **all** sections with facets/status ignored, any-ZIP cards count as favorite, lazy pd/utils ZIP resolution; stored **per section tree** in `favorites.txt` under `<Patch>/<tree>/` — console layout — plus legacy `favorites.txt` and foreign-line pass-through, see root README), and **Hatari launch** (`P` / `Space` / Play button, `{cfg}`/`{zip}` substitution, bundled-cfg fallback, non-blocking). **Self-update** in release builds only (silent startup check against the GitHub `desktop-v*` releases; amber `⬆ <version>` badge left of the Folders button → download platform ZIP, swap-install with `*.old` backup, automatic relaunch; version from `--build-name` via `package_info_plus`; dev builds never check; the status bar shows the running app version right-aligned). **Windows is two-phase** (in-process rename is blocked by the mapped `data\app.so`/`flutter_windows.dll`): a hidden PowerShell helper waits for the app to exit, then swaps/relaunches; it is started via a **one-shot Task Scheduler task** (`schtasks` `/SC ONCE /IT`, encoded-command wrapper; the app sits in a job object with kill-on-close, so a plain child would die with it — direct detached spawn is only the fallback), and both the app (`UpdateLog`, incl. the exact command line, `currentProcessInJob()` via FFI and a 700 ms stdout/stderr drain) and the helper log to `MarcerUpdater.log` next to the app; the log path is shown in the failure dialog. **Manual screenshot curation** (lightbox `M` = swap shown candidate ↔ main image on disk, refreshing grid/detail/filmstrip/candidate strips immediately via per-path `imageVersionOf` + `ValueKey` image keys **plus** an `imageCache.clear()` + `clearLiveImages()` flush — `clear()` alone keeps `_liveImages`, which `putIfAbsent` consults, and would hand the old completer back during the rebuild — `CatalogController.swapPreviewImage`; `C` in lightbox/detail = edit status/kind in memory, pending until the filter bar's **Save (n)** button writes the section's index file (`index.json`/`index-pd.json`/`index-utils.json`) + mirror meta atomically under the `shotgen.lock` PID lock — `lib/index_editor.dart`; status filter gains strict `desktop text`/`desktop black`, "This ZIP" shows the Kind row; the `pending` status filter is app-specific — a card matches when **any** of its ZIPs is pending; each section loads its own screenshot index (cracked `index.json`, pd `index-pd.json`, utils `index-utils.json`) — pd/utils cards are the **union** of their index groups (status/screenshots/variants) and gameinfo-only folders, their status filter defaults to `any` (cracked keeps `DefaultStatus`) and the status dropdown is available in all sections; the status bar is section-aware (app-only divergence from the gallery footer) and shows each status as **games (ZIPs)** — e.g. `done 2635 (8979 zips)` — plus `N folders` and `M with screenshot` segments (games), so the games number always equals the matching dropdown result count (`pending` uses the any-variant rule, so it can overlap e.g. with `done`); section trees are discovered with canonical-name preference so decoy trees like `Bonus/Cracked Demos` never win; the card's main preview prefers a `done` variant of kind `game` over e.g. `textscreen` and the 2×2 thumb grid orders its tiles the same way within a status tier (`GameCard.thumbIndices`) — app-only divergence from gallery §4.4 first-by-rel / status-only thumbs). **Missing ZIPs & local layer**: because the catalog is index/gameinfo-only (no FS scan), the app resolves both existence and layer on demand from the local filesystem (`CatalogController.zipLayer` → `ROOT`/`PATCH`/`BOTH`/absent, cached; `variantLayer`/`cardLayer` aggregate per variant/card; `zipExists`/`variantMissing`/`cardMissing` reuse it, patch or root) — so the card/variant layer badge and the "This ZIP" Layer row show **where the ZIP actually lives** (a ZIP published as `PATCH` but moved to `ROOT` shows `ROOT`; `BOTH` when variants split across layers; no badge when absent), not the published index layer. Absent files get a `MISSING` card badge (grid tile/detail panel/lightbox header) when **no** variant exists locally, and a per-variant `MISSING` (red filmstrip tag + "This ZIP" `Missing` row) when just that ZIP is absent; launch prefers the patch copy whenever it exists (SPEC R14), else root. Reloads build a fresh controller so the caches refresh. **Download missing (FTP)**: a `MISSING` card gets a **Download folder** button in the detail sidebar (`detail_panel.dart`, next to the `MISSING` badge) that recursively downloads the card's whole folder (all ZIP variants + subdirs) from the Marcer FTP server into the patch layer (or `RootDirectory` when `PatchDirectory` is empty) and then drops the cached layer state of that folder (`CatalogController._refreshAfterDownload` → badges clear in place, no full reload). Plain FTP on port 21 by default (`host:port` overrides it; `ftpconnect`; `lib/ftp_downloader.dart`, a `Downloader` interface with `FtpDownloader` impl, two passes: discovery for progress + transfer skipping existing local files, cancellable). Config `Ftp.Host`/`Ftp.User`/`Ftp.Password`/`Ftp.RemoteBase` (default `/GameDVD/`; `DesktopConfig.ftpConfigured`/`downloadTargetDirectory`) edited in the shared settings form (free-text fields, never block Save). **Catalog-data download (FTP)**: the shared form is ordered RootDirectory → PatchDirectory → FTP → ScreenshotDirectory/GameinfoDirectory → Hatari; the two catalog-data fields carry a **Download from FTP** button (next to Browse…) that fetches the newest `screenshots-*.zip`/`gameinfo-*.zip` from `Ftp.AssetsRemote` (default `/Uploads/MarcerGameDVDLauncher-assets/`; uploads never overwrite so the newest is picked by the `yyyyMMdd-HHmmss` name timestamp) and extracts it with the `archive` package into the target directory (created when missing; `Ftp.Host` + target required, inline progress + Cancel; both downloaders force binary FTP transfer after connect (`TransferType.binary`; `connect()` resets to ASCII and RETR in ASCII corrupts the ZIPs), a post-download size check (`downloadSizeError` vs the FTP `size`) rejects truncated transfers, the download reports live byte progress (`ftpconnect` `FileProgress`), and the ZIP extraction runs in a background isolate (`extractZipWithProgress`, `dart:isolate` + streamed one file at a time, throttled file-counter progress `done/total files` + pollable cancel, an `onExit` safety net so a crashed extractor fails instead of hanging) so the UI never blocks on thousands of PNGs; while a download/extraction runs the form reports busy (`SettingsForm.onBusyChanged`) so the settings dialog / setup page disable Save, Cancel and Exit and block dismissal (the running transfer must not be interrupted); `lib/catalog_assets.dart`, `CatalogAssetDownloader`/`FtpCatalogAssets`, top-level `newestAssetArchiveName`); after a successful download the applied archive is recorded in `<targetDir>/.marcer-assets.json` (`writeAppliedAssetVersion`/`readAppliedAssetVersion`/`assetDataPresent`/`isAssetUpToDate`) and a further click reports "already up to date" with a "Download anyway" option (`force`); `GameinfoDirectory` has no implicit fallback (the former `<Patch>/../Data` convention was removed). **TOS ROM download**: when `TOS.IMG` (expected by the bundled cfg in the Hatari working dir = executable dir) is missing, a pre-launch guard (`CatalogController.beforeLaunch` → `HomePage._ensureTos`) opens a dialog (`lib/widgets/tos_rom_dialog.dart`) offering TOS 1.02/1.04 `English (UK)`/`Deutsch` (language first, EN-UK before Deutsch, newer first; default `English (UK) — TOS 1.04`) fetched on demand (no bundling; Atari-copyrighted, non-commercial) from `atariworld.org/tos-rom` and extracted to `appDir/TOS.IMG` (`lib/tos_rom.dart`, `TosRomDownloader`/`HttpTosRomDownloader`, pure Dart `dart:io` HttpClient + `archive`); the shared settings form also has a `TOS ROM` row in the Hatari section (status + download, `tosDownloader` injectable). State `downloading`/`downloadingCard`/`downloadProgress`/`downloadError` (`downloadMissing`/`cancelDownload`, error modal + status-bar progress in `main.dart`); an unconfigured host shows a hint instead of downloading. **Not** built via the console build script (`apps/marcer_console/build.*`).
- apps/marcer_desktop/packages/marcer_catalog/: Pure Dart data layer (overlay merge per SPEC §7, gameinfo join, screenshot index, gallery `GameCard` universe + facets + filter/sort engine, config). Read-only consumers; unit tests via `dart test`.

Note: This overview is intentionally concise. For behavioral changes (navigation, color scheme, launch command or config schema), update this file (AGENTS.md) and README.md as required by project policy.

**Specification:** [`docs/SPEC.md`](docs/SPEC.md) is the technology-neutral behavioral specification of the launcher (used as the basis for reimplementation in other languages or as a desktop app). Behavioral changes must be reflected in `docs/SPEC.md` as well — keep sections 1–17 and the Conformance Checklist in sync with the implementation.
**Note for Automated Tests/CI:**
The console launcher cannot be executed or tested via `apps/marcer_console/start.cmd` from this environment (build system, automation agent) since no Windows console environment is present. For release workflows and developer validation, it is ALWAYS required to do a manual test run via `apps/marcer_console/start.cmd` (Windows) or `apps/marcer_console/start.sh` (Linux/macOS) per documentation and policy before delivery.

**Release Process (automated via GitHub Actions):**
- Monorepo with **one tag scheme per app**, so each app is released independently:
  - Console launcher (`apps/marcer_console/`): tag `v*` → `.github/workflows/release.yml` → `MarcerGameDvdConsole-v…-{win,linux,osx}-x64.zip` (GitHub Release title: `Marcer Console vX.Y.Z`).
  - Flutter desktop (`apps/marcer_desktop/`): tag `desktop-v*` → `.github/workflows/desktop-release.yml` → `MarcerDesktop-v…-{win,linux,osx}-x64.zip`.
- Each workflow triggers only on its own tag prefix (`v*` never matches `desktop-v*` and vice versa), so releasing one app never rebuilds the other. Release notes are matched with the same prefix (`git describe --match`).
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
- `Hatari.ConfigFile` is optional. When empty, the bundled `MarcerGameDvd-Hatari.cfg` (shipped with the launcher) is used automatically.

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
