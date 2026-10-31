# Flutter Dependency Update Plan (marcer_desktop)

Status: **Stage 1 + 2 done** (2026-10-31) — working note for the staged upgrade
of the Flutter desktop app's dependencies. Stage 1 (lock refresh) and Stage 2
(`archive` 4, `cupertino_icons` removal) are applied; Stage 3 (plugin majors)
is pending.

Toolchain: **Flutter 3.47.7 stable** / **Dart 3.13.5** (`~/flutter`),
`environment: sdk: ^3.13.5`, `pubspec.lock` pins `flutter: ">=3.38.0"`.

## Why / goal

`./run.sh` (`flutter pub get`) reports:

> 5 dependencies are constrained to versions that are older than a resolvable version.

This is **informational, not an error** — the app works. The goal of this plan
is to reduce the debt *deliberately and in small, verified steps*, not to chase
every version:

- **Security first:** `archive` (`ZipDecoder`) and `win32` (FFI) are the
  risk-bearing packages; `archive` decodes a *downloaded* update ZIP
  (`lib/self_updater.dart`).
- Stay attachable to newer Flutter/Dart SDKs so the eventual migration is a
  series of small steps, not one big-bang.
- Unblock currently pinned transitive packages (e.g. `cross_file`,
  `screen_retriever`) once their parent packages move.

## Snapshot: `flutter pub outdated` (2026-10-31)

Columns: **Current** (installed) · **Upgradable** (reachable via
`flutter pub upgrade`, no `pubspec.yaml` change) · **Resolvable** (reachable
after editing `pubspec.yaml`) · **Latest** (newest published).

### Direct dependencies

| Package | Current | Upgradable | Resolvable | Latest |
|---|---|---|---|---|
| file_picker | 11.0.3 | 11.0.3 | 13.3.0 | 13.3.0 |
| package_info_plus | 9.0.1 | 9.0.1 | 10.2.2 | 10.2.2 |
| screen_retriever | 0.2.2 | 0.2.2 | 0.2.2 | 0.3.0 |

All other direct dependencies (including `archive` 4.5.2) are current.

### Transitive dependencies

| Package | Current | Upgradable | Resolvable | Latest |
|---|---|---|---|---|
| cross_file | 0.3.5+5 | 0.3.5+5 | 0.3.5+5 | 0.4.0 |
| dartssh2 | 3.3.1 | 3.3.1 | 3.3.1 | 4.1.0 |
| dbus | 0.7.15 | 0.7.15 | 0.8.0 | 0.8.0 |
| material_color_utilities | 0.13.0 | 0.13.0 | 0.13.0 | 0.13.1 |
| package_info_plus_platform_interface | 3.2.1 | 3.2.1 | 4.1.0 | 4.1.0 |
| win32 | 5.15.0 | 5.15.0 | 6.4.0 | 6.4.0 |
| test_api | 0.7.12 | 0.7.12 | 0.7.12 | 0.7.15 |

## Classification

### Done

- **Stage 1 — lock refresh:** `asn1lib` 1.6.8, `crypto` 3.0.8, `meta` 1.19.0,
  `petitparser` 7.1.0, `vector_math` 2.4.4, `vm_service` 15.4.0, `web` 1.1.2,
  `xml` 7.1.0. No code changes.
- **Stage 2 — `archive` 3→4.5.2** (+ `posix` 6.5.4 transitive): code migrated,
  see below.
- **`cupertino_icons` removed** (unused — no `CupertinoIcons` in the code).

### Remaining — Stage 3 (plugin majors, coupled)

`file_picker` 11→13.3 and `package_info_plus` 9→10.2 **must move together**:
`package_info_plus` 10 requires `win32 ^6`, while `file_picker` 11 pins
`win32 ^5.9.0`. `file_picker` 12+ is a federated rewrite and uses `win32` 6.
This unblocks `win32` 6.4, `package_info_plus_platform_interface` 4.1 and
`dbus` 0.8.

Migration surface: `lib/widgets/settings_form.dart` — `FilePicker.pickFiles()`
returns `List<PlatformFile>` in v12+, `allowMultiple` is gone in v13; switch the
single-file picker to `FilePicker.pickFile()` and read `file?.path`.
`FilePicker.getDirectoryPath()` and `skipEntitlementsChecks()` remain.

### Not resolvable at all (pinned by SDK/parent, regardless of our edits)

- `screen_retriever` 0.2.2 — `window_manager` 0.5.2 (latest) pins `^0.2.2`.
- `cross_file` 0.3.5+5 — pinned by `file_picker` 11 (re-check after Stage 3).
- `dartssh2` 3.3.1 — pinned by `ftpconnect`.
- `material_color_utilities` 0.13.0 — pinned by the Flutter SDK.
- `test_api` 0.7.12 — pinned by `flutter_test`.

## How the affected packages are used (risk surface)

