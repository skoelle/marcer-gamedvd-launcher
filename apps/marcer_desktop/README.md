# Marcer GameDVD Desktop App (Flutter, Surface A)

Inventory browser for the Marcer GameDVD archive: windowed master-detail UI,
gameinfo metadata and screenshot previews, gallery-style global filters with a
**catalog grid as the default view** (section tabs, search, facets incl.
crew/cracker, sort, **★ Favorites**) and a gallery-style detail sidebar
(Game info + Release variants + This ZIP); an optional overlay folder
browser (`T` / Folders button) per `SPEC.md` §7, plus a gallery-style
lightbox (filmstrip + info panel). **Read-only** consumer of all data roots
except favorites and, on explicit Save, manual screenshot curation.

![Catalog grid](../../docs/images/catalog.png)

Plan: [`PLAN.md`](PLAN.md). Architecture decision:
[`DECISION-app-architecture.md`](../../docs/DECISION-app-architecture.md).

## Structure

- `packages/marcer_catalog/` — pure Dart data layer (overlay merge, gameinfo
  join, screenshot index, `GameCard` universe + facets + filter/sort engine,
  config). No Flutter dependency; unit-tested via `dart test`.
- `lib/` — Flutter app (gallery catalog grid, optional folder browser,
  list/grid entry views, lightbox with a gallery-style status bar). The
  catalog loads in a background isolate that reports progress on the loading
  screen (`Loading screenshot index…`, `Loading game metadata…`,
  `Building catalog — cracked 1200/8000…`, `Finalizing…`).
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
  screenshot archive (`index.json`, `index-pd.json`, `index-utils.json` +
  PNGs), gameinfo `Data/` dir.
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

## macOS

The app is **not sandboxed** on macOS (`macos/Runner/*.entitlements`): it reads
game archives from arbitrary directories, writes `favorites.txt`/`index.json`
next to the data, launches Hatari and self-updates its own `.app` — none of which
the App Sandbox permits. `lib/main.dart` calls
`FilePicker.skipEntitlementsChecks()` so the native picker works without the
user-selected entitlement. See
[`docs/DECISION-macos-distribution.md`](../../docs/DECISION-macos-distribution.md).

- **Protected folders:** macOS still guards `~/Downloads`, `~/Documents`,
  `~/Desktop` and external/network volumes via TCC. The first access shows a
  system prompt (grant it); until then the path fails with
  `Operation not permitted`. Paths outside those folders (e.g. `~/Games`) work
  directly.
- **Gatekeeper:** the release build is ad-hoc signed and **not notarized**, so a
  downloaded ZIP is quarantined. Open it once via **right-click → Open**, or run
  `xattr -dr com.apple.quarantine /path/to/MarcerGameDVDLauncher.app`.

## Config (`desktop.config.json`)

The app looks for `desktop.config.json` in this order (first existing wins):

1. current working directory
2. the directory of the executable (portable ZIP release)
3. macOS only: the folder containing the `.app` bundle

The release ZIPs ship `desktop.config.example.json` — copy it next to the
executable (or the `.app`), rename it to `desktop.config.json`, and set your
absolute paths. Without a config the app opens the first-run setup page.

The setup/settings form lays the fields out as: **RootDirectory**,
**PatchDirectory**, the **FTP** server (used both for game-folder downloads
and for the catalog-data downloads), then **ScreenshotDirectory** and
**GameinfoDirectory** — each with a **Download from FTP** button next to
*Browse…* — and finally the Hatari settings plus the **Hatari installation**
and **TOS ROM** rows (download/install on demand, see below).

