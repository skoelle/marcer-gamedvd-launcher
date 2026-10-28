# DECISION: macOS Distribution & Sandbox (Desktop App)

Why the desktop app runs **without** the macOS App Sandbox, what entitlements it
uses, and the known limits (TCC, Gatekeeper/notarization).
Decision date: 2026-10-18.

**Related documents:**
- [`SPEC-desktop.md`](../specs/SPEC-desktop.md) — macOS behavior
- [`DECISION-hatari-download.md`](DECISION-hatari-download.md) — on-demand installs
- [`apps/marcer_desktop/macos/Runner/`](../../apps/marcer_desktop/macos/Runner/) — entitlements/Info.plist

---

## 1. Problem / Starting Point

The first macOS test surfaced three failures: the file picker aborted with
`ENTITLEMENT_NOT_FOUND`, FTP/TOS downloads failed, and a hand-typed path raised
`Operation not permitted`. All came from the Flutter-default **App Sandbox**
with incomplete entitlements (no user-selected read-write, no network client,
no access to arbitrary typed paths).

The app is a **portable launcher** shipped as a GitHub release ZIP (never via the
App Store). It reads game archives from arbitrary configured directories,
writes favorites/index next to the data, launches Hatari via `Process.start`,
downloads assets and self-updates its bundle. None of that is compatible with
the App Sandbox.

## 2. Decision

**The macOS app is not sandboxed.** `com.apple.security.app-sandbox` is `false`
in both entitlement files.

- The entitlements add the hardened-runtime entitlements
  (`allow-jit`, `allow-unsigned-executable-memory`,
  `disable-library-validation`); Debug also keeps `network.server` for the VM
  service.
- `lib/main.dart` calls `FilePicker.skipEntitlementsChecks()` on macOS before
  any picker use — the documented switch for the non-sandboxed case.
- `Info.plist` carries TCC usage descriptions for Downloads/Documents/Desktop/
  removable/network volumes.
- Downloaded artifacts (Hatari, TOS ROM) are installed into
  `~/Library/Application Support/MarcerGameDVDLauncher`, **not** inside the
  `.app`; that directory is also Hatari's working directory and the last config
  search/save location. An App-Translocation check shows a startup hint.

## 3. Consequences

### 3.1 TCC-protected folders still prompt

Without the sandbox, macOS still guards `~/Downloads`, `~/Documents`,
`~/Desktop` and external/network volumes via TCC. The first access raises a
system dialog; until granted, access fails with `EPERM`. Paths outside those
folders work directly.

### 3.2 Picker vs. hand-typed paths

Both work: the native picker returns a path, and a hand-typed path is reachable
as long as TCC allows the location.

### 3.3 App Translocation

**Recommended portable layout:** extract the ZIP anywhere, create
`~/MarcerGameDVDLauncher`, **move `MarcerGameDVDLauncher.app` individually in
Finder** into it (not the whole folder, not `mv` in Terminal — only the
individual Finder move ends translocation), copy the cfg/example config next to
it, and start from there.

A quarantined app that was not moved individually runs from a randomized,
read-only App-Translocation path. Writing inside the bundle is blocked or
disappears, and the path changes on every launch. The app therefore keeps
downloaded artifacts and a fallback config outside the bundle, so browsing,
launching and downloads work. Two things still need a real move:

- **Self-update** cannot replace a read-only translocated bundle; the app
  detects translocation and refuses check/install with instructions.
- **Favorites without a `PatchDirectory`** are written next to the executable
  and fail silently there.

If the app still reports translocation, move the `.app` individually out and
back, or run `xattr -dr com.apple.quarantine <app>`.

### 3.4 Gatekeeper / notarization

The release build is **ad-hoc signed and not notarized** (`CODE_SIGN_IDENTITY =
"-"`, no notary step in CI). Users must clear the quarantine (right-click →
Open, or `xattr -dr com.apple.quarantine <app>`).

### 3.5 Self-update must preserve framework symlinks

The `.app` framework layout relies on **Unix symlinks** (`App` →
`Versions/Current/App`, `Versions/Current` → `A`, same for
`FlutterMacOS.framework`). The release ZIP preserves them via `ditto`. The
self-update extractor recreates them as real links (`Link.create`) and
`_copyDir`/`swapInstall`/`_deletePathBestEffort` handle `Link` entries.

After `swapInstall`, `verifyMacOsFrameworkLinks` asserts the links are still
links; a failure triggers `rollbackInstall` from the `*.old` backup. The
swapped `.app` is re-signed ad-hoc (`codesign --force --deep --sign -`).
