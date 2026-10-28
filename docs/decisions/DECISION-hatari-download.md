# DECISION: Hatari Download & Install (Desktop App)

How the desktop app obtains Hatari when it is not already installed, the
sources used and their limits. Decision date: 2026-10-17.

**Related documents:**
- [`SPEC-desktop.md`](../specs/SPEC-desktop.md) — Hatari launch/install behavior
- [`DECISION-macos-distribution.md`](DECISION-macos-distribution.md) — why installs live outside the `.app`
- [`apps/marcer_desktop/lib/hatari_installer.dart`](../../apps/marcer_desktop/lib/hatari_installer.dart) — downloader

---

## 1. Problem / Starting Point

Launching requires `Hatari.Executable` to point at an existing binary. The app
only *reported* a missing executable; the user had to install Hatari. The TOS
ROM download already established a "fetch on demand, install next to the app"
pattern.

Hatari has **no official prebuilt binary for every OS**:

- The GitHub mirror has **no releases**.
- SourceForge publishes only `hatari-<v>_windows64.zip`,
  `hatari-<v>_macos.zip` (universal) and the source tarball.
- **No Linux binary** — Linux users rely on distro packages or compile.

## 2. Decision

**Stage 1: prebuilt Windows + macOS binaries from the official SourceForge
release, installed on demand into `<appDir>/hatari`; Linux falls back to a
manual/system install.**

- Pinned release `kHatariVersion = '2.6.1'`; `hatariBuildFor()` returns `null`
  for Linux.
- Download honours SourceForge mirror redirects; unpack via `archive`; locate
  the executable (`hatari.exe` / macOS `*.app/Contents/MacOS/*` / plain
  `hatari`), `chmod +x`, and on macOS strip the download quarantine.
- Install target: `<appDir>/hatari` on Windows/Linux (portable) and
  `~/Library/Application Support/MarcerGameDVDLauncher/hatari` on macOS —
  **never inside the `.app` bundle** (read-only/unstable under App Translocation
  and replaced by self-updates).
- The path is stored in `Hatari.Executable` — relative to the app directory on
  the portable layout, absolute on macOS.
- Two entry points: the chained pre-launch guard (`_ensureHatari` before
  `_ensureTos`) and the settings form's **Hatari installation** row.
- After a pre-launch install the live controller is updated in place — no
  catalog reload.

## 3. Consequences

- **Linux is not covered:** the dialog points to a manual install and the normal
  launch error applies until `Hatari.Executable` is set.
- **No checksum:** SourceForge publishes no SHA-256, so verification is skipped;
  the hook exists for a future mirror.
- **macOS installs outside the bundle:** Hatari and the TOS ROM live in the
  per-user Application Support directory, which is also Hatari's working
  directory (where `TOS.IMG` lives).
- **Not part of the release ZIP / self-update:** the install directory is never
  touched by `swapInstall`.
