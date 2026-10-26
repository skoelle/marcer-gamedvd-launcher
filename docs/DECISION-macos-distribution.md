# DECISION: macOS Distribution & Sandbox (Desktop App)

Records why the Flutter desktop app runs **without** the macOS App Sandbox, what
entitlements it uses, and the known limits (TCC-protected folders, Gatekeeper /
notarization). Follows the style of `DECISION-catalog-data-source.md`. Decision
date: 2026-10-18.

**Related documents:**
- [`apps/marcer_desktop/README.md`](../apps/marcer_desktop/README.md) — user-facing macOS notes
- [`apps/marcer_desktop/macos/Runner/DebugProfile.entitlements`](../apps/marcer_desktop/macos/Runner/DebugProfile.entitlements) / [`Release.entitlements`](../apps/marcer_desktop/macos/Runner/Release.entitlements)
- [`apps/marcer_desktop/macos/Runner/Info.plist`](../apps/marcer_desktop/macos/Runner/Info.plist) — TCC usage descriptions
- [`.github/workflows/desktop-release.yml`](../.github/workflows/desktop-release.yml) — ad-hoc signed macOS build
- [`DECISION-hatari-download.md`](DECISION-hatari-download.md) — on-demand Hatari install

---

## 1. Problem / Starting Point

The first macOS test surfaced three failures at once:

1. the file/directory picker failed with
   `PlatformException(ENTITLEMENT_NOT_FOUND) either read-only or read-write
   entitlement is required`,
2. FTP connect and the TOS ROM download failed (DNS/network unreachable),
3. a directory typed by hand raised `OS Error: Operation not permitted,
   errno = 1`.

All three came from the Flutter-default **App Sandbox** (`com.apple.security.app-sandbox
= true`) with incomplete entitlements: no `files.user-selected.read-write`
(`file_picker` aborts in `FilePickerPlugin.checkEntitlement`), no
`network.client`, and no way at all to reach a hand-typed absolute path outside
the app container.

The app is a **portable launcher** shipped as a GitHub release ZIP (never via the
App Store). By design it:

- reads game archives from arbitrary directories set in `desktop.config.json`,
- writes `favorites.txt` / `index.json` next to the data,
- launches an external emulator (Hatari) via `Process.start`,
- downloads Hatari/TOS/catalog assets and self-updates its own `.app` bundle.

None of that is compatible with the App Sandbox, which only allows the app
container plus security-scoped bookmarks from the native open panel.

## 2. Decision

**The macOS app is not sandboxed.** `com.apple.security.app-sandbox` is set to
`false` in both entitlement files.

- `DebugProfile.entitlements` / `Release.entitlements` add the Flutter/hardened
  runtime entitlements `com.apple.security.cs.allow-jit`,
  `com.apple.security.cs.allow-unsigned-executable-memory` and
  `com.apple.security.cs.disable-library-validation` (Debug also keeps
  `network.server` for the Flutter VM service; both list `network.client` for
  clarity, though it is moot when unsandboxed).
- `lib/main.dart` calls `FilePicker.skipEntitlementsChecks()` once on macOS
  before any picker use — the plugin's documented switch for the non-sandboxed
  case (`file_picker` 11.0.3); without it the picker still aborts with
  `ENTITLEMENT_NOT_FOUND`.
- `macos/Runner/Info.plist` carries TCC usage descriptions
  (`NSDownloadsFolderUsageDescription`, `NSDocumentsFolderUsageDescription`,
  `NSDesktopFolderUsageDescription`, `NSRemovableVolumesUsageDescription`,
  `NSNetworkVolumesUsageDescription`) so the system prompts for the protected
  folders are labelled.
- Downloaded artifacts (**Hatari**, the **TOS ROM**) are installed into
  `~/Library/Application Support/MarcerGameDVDLauncher` (`downloadedDataDir`,
  `lib/app_paths.dart`), **not** inside the `.app` bundle, and Hatari runs with
  that directory as its working directory
  (`DesktopConfig.hatariWorkingDirectory`). The same per-user directory is the
  **last** config search/save location (`config_locator.dart` `extraDir`), so the
  first-run setup can write `desktop.config.json` even when the `.app` is
  read-only and the next launch finds it. An App-Translocation check
  (`isAppTranslocated`) shows a non-blocking startup hint with the Finder-move
  instruction.

## 3. Consequences

### 3.1 TCC-protected folders still prompt
Without the sandbox, macOS still guards `~/Downloads`, `~/Documents`,
`~/Desktop` and external/network volumes via **TCC**. The first access raises a
system dialog (now with a proper description); until it is granted the access
fails with `EPERM`. Paths outside those folders (e.g. `~/Games`) work directly.
This is expected macOS behaviour, not an app bug.

### 3.2 Picker vs. hand-typed paths
Both work: the native picker returns a path, and a hand-typed path in the config
is reachable as long as TCC allows the location.

### 3.3 App Translocation
**Recommended portable layout:**

