# SPEC — Marcer GameDVD Launcher

Technology-neutral behavioral specification of the launcher.

The purpose of this document is to allow a **1:1 reimplementation** of the tool in
any programming language and with any presentation technology (terminal/CLI, desktop
GUI, web UI, ...). It describes *what the application does*, not *how it is built*.

- Implementation reference: `apps/marcer_console/` (C#/.NET, terminal UI)
- User-facing documentation: `README.md`
- Development policy: `AGENTS.md`

A conforming implementation must satisfy the **Conformance Checklist** in section 17.

---

## 1. Purpose & Scope

### 1.1 Problem

Users hold an archive of Atari ST games (ZIP files) organized in folders, typically
spread across two directories:

- a **root directory** (the "game DVD" content) and
- an **optional patch directory** (updated files/folders from a community mirror).

The launcher presents both directories as a single merged, navigable tree and starts
the selected game in the Hatari emulator.

### 1.2 In scope

- Merging two directory trees into one virtual listing (overlay/patch mode).
- Keyboard/pointer-driven navigation confined to the root directory.
- Remembering the selection position per directory.
- Marking ZIP files as favorites, persisted across sessions.
- Launching an external emulator process with a templated argument string.
- Configurable color scheme and configurable directory/emulator paths.

### 1.3 Out of scope (non-goals)

- Any file management (copy, move, delete, rename, extract).
- Network access, updates, sync (patch syncing is done by an external tool).
- Configurable keybindings.
- Screenshot/cover art display, sound/music.
- Persistent UI settings (window size, theme beyond colors).
- Reading or validating the *contents* of ZIP archives (current version).

### 1.4 Terminology note

"CLI"/"console" in this document means *any full-screen list-based UI surface*.
Where behavior depends on the surface (e.g. resizing), the UI Contract (section 4)
defines what the surface must provide.

---

## 2. Glossary

| Term | Meaning |
|---|---|
| **Root layer** | The directory tree under `RootDirectory`. |
| **Patch layer** | The directory tree under `PatchDirectory`. Absent when `PatchDirectory` is empty/missing. |
| **Overlay** | The merged view of root + patch layer at the current relative path. |
| **Entry** | One visible item in the overlay: a directory or a ZIP file. |
| **Virtual entry** | An entry not backed by the file system (only the `Favorites` pseudo-folder today). |
| **Relative path** | Path of the current directory relative to the layer root, `""` at root, `A/B` below. |
| **Layer status** | One of `BOTH`, `ROOT`, `PTCH` — which layers contain the entry. |
| **Favorites** | A persistent set of ZIP paths, shown as a virtual folder at the root. |
| **Emulator** | The external program (Hatari) started to run a game. |
| **Surface** | The drawing area provided by the UI layer (see section 4). |

---

## 3. Architecture (technology-neutral)

The specification is organized in three logical layers. Any module decomposition is
acceptable as long as the behavior is preserved.

```
┌─────────────────────────────────────────────────────────┐
│ UI layer (CLI / desktop app / ...)                      │
│   implements the UI Contract (section 4)                │
├─────────────────────────────────────────────────────────┤
│ Application core                                        │
│   overlay resolution (7) · navigation state (8)         │
│   favorites model (11) · launch command building (12)   │
├─────────────────────────────────────────────────────────┤
│ Platform services                                       │
│   configuration (5) · file system access                │
│   favorites persistence (11) · process launching (12)   │
└─────────────────────────────────────────────────────────┘
```

Requirements on decomposition:

- **R1** — Overlay resolution, navigation state and favorites logic must not depend
  on the UI layer (they must be testable without a visible surface).
- **R2** — All rendering goes through the UI Contract; no other component may write
  to the surface directly (the help overlay and modal are part of the contract).
- **R3** — A single event loop is sufficient; no concurrency is required. While the
  emulator runs, the application is blocked (section 12).

---

## 4. UI Contract

Every conforming implementation must provide the following capabilities.

### 4.1 Surface metrics

| Capability | Rule |
|---|---|
| `width` | Current width of the surface in characters. |
| `height` | Current height of the surface in rows. |
| `availableLines` | **`max(0, height - 1)`** — exactly one row less than the height. |

**Rationale:** the last row must never be written. This prevents auto-scroll/flicker
on terminals and guarantees the selection never enters a non-visible area. This value
is the *single* page size used for rendering and paging everywhere.

**R4** — A change of `width` or `height` must trigger a full re-layout and full
redraw on the next loop iteration (no user key press required).

### 4.2 Drawing

| Capability | Contract |
|---|---|
| `drawLine(row, text, fg, bg)` | Write `text` (exactly `width` characters) at `row` (0-based) with the given foreground/background color. |
| `invalidateAll()` | Mark the whole surface as unknown, so the next draw rewrites every row. |
| `fullRedraw()` | Equivalent to invalidating and redrawing all rows of the current view. |

**R5** — Rows outside `[0, availableLines)` must never be written.
**R6** — The renderer must track the last state per row and write **only changed
rows** (diff rendering). A full clear + rewrite of all rows on every keystroke is
**not** conforming. After an overlay (help box, modal) has overwritten rows, the
cache must be invalidated so a full redraw follows.

### 4.3 Input events

The UI layer maps physical input to this abstract event set:

| Event | Terminal binding (reference) | Section |
|---|---|---|
| `MoveUp` | `↑` | 10 |
| `MoveDown` | `↓` | 10 |
| `PageUp` | `PageUp` | 10 |
| `PageDown` | `PageDown` | 10 |
| `Activate` | `Enter`, `→` | 10 |
| `Parent` | `Backspace`, `←` | 10 |
| `ToggleFavorite` | `*` | 10 |
| `Help` | `?` | 10 |
| `Exit` | `ESC`, `Q` | 10 |

**R7** — After each handled navigation event, buffered/repeated input must be
discarded where the platform allows it, so a held key does not produce an
"afterglow" of queued events. (Best effort; not required where the platform has no
input buffer.)

**R8** — A desktop implementation may add pointer input (click, double-click,
scroll) *in addition*; the event semantics above must remain unchanged. Key
bindings themselves are fixed (non-goal: configurable keybindings).

### 4.4 Modals

| Capability | Contract |
|---|---|
| `showMessage(lines, color)` | Display one or more lines, wait for a single key press, then restore the previous view (full redraw). |
| `showModalUntilProcessExited(text, processHandle)` | Center a one-line modal, **block** until the process exits, remove the line, restore the view. |
| `showHelpOverlay()` | Display the help box (content in section 9.4), wait for a key, then restore the view (full redraw). |

**R9** — Error messages are *modal and non-fatal*: after dismissal, the application
returns to the navigation loop in the same directory.

---

## 5. Configuration

### 5.1 File

- File name: `launcher.config.json`, located in the **application directory**
  (the directory of the executable).
- Format: JSON. A template named `launcher.config.example.json` ships with the app.
- The file is read **once at startup**; changes require a restart.
- Field names are matched case-insensitively, except the `Colors` section and its
  fields, which are looked up by their exact names (an unrecognized name simply
  leaves the default in place — see R19).

> JSON here is an interchange format choice of the reference implementation, not a
> language requirement. Any implementation must accept this exact structure (or an
> equivalent with identical field names) so configs stay interchangeable.

### 5.2 Schema

```json
{
  "RootDirectory": "C:\\Games\\Hatari\\ROMS",
  "PatchDirectory": "C:\\Games\\Hatari\\PATCH",
  "Hatari": {
    "Executable": "C:\\Tools\\hatari\\hatari.exe",
    "ConfigFile": "",
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

| Field | Required | Semantics |
|---|---|---|
| `RootDirectory` | ✅ | Game root. Navigation must never leave it. |
| `PatchDirectory` | ❌ | Optional overlay layer. Empty/missing ⇒ **no patch layer at all** (never implicitly points at the app directory or any other folder). |
| `Hatari.Executable` | ✅ | Path to the emulator binary. Validated at startup. |
| `Hatari.ConfigFile` | ❌ | Emulator config file. Empty ⇒ the bundled `MarcerGameDvd-Hatari.cfg` is used automatically. |
| `Hatari.ArgsTemplate` | ✅ | Argument template; **must contain `{zip}` and `{cfg}`**. |
| `Colors` | ❌ | Optional color overrides; see section 9.3. |

### 5.3 Path resolution

**R10** — Every path field is resolved as follows: if it is relative, it is resolved
against the **application directory**; if absolute, it is used as-is; empty/null
stays empty.

### 5.4 Startup validation

The following must be checked before entering the navigation loop. On failure the
application shows a clear message (naming the offending field/value) and exits; it
must not start with an invalid configuration.

1. Configuration file exists and parses; not empty/malformed.
2. `RootDirectory` set **and** the directory exists.
3. `Hatari` section present; `Executable` set and the file exists.
4. `Hatari.ConfigFile`, if non-empty, exists.
5. `Hatari.ArgsTemplate` contains `{cfg}` **and** `{zip}`.

---

## 6. Data Model

### 6.1 Entry

| Field | Type | Meaning |
|---|---|---|
| `Name` | string | File/directory name including extension (e.g. `Pac-Man.zip`). |
| `Kind` | `Directory` \| `Zip` | Entry type. |
| `InRoot` | bool | Present in the root layer. |
| `InPatch` | bool | Present in the patch layer. |
| `RootPath` | string | Absolute path within the root layer. |
| `PatchPath` | string | Absolute path within the patch layer (empty if no patch layer). |
| `IsVirtual` | bool | Not file-system backed (the `Favorites` folder). |

**Effective path** — the path used for launching/favoriting:
`InPatch ? PatchPath : RootPath` (**patch always wins**).

### 6.2 Derived values

- **Layer status:** `InRoot && InPatch` → `BOTH`; `InPatch` only → `PTCH`;
  `InRoot` only → `ROOT`.
- **Is favorite:** `Kind == Zip && favorites.contains(effectivePath)`.

---

## 7. Overlay Resolution

Performed for the current relative path whenever entries are (re)loaded — i.e. at
startup, on `Activate` into a directory, and on `Parent`. **Not** on every loop tick.

### 7.1 Algorithm

1. **Sanitize** the relative path: strip leading separators; if it is absolute or
   contains a `..` segment → reset to `""`.
2. Compute `rootPath = normalize(root + rel)`; if it is not inside `root`, use
   `root` itself. Same for `patchPath` when a patch layer exists.
3. Enumerate **directories** in `rootPath` and `patchPath`, excluding entries with
   the *hidden* attribute.
4. Enumerate **files ending in `.zip`** (case-insensitive) in both, excluding
   hidden entries.
5. All other file types (PDF, TXT, ...) and hidden entries are **ignored**.
6. Build the union of directory names and the union of ZIP names, each compared
   **case-insensitively**.
7. Sort each union **case-insensitively ascending**.
8. Emit **all directories first**, then all ZIPs; each entry carries its layer flags
   and both candidate paths.

### 7.2 Rules

- **R11** — The merge is applied at **every level**, recursively: the same relative
  path resolves against both layers, so navigation is symmetric in both directions.
- **R12** — Each name appears **exactly once** per listing. Name equality is
  case-insensitive: a root file `Foo.zip` and a patch file `FOO.zip` are the
  same entry (both layer flags set), not two. Which of the two spellings is
  displayed is implementation-defined; launching still resolves the patch
  location per R14.
- **R13** — No patch layer configured ⇒ every entry is `ROOT` and patch paths are empty.
- **R14** — A directory or ZIP present in both layers is opened/launched from the
  **patch** location.
- **R15** — File system errors during enumeration surface as a modal error; the view
  then shows an empty list (navigation loop continues).

### 7.3 Security / confinement

- **R16** — It must be impossible to reach any path outside `RootDirectory`
  (and outside `PatchDirectory` for patch-side lookups), regardless of input.
- **R17** — `Root`-level `Parent` is a **no-op**: no error, no exit, no state change.

---

## 8. Navigation & State

### 8.1 State

| State | Meaning |
|---|---|
| `currentRelativePath` | Current directory (`""` = root). |
| `selectedIndex` | Index of the selected entry in the full entry list. |
| `scrollOffset` | Index of the first visible entry. |
| `lastSelections` | Map *relative path → (selectedIndex, scrollOffset)*, remembered per visited directory for the session. |

### 8.2 Page size

`availableLines = max(0, height - 1)` (section 4.1). If the platform reports a
degenerate surface, use at least 1 line for internal math.

### 8.3 Movement

| Event | Behavior |
|---|---|
| `MoveUp` | `selectedIndex--`, clamp at 0. |
| `MoveDown` | `selectedIndex++`, clamp at `count-1`. |
| `PageUp` | `selectedIndex -= availableLines`, clamp at 0. |
| `PageDown` | `selectedIndex += availableLines`, clamp at `count-1`. |
| Empty list | All movement events are no-ops. |

### 8.4 Scrolling (1/3–2/3 rule)

Let `F_bottom = 2/3`, `F_top = 1/3` (fixed, not configurable).

```
if count <= availableLines:        scrollOffset = 0
else if selectedIndex == 0:        scrollOffset = 0
else:
  bottomTrigger = scrollOffset + floor(availableLines * 2/3)
  topTrigger    = scrollOffset + floor(availableLines * 1/3)
  if selectedIndex >= bottomTrigger and scrollOffset + availableLines < count:
      scrollOffset = selectedIndex - floor(availableLines * 2/3)
  else if selectedIndex < topTrigger and scrollOffset > 0:
      scrollOffset = selectedIndex - floor(availableLines * 1/3)
  scrollOffset = clamp(scrollOffset, 0, count - availableLines)
```

**R18** — The selection is always visible; `scrollOffset <= selectedIndex < scrollOffset + availableLines`.

### 8.5 Directory changes

- **`Activate` on a directory:** save `(selectedIndex, scrollOffset)` under the
  current path; append the name to `currentRelativePath`; restore the remembered
  state for the new path, else reset to `(0, 0)`; reload entries.
- **`Parent`:** if at root → no-op (R17). Otherwise save state, drop the last path
  segment, restore remembered state or `(0, 0)`, reload entries.
- **`SetEntriesCount` on reload:** if `selectedIndex` is out of range → reset to
  `(0, 0)`; clamp `scrollOffset` to `max(0, count-1)`.
- The remembered state map is **session-only** (never persisted) and is keyed by
  relative path — the same path in root-only vs. patch-only contexts is one key.

---

## 9. Rendering & Layout

### 9.1 Line format

Every visible row is exactly `width` characters:

```
[ 7 chars layer label ][ 6 chars type field ][ name ][ padding ]
└──────────── 13 characters ────────────┘
```

- **Layer label** (7 chars): `"[BOTH] "`, `"[PTCH] "`, `"[ROOT] "`, or `"       "`.
- **Type field** (6 chars): `"[DIR] "` for directories; for ZIPs `"    * "` when it
  is a favorite, otherwise `"      "`.
- **Name:** if it does not fit, truncate with `"..."` (needs > 3 remaining chars,
  else hard truncate).
- Truncate the whole line if the surface is narrower than the 13-char prefix.
- Pad with spaces to exactly `width`; never write beyond `width`.
- **Virtual entries** (the `Favorites` folder) render exactly like a normal
  directory (`[ROOT] [DIR] `, since they are flagged `InRoot = true`) — they are
  recognized by `IsVirtual` for coloring only, and by name for activation.

### 9.2 Selection

The selected row is drawn with `SelectedForeground` on `SelectedBackground`;
all other rows use their entry color on a black background.

### 9.3 Color scheme (defaults)

| Situation | Field | Default |
|---|---|---|
| Folder in both layers | `FolderBoth` | Yellow |
| Folder only in patch | `FolderPatchOnly` | DarkYellow |
| Folder only in root | `FolderRootOnly` | Gray |
| ZIP in both layers | `ZipBoth` | Green |
| ZIP only in root | `ZipRootOnly` | DarkGreen |
| ZIP only in patch | `ZipPatchOnly` | Magenta |
| Selected entry (fg) | `SelectedForeground` | Black |
| Selected entry (bg) | `SelectedBackground` | DarkCyan |
| Virtual entry | `VirtualEntry` | White |

**R19** — Color values are symbolic names from the reference palette
(16 standard console colors: `Black, DarkBlue, DarkGreen, DarkCyan, DarkRed,
DarkMagenta, DarkYellow, Gray, DarkGray, Blue, Green, Cyan, Red, Magenta,
Yellow, White`), matched case-insensitively. An invalid or missing value falls
back to the default for that field; a missing `Colors` section falls back entirely
to the defaults. Color parsing errors must never crash the application.

### 9.4 Help overlay

Toggled by `Help`; displayed centered (full width, vertically centered within
`availableLines`, no border) with `DarkGray` background / `White` text; any key
dismisses it, then the list is fully redrawn.

```
  Help — Key Bindings

   ↑ / ↓          Move selection up / down
   PgUp / PgDn    Jump one page up / down
   Enter / →      Open folder / launch ZIP with Hatari
   *              Toggle favorite on selected ZIP
   ← / Backspace  Go up one directory (never exceeds root)
   ?              Show this help
   ESC / q        Exit the program

  Navigation is strictly limited to RootDirectory.
  The overlay shows both root and patch layers combined.

  Press any key to continue...
```

### 9.5 Redraw policy

- **R20** — Moving the selection within the visible window redraws **only the two
  affected rows** (old and new selection). Scrolling redraws the affected rows /
  full view as needed — but never the whole surface unnecessarily.
- **R21** — No `Clear` of the surface during normal navigation.
- **R22** — After a modal/overlay or after the emulator exits, the cache is
  invalidated and the view is fully redrawn.
- **R23** — The cursor must be hidden while the list is displayed (where the
  platform supports it).

---

## 10. Input Mapping

| Event | Condition | Action |
|---|---|---|
| `MoveUp` / `MoveDown` | always | Move selection (8.3), scroll (8.4), partial redraw |
| `PageUp` / `PageDown` | always | Jump one page, full redraw of view |
| `Activate` | selected entry is a **directory** | Enter directory (8.5), reload, redraw |
| `Activate` | selected entry is a **ZIP** | Launch (12), then full redraw |
| `Activate` | list empty | no-op |
| `Parent` | at root | no-op (R17) |
| `Parent` | below root | Go up (8.5), reload, redraw |
| `ToggleFavorite` | selected entry is a ZIP | Toggle (11.2), full redraw |
| `ToggleFavorite` | directory / empty list | no-op |
| `Help` | always | Show help overlay (9.4), redraw after |
| `Exit` | always | Terminate the application |

**R24** — A ZIP whose effective path no longer exists is **not** launched; a modal
error `ZIP file not found: <path>` is shown, then the view is redrawn.

---

## 11. Favorites

### 11.1 Storage

- File name: `favorites.txt`.
- Location: inside `PatchDirectory` if configured, otherwise the application directory.
- Encoding: UTF-8, **one absolute path per line**, sorted case-insensitively.
- Loaded once at startup. Missing file ⇒ empty set. Unparseable lines are skipped.
- Persisted **immediately on every toggle**.

### 11.2 Toggle semantics

- `Toggle(path)` on a non-favorite adds it; on a favorite removes it; then saves.
- Paths are normalized (absolute) before comparison; matching is case-insensitive.
- **R25** — A save failure (read-only media, disk full) must **not** crash or
  interrupt the UI: the in-memory state stays updated, only the disk write is lost.

### 11.3 Virtual `Favorites` folder

- Displayed **only** at root, **only** when at least one favorite exists, and always
  as the **first** entry.
- Name: `Favorites` (fixed).
- `Activate` on it opens a flat list of the favorited ZIPs, each shown with its
  file name, ordered case-insensitively by stored full path.
- Selecting an entry there launches the stored absolute path.
- Leaving it (`Parent`) returns to root.
- **R26** — Favorite state is keyed by the ZIP's **effective path** (patch path when
  the entry exists in the patch layer, else root path).

---

## 12. Game Launch

### 12.1 Command construction

```
args = ArgsTemplate
args = args.replace("{cfg}", ConfigFile != "" ? ConfigFile
                                             : <working directory>/MarcerGameDvd-Hatari.cfg)
args = args.replace("{zip}", effectiveZipPath)
start process: executable = Hatari.Executable, arguments = args,
               workingDirectory = <current working directory of the launcher>
```

- `{zip}` and `{cfg}` are plain literal replacements (no shell interpretation).
- The emulator config file `MarcerGameDvd-Hatari.cfg` ships with the application and
  is the fallback whenever `Hatari.ConfigFile` is empty; it is resolved relative to
  the launcher's current working directory. The bundled file expects the TOS ROM
  (`TOS.IMG`) to be present in that directory (see README).
- **Desktop extension (optional):** a desktop implementation may offer additional
  launch *variants* that append extra emulator arguments after the template (e.g.
  `--monitor mono`, `--machine ste`) and select a different TOS image
  (e.g. `TOS162.IMG`/`TOS102.IMG`); the base construction above is unchanged.

### 12.2 Blocking behavior

- **R27** — While the emulator runs, show the centered modal
  `Hatari is running...` (DarkGray/White) and **block** until the process exits;
  then remove the modal and fully redraw the list.
- **R28** — Launch failures are reported as a modal error; the application continues
  in the same directory.

---

## 13. Error Handling & Edge Cases

| # | Situation | Required behavior |
|---|---|---|
| E1 | Config file missing/malformed | Message + exit (5.4). |
| E2 | `RootDirectory` missing | Message + exit. |
| E3 | Emulator executable missing | Message + exit. |
| E4 | ArgsTemplate lacks `{zip}`/`{cfg}` | Message + exit. |
| E5 | Root directory has no children | Empty list displayed; movement is a no-op; no error. |
| E6 | `Parent` at root | No-op, no error, no exit. |
| E7 | ZIP path vanished at launch | Modal `ZIP file not found: ...`, view restored. |
| E8 | File system error while enumerating | Modal error, empty list, loop continues. |
| E9 | Favorites file unwritable | Silent: in-memory state updated, no crash (R25). |
| E10 | Invalid color name in config | Fall back to default color (R19). |
| E11 | Surface resized (any direction) | Re-layout + full redraw without key press (R4). |
| E12 | Paths with spaces / special chars | Must work (paths are passed as data, not shell-interpreted). |
| E13 | Very deep / large trees | Navigation stays correct and responsive; no per-tick file system access. |
| E14 | Relative path input containing `..` or absolute | Sanitized to root (7.1, R16). |

---

## 14. Startup & Lifecycle

```
1. Set application title/name (fixed: "Marcer GameDVD Launcher").
2. Load + validate configuration (5.3, 5.4)  ── error → message + exit.
3. Build services: overlay browser, navigation state, favorites (load),
   emulator launcher, renderer, error presenter.
4. Hide the cursor.
5. Load entries for the root directory; prepend the virtual Favorites folder
   if applicable (11.3).
6. Main loop:
     a. detect width/height change → refresh view (R4)
     b. if no input pending → idle wait (short sleep) and repeat
     c. read one input event → dispatch (10) → redraw as required
     d. on Exit → terminate cleanly
```

**R29** — The loop must never perform file system enumeration except on explicit
navigation events (startup, enter, parent).

---

## 15. Performance Requirements

- **P1** — Diff-based drawing: only changed rows are written (R6, R20).
- **P2** — No full-screen clear during navigation (R21).
- **P3** — No file system access per loop iteration (R29).
- **P4** — Directory enumeration is per directory, not recursive over the whole tree;
  listing cost must not grow with the total size of the archive below the current
  directory.
- **P5** — Idle CPU use must be negligible (event-driven or short-sleep polling).

---

## 16. Roadmap (Future — not yet specified)

The following items are planned but **not** part of conformance. Implementations may
omit them; if implemented, they must not break sections 1–15.

| Version | Feature | Sketch |
|---|---|---|
| 2.0 | ZIP database & metadata extraction | Persist per-ZIP metadata; show additional columns/details. |
| 2.0 | Quicksearch / filter over ZIPs | Type-ahead filtering of the current listing. |
| 2.0 | History of recently launched games | Most-recent-first virtual folder. |
| 3.0 | Overlay hot-swap at runtime | Change/reload the patch layer without restarting. |

---

## 17. Conformance Checklist

A reimplementation is conforming when all statements hold.

**Configuration**
- [ ] C1 — `launcher.config.json` is read from the application directory; relative paths resolve against it (R10).
- [ ] C2 — Missing/invalid config, missing root, missing emulator, or a template without `{zip}`/`{cfg}` prevents startup with a clear message (5.4).
- [ ] C3 — Empty/missing `PatchDirectory` disables the patch layer entirely (R13).
- [ ] C4 — Invalid or missing color values fall back to defaults without crashing (R19).

**Overlay**
- [ ] C5 — Only directories and `.zip` files are listed; hidden and other files are ignored (7.1).
- [ ] C6 — Listings are: directories first, then ZIPs, each sorted case-insensitively (7.1).
- [ ] C7 — Each name appears exactly once; layer flags correctly reflect BOTH/ROOT/PTCH (R12).
- [ ] C8 — Opening/launching a name present in both layers uses the **patch** copy (R14).
- [ ] C9 — The merge applies at every depth; `Parent`/`Activate` are symmetric (R11).
- [ ] C10 — Navigation can never leave `RootDirectory` (R16).

**Navigation**
- [ ] C11 — Visible page size is `height - 1` everywhere (4.1).
- [ ] C12 — The 1/3–2/3 scroll rule holds exactly as in 8.4 (R18).
- [ ] C13 — `PageUp`/`PageDown` move by exactly one page, clamped at both ends.
- [ ] C14 — Selection & scroll position are remembered per directory within a session (8.5).
- [ ] C15 — `Parent` at root is a silent no-op (R17).
- [ ] C16 — Empty directories render correctly and swallow movement input.

**Rendering**
- [ ] C17 — Line layout matches 9.1 (13-char prefix, `...` truncation, exact width).
- [ ] C18 — Colors match 9.3 defaults and are configurable per field.
- [ ] C19 — Only changed rows are redrawn; no full clear during navigation (P1, P2).
- [ ] C20 — Help overlay shows the text of 9.4 and returns to a fully redrawn list.
- [ ] C21 — Resizing re-lays out and redraws without requiring a key press (R4).

**Input**
- [ ] C22 — All events of section 10 are implemented with the listed semantics.
- [ ] C23 — Favorites toggle only on ZIP entries; state persists across restarts (11).
- [ ] C24 — The virtual `Favorites` folder appears only at root, first, when non-empty (11.3).

**Launch**
- [ ] C25 — `{cfg}`/`{zip}` substitution and the bundled-config fallback match 12.1.
- [ ] C26 — The UI blocks with the running-modal until the emulator exits, then fully redraws (R27).
- [ ] C27 — A vanished ZIP produces the error modal instead of a launch (R24).

**Robustness**
- [ ] C28 — All behaviors of the error matrix (section 13) are satisfied.
- [ ] C29 — The core logic (sections 6–8, 11–12) is exercisable without a UI (R1).

---

## License

Licensed under the [MIT License](../LICENSE) - Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
