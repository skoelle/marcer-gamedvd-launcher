# Flutter Dependency Update Plan (marcer_desktop)

Status: **planned, not started** (2026-10-17) — working note for a staged
upgrade of the Flutter desktop app's dependencies. Nothing here is applied yet;
the app builds and runs as-is.

Toolchain at time of writing: **Flutter 3.47.7 stable** / **Dart 3.13.5**
(`~/flutter`), `environment: sdk: ^3.13.5`, `pubspec.lock` pins
`flutter: ">=3.38.0"`.

## Why / goal

`./run.sh` (`flutter pub get`) reports:

> 17 packages have newer versions incompatible with dependency constraints.

This is **informational, not an error** — the app works. The goal of this plan
is to reduce the debt *deliberately and in small, verified steps*, not to chase
every version:

- **Security first:** `archive` (`ZipDecoder`) and `win32` (FFI) are the
  risk-bearing packages; `archive` decodes a *downloaded* update ZIP
  (`lib/self_updater.dart:837`).
- Stay attachable to newer Flutter/Dart SDKs so the eventual migration is a
  series of small steps, not one big-bang.
- Unblock currently pinned transitive packages (e.g. `cross_file`,
  `screen_retriever`) once their parent packages move.

## Snapshot: `flutter pub outdated` (2026-10-17)

Columns: **Current** (installed) · **Upgradable** (reachable via
`flutter pub upgrade`, no `pubspec.yaml` change) · **Resolvable** (reachable
after editing `pubspec.yaml`) · **Latest** (newest published).

### Direct dependencies

| Package | Current | Upgradable | Resolvable | Latest |
|---|---|---|---|---|
| archive | 3.6.1 | 3.6.1 | 4.5.2 | 4.5.2 |
| cupertino_icons | 1.0.9 | 1.0.9 | 2.0.0 | 2.0.0 |
| file_picker | 11.0.3 | 11.0.3 | 13.1.0 | 13.1.0 |
| package_info_plus | 9.0.1 | 9.0.1 | 10.2.2 | 10.2.2 |

### Transitive dependencies

| Package | Current | Upgradable | Resolvable | Latest |
|---|---|---|---|---|
| cross_file | 0.3.5+5 | 0.3.5+5 | 0.3.5+5 | 0.4.0 |
| dbus | 0.7.15 | 0.7.15 | 0.8.0 | 0.8.0 |
| material_color_utilities | 0.13.0 | 0.13.0 | 0.13.0 | 0.13.1 |
| meta | 1.18.3 | 1.19.0 | 1.19.0 | 1.19.0 |
| package_info_plus_platform_interface | 3.2.1 | 3.2.1 | 4.1.0 | 4.1.0 |
| petitparser | 7.0.2 | 7.1.0 | 7.1.0 | 7.1.0 |
| screen_retriever | 0.2.2 | 0.2.2 | 0.2.2 | 0.3.0 |
| vector_math | 2.4.0 | 2.4.3 | 2.4.3 | 2.4.3 |
| vm_service | 15.3.0 | 15.4.0 | 15.4.0 | 15.4.0 |
| win32 | 5.15.0 | 5.15.0 | 6.4.0 | 6.4.0 |
| xml | 7.0.1 | 7.1.0 | 7.1.0 | 7.1.0 |

### Transitive dev dependencies

| Package | Current | Upgradable | Resolvable | Latest |
|---|---|---|---|---|
| test_api | 0.7.12 | 0.7.12 | 0.7.12 | 0.7.15 |

## Classification

`flutter pub outdated` already splits the 16 into two actionable groups (the two
footnote lines at the bottom of its output).

### Group A — "locked (in pubspec.lock) to older versions" (5, low risk)

Reachable with a plain `flutter pub upgrade`; no `pubspec.yaml` or code change.

`meta` 1.18.3→1.19.0 · `petitparser` 7.0.2→7.1.0 · `vector_math` 2.4.0→2.4.3 ·
`vm_service` 15.3.0→15.4.0 · `xml` 7.0.1→7.1.0

### Group B — "constrained to versions older than resolvable" (7, major bumps)

Need a `pubspec.yaml` edit and may need code changes (breaking changes).

- **Direct (we control):** `archive` 3→4 · `cupertino_icons` 1→2 ·
  `file_picker` 11→13 · `package_info_plus` 9→10