1. Extract the release ZIP anywhere (e.g. Downloads).
2. Create the target folder `~/MarcerGameDVDLauncher`.
3. **Move `MarcerGameDVDLauncher.app` individually in Finder into that folder —
   not the whole extracted folder, not `mv` in Terminal. Only the individual
   Finder move of the `.app` ends App Translocation; this step is essential.**
4. Move `desktop.config.example.json` and `MarcerGameDvd-Hatari.cfg` (and a
   portable `desktop.config.json`, if present) next to the app.
5. Start the app from there.

This is the tested distribution layout: the config/cfg stay next to the app and
self-update can replace the bundle in the writable folder.

A quarantined, not-notarized app that was not individually moved in Finder is
run by macOS from a randomized, read-only **App Translocation** path
(`/private/var/folders/…/AppTranslocation/…`). Writing inside the `.app` bundle
there is blocked or lands in a location that disappears, and the bundle path
changes on every launch. Because of that the app keeps downloaded artifacts **and
a fallback config** outside the bundle (§2) — so browsing, launching and
downloads work even while translocated. Two things still need a real move:

- **Self-update** cannot replace a read-only translocated bundle. The controller
  detects translocation (`isAppTranslocated`) and refuses both the check and the
  install with actionable guidance instead of attempting a copy into the
  read-only path. The update log falls back to the system temp dir and the
  dialog shows the path that actually received the log.
- **Favorites without a `PatchDirectory`** are written next to the executable
  (`favorites-<section>.txt`) and fail silently there.

Ending translocation requires moving the `.app` **individually in Finder** to a
different folder (`mv` in Terminal or moving the enclosing folder does **not**
count), or removing the quarantine. If the app already sits in the target folder
and is still translocated, move it individually out (e.g. to Downloads) and
individually back, or run
`xattr -dr com.apple.quarantine /path/to/MarcerGameDVDLauncher.app`. The app
shows a non-blocking snackbar hint on startup and uses the same instructions for
the refused self-update.

### 3.4 Gatekeeper / notarization (open)
The release build is **ad-hoc signed and not notarized** (`CODE_SIGN_IDENTITY =
"-"` in `Runner.xcodeproj`, no notary step in `desktop-release.yml`). Users who
download the ZIP must clear the quarantine (right-click → Open, or
`xattr -dr com.apple.quarantine <app>`); this is documented in the README.
Notarization (Apple Developer ID + `notarytool` in CI + secrets) is a deferred
follow-up.

### 3.5 Self-update and external launch work
Disabling the sandbox also unblocks the in-process `swapInstall` of the `.app`
bundle (`self_updater.dart`) and launching Hatari installed in the per-user data
directory.

### 3.6 Self-update must preserve framework symlinks
The macOS `.app` bundle is a versioned framework layout whose top-level entries
are **Unix symlinks** (`MarcerGameDVDLauncher.app/Contents/Frameworks/
App.framework/App` → `Versions/Current/App`, `Versions/Current` → `A`, and the
same for `FlutterMacOS.framework`). The release ZIP preserves them via
`ditto -c -k --sequesterRsrc`.

The self-update extractor must recreate these as real symlinks. An earlier
build extracted them as regular files, so after a self-update the Flutter engine
could not resolve the AOT snapshot (`assetsPath` was nil) and the app crashed in
`NSApplicationMain` before any Dart ran (`SIGABRT`, `+[NSArray
arrayWithObjects:count:]`) — the bundle was unstartable. The fix:

- `extractArchiveToDir` recreates symlink entries (`ArchiveFile.isSymbolicLink`
  + `nameOfLinkedFile`, which Dart `archive` populates from `ditto` zips) as
  `Link.create`, and `_copyDir`/`swapInstall`/`_deletePathBestEffort` also handle
  `Link` entries.
- After `swapInstall`, `verifyMacOsFrameworkLinks` asserts the framework links
  are still links; a failure triggers `rollbackInstall` from the `*.old`
  backups so a broken swap never replaces a working install.
- `resignMacOsBundle` re-signs the swapped `.app` ad-hoc
  (`codesign --force --deep --sign -`) because the copy invalidates the
  signature.

## 4. Deferred / Follow-up Ideas

1. **Notarization (idea).** Add Developer ID signing + `notarytool` to the macOS
   release job so users no longer hit Gatekeeper; requires an Apple certificate
   and CI secrets.
2. **Security-scoped bookmarks (idea).** If a sandboxed build is ever needed
   (e.g. Mac App Store), every configured path would have to come from the
   picker and be persisted as a bookmark — a substantial rework.

## 5. Conformance Notes

- Changing the macOS entitlements, the picker bootstrap or the TCC strings must
  update this document, `apps/marcer_desktop/README.md` and `AGENTS.md`.
- The app stays read-only towards the game data roots (same rule as the console
  launcher and `shotgen`), except for the explicit favorites/index/asset writes.

---

## License

Licensed under the [MIT License](../LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
