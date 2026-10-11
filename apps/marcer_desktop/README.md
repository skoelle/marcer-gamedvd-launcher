# Marcer GameDVD Desktop App (Flutter, Surface A)

Inventory browser for the Marcer GameDVD archive: windowed master-detail UI,
gameinfo metadata and screenshot previews, gallery-style global filters with a
**catalog grid as the default view** (section tabs, search, facets incl.
crew/cracker, sort) and a gallery-style detail sidebar (Game info + Release
variants + This ZIP); an optional overlay folder browser (`T` / Folders button)
per `SPEC.md` §7, plus a gallery-style lightbox (filmstrip + info panel).
**Read-only** consumer of all data roots.

![Catalog grid](../../docs/images/catalog.png)

Plan: [`PLAN.md`](PLAN.md). Architecture decision:
[`DECISION-app-architecture.md`](../../docs/DECISION-app-architecture.md).

## Structure

- `packages/marcer_catalog/` — pure Dart data layer (overlay merge, gameinfo
  join, screenshot index, `GameCard` universe + facets + filter/sort engine,
  config). No Flutter dependency; unit-tested via `dart test`.
- `lib/` — Flutter app (gallery catalog grid, optional folder browser,
  list/grid entry views, lightbox with a gallery-style status bar).
- `assets/icon/app_icon.png` — master app icon; `tool/generate_icons.py`
  regenerates the platform icon sets from the gallery favicon.
- `desktop.config.example.json` — config template (absolute paths).
  Real `desktop.config.json` is git-ignored.
- `MarcerGameDvd-Hatari.cfg` — bundled Hatari config, shipped next to the
  executable and used when `Hatari.ConfigFile` is empty (launch fallback).
- `run.sh` — seeds `desktop.config.json` from `../../local/paths.env` on
  first run, then `flutter run -d linux`.

The executable / app bundle is named **`MarcerGameDVDLauncher`**
(`MarcerGameDVDLauncher.exe` on Windows, `MarcerGameDVDLauncher.app` on
macOS); the Dart package name stays `marcer_desktop`.

## Prerequisites

- Flutter SDK (stable) in `~/flutter` (`export PATH="$HOME/flutter/bin:$PATH"`)
- Linux desktop toolchain: `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`
- Data roots reachable (see `local/paths.env`): game tree, patch tree,
  screenshot archive (`index.json` + PNGs), gameinfo `Data/` dir.
  All optional — missing artifacts degrade to empty states.

## Commands

```sh
export PATH="$HOME/flutter/bin:$PATH"
./run.sh                          # run app (linux desktop)
cd packages/marcer_catalog && dart test   # data-layer unit tests
flutter test                      # app unit tests
flutter analyze                   # lint
../../.venv/bin/python tool/generate_icons.py   # regenerate app icons
```

## Config (`desktop.config.json`)

The app looks for `desktop.config.json` in this order (first existing wins):

1. current working directory
2. the directory of the executable (portable ZIP release)
3. macOS only: the folder containing the `.app` bundle

The release ZIPs ship `desktop.config.example.json` — copy it next to the
executable (or the `.app`), rename it to `desktop.config.json`, and set your
absolute paths. Without a config the app shows a page listing the searched
locations.

| Field | Required | Notes |
|---|---|---|
| `RootDirectory` | yes | game root; navigation never leaves it |
| `PatchDirectory` | no | empty/missing ⇒ no patch layer |
| `OutDirectory` | no | screenshot archive (`index.json`, PNGs) |
| `DataDirectory` | no | gameinfo JSONs; default `<Patch>/../Data` |
| `Hatari.Executable` | for launch | Hatari binary; relative resolves against the app dir |
| `Hatari.ConfigFile` | no | empty ⇒ bundled `MarcerGameDvd-Hatari.cfg` |
| `Hatari.ArgsTemplate` | no | must contain `{cfg}` and `{zip}` |
| `ShowCandidates` | no | candidate thumb strip on grid cards (default `true`) |
| `DefaultStatus` | no | initial status preset (default `with_screenshot`) |
| `Window.width/height` | no | reserved — parsed but not applied yet |

## Launch (Hatari)

Press `P` (list/grid), `Space`/`P` (lightbox) or the **(P)lay** button in the
detail sidebar to start the selected ZIP in Hatari. Arguments are built from
`Hatari.ArgsTemplate` with literal `{cfg}`/`{zip}` substitution (no shell);
`{cfg}` falls back to the bundled `MarcerGameDvd-Hatari.cfg` (searched in the
same locations as the config) when `Hatari.ConfigFile` is empty. Launching is
**non-blocking** — the status bar shows a "Hatari is running…" indicator and
errors appear as a modal (missing executable, vanished ZIP, …). The bundled
config expects a TOS ROM (`TOS.IMG`) next to the app, matching the console
launcher.

## License

MIT License — Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
