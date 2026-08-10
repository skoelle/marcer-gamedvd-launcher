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

| Entry | Label | Color | Meaning |
|---|---|---|---|
| Folder in both layers | `[BOTH]` | Yellow | Exists in main + patch |
| Patch-only folder | `[PTCH]` | DarkYellow | Only in patch layer |
| Main-only folder | `[ROOT]` | Gray | Only in main layer |
| ZIP in both layers | `[BOTH]` | Green | Exists in main + patch |
| Main-only ZIP | `[ROOT]` | DarkGreen | Only in main layer |
| Patch-only ZIP | `[PTCH]` | Magenta | Only in patch layer |

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

### 🚀 Release Process

Releases are automated via GitHub Actions (`.github/workflows/release.yml`).

**To create a release:**
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
