# PLAN

Ziel: Das Repo aufräumen (Doku, Code, Config)

## 1. Code-Qualität – Schwächen beheben (harmlos, rein refaktoriell)

- [x] **LauncherApp.cs zerlegen:** Die ~300-Zeilen-Klasse in separate Klassen aufteilen
  (InputController.cs extrahiert mit Key-Handling + ReloadGameEntries; Lifecycle & Main-Loop bleiben in AppHost).
  Ziel: keine Funktionsänderung, nur Struktur.
- [ ] **Magische Strings entfernen / zentralisieren (nur im Code, siehe 2c):**
  - [x] Virtueller Ordnername `"Favorites"` → `FavoritesService.FavoritesRootName` Konstante (nicht konfigurierbar).
  - [x] Dateiname `"favorites.txt"` → `FavoritesService.DefaultFileName` Konstante (nicht konfigurierbar).
  - [x] Console-Titel `"Marcer GameDVD Launcher"` (Program.cs) → `DefaultTitle` Konstante (nicht konfigurierbar).
  - [x] Default-ArgsTemplate `-c "{cfg}" --disk-a "{zip}"` (LauncherApp.cs) → redundanten Fallback entfernt; Config liefert das Template (Validation `{zip}` existiert schon).
- [x] **Scroll-Trigger magische Zahlen** (NavigationController.cs: `2/3`, `1/3`) in benannte Konstanten
      (`BottomScrollFraction = 2.0/3.0`, `TopScrollFraction = 1.0/3.0`) mit Kommentar aufzählen.
  - [x] Redundanz beseitigen: `RedrawEntry` — überflüssige `maxRow`-Logik entfernt, `EnsureCacheForRow` durch `EnsureCache` ersetzt (klare Formulierung).
- [x] **Fehler-Schlucken besprechen:** `FavoritesService.Save()` (catch leer) — Kommentar korrigiert ("bewusst still", erklärt warum Persistence-Fehler nicht zum Absturz führen); `UIErrorService` — DocComment erweitert (Fehler werden gezeigt, nicht regeworfen, App bleibt im Loop).
- [ ] (Optional) Testprojekt hinzufügen für NavigationController & OverlayDirectoryBrowser –
      vorab mit Nutzer klären, da Policy bisher keine Tests vorsieht.

---

## 2. Hardcoded-Werte – Aufgaben

### 2a. Colorschema konfigurierbar machen (entschieden)

- Aktuell: `MenuRenderer.cs` (`GetColorForEntry`) und README/agents-Doku (6 Entry-Typen +
  Auswahl-Schema schwarz/blau).
- Ziel: Farben (Foreground pro Entry-Typ + Selection-Farben) in `launcher.config.json` konfigurierbar
  machen (**Entscheidung: ja, konfigurierbar**), mit Default-Fallback auf heutige Werte.

- [x] `AppConfig` erweitern: neuen Abschnitt `"Colors"` hinzugefügt:
      - [x] POCO `AppColorConfig` mit `ConsoleColor`-Werten (als String, z.B. `"Yellow"`):
            FolderBoth, FolderPatchOnly, FolderRootOnly, ZipBoth, ZipRootOnly, ZipPatchOnly,
            SelectedForeground, SelectedBackground, VirtualEntry.
      - [x] Deserialisierung per `Enum.TryParse<ConsoleColor>` + Default-Fallback (manuell via `ParseAppColors`/`ParseColorField`).
      - [x] `MenuRenderer` bekommt `AppColorConfig` via Konstruktor-Injection; `GetColorForEntry`/`GetColors` nutzen Config statt Konstanten.
      - [x] Falls Config-Werte fehlen → heutiges Verhalten beibehalten (fallback).
- [x] Doku synchronisiert: README + AGENTS.md Farbtabellen auf Config-Felder verlinkt.
- [x] Beispielwerte ins `launcher.config.example.json` aufgenommen.

### 2b. Benutzer-Config (User-Config) – entschieden

Ziel: die echte lokale Config gehört NICHT ins Repo, sondern bleibt lokal.

- [x] **Entscheidung getroffen (Variante 1):** `launcher.config.json` bleibt im Build-Output/EXE-Ordner (lokal, gitignored). Die `launcher.config.example.json` wird beim Release mitgeliefert und der Nutzer kopiert sie manuell zu `launcher.config.json`.
- [x] KEINE zusätzliche Suchreihenfolge (`%APPDATA%`, `~/.config`) implementiert — Pfad ist ausschließlich `AppContext.BaseDirectory`.
- [x] KEIN CLI-Parameter `--config` eingeführt.
- [x] `.gitignore` ergänzt: `launcher.config.json` und `favorites.txt` werden nie committet.
- [x] README: Abschnitt „Configuration" beschreibt manuelles Kopieren der example.

### 2c. Platzhalterwerte zentralisieren (sehr detailliert)