- **Transitive (parent controls):** `dbus` 0.7→0.8 · `win32` 5→6 ·
  `package_info_plus_platform_interface` 3→4

### Not resolvable at all (pinned by SDK/parent, regardless of our edits)

`cross_file` 0.3.5+5 (0.4.0 exists) · `screen_retriever` 0.2.2 (0.3.0 exists) ·
`material_color_utilities` (0.13.1) · `test_api` (0.7.15)

These only move when their parent packages (`file_picker`, `window_manager`,
Flutter SDK) relax their constraints.

## How the affected packages are used (risk surface)

| Package | Usage in the app | Risk if bumped |
|---|---|---|
| `archive` | `lib/self_updater.dart:837` — `ZipDecoder().decodeBytes` on the downloaded `desktop-v*` update ZIP | **Security-relevant** (ZIP-slip / zip-bomb CVEs); 3→4 likely API changes |
| `win32` | FFI in the Windows two-phase updater (`currentProcessInJob()`) | Platform-specific; 5→6 likely API renames |
| `file_picker` | `lib/widgets/settings_form.dart:174,181` — directory/file pickers | 11→13 spans two majors; check `FilePicker.getDirectoryPath` / `pickFiles` signatures |
| `package_info_plus` | `lib/main.dart:324,347` — app version for the self-update badge / status bar | 9→10; verify `PackageInfo.fromPlatform()` still returns `version`/`buildNumber` |
| `cupertino_icons` | Icon font asset only | Cosmetic; low risk |
| Group A + `dbus`/`screen_retriever`/`cross_file` | transitives (window_manager, ftpconnect, file_picker) | None directly |

## Staged plan

Do one stage at a time, in its own commit, each gated by the verification
checklist below. Do **not** combine stages.

### Stage 1 — safe refresh (Group A)

- [ ] `flutter pub upgrade` (no `pubspec.yaml` change)
- [ ] `dart test` in `packages/marcer_catalog` + `flutter test` + build/run

Expected: 5 packages move; zero code changes. Revert is `git checkout
pubspec.lock`.

### Stage 2 — direct major bumps (Group B, direct)

- [ ] Bump in `pubspec.yaml`: `archive ^4`, `cupertino_icons ^2`,
  `file_picker ^13`, `package_info_plus ^10`
- [ ] Fix compile breaks (start with `self_updater.dart` for `archive` v4 API)
- [ ] Full test + build/run, **especially** the self-update path and the settings pickers

### Stage 3 — transitive majors (Group B, transitive)

- [ ] Run `flutter pub upgrade --major-versions` for `dbus`/`win32`/
  `package_info_plus_platform_interface`, **only if** the parents allow it
- [ ] If they stay pinned, leave them and re-check after the parents update;
  do not force overrides unless a concrete need exists

### Deferred — not resolvable

`cross_file`, `screen_retriever`, `material_color_utilities`, `test_api`: revisit
after Stage 2/3 and after any Flutter SDK upgrade. No action possible now.

## Verification checklist (per stage)

- [ ] `flutter pub get` (via `./run.sh`) resolves cleanly
- [ ] `dart test` in `packages/marcer_catalog` passes
- [ ] `flutter test` passes
- [ ] App builds and launches (`./run.sh`)
- [ ] Manual smoke test: catalog grid + detail, lightbox, favorites, Hatari launch
- [ ] Stage 2 only: settings editor pickers (Root/Patch/Screenshot/Gameinfo/Hatari)
      and the self-update check/badge still work
- [ ] `flutter pub outdated` re-run; snapshot the new state into this file

## Open questions / decisions

- Is the ZIP from the self-updater already integrity-checked (`sha256`) before
  `ZipDecoder`? If not, harden that regardless of the `archive` version
  (see `lib/asset_updater.dart` for the pointer-level `sha256` pattern).
- Stage 3 may be a no-op until `file_picker`/`window_manager` release constraint
  relaxations — decide then whether to wait or add `dependency_overrides`
  (avoid unless necessary).

## References

- `apps/marcer_desktop/PLAN.md` — overall app plan
- `apps/marcer_desktop/pubspec.yaml` — direct constraints
- `apps/marcer_desktop/pubspec.lock` — resolved/pinned set
- [`docs/SPEC.md`](../../docs/SPEC.md) §12 (launch), self-update is app-only
