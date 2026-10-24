# Marcer GameDVD Launcher — Release Setup Guide

This guide is for users of the prebuilt **Marcer Desktop** release ZIPs. It
covers the first start, the macOS specifics, the game/patch directories
(including the optional `ftp-sync` workflow), the FTP connection and the
catalog-data downloads. It does **not** describe how to build the app from
source.

## Quick start (TL;DR)

1. Download the release ZIP for your platform, extract it and start the app
   ([Download and start](#1-download-and-start)).
2. **macOS only:** extract the **whole ZIP** into a normal folder under your
   home directory, e.g. `~/MarcerGameDVDLauncher/`, so the `.app`,
   `desktop.config.example.json` and `MarcerGameDvd-Hatari.cfg` stay together.
   Right-click the app → **Open** (or run
   `xattr -dr com.apple.quarantine …`) and start it from that folder. Do not
   run it from Downloads/Documents/Desktop or directly from the ZIP
   ([macOS](#7-macos)).
3. In the setup page, set **RootDirectory** to your local game archive. If you
   use `ftp-sync`, also set **PatchDirectory** to its `patchDir`; otherwise
   leave it empty ([ftp-sync](#3-syncing-the-game-archive-with-ftp-sync)).
4. Enter the FTP **host** (use `host:2121` for the community server), **user**
   and **password**.
5. Set **ScreenshotDirectory** and **GameinfoDirectory**, then click
   **Download from FTP** next to each. Optional: set
   **AtariLegendDirectory** and click **Download AtariLegend data**
   ([FTP and catalog data](#4-ftp-connection-and-catalog-data)).
6. Press **Save**. Install Hatari and download the TOS ROM when prompted
   ([Hatari and TOS ROM](#5-hatari-and-tos-rom)).
7. Press `?` in the app for all keyboard shortcuts. The detailed sections
   below cover every option.

**ftp-sync in 3 steps:** `localDir` → **RootDirectory**, `patchDir` →
**PatchDirectory**, then enter the FTP data and download the catalog data in
the app.

For the full feature list and keyboard shortcuts see
[`apps/marcer_desktop/README.md`](../apps/marcer_desktop/README.md). The legacy
console launcher has its own documentation:
[`apps/marcer_console/README.md`](../apps/marcer_console/README.md).

---

## 1. Download and start

Download the ZIP for your platform from the
[Releases](https://github.com/skoelle/marcer-gamedvd-launcher/releases) page:

| Platform | Archive | Start |
|---|---|---|
| Windows | `MarcerDesktop-<version>-win-x64.zip` | `MarcerGameDVDLauncher.exe` |
| Linux | `MarcerDesktop-<version>-linux-x64.zip` | `./MarcerGameDVDLauncher` |
| macOS (Apple Silicon) | `MarcerDesktop-<version>-osx-arm64.zip` | `MarcerGameDVDLauncher.app` |

### System requirements

| Platform | Minimum |
|---|---|
| Windows | Windows 10/11 (64-bit). The ZIP includes the Visual C++ runtime DLLs. |
| Linux | Ubuntu 24.04 LTS or newer (64-bit, GTK3). The release is built on Ubuntu 24.04; older distributions may work with glibc 2.34 or newer, but are not tested. |
| macOS | macOS 12 Monterey or newer on Apple Silicon. **Intel Macs are not supported** (no x64 build). |

Extract the ZIP to a normal folder, for example:

- Windows: `C:\Games\MarcerGameDVDLauncher\`
- Linux: `~/Games/MarcerGameDVDLauncher/`
- macOS: `~/MarcerGameDVDLauncher/` (the folder containing the `.app` and the
  two companion files; see [macOS](#7-macos))

The release ZIP contains the application, `desktop.config.example.json` and the
bundled Hatari configuration `MarcerGameDvd-Hatari.cfg`.

> **Windows:** the build is not code-signed, so SmartScreen may show
> "Windows protected your PC". Choose **More info → Run anyway**.

On Linux make the binary executable if needed:

```bash
chmod +x MarcerGameDVDLauncher
./MarcerGameDVDLauncher
```

On macOS extract the **whole ZIP** into a normal folder under your home
directory (e.g. `~/MarcerGameDVDLauncher/`) and start the `.app` there; do not
run it from Downloads/Documents/Desktop or directly from the ZIP. Read
[macOS](#7-macos) first.

---

## 2. First start and configuration

When no `desktop.config.json` exists, the app opens the **first-run setup
page**. It lists the locations it searched and the locations it can write a new
config to. Fill in the paths, watch the green ✓ / red ✗ validation and press
**Save**.

You can reopen the same form at any time with the **⚙ gear** button in the top
bar. Changes are written back to the same `desktop.config.json` and the catalog
reloads in place. If you prefer editing by hand, copy
`desktop.config.example.json` to `desktop.config.json` next to the executable
(or the `.app`) and fill in the paths before the first start.

The config is searched in this order (first existing file wins):

1. the current working directory
2. the directory of the executable (the portable release layout)
3. macOS only: the folder containing the `.app`
4. macOS only: `~/Library/Application Support/MarcerGameDVDLauncher`

A new config is written to the first **writable** location. On macOS this is
usually next to the `.app`, or the per-user Application Support directory when
the app is read-only/translocated.

### Recommended directories

Create the folders before filling in the form (empty folders are fine):

```
GameDVD/                       <- RootDirectory (the game archive)
GameDVD-Patch/                 <- PatchDirectory (optional)
MarcersGameDVD-Data/
  Screenshots/                 <- ScreenshotDirectory
  Gameinfo/                    <- GameinfoDirectory
  AtariLegend/                 <- AtariLegendDirectory (optional)
```

| Field | Required | Meaning |
|---|---|---|
| `RootDirectory` | yes | The local Marcer GameDVD game tree. Navigation never leaves it. |
| `PatchDirectory` | no | Optional overlay/patch tree. Files there take precedence over the root. Leave empty for no patch layer. |
| `ScreenshotDirectory` | no | Target for the screenshot index (`index.json`, `index-pd.json`, `index-utils.json`, `index-magazine.json`, `index-falcon.json`) and the PNG previews. |
| `GameinfoDirectory` | no | Target for the game metadata (`games-*.json`). There is no implicit fallback. |
| `AtariLegendDirectory` | no | Optional AtariLegend metadata cache (`atarilegend.json`, `atarilegend-texts.json`). |

Without screenshots/gameinfo the catalog is empty or incomplete; the app then
shows a notice that points to the download buttons and to the status filter
**any**.

---

## 3. Syncing the game archive with `ftp-sync`

The app does not mirror the whole game archive by itself. The community uses
[`ftp-sync`](https://github.com/slippyex/ftp-sync) to download only new or
changed files from Marcer's FTP server. This is optional but recommended for
keeping a large archive up to date.

`ftp-sync` is a separate Node.js tool and is not bundled with the launcher.

### 3.1 Install and configure `ftp-sync`

Requirements: Node.js and npm.

```bash
git clone https://github.com/slippyex/ftp-sync.git
cd ftp-sync
npm install
```

Create a `config.json`:

```json
{
  "ftpConfig": {
    "host": "<ftp-host>",
    "user": "<username>",
    "password": "<password>",
    "port": 2121
  },
  "localDir": "C:\\Games\\MarcersGameDVD\\",
  "remoteDir": "/GameDVD",
  "patchDir": "C:\\Games\\MarcersGameDVD-Patch\\"
}
```

- Use the current community FTP credentials (ask in the
  [Facebook group](https://www.facebook.com/groups/360493904888475/)).
- The community FTP uses port **2121**.
- `localDir` is the main game tree, `patchDir` is the separate patch/update
  tree. Both are local directories.
- On Linux/macOS use POSIX paths, e.g. `/home/you/Games/MarcersGameDVD/`.
- Do not share or commit the credentials.

Run the sync:

```bash
npm run sync config.json
```

Press `s` to start syncing and `q` (or `Ctrl+C`) to quit when it is done.

### 3.2 Point the launcher at the synced directories

After the sync, set in the app's setup/settings form:

- **`RootDirectory`** = the `localDir` from `config.json`
- **`PatchDirectory`** = the `patchDir` from `config.json`

If you do not use a patch directory, leave `PatchDirectory` empty. The app then
shows no patch layer. If a ZIP exists in both layers, the patch copy is used.

The app's own FTP fields are **not** a replacement for `ftp-sync`: they are used
for the catalog-data downloads and for downloading individual missing game
folders (see the next section).

---

## 4. FTP connection and catalog data

The setup/settings form has an **FTP** section and two catalog-data fields with
download buttons. The same connection is used for:

- the screenshot/gameinfo catalog archives,
- the optional AtariLegend data,
- **Download folder** for cards marked `MISSING`.

| Field | Default | Notes |
|---|---|---|
| FTP host | – | `host` or `host:port`; the community server uses port **2121** |
| FTP user | – | Empty user means anonymous |
| FTP password | – | Stored in plaintext in `desktop.config.json` |
| FTP remote base dir (game folders) | `/GameDVD/` | Remote prefix for game-folder downloads; empty means the FTP login root |
| FTP asset dir (screenshots + gameinfo) | `/Uploads/MarcerGameDVDLauncher-assets/` | Remote directory with `screenshots-*.zip` and `gameinfo-*.zip` |

### 4.1 Download the catalog data

1. Enter the FTP host, user and password.
2. Set **`ScreenshotDirectory`** and click **Download from FTP** next to it.
   The newest `screenshots-*.zip` is downloaded and extracted into that folder
   (the folder is created when missing).
3. Set **`GameinfoDirectory`** and click **Download from FTP** next to it. The
   newest `gameinfo-*.zip` is extracted there.
4. Optional: set **`AtariLegendDirectory`** and click **Download AtariLegend
   data**. This downloads the weekly AtariLegend dump, builds the compact cache
   and can be repeated later. AtariLegend data is CC BY-NC-SA 4.0 and is not
   bundled.
5. Press **Save**. The catalog reloads with the new data.

Downloads show progress and can be cancelled. The newest archive is chosen by
the timestamp in its name. The applied archive is recorded in
`.marcer-assets.json` in the target folder; clicking the button again reports
**already up to date** and offers **Download anyway** if you want to force it.

### 4.2 Download a missing game folder

Cards whose ZIPs are not present locally show a red **`MISSING`** badge. Open
the card and click **Download folder** in the detail sidebar. The app downloads
the whole card folder (all ZIP variants and subfolders) from the FTP server into
the patch layer, or into `RootDirectory` when no patch directory is configured.
The badges clear in place after the download.

---

## 5. Hatari and TOS ROM

The app launches games in [Hatari](https://www.hatari-emu.org/). Hatari and the
TOS ROM are not bundled.

- **Windows/macOS:** if no Hatari executable is configured, the app offers to
  install a prebuilt Hatari 2.6.1. The **Hatari installation** row in the
  settings form shows the current status and an **Install Hatari…** /
  **Reinstall Hatari…** button.
- **Linux:** install Hatari with your package manager (for example
  `sudo apt install hatari`) and set **Hatari executable** to the binary path.
- **TOS ROM:** if `TOS.IMG` is missing, the app offers to download TOS 1.04
  (English (UK) or German). The STE, Low Res TOS 1.02, Low Res TOS 1.00 and
  Falcon 4.04 variants download their TOS files on demand when first used.
- The bundled `MarcerGameDvd-Hatari.cfg` is used automatically when
  **Hatari config file** is empty.

Downloaded Hatari/TOS files are stored next to the app on Windows/Linux and in
`~/Library/Application Support/MarcerGameDVDLauncher/` on macOS, not inside the
`.app` bundle.

---

## 6. Launching and daily use

- Select a card and press `P` / `Space`, or use the **Play** button. The split
  button opens the variant menu (Standard, Mono, STE, Low Res TOS 1.02, Low Res
  TOS 1.00; Falcon variants in the Falcon section).
- `?` opens the in-app help overlay with all keyboard shortcuts.
- `*` toggles a favorite; the **★ Favorites** filter lists favorites of the
  active section.
- The status filter is available in every section. Use **any** to show cards
  without screenshots.
- The **Folders** button / `T` opens the optional overlay folder browser.

---

## 7. macOS

The macOS release is an **Apple Silicon** build (`osx-arm64`) and requires
macOS 12 Monterey or newer. **Intel Macs are not supported** (there is no x64
build). The app is ad-hoc signed and **not notarized**, and it is **not
sandboxed** (it must read game folders you choose, launch Hatari and update its
own bundle).

### 7.1 Gatekeeper

Because the app is not notarized, macOS quarantines the download. If macOS says
the app cannot be opened:

- **Right-click the app → Open**, then confirm **Open** once, or
- remove the quarantine attribute in Terminal:

```bash
xattr -dr com.apple.quarantine /path/to/MarcerGameDVDLauncher.app
```

### 7.2 App Translocation

**Recommended:** extract the **whole ZIP** into a normal folder under your home
directory, e.g. `~/MarcerGameDVDLauncher/`, and start the `.app` from there.
Keep the `.app`, `desktop.config.example.json` and `MarcerGameDvd-Hatari.cfg`
together — this is the portable layout, so the config/cfg are next to the app
and self-update can replace the bundle in the writable folder.

Do not run the app from Downloads/Documents/Desktop or directly from the ZIP or
a mounted archive. If macOS still runs it from a randomized, read-only copy
(**App Translocation**, the app shows a hint), quit it and:

- clear the quarantine (`xattr -dr com.apple.quarantine /path/to/…app`), or
- re-extract the whole ZIP into a **different** normal folder, or
- move the `.app` individually in Finder to a normal folder and copy
  `desktop.config.example.json` + `MarcerGameDvd-Hatari.cfg` next to it.

A Finder move to a different folder (or removing the quarantine) ends
translocation; `mv` in Terminal does not. The per-user data directory
(`~/Library/Application Support/…`) remains the fallback for the config and
downloaded Hatari/TOS files.

### 7.3 Protected folders (TCC)

macOS still protects `~/Downloads`, `~/Documents`, `~/Desktop` and external or
network volumes. The first access shows a system permission prompt; until it is
granted, the path fails with `Operation not permitted`. A folder outside those
locations (for example `~/Games`) works without a prompt.

### 7.4 Config and downloaded data

On macOS the app writes the fallback config and the downloaded Hatari/TOS files
to:

```
~/Library/Application Support/MarcerGameDVDLauncher/
```

The config is searched in the current working directory, next to the
executable/`.app`, and finally in the per-user directory (section 2). This keeps
browsing, launching and downloads working even when the `.app` is read-only.
Self-update and favorites without a patch directory still need the app to live
in a writable folder.

---

## 8. Troubleshooting

| Problem | What to do |
|---|---|
| macOS: “app is damaged” / “unidentified developer” | Right-click → Open, or run `xattr -dr com.apple.quarantine …` (section 7.1). |
| macOS: settings/favorites/self-update do not stick | Quit, clear the quarantine and/or re-extract the whole ZIP into a different normal folder (section 7.2). |
| `Operation not permitted` on a configured path | Grant the macOS permission prompt, or use a folder outside Downloads/Documents/Desktop (section 7.3). |
| Catalog is empty | Set `ScreenshotDirectory`/`GameinfoDirectory` and use **Download from FTP**; then select status **any**. |
| FTP download fails | Check host/port (community port **2121**), user/password and `Ftp.RemoteBase` / `Ftp.AssetsRemote`. |
| A card shows `MISSING` | Use **Download folder** in the detail sidebar (requires FTP), or sync the archive with `ftp-sync`. |
| Hatari does not start | Install Hatari via the settings row (Windows/macOS) or set the Linux binary path. |
| TOS ROM missing | Use the TOS download dialog, or place the ROM in the app data directory. |
| Settings changes do not apply | Press **Save**; every filled path must be valid (green ✓) before Save is enabled. The catalog reloads in place. |

---

## 9. Related documentation

- [`apps/marcer_desktop/README.md`](../apps/marcer_desktop/README.md) — full desktop feature and configuration reference
- [`apps/marcer_console/README.md`](../apps/marcer_console/README.md) — legacy console launcher and the original `ftp-sync` notes
- [`DECISION-macos-distribution.md`](DECISION-macos-distribution.md) — why the app is not sandboxed and the Gatekeeper/notarization background
- [`SPEC.md`](SPEC.md) — launcher behavior and overlay/patch rules