| Field | Required | Notes |
|---|---|---|
| `RootDirectory` | yes | game root; navigation never leaves it |
| `PatchDirectory` | no | empty/missing ⇒ no patch layer |
| `ScreenshotDirectory` | no | screenshot archive (`index.json`/`index-pd.json`/`index-utils.json`, PNGs) |
| `GameinfoDirectory` | no | gameinfo JSONs (no implicit fallback; fill it or download) |
| `Hatari.Executable` | for launch | Hatari binary; relative resolves against the app dir |
| `Hatari.ConfigFile` | no | empty ⇒ bundled `MarcerGameDvd-Hatari.cfg` |
| `Hatari.ArgsTemplate` | no | must contain `{cfg}` and `{zip}` |
| `Ftp.Host` | for download | FTP server for "Download missing" and the catalog assets; `host` or `host:port` (default port 21) |
| `Ftp.User` / `Ftp.Password` | no | FTP credentials (empty user ⇒ `anonymous`; password stored in plaintext) |
| `Ftp.RemoteBase` | no | remote prefix of the game folders (default `/GameDVD/`; empty ⇒ FTP login root) |
| `Ftp.AssetsRemote` | no | remote dir of the catalog asset archives, `screenshots-*.zip` / `gameinfo-*.zip` (default `/Uploads/MarcerGameDVDLauncher-assets/`) |
| `ShowCandidates` | no | candidate thumb strip on grid cards (default `true`) |
| `DefaultStatus` | no | initial status preset for the cracked section (default `with_screenshot`; pd/utils default `any`) |
| `Window.width/height` | no | initial/restore window size (default 1280×800) |
| `Window.maximized` | no | start maximized (default `true`; `false` ⇒ `width`×`height`, centered) |

## Launch (Hatari)

