# Marcer GameDVD Desktop App (Flutter, Surface A)

Inventory browser for the Marcer GameDVD archive. The complete behavioral
specification lives in
[`docs/specs/SPEC-desktop.md`](../../docs/specs/SPEC-desktop.md); this README
covers building and running the app.

![Catalog grid](../../docs/images/catalog.png)

## Structure

- `packages/marcer_catalog/` — pure Dart data layer (overlay merge, gameinfo
  join, screenshot-independent full index + screenshot overlay, `GameCard`
  universe + facets + filter/sort engine, config). No Flutter dependency;
  unit-tested via `dart test`.
- `lib/` — Flutter app (gallery catalog grid, optional folder browser,
  list/grid entry views, lightbox with a gallery-style status bar).
- `assets/icon/app_icon.png` — master app icon; `tool/generate_icons.py`
  regenerates the platform icon sets from the gallery favicon.
- `desktop.config.example.json` — config template (absolute paths).
  Real `desktop.config.json` is git-ignored.
- `MarcerGameDvd-Hatari.cfg` — bundled Hatari config, used when
  `Hatari.ConfigFile` is empty.
- `run.sh` — **regenerates** `desktop.config.json` from
  `../../local/paths.env` on every run (all path/FTP/Hatari values are
  overwritten, so manual config edits are lost), then `flutter run -d linux`.

The executable / app bundle is named **`MarcerGameDVDLauncher`**
(`MarcerGameDVDLauncher.exe` on Windows, `MarcerGameDVDLauncher.app` on
macOS); the Dart package name stays `marcer_desktop`.

## Release platform support

| Platform | Minimum |
|---|---|
| Windows | Windows 10/11 (64-bit); the release ZIP bundles the Visual C++ runtime DLLs. |
| Linux | Ubuntu 24.04 LTS+ (64-bit, GTK3); built on Ubuntu 24.04. Older distributions may work with glibc 2.34+ but are untested. |
| macOS | macOS 12 Monterey+ on Apple Silicon; Intel Macs are not supported. |

## Prerequisites

- Flutter SDK (stable) in `~/flutter` (`export PATH="$HOME/flutter/bin:$PATH"`)
- Linux desktop toolchain: `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`
- Data roots reachable (see `local/paths.env`): game tree, patch tree,
  screenshot archive (`index.json`, `index-pd.json`, `index-utils.json`,
  `index-magazine.json`, `index-falcon.json` + PNGs) and gameinfo directory
  (including `full-index.json.gz`, the screenshot-independent catalog index).
  All optional — missing artifacts degrade to empty states.

## Commands

```sh
export PATH="$HOME/flutter/bin:$PATH"
./run.sh                          # run app (linux desktop)
cd packages/marcer_catalog && dart test   # data-layer unit tests
flutter test                      # app unit tests
flutter analyze                   # lint
dart run tool/benchmark.dart      # catalog data-layer benchmark (real artifacts)
../../.venv/bin/python tool/generate_icons.py   # regenerate app icons
```

## Related documents

- Behavior: [`docs/specs/SPEC-desktop.md`](../../docs/specs/SPEC-desktop.md)
- User setup guide: [`docs/guides/GETTING-STARTED.md`](../../docs/guides/GETTING-STARTED.md)
- Architecture decision: [`docs/decisions/DECISION-app-architecture.md`](../../docs/decisions/DECISION-app-architecture.md)
- Catalog data source: [`docs/decisions/DECISION-catalog-data-source.md`](../../docs/decisions/DECISION-catalog-data-source.md)

## License

MIT License — Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
