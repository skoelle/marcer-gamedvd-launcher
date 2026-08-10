# Marcer GameDVD Launcher

A fast, keyboard-driven console launcher for the Hatari emulator. Browse your Atari ST game archive, navigate folders, and launch ZIPs — all from the terminal. Supports overlay/patch mode for comparing and merging game directories.

Built for the [Marcer GameDVD](https://www.facebook.com/groups/360493904888475/) community on Facebook.

---

## 🎮 Features

- **Overlay/Patch Mode:** Recursively merges a main game directory with an optional patch directory. If a file or folder exists in both, the patch version takes precedence.
- **Layer Labels:** Each entry shows its source — `[BOTH]`, `[ROOT]`, or `[PTCH]` — with a matching color scheme.
- **Favorites:** Press `*` on any ZIP to bookmark it. Bookmarked games appear in a virtual `Favorites` folder at the top of the root listing.
- **Robust Navigation:** Cursor position is remembered per directory. Scrolling and page jumps adapt dynamically to any console height.
- **Minimal Redraw:** Only changed lines are redrawn — no flicker, no `Console.Clear`, smooth even in huge directory trees.

### Color Scheme

Colors are configurable via the `Colors` section in `launcher.config.json` (see [Configuration](#-configuration)). Defaults are shown below:

| Entry | Label | Default Color | Meaning |
|---|---|---|---|
| Folder in both layers | `[BOTH]` | Yellow | Exists in main + patch |
| Patch-only folder | `[PTCH]` | DarkYellow | Only in patch layer |
| Main-only folder | `[ROOT]` | Gray | Only in main layer |
| ZIP in both layers | `[BOTH]` | Green | Exists in main + patch |
| Main-only ZIP | `[ROOT]` | DarkGreen | Only in main layer |
| Patch-only ZIP | `[PTCH]` | Magenta | Only in patch layer |
| Selected entry | — | Black on DarkCyan | Highlighted entry |
| Virtual entry (Favorites) | — | White | Pseudo-folder |

---

## 🕹️ End Users

### 📥 Download

Download the ZIP for your platform from the [Releases](https://github.com/anomalyco/marcer-gamedvd-launcher/releases) page:

| Platform | Archive |
|---|---|
| Windows | `*-win-x64.zip` |
| Linux | `*-linux-x64.zip` |
| macOS | `*-osx-x64.zip` |

### 💻 System Requirements

- **.NET Runtime 10** or later ([download](https://dotnet.microsoft.com/download/dotnet/10.0))
- **Hatari Emulator** with a working configuration file
  - Windows: native Hatari
  - Linux / macOS: Hatari via Wine or native build

### ⚡ Quick Start

1. Extract the release ZIP to any folder.
2. Copy `launcher.config.example.json` to `launcher.config.json`.
3. Edit `launcher.config.json` — set your game directory and Hatari paths (see [Configuration](#%EF%B8%8F-configuration) below).
4. Run the launcher:
   - **Windows:** Double-click `MarcerGameDvdLauncher.exe` or run from a terminal.
   - **Linux:** `chmod +x MarcerGameDvdLauncher && ./MarcerGameDvdLauncher`
   - **macOS:** `chmod +x MarcerGameDvdLauncher && ./MarcerGameDvdLauncher`
5. Browse and launch games with your keyboard.

### ⚙️ Configuration

The launcher reads `launcher.config.json` from the same directory as the executable. A template is included in the release — copy it and adjust:

```json
{
  "RootDirectory": "C:\\Games\\Hatari\\ROMS",
  "PatchDirectory": "C:\\Games\\Hatari\\PATCH",
  "Hatari": {
    "Executable": "C:\\Tools\\hatari\\hatari.exe",
    "ConfigFile": "C:\\Tools\\hatari\\hatari-st.cfg",
    "ArgsTemplate": "-c \"{cfg}\" --disk-a \"{zip}\""
  },
  "Colors": {
    "FolderBoth": "Yellow",
    "FolderPatchOnly": "DarkYellow",
    "FolderRootOnly": "Gray",
    "ZipBoth": "Green",
    "ZipRootOnly": "DarkGreen",
    "ZipPatchOnly": "Magenta",
    "SelectedForeground": "Black",
    "SelectedBackground": "DarkCyan",
    "VirtualEntry": "White"
  }
}
```

| Field | Required | Description |
|---|---|---|
| `RootDirectory` | ✅ | Game root folder. Navigation never leaves this directory. |
| `PatchDirectory` | ❌ | Optional overlay/patch directory merged at runtime. |
| `Hatari.Executable` | ✅ | Path to the Hatari executable. Validated at startup. |
| `Hatari.ConfigFile` | ✅ | Path to the Hatari configuration file. |
| `Hatari.ArgsTemplate` | ✅ | Argument template. Must contain `{zip}`, optionally `{cfg}`. |
| `Colors` | ❌ | Optional color overrides. See [Color Scheme](#-color-scheme) below. Missing or invalid values fall back to defaults. |

**Notes:**
- Relative paths are resolved relative to the executable's directory.
- Include quotes around `{cfg}` and `{zip}` in the template if your paths contain spaces.
- After editing `launcher.config.json`, restart the application.

### 🎨 Color Scheme

Colors are fully configurable via the `Colors` section of `launcher.config.json`. Each field accepts a [ConsoleColor](https://learn.microsoft.com/dotnet/api/system.consolecolor) name (case-insensitive). Omitting the entire `Colors` section — or any individual field — falls back to the built-in defaults:

| Field | Default | Applies to |
|---|---|---|
| `FolderBoth` | Yellow | Folders in both layers |
| `FolderPatchOnly` | DarkYellow | Folders in patch only |
| `FolderRootOnly` | Gray | Folders in root only |
| `ZipBoth` | Green | ZIPs in both layers |
| `ZipRootOnly` | DarkGreen | ZIPs in root only |
| `ZipPatchOnly` | Magenta | ZIPs in patch only |
| `SelectedForeground` | Black | Foreground for the highlighted entry |
| `SelectedBackground` | DarkCyan | Background for the highlighted entry |
| `VirtualEntry` | White | Virtual entries (e.g. the Favorites pseudo-folder) |

**Notes:**
- Relative paths are resolved relative to the executable's directory.
- Include quotes around `{cfg}` and `{zip}` in the template if your paths contain spaces.
- After editing `launcher.config.json`, restart the application.

### ⌨️ Controls

| Key | Action |
|---|---|
| `↑` / `↓` | Move selection |
| `Enter` / `→` | Open folder or launch ZIP |
| `Backspace` / `←` | Go up one directory level |
| `PageUp` / `PageDown` | Jump one page |
| `*` | Toggle favorite on selected ZIP |
| `?` | Show help overlay |
| `ESC` / `Q` | Exit |

**Navigation rules:**
- Backspace in the root directory has no effect — you can never leave it.
- Empty directories are displayed correctly.
- When a ZIP or folder exists in both layers, the patch version is always launched/opened.

### 🔄 Keeping Your Patch Directory Updated

The community uses [ftp-sync](https://github.com/slippyex/ftp-sync) to keep the patch directory in sync with Marcer's FTP server. This downloads only changed or new files — fast and bandwidth-friendly.

**Setup:**

1. Clone and install ftp-sync:
   ```bash
   git clone https://github.com/slippyex/ftp-sync.git
   cd ftp-sync
   npm install
   ```

2. Create a `config.json` with your paths and the FTP credentials from the community:
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
   > 💡 Ask in the [Facebook group](https://www.facebook.com/groups/360493904888475/) for the current FTP credentials.

3. Run the sync:
   ```bash
   npm run sync config.json
   ```
   Press `s` to start syncing. Press `q` to exit when done.

4. Point the launcher's `PatchDirectory` in `launcher.config.json` to the `patchDir` from your ftp-sync config.

---

## 🛠️ Developers

### 📋 Prerequisites

- [.NET SDK 10](https://dotnet.microsoft.com/download/dotnet/10.0)
- Windows: `build.cmd` / `start.cmd`
- Linux / macOS: `build.sh` / `start.sh` (run `chmod +x scripts/*.sh` first)

### 🔨 Build & Run

**Windows:**
```bat
scripts\build.cmd
scripts\start.cmd
```

**Linux / macOS:**
```bash
scripts/build.sh
scripts/start.sh
```

> ⚠️ Do **not** use `dotnet build` or `dotnet run` directly — always use the platform build script to ensure consistent output.

### 🧪 Demo Mode

`demo.sh` creates a complete test environment with fake ZIPs and two layers (root + patch), then launches the launcher:

```bash
scripts/demo.sh
```

This builds the project, generates a structured `.demo/` directory with sample folders and ZIPs, writes a matching `launcher.config.json`, and starts the launcher. Useful for quickly testing overlay behavior and navigation without setting up real game files.

> ⚠️ Windows is not supported for `demo.sh`. Use `start.cmd` with your own game files instead.

### 🚀 Release Process

Releases are automated via GitHub Actions (`.github/workflows/release.yml`).

**To create a release:**

You can use the `/create-release` command (via opencode) for a fully automated flow:

```text
/create-release 1.0.0
```

This command validates the version, checks for uncommitted changes, generates a release summary from recent commits, creates a release commit with the summary as the commit message, tags it, and pushes — all in one step. The GitHub Action then builds platform ZIPs and creates the GitHub Release.

**Manual release:**
1. Ensure `README.md` and `AGENTS.md` are up to date.
2. Commit all changes.
3. Tag and push:
   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```
4. The workflow builds platform ZIPs, generates release notes, and creates a GitHub Release.

---

## 🗺️ Roadmap

| Version | Feature |
|---|---|
| 2.0 | ZIP database & metadata extraction |
| 2.0 | Quicksearch / filter over ZIPs |
| 2.0 | History of recently launched games |
| 3.0 | Overlay hot-swap at runtime |

**Not planned:** Configurable keybindings, screenshot/cover display, sound/music integration, persistent UI settings.

---

## 📝 Notes

- Full technical requirements and build rules are in [`AGENTS.md`](AGENTS.md).
- After any functional change, both `README.md` and `AGENTS.md` must be updated.
- Every release **must** include release notes listing all changes and bugfixes.

---

## License

Licensed under the [MIT License](LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
