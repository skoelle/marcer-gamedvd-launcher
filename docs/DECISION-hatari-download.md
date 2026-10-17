# DECISION: Hatari Download & Install (Desktop App)

Records how the Flutter desktop app obtains Hatari when it is not already
installed, the sources used and their limits, and the deferred follow-up stages.
Follows the style of `DECISION-catalog-data-source.md`. Decision date: 2026-10-17.

**Related documents:**
- [`apps/marcer_desktop/README.md`](../apps/marcer_desktop/README.md) — user-facing "Hatari (download & install)" section
- [`apps/marcer_desktop/lib/hatari_installer.dart`](../apps/marcer_desktop/lib/hatari_installer.dart) — the downloader
- [`apps/marcer_desktop/lib/widgets/hatari_install_dialog.dart`](../apps/marcer_desktop/lib/widgets/hatari_install_dialog.dart) — the dialog
- [`SPEC.md`](SPEC.md) §12.1 — launch construction (desktop extensions)

---

## 1. Problem / Starting Point

Launching requires `Hatari.Executable` to point at an existing emulator binary.
Until now the desktop app only ever *reported* a missing executable (launch
error); the user had to install Hatari themselves. The TOS ROM download
(`lib/tos_rom.dart`) already established a "fetch on demand, install next to the
app" pattern that this feature mirrors.

The obstacle is distribution: Hatari has **no official prebuilt binary for every
OS**.

- The GitHub mirror (`github.com/hatari/hatari`) has **no releases**.
- The official SourceForge project publishes, per release, only:
  - `hatari-<v>_windows64.zip` (Windows x64),
  - `hatari-<v>_macos.zip` (macOS universal, x86-64 + arm64),
  - `hatari-<v>.tar.bz2` (source).
- **No Linux binary** — Linux users rely on distro packages (deb/rpm) or compile.

## 2. Decision

**Stufe 1 (implemented): prebuilt Windows + macOS binaries from the official
SourceForge release, installed on demand into `<appDir>/hatari`; Linux falls back
to a manual/system install.**

- Pinned release: `kHatariVersion = '2.6.1'` (`lib/hatari_installer.dart`).
- `hatariBuildFor()` maps `Platform.operatingSystem` → a `HatariBuild{os, label,
  url, sha256?}`; it returns `null` for Linux.
- Download honours the SourceForge mirror redirects (`dart:io` `HttpClient`);
  unpack via `archive`; the executable is located inside the archive
  (`hatari.exe` / macOS `*.app/Contents/MacOS/*` / plain `hatari`), `chmod +x`,
  and on macOS the download quarantine is stripped (`xattr -dr
  com.apple.quarantine`).
- The resulting path is stored **relative to the app directory** in
  `Hatari.Executable` (via `DesktopConfig.copyWith` + `save`), so the portable
  folder keeps working after being moved (`DesktopConfig.resolveHatariExecutable`).
- Two entry points:
  1. the chained pre-launch guard `HomePage._beforeLaunch` → `_ensureHatari` (then
     `_ensureTos`), and
  2. the shared settings form's **Hatari installation** status row.
- After a successful pre-launch install the live controller is updated in place
  (`CatalogController.replaceConfig`) — no catalog reload.

## 3. Consequences

### 3.1 Linux is not covered
`hatariBuildFor()` returns `null`; the row/dialog point to a manual install and
the normal launch error (SPEC E3) applies until `Hatari.Executable` is set.

### 3.2 SourceForge has no checksum
SourceForge publishes no SHA-256, so `HatariBuild.sha256` stays `null` and the
verification is skipped. The hook exists for a future self-hosted mirror.

### 3.3 macOS bundle location
Hatari is installed into `config.appDir`, which on macOS is the executable
directory **inside** `MarcerGameDVDLauncher.app/Contents/MacOS` — consistent
with where `TOS.IMG` is already written. The unsigned bundle makes this workable;
a future signed/notarized bundle would need the install to move next to the
`.app` instead.

### 3.4 Not part of the release ZIP / self-update
`<appDir>/hatari` is not shipped in the release archive, so the self-update swap
(`swapInstall`) never touches an installed Hatari.

## 4. Deferred / Follow-up Ideas

1. **Stufe 2 — self-hosted mirror (idea).** Publish a small `hatari-latest.json`
   pointer (per OS/arch, with `sha256`) plus mirrored assets on an own GitHub
   prerelease (like the `catalog-latest` catalog pointer), including a
   **Linux** build (AppImage with bundled SDL2, or a static build in CI). This
   gives stable URLs, checksums and full Linux coverage.
2. **Prefer a system Hatari (idea).** Detect an existing system install
   (e.g. `/usr/bin/hatari`, Homebrew) and offer it before downloading.
3. **Architecture-aware assets (idea).** `platformAssetTag`/`hatariBuildFor`
   currently key on the OS only; add CPU-architecture detection (Intel vs. Apple
   Silicon) if a platform gains separate builds.

## 5. Conformance Notes

- Nothing is bundled; Hatari is free software (GPL-2.0) and is downloaded on
  demand, with the source page shown in the dialog.
- A behavioral change to the download sources or install location must update
  this document, `apps/marcer_desktop/README.md`, `AGENTS.md` and (if the
  optional desktop behavior changes) `SPEC.md` §12.1.

---

## License

Licensed under the [MIT License](../LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