| Package | Usage in the app | Risk if bumped |
|---|---|---|
| `archive` | ZIP decode/extract in `self_updater`, `tos_rom`, `hatari_installer`, `boot_media`, `piratefinder_zip`, `local_assets`, `catalog_assets`, `cosmos_ex` | **Security-relevant** (ZIP-slip / zip-bomb CVEs); 3→4 API changes (done) |
| `win32` | FFI in the Windows two-phase updater (`currentProcessInJob()`) | Platform-specific; 5→6 only resolved via Stage 3 |
| `file_picker` | `lib/widgets/settings_form.dart` — directory/file pickers | 11→13 spans two majors; federated rewrite, verify pickers on all OS |
| `package_info_plus` | `lib/main.dart` — app version for the self-update badge / status bar | 9→10; API stable, requires `win32` 6 |
| `screen_retriever`/`cross_file`/`dbus` | transitives (window_manager, file_picker) | none directly |

## Stage 2 details (applied)

`archive` 4 removed `ZipDecoder.decodeBuffer` (renamed to `decodeStream`), made
`ArchiveFile.content` non-nullable, dropped the `nameOfLinkedFile` getter
(use `symbolicLink`) and made `ZipEncoder.encode` non-nullable. Changes:

- `decodeBuffer` → `decodeStream`: `boot_media.dart`, `piratefinder_zip.dart`,
  `local_assets.dart` (2×), `catalog_assets.dart`.
- Removed redundant null/type checks on `ArchiveFile.content`: `boot_media.dart`,
  `cosmos_ex.dart`, `local_assets.dart`, `tos_rom.dart`.
- Symlink extraction uses `ArchiveFile.symbolicLink`: `self_updater.dart`.
- Invalid-archive guard restored in `hatari_installer.dart` (archive 4 decodes
  some malformed inputs to an empty archive instead of throwing).
- Tests: removed now-unneeded `!` on `ZipEncoder.encode`, symlink fixtures use
  `ArchiveFile.symlink`, invalid-ZIP test uses a temp target dir.

## Staged plan

Do one stage at a time, in its own commit, each gated by the verification
checklist below. Do **not** combine stages.

### Stage 1 — safe refresh (done, 2026-10-31)

- [x] `flutter pub upgrade` (no `pubspec.yaml` change)

### Stage 2 — direct major bumps, non-plugin (done, 2026-10-31)

- [x] `archive ^4.5.2` + code migration
- [x] Remove `cupertino_icons`
- [x] Full test + `flutter build linux`

### Stage 3 — plugin majors (pending)

- [ ] Bump `file_picker ^13.3.0` + `package_info_plus ^10.2.2` together
- [ ] Migrate `settings_form.dart` to `FilePicker.pickFile()`
- [ ] Confirm `win32` 6 / `package_info_plus_platform_interface` 4 resolve
- [ ] Full test + build/run, **especially** the settings pickers and the
      self-update check/badge on Linux, Windows and macOS

### Deferred — not resolvable

`screen_retriever`, `cross_file`, `dartssh2`, `material_color_utilities`,
`test_api`: revisit after Stage 3 and after any Flutter SDK upgrade.

### Optional — Flutter SDK patch

Flutter 3.47.9 stable is available (local toolchain and CI pin are 3.47.7).
Update `~/flutter` and `.github/workflows/ci-desktop.yml` +
`desktop-release.yml` in a separate change.

## Verification checklist (per stage)

- [x] `flutter pub get` (via `./run.sh`) resolves cleanly
- [x] `dart test` in `packages/marcer_catalog` passes
- [x] `flutter analyze` / `flutter test` pass
- [x] `flutter build linux --debug` builds
- [x] Manual smoke test: catalog grid + detail, lightbox, favorites, Hatari launch
- [ ] Stage 3 only: settings editor pickers (Root/Patch/Screenshot/Gameinfo/Hatari)
      and the self-update check/badge still work
- [x] `flutter pub outdated` re-run; snapshot updated above

## Open questions / decisions

- The self-updater verifies the downloaded ZIP only via HTTPS, not by SHA256.
  `archive` 4.5 exposes `maxOutputSize`/`maxSize` — consider adding a zip-bomb
  cap to `extractZipToDir` (separate change; `catalog_assets.dart` already
  verifies SHA256 before extraction).
- Stage 3 is best done when a manual picker test on all three desktop OSes is
  possible; do not add `dependency_overrides` just to force it.

## References

- `apps/marcer_desktop/pubspec.yaml` — direct constraints
- `apps/marcer_desktop/pubspec.lock` — resolved/pinned set
- [`docs/specs/SPEC-desktop.md`](../../docs/specs/SPEC-desktop.md) — app behavior incl. self-update; [`SPEC-launcher.md`](../../docs/specs/SPEC-launcher.md) §12 — launch rules
