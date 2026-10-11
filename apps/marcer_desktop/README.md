# Marcer GameDVD Desktop App (Flutter, Surface A)

Inventory browser for the Marcer GameDVD archive: windowed master-detail UI
(Playnite-inspired), overlay tree per `SPEC.md` §7, gameinfo metadata and
screenshot previews, gallery-style global filters with a card grid
(section tabs, search, facets, sort), list/grid auto-switch and a
lightbox (filmstrip + info panel). **Read-only** consumer of all data roots.

Plan: [`PLAN.md`](PLAN.md). Architecture decision:
[`DECISION-app-architecture.md`](../../DECISION-app-architecture.md).

## Structure

- `packages/marcer_catalog/` — pure Dart data layer (overlay merge, gameinfo
  join, screenshot index, `GameCard` universe + facets + filter/sort engine,
  config). No Flutter dependency; unit-tested via `dart test`.
- `lib/` — Flutter app (Phase 3 UI: folder browser, catalog filters,
  list/grid views, lightbox).
- `desktop.config.example.json` — config template (absolute paths).
  Real `desktop.config.json` is git-ignored.
- `run.sh` — seeds `desktop.config.json` from `../../local/paths.env` on
  first run, then `flutter run -d linux`.

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
| `Hatari.*` | no (MVP) | launch config, used from Phase 5+ |
| `ShowCandidates` | no | candidate thumb strip on grid cards (default `true`) |
| `DefaultStatus` | no | initial status preset (default `with_screenshot`) |
| `Window.width/height` | no | initial window size (default 1280×800) |

## License

MIT License — Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
