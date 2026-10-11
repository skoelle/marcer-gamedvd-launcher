# Marcer GameDVD

Tools and apps for browsing and launching the [Marcer GameDVD](https://www.facebook.com/groups/360493904888475/) Atari ST game archive.

The primary application is the **Flutter desktop app** — a gallery-style inventory browser with metadata and screenshot previews. A legacy **console launcher** (C#) and a set of Python maintenance tools round out the monorepo.

---

## 🗂️ Applications

| App | Path | Tag | Description |
|---|---|---|---|
| **Desktop app** (primary) | [`apps/marcer_desktop`](apps/marcer_desktop/README.md) | `desktop-v*` | Flutter desktop app: gallery-style catalog grid, game info, screenshots, lightbox, optional folder browser. |
| Console launcher (legacy) | [`apps/marcer_console`](apps/marcer_console/README.md) | `v*` | Keyboard-driven terminal UI over the same archive; launches ZIPs in Hatari. |

Both are strictly **read-only** consumers of the archive and its derived artifacts.

---

## 🖥️ Desktop App (Flutter)

Windowed desktop app (Surface A: master-detail inventory browser, later Surface B: fullscreen couch mode) built with Flutter — see [`DECISION-app-architecture.md`](DECISION-app-architecture.md) for the technology decision and [`apps/marcer_desktop/PLAN.md`](apps/marcer_desktop/PLAN.md) for the phased plan.

- **Layout:** `apps/marcer_desktop/` (Flutter app) with the pure-Dart data layer `apps/marcer_desktop/packages/marcer_catalog/` (overlay merge per [`SPEC.md`](SPEC.md) §7, gameinfo join, screenshot index, gallery-style `GameCard` universe with facets).
- **UI:** gallery-style **catalog grid by default** with global filters (section tabs cracked/pd/utils, search, status/publisher/crew/cracker/language/year, tri-state raw/pasti/boxscan, TOS/Bad, sort + order, clear — gallery field order) and a right-hand gallery-style detail sidebar (Game info + Release variants + This ZIP); an optional overlay folder browser (`T` / Folders button) with tree + list/grid; gallery-style lightbox (integer-upscaled image, variant filmstrip with `+N` badges + scrollbar, candidate strip, release-variant table with the open ZIP highlighted); gallery-style status bar. Crew/cracker filter focuses each card on the group's ZIP (preview + lightbox variant) with fuzzy matching; grid cards show a 2×2 variant grid when a folder has multiple screenshots.
- The app is a **read-only** consumer of all data roots and degrades gracefully when `index.json` or the gameinfo `Data/` directory are absent.

### 📥 Download

Download the ZIP for your platform from the [Releases](https://github.com/skoelle/marcer-gamedvd-launcher/releases) page:

| Platform | Archive |
|---|---|
| Windows | `MarcerDesktop-*-win-x64.zip` |
| Linux | `MarcerDesktop-*-linux-x64.zip` |
| macOS | `MarcerDesktop-*-osx-arm64.zip` |

The release ZIPs ship `desktop.config.example.json` — copy it next to the executable (or the `.app`), rename it to `desktop.config.json`, and set your absolute paths.

### ⚙️ Configuration (`desktop.config.json`)

The app looks for `desktop.config.json` in this order (first existing wins):

1. current working directory
2. the directory of the executable (portable ZIP release)
3. macOS only: the folder containing the `.app` bundle

Without a config the app shows a page listing the searched locations. Template: [`apps/marcer_desktop/desktop.config.example.json`](apps/marcer_desktop/desktop.config.example.json).

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

### 🛠️ Build & Run (developers)

Requires the Flutter stable SDK in `~/flutter` plus the Linux desktop toolchain (`clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`).

```sh
export PATH="$HOME/flutter/bin:$PATH"
apps/marcer_desktop/run.sh                      # run app (linux desktop)
cd apps/marcer_desktop/packages/marcer_catalog && dart test   # data-layer unit tests
cd apps/marcer_desktop && flutter test          # app unit tests
cd apps/marcer_desktop && flutter analyze       # lint
```

`run.sh` seeds a git-ignored `desktop.config.json` from `local/paths.env` on first start.

---

## ⌨️ Console Launcher (legacy)

A fast, keyboard-driven terminal launcher for the Hatari emulator, still shipped for CLI users and CI-free environments. It uses `launcher.config.json` and the same overlay/patch semantics as the desktop app.

**Full documentation, configuration and controls: [`apps/marcer_console/README.md`](apps/marcer_console/README.md).**

Build & run via the platform scripts (only needed when changing `apps/marcer_console/`):

```bat
apps\marcer_console\build.cmd
apps\marcer_console\start.cmd
```

```bash
apps/marcer_console/build.sh
apps/marcer_console/start.sh
```

> ⚠️ Do **not** use `dotnet build` or `dotnet run` directly — always use the platform build script.

---

## 🔧 Tools

Helper tools for maintaining and enriching the game archive (not part of either app's release ZIP). Python scripts run via their `run.sh` wrapper with the repo `.venv`; paths come exclusively from the git-ignored `local/paths.env`.

| Tool | Purpose | Docs |
|---|---|---|
| [`tools/gameinfo-gen`](tools/gameinfo-gen/README.md) | Extracts game metadata (publisher, cracker, year, language, dump flags, …) from the GameDVD XLS workbooks into JSON under `MARCER_DATA_DIR`. | [`tools/gameinfo-gen/README.md`](tools/gameinfo-gen/README.md), [`ANALYSIS-game-data.md`](ANALYSIS-game-data.md) |
| [`tools/gallery`](tools/gallery/README.md) | Interactive gallery webapp over the screenshot archive (`MARCER_OUT_DIR`) joined with game metadata (`MARCER_DATA_DIR`). | [`tools/gallery/README.md`](tools/gallery/README.md), [`SPEC-gallery-webapp.md`](SPEC-gallery-webapp.md) |
| [`tools/screenshot-gen`](tools/screenshot-gen/README.md) | Boots every ZIP in Hatari on a virtual display and captures preview screenshots into `MARCER_OUT_DIR`. | [`tools/screenshot-gen/README.md`](tools/screenshot-gen/README.md), [`SPEC-screenshot-generator.md`](SPEC-screenshot-generator.md) |

---

## 🚀 Release Process

Releases are automated via GitHub Actions. This is a monorepo with **one tag scheme per app** so each app is built and released independently:

| App | Tag scheme | Workflow | Artifacts |
|---|---|---|---|
| Console launcher (`apps/marcer_console/`) | `vX.Y.Z` (e.g. `v0.9.8`) | [`release.yml`](.github/workflows/release.yml) | `MarcerGameDvdConsole-v…-{win,linux,osx}-x64.zip` |
| Flutter desktop (`apps/marcer_desktop/`) | `desktop-vX.Y.Z` (e.g. `desktop-v0.1.0`) | [`desktop-release.yml`](.github/workflows/desktop-release.yml) | `MarcerDesktop-v…-{win,linux,osx}-x64.zip` |

Each workflow triggers only on its own tag prefix (`v*` never matches `desktop-v*` and vice versa), so a desktop release never rebuilds the console launcher and the other way around. Path-based CI (build + test on `main` and PRs, **no release**) runs only when the relevant app changed: [`ci-launcher.yml`](.github/workflows/ci-launcher.yml) for `apps/marcer_console/**`, [`ci-desktop.yml`](.github/workflows/ci-desktop.yml) for `apps/marcer_desktop/**`.

**To create a release:**

You can use the `/create-release` command (via opencode) for a fully automated flow:

```text
/create-release 1.0.0            # console launcher → v1.0.0
/create-release desktop 0.1.0    # Flutter desktop  → desktop-v0.1.0
```

This command validates the version, checks for uncommitted changes, generates a release summary from recent commits, creates a release commit with the summary as the commit message, tags it, and pushes — all in one step. The matching GitHub Action then builds platform ZIPs and creates the GitHub Release.

**Manual release:**
1. Ensure `README.md` and `AGENTS.md` are up to date.
2. Commit all changes.
3. Tag and push (console example):
   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```
   Desktop example:
   ```bash
   git tag desktop-v0.1.0
   git push origin desktop-v0.1.0
   ```
4. The matching workflow builds platform ZIPs, generates release notes, and creates a GitHub Release.

---

## 📝 Notes

- Full technical requirements and build rules are in [`AGENTS.md`](AGENTS.md).
- Technology-neutral behavioral specification (for reimplementation in other languages or as a desktop app) is in [`SPEC.md`](SPEC.md).
- Analysis of external game metadata sources (XLS workbooks, data model, roadmap) is in [`ANALYSIS-game-data.md`](ANALYSIS-game-data.md).
- After any functional change, both `README.md` and `AGENTS.md` must be updated.
- Every release **must** include release notes listing all changes and bugfixes.

---

## License

Licensed under the [MIT License](LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
