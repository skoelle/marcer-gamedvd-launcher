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

### 3.3 Gatekeeper / notarization (open)
The release build is **ad-hoc signed and not notarized** (`CODE_SIGN_IDENTITY =
"-"` in `Runner.xcodeproj`, no notary step in `desktop-release.yml`). Users who
download the ZIP must clear the quarantine (right-click → Open, or
`xattr -dr com.apple.quarantine <app>`); this is documented in the README.
Notarization (Apple Developer ID + `notarytool` in CI + secrets) is a deferred
follow-up.

### 3.4 Self-update and external launch work
Disabling the sandbox also unblocks the in-process `swapInstall` of the `.app`
bundle (`self_updater.dart`) and launching Hatari installed next to the app.

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