**Was bedeutet das Problem?**
Einige Werte stehen direkt („hartkodiert") im Code statt an einer zentralen Stelle. Bei Wiederverwendung
oder Änderung des Verhaltens sucht man sie an mehreren Stellen im Quelltext — und es passieren schnell
Inkonsistenzen. Die folgenden Werte sind betroffen:

| # | Wert | Aktuelle Stelle | Was es tut | Geplanter Fix |
|---|------|-----------------|------------|---------------|
| 1 | `"Favorites"` | `LauncherApp.cs` (2×) | Virtueller Ordnername, der dem Nutzer als Eintrag an der Wurzel angezeigt wird. Wenn zwei voneinander abweichende Literale im Codestand bleiben, funktioniert Enter/Anzeige dieses Ordners nicht mehr. | Eine einzige Konstante `const string FavoritesRootName = "Favorites";` (z.B. in `FavoritesService`); beide Verwendungen darauf zurückführen. **Nur Code-Konstante, nicht konfigurierbar.** |
| 2 | `"favorites.txt"` | `LauncherApp.cs` | Dateiname der Favoriten-Persistenz (liegt im Patch-Dir oder neben EXE). | Konstante im `FavoritesService` (z.B. `public const string DefaultFileName = "favorites.txt";`); Aufrufer nutzen diese statt Literal. **Nur Code-Konstante, nicht konfigurierbar.** |
| 3 | `"Marcer GameDVD Launcher"` | `Program.cs` (`Console.Title`) | Konsolen-Titel, der im Fenstertitel erscheint. | Konstante `const string DefaultTitle = "Marcer GameDVD Launcher";` (Nutzer-visible, aber **nicht konfigurierbar** — fixer Anzeige-Titel). |
| 4 | Default-ArgsTemplate `-c "{cfg}" --disk-a "{zip}"` | `LauncherApp.cs` | Redundanter Fallback, falls `Hatari.ArgsTemplate` in der Config nicht gesetzt ist. Ist bereits in der example definiert → das Hardcode ist nur ein Sicherheitsnetz. | Redundanz entfernen: Fallback streichen und erzwingen, dass die Config den Template liefert (Validation `{zip}` existiert schon). **Config-Feld bleibt die einzige Quelle.** |
| 5 | Scroll-Anteile `2/3` und `1/3` | `NavigationController.cs` | Bestimmt, ab welcher relativen Position im sichtbaren Fenster automatisch gescrollt wird (Cursor bei 2/3 unten → scrollen, bei 1/3 oben → zurückscrollen). | Benannte Konstanten `BottomScrollTriggerFraction = 2f/3f` und `TopScrollTriggerFraction = 1f/3f` mit Kommentar; Logik bleibt identisch. **Nur Code-Konstanten, nicht konfigurierbar.** |
| 6 | `WindowHeight - 1` / `WindowWidth` | `LauncherApp.cs` / `MenuRenderer.cs` | Die Liste ist immer eine Zeile weniger als die Konsolenhöhe (Policy, verhindert Auto-Scroll am Fensterrand). Wird an mehreren Stellen erneut berechnet. | Zentrale Helfer-Berechnung (z.B. statische Methode/Property `AvailableLines`), damit die Policy an genau einer Stelle kodiert ist; Logik unverändert (Resize-Handling bleibt). **Nur Code, nicht konfigurierbar.** |
| 7 | `STD_INPUT_HANDLE = -10`, `VK_RETURN = 0x0D` | `ProgramHelpers.cs` | Win32-Konstanten für FlushConsoleInputBuffer bzw. GetAsyncKeyState. Diese sind per Definition konstant. | KEINE Änderung nötig — nur per Kommentar als „bewusst hartkodiert" markieren (Win32-API-Konstanten). |

**Entscheidung:** Alle o.g. Werte werden **nur im Code zentralisiert** (Konstanten/Helfer).
Sie werden **NICHT** als Konfigurationsfelder in `launcher.config.json` angeboten — es gibt keine
externe Anpassungsmöglichkeit dafür.

**Verbindliche To-dos für 2c:**

- [x] Konstanten/Helfer eingeführt für: `FavoritesRootName` (FavoritesService), `DefaultFileName` (FavoritesService), `DefaultTitle` (Program), `BottomScrollFraction`/`TopScrollFraction` (NavigationController), `AvailableLines`-Helfer (ProgramHelpers).
- [x] Default-ArgsTemplate-Fallback entfernt; Config muss `ArgsTemplate` immer liefern (Validation existiert bereits).
- [x] Alle String-Literale auf Konstanten zurückgeführt (kein doppeltes `"Favorites"` mehr — nur die Konstantendefinition).
- [x] Kommentare ergänzt, die erklären, WARUM Werte fest sind (`AvailableLines` als Policy, Win32-Konstanten als API-konstant, Scroll-Anteile als feste Navigation).
- [x] Win32-Konstanten (Punkt 7) NICHT angefasst, nur per Kommentar als „bewusst hartkodiert" markiert.
- [x] README/agents nicht um diese rein implementativen Werte erweitert (keine Config-Felder dokumentiert);
      Doku bleibt bei nutzersichtbaren, konfigurierbaren Werten (Farben, Titel, RootDir/Patch/Hatari).

---

## 4. Abschlusskriterien

- [ ] Commit mit aussagekräftiger Message (nur echter Autor, kein Co-Author).
- [ ] Nach Doku- und Code-Änderungen: `scripts/build.cmd` (Windows) bzw. `scripts/build.sh` (Linux) läuft fehlerfrei.