Press `P` (list/grid), `Space`/`P` (lightbox) or the **(P)lay** button in the
detail sidebar to start the selected ZIP in Hatari. Arguments are built from
`Hatari.ArgsTemplate` with literal `{cfg}`/`{zip}` substitution (no shell);
`{cfg}` falls back to the bundled `MarcerGameDvd-Hatari.cfg` (searched in the
same locations as the config) when `Hatari.ConfigFile` is empty. Launching is
**non-blocking** — the status bar shows a "Hatari is running…" indicator and
errors appear as a modal (missing executable, vanished ZIP, …). The bundled
config expects a TOS ROM (`TOS.IMG`) next to the app (in the executable
directory, which is Hatari's working directory), matching the console launcher.

The **PLAY** button is a split button: the main part launches the default
variant, the arrow opens a menu of variants (detail sidebar and lightbox; `P` /
`Space` use the default). Built-in variants:

| Variant | Extra Hatari args | TOS |
|---|---|---|
| Standard | – | `TOS.IMG` (1.04) |
| Mono | `--monitor mono` | `TOS.IMG` (1.04) |
| STE | `--machine ste` | `TOS162.IMG` (1.62) |
| Low Res TOS 1.02 | – | `TOS102.IMG` (1.02) |

The extra args are appended after `Hatari.ArgsTemplate` (Hatari CLI overrides
the config file). Variants with a TOS file download it on demand (see below).

## Hatari (download & install)

When no Hatari executable is configured/found, the app offers to install a
prebuilt Hatari instead of failing at launch: before the first start an install
dialog appears (the ⚙ settings editor also has a **Hatari installation** row
with the current status and an **Install Hatari…**/**Reinstall Hatari…**
button). The pinned release (**2.6.1**) is downloaded from the official
[SourceForge project](https://www.hatari-emu.org/) — prebuilt Windows (x64) and
macOS (universal, x86-64 + arm64) archives — and unpacked into
`<appDir>/hatari`; the executable is located inside the archive (Windows
`hatari.exe` / macOS `Hatari.app/Contents/MacOS/hatari`), made executable and,
on macOS, stripped of the download quarantine. The resulting path is written to
`Hatari.Executable` (relative to the app directory, so the portable folder keeps
working after being moved) and the running catalog updates in place.

- **Linux has no official prebuilt binary** — the row/dialog point to a manual
  (system package) install instead; the normal launch error surfaces until
  `Hatari.Executable` is set.
- Hatari is free software (GPL-2.0); nothing is bundled, only downloaded on
  demand.
- The install directory is not part of the release ZIP, so a self-update never
  overwrites it.

## TOS ROM

When `TOS.IMG` is missing, the app offers to download it instead of failing at
launch: before the first start the **TOS ROM** dialog appears (and the ⚙
settings editor has a **TOS ROM** row in the Hatari section with the current
status). It offers
the TOS **1.04** **English (UK)** and **German** images — English (UK) before
Deutsch; the default is **English (UK) — TOS 1.04**. The chosen ZIP is fetched
on demand from
[atariworld.org/tos-rom](https://www.atariworld.org/tos-rom/) (nothing is
bundled; the images are Atari-copyrighted and offered there for
non-commercial use), the ROM is extracted and written as `TOS.IMG` into the
app directory. The **STE** Play variant needs **TOS 1.62** (`TOS162.IMG`) and
the **Low Res TOS 1.02** variant **TOS 1.02** (`TOS102.IMG`) — each offered
filtered to that version when the file is missing. The ⚙ settings editor's
**TOS ROM** row reflects only `TOS.IMG`; the variant TOS files
(`TOS162.IMG`/`TOS102.IMG`) are managed by the Play variants (a missing one is
offered when that variant is launched).

## Favorites

`*` favorites the selected ZIP/catalog card (also from the detail panel and
from the ★/☆ star on every lightbox filmstrip thumb). A card shows as
favorite as soon as **any** of its ZIPs is starred; the **★ Favorites**
filter lists your favorites of **all** sections at once (facets and status
are ignored there, the text search stays active). Cards without raw variants
(pd/utils) resolve their folder ZIPs on demand, so they can be starred and
launched like cracked games. Launching a favorited card plays the starred ZIP
when exactly one variant is favorited.

Storage (one absolute path per line, same format as the console launcher):

- with a patch layer: `<Patch>/<section tree>/favorites.txt` per section
  (e.g. `Patch/Title Sorted/Cracked Games - Title Sorted/favorites.txt`) —
  the same files the console launcher shares; paths outside any section tree
  go to `<Patch>/favorites.txt`.
- without a patch layer: `favorites-<section>.txt` next to the executable
  (misc paths → `favorites.txt`).
- a legacy single `favorites.txt` (`PatchDirectory` → application directory
  → CWD) is still read; entries of the other OS (e.g. Windows `Y:\…`
  lines in a shared file) are preserved on save but not shown.

## Status filter

The status dropdown (`with screenshot`, `any`, `done`, `desktop`,
`desktop text`, `desktop black`, `pending`, `no usable shots`,
`interrupted`, `skipped (disk 2+)`) is available in **all three sections**
(cracked, pd, utils):

- `pending` matches a game when **at least one** of its ZIPs is pending
  (the same rule the gallery's status filter applies — the aggregated
  card status would otherwise hide pending ZIPs inside otherwise-done
  folders).
- All other status values use the aggregated card status
  (`done → desktop → no usable shots → interrupted → pending → skipped`).
- The default is `with screenshot` for cracked and `any` for pd/utils
  (their metadata-only cards have no screenshot).

The status bar reports every status as **games (ZIPs)** (see below), so the
games number always equals the result count of the matching dropdown
selection.

## Status bar

The gray bar at the bottom shows the current view path (folder browser),
result/entry counts, the gallery-style status info and — right aligned —
the **running app version** (`v…`; release builds: stamped from the
`desktop-v*` git tag via `--build-name`, dev builds: the pubspec version).

Status info in catalog mode is **section-aware** (same `games (ZIPs)` format
as the gallery's statistics bar, plus the folder total; the gallery labels
the coverage `info N folders` / `N without info`):

- `3287 folders` — games (cards) of the active section; cracked cards are
  built from `index.json`, pd/utils cards are the union of their own
  index (`index-pd.json` / `index-utils.json`) and gameinfo-only folders;
  every game folder with at least one ZIP is one card.
- `3211 with screenshot` — games of the section with a preview (prefer
  `done` game shot, else first `done`, else first `desktop`).
- `done 2635 (8979 zips)` — per status: number of **games** (cards) plus
  their **ZIP entries** in parentheses, counted for the active section.
  The games number equals the result count of the matching status dropdown
  selection — `done`, `desktop`, `no usable shots`, `interrupted` and
  `skipped (disk 2+)` use the aggregated card status, `pending` counts a
  game when **any** of its ZIPs is pending (same rule as the filter; a game
  can therefore appear in `pending` and `done` at once).
- `gameinfo N folders`, `N without gameinfo` — gameinfo match coverage
  (`N` cracked folders matched by the gameinfo generator, `manifest.json`
  `matched_folders`; cracked only) / cards of the active section whose
  gameinfo join is empty.
- `index.json: …` (or `index-pd.json` / `index-utils.json` for those
  sections), `gameinfo: …` — active index mtime and gameinfo generation
  timestamp.

## Missing ZIPs

The catalog is built from the screenshot index + gameinfo **without any
filesystem scan**, so it also lists games/ZIPs that are not synced locally
yet. The app therefore resolves ZIP existence **and** the displayed
`ROOT`/`PATCH`/`BOTH` layer on demand from the actual filesystem (cached), so
a ZIP moved between layers still shows where it really lives, and it marks
absent files:

- **`MISSING` card badge** (grid tile, detail panel, lightbox header) when
  **none** of the card's ZIPs exists in either `RootDirectory` or
  `PatchDirectory` — such a card cannot be launched.
- **Per-variant `MISSING`** in the lightbox filmstrip (red tag) and the
  "This ZIP" table (`Missing` row) when that specific ZIP is absent, while
  other variants of the same card are present.

A card with at least one local ZIP is not marked, even if some variants are
missing. The check is cached per session; files that appear or vanish while
the app runs are re-evaluated after a download or a settings reload.

## Download missing (FTP)

A card that has no local ZIP (red `MISSING` badge) can be pulled from the
Marcer FTP server without leaving the app: the detail sidebar shows a
**Download folder** button next to the `MISSING` badge that downloads the
card's whole folder recursively (all ZIP variants and subdirectories) into the
patch layer — or the root directory when `PatchDirectory` is empty — and then
re-checks the local layer so the `MISSING` badge disappears.

Connection settings live in the same `desktop.config.json` under `Ftp` and are
edited in the ⚙ settings editor:

- `Ftp.Host` — FTP server as `host` or `host:port` (port 21 by default, so a
  non-standard port is given inline, e.g. `ftp.example.com:2121`). While the
  host is empty the button shows a "FTP not configured" hint instead of
  downloading.
- `Ftp.User` / `Ftp.Password` — credentials (an empty user connects as
  `anonymous`; the password is stored in plaintext in the config file).
- `Ftp.RemoteBase` — remote directory prefix, default `/GameDVD/` (the game
  folders are looked up as `<RemoteBase>/<section tree>/<letter>/<folder>`).
  Leave it empty when the FTP login directory is already the catalog root.

The transfer always runs in **binary FTP** mode (ASCII would corrupt the ZIP
files).

Existing local files are skipped, so an interrupted run can simply be repeated.
The sidebar and the status bar show progress and a **Cancel** button; failures
appear as a modal. The download runs in the background (non-blocking, one at a
time), so browsing stays responsive.

## Catalog data (Download from FTP)

The catalog is built from the screenshot index and the gameinfo JSONs; without
them the catalog is empty. The setup/settings form therefore puts a **Download
from FTP** button next to *Browse…* on both `ScreenshotDirectory` and
`GameinfoDirectory`:

- the newest `screenshots-*.zip` is fetched from `Ftp.AssetsRemote` and
  extracted into `ScreenshotDirectory`, the newest `gameinfo-*.zip` into
  `GameinfoDirectory`.
- uploads never overwrite, so the newest archive is picked by the
  `yyyyMMdd-HHmmss` timestamp in its name; the two archives must both be present
  in the asset directory.
- after a successful download the applied archive is recorded in
  `<targetDir>/.marcer-assets.json`; clicking **Download from FTP** again when
  the newest archive is already applied (and its data is present) reports
  **"Already up to date"** and offers a **Download anyway** dialog instead of
  re-downloading.
- `Ftp.Host` and the target directory are required (the target directory is
  created when missing); progress and **Cancel** show inline, failures as a
  SnackBar.
- the transfer forces **binary FTP** mode (ASCII would corrupt the ZIPs) and a
  post-download size check rejects truncated transfers.
- the ZIP is extracted in a **background isolate** showing file-count progress
  (`Extracting 1234/8000 files…`, the screenshot archive holds thousands of
  PNGs), so the UI stays responsive and the run can be cancelled; a crashed
  extractor fails with an error instead of hanging.
- while a download/extraction runs, **Save**, **Cancel** and **Exit** are
  disabled (and the dialog cannot be dismissed) so the transfer is not
  interrupted; use the inline **Cancel** in the progress row to stop it.
- `Ftp.AssetsRemote` defaults to `/Uploads/MarcerGameDVDLauncher-assets/` — set it
  in the form (or config) when the assets live elsewhere.

`GameinfoDirectory` has **no implicit fallback**: if it is empty no gameinfo is
loaded.

## Catalog-data update check

After the (release-only) app self-update check, a silent startup check fetches
the small `latest.json` pointer published by `tools/asset-manifest` from the
GitHub `catalog-latest` prerelease — **GitHub only, never the FTP** (the FTP is
contacted only when you actually update). A gray **dataset** icon button sits in
the top bar (always available, right of the version badge) and shows a small
green count badge when updates are pending.

Clicking it opens the **Catalog data** dialog, listing **game info first, then
screenshots** with the local and remote archive names and per asset:

- **Update** (or **Install** when nothing is applied yet) — downloads the newest
  archive from the FTP and extracts it; progress and **Cancel** show inline.
  When the extracted data is present but the applied version is unknown (no
  `.marcer-assets.json`) the row shows **version unknown (data present)** and the
  button is **Overwrite**.
- **Skip this version** — the remote archive is recorded in
  `<targetDir>/.marcer-assets.json` under `skipped`, so you are only notified
  again when a newer archive appears (cleared automatically once applied).
- **Close** at the bottom.

An asset counts as up to date only when the recorded archive matches the remote
**and** the extracted data is still present, so a deleted/emptied target
directory is offered again.

If the pointer provides a `sha256`, the downloaded archive is verified against
it; a mismatch aborts the update. After a successful update the catalog reloads
in place.

## Catalog coverage

Conversely, a ZIP that exists in your `RootDirectory`/`PatchDirectory` but is
in **neither** the screenshot index nor gameinfo does **not** appear in the
catalog at all — the catalog is artifact-driven, not a tree listing. Such files
are only reachable in the folder browser (`T`); regenerate the artifacts
(`shotgen index`, `gameinfo-gen extract`) to bring them into the catalog. The
displayed `ROOT`/`PATCH`/`BOTH` layer is always resolved from your own copy
(see above), never from the published index. See
[`docs/DECISION-catalog-data-source.md`](../../docs/DECISION-catalog-data-source.md).

When a section has **no** cards because the artifacts are missing, a banner
explains what is missing and points to the settings **Download from FTP** (and
the status filter `any`). Loading is robust: a malformed/truncated
`games-*.json` is skipped with a warning instead of aborting the whole catalog,
and a load failure shows an error screen with **Retry**/**Settings…** instead of
hanging on the loading spinner.

## License

MIT License — Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
