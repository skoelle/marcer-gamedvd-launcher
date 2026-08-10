# PLAN

Ziel: Das Repo aufräumen (Doku, Code, Config)

## 1. Code-Qualität – Schwächen beheben (harmlos, rein refaktoriell)

- [ ] **LauncherApp.cs zerlegen:** Die ~300-Zeilen-Klasse in separate Klassen aufteilen
  (z.B. `InputController`/`KeyHandler` für den switch-Block, Lifecycle bleibt in LauncherApp).
  Ziel: keine Funktionsänderung, nur Struktur.
- [ ] **Magische Strings entfernen / zentralisieren (nur im Code, siehe 2c):**
  - [ ] Virtueller Ordnername `"Favorites"` (LauncherApp.cs) → gemeinsame Konstante (nicht konfigurierbar).
  - [ ] Dateiname `"favorites.txt"` (LauncherApp.cs) → Konstante in FavoritesService (nicht konfigurierbar).
  - [ ] Console-Titel `"Hatari ZIP Launcher"` (Program.cs) → Konstante (nicht konfigurierbar).
  - [ ] Default-ArgsTemplate `-c "{cfg}" --disk-a "{zip}"` (LauncherApp.cs) → redundanten Fallback
        entfernen; Config liefert den Template (ist schon in der example definiert, Validation `{zip}` existiert).
- [ ] **Scroll-Trigger magische Zahlen** (NavigationController.cs: `2/3`, `1/3`) in benannte Konstanten
      (z.B. `BottomScrollFraction = 2f/3f`) mit Kommentar aufzählen.
  - [ ] Redundanz beseitigen: `RedrawEntry` hat unnötige `maxRow`-Logik; `EnsureCacheForRow` ungenau →
        klarer formulieren.
- [ ] **Fehler-Schlucken besprechen:** `FavoritesService.Save()` (catch leer) und `UIErrorService` –
      entweder Kommentar ergänzen („bewusst still") oder Rückgabewert einführen.
- [ ] (Optional) Testprojekt hinzufügen für NavigationController & OverlayDirectoryBrowser –
      vorab mit Nutzer klären, da Policy bisher keine Tests vorsieht.

---

## 2. Hardcoded-Werte – Aufgaben

### 2a. Colorschema konfigurierbar machen (entschieden)

- Aktuell: `MenuRenderer.cs` (`GetColorForEntry`) und README/agents-Doku (6 Entry-Typen +
  Auswahl-Schema schwarz/blau).
- Ziel: Farben (Foreground pro Entry-Typ + Selection-Farben) in `launcher.config.json` konfigurierbar
  machen (**Entscheidung: ja, konfigurierbar**), mit Default-Fallback auf heutige Werte.

- [ ] `AppConfig` erweitern: neuen Abschnitt z.B. `"Colors"` hinzufügen:
      - [ ] POCO `AppColorConfig` mit `ConsoleColor`-Werten (als String, z.B. `"Yellow"`):
            - FolderBoth, FolderPatchOnly, FolderRootOnly,
              ZipBoth, ZipRootOnly, ZipPatchOnly,
              SelectedForeground, SelectedBackground, VirtualEntry(vorab optional).
      - [ ] Deserialisierung per `Enum.TryParse<ConsoleColor>` + Default-Fallback.
      - [ ] `MenuRenderer` bekommt optional passende `AppColorConfig` (Konstruktor-Injection);
            `GetColorForEntry`/`GetColors` nutzen Config statt Konstanten.
      - [ ] Falls Config-Werte fehlen → heutiges Verhalten beibehalten (fallback).
- [ ] Doku synchronisieren: README + agents.md Farbtabellen auf Config-Felder verlinken.
- [ ] Beispielwerte ins `launcher.config.example.json` aufnehmen.

### 2b. Benutzer-Config (User-Config) – entschieden

Ziel: die echte lokale Config gehört NICHT ins Repo, sondern bleibt lokal.

- [ ] **Entscheidung getroffen (Variante 1):** `launcher.config.json` bleibt im Build-Output/EXE-Ordner
      (lokal, gitignored). Die `launcher.config.example.json` wird beim Release mitgeliefert und der
      Nutzer passt sie sich manuell an → kopieren zu `launcher.config.json`.
- [ ] KEINE zusätzliche Suchreihenfolge (`%APPDATA%`, `~/.config`) implementieren.
- [ ] KEIN CLI-Parameter `--config` einführen.
- [ ] `.gitignore` entsprechend ergänzen (echte `launcher.config.json` + `favorites.txt` werden nie committet).
- [ ] README: Abschnitt „Configuration" beschreibt nur das manuelle Kopieren der example.

### 2c. Platzhalterwerte zentralisieren (sehr detailliert)

**Was bedeutet das Problem?**
Einige Werte stehen direkt („hartkodiert") im Code statt an einer zentralen Stelle. Bei Wiederverwendung
oder Änderung des Verhaltens sucht man sie an mehreren Stellen im Quelltext — und es passieren schnell
Inkonsistenzen. Die folgenden Werte sind betroffen:

| # | Wert | Aktuelle Stelle | Was es tut | Geplanter Fix |
|---|------|-----------------|------------|---------------|
| 1 | `"Favorites"` | `LauncherApp.cs` (2×) | Virtueller Ordnername, der dem Nutzer als Eintrag an der Wurzel angezeigt wird. Wenn zwei voneinander abweichende Literale im Codestand bleiben, funktioniert Enter/Anzeige dieses Ordners nicht mehr. | Eine einzige Konstante `const string FavoritesRootName = "Favorites";` (z.B. in `FavoritesService`); beide Verwendungen darauf zurückführen. **Nur Code-Konstante, nicht konfigurierbar.** |
| 2 | `"favorites.txt"` | `LauncherApp.cs` | Dateiname der Favoriten-Persistenz (liegt im Patch-Dir oder neben EXE). | Konstante im `FavoritesService` (z.B. `public const string DefaultFileName = "favorites.txt";`); Aufrufer nutzen diese statt Literal. **Nur Code-Konstante, nicht konfigurierbar.** |
| 3 | `"Hatari ZIP Launcher"` | `Program.cs` (`Console.Title`) | Konsolen-Titel, der im Fenstertitel erscheint. | Konstante `const string DefaultTitle = "Hatari ZIP Launcher";` (Nutzer-visible, aber **nicht konfigurierbar** — fixer Anzeige-Titel). |
| 4 | Default-ArgsTemplate `-c "{cfg}" --disk-a "{zip}"` | `LauncherApp.cs` | Redundanter Fallback, falls `Hatari.ArgsTemplate` in der Config nicht gesetzt ist. Ist bereits in der example definiert → das Hardcode ist nur ein Sicherheitsnetz. | Redundanz entfernen: Fallback streichen und erzwingen, dass die Config den Template liefert (Validation `{zip}` existiert schon). **Config-Feld bleibt die einzige Quelle.** |
| 5 | Scroll-Anteile `2/3` und `1/3` | `NavigationController.cs` | Bestimmt, ab welcher relativen Position im sichtbaren Fenster automatisch gescrollt wird (Cursor bei 2/3 unten → scrollen, bei 1/3 oben → zurückscrollen). | Benannte Konstanten `BottomScrollTriggerFraction = 2f/3f` und `TopScrollTriggerFraction = 1f/3f` mit Kommentar; Logik bleibt identisch. **Nur Code-Konstanten, nicht konfigurierbar.** |
| 6 | `WindowHeight - 1` / `WindowWidth` | `LauncherApp.cs` / `MenuRenderer.cs` | Die Liste ist immer eine Zeile weniger als die Konsolenhöhe (Policy, verhindert Auto-Scroll am Fensterrand). Wird an mehreren Stellen erneut berechnet. | Zentrale Helfer-Berechnung (z.B. statische Methode/Property `AvailableLines`), damit die Policy an genau einer Stelle kodiert ist; Logik unverändert (Resize-Handling bleibt). **Nur Code, nicht konfigurierbar.** |
| 7 | `STD_INPUT_HANDLE = -10`, `VK_RETURN = 0x0D` | `ProgramHelpers.cs` | Win32-Konstanten für FlushConsoleInputBuffer bzw. GetAsyncKeyState. Diese sind per Definition konstant. | KEINE Änderung nötig — nur per Kommentar als „bewusst hartkodiert" markieren (Win32-API-Konstanten). |

**Entscheidung:** Alle o.g. Werte werden **nur im Code zentralisiert** (Konstanten/Helfer).
Sie werden **NICHT** als Konfigurationsfelder in `launcher.config.json` angeboten — es gibt keine
externe Anpassungsmöglichkeit dafür.

**Verbindliche To-dos für 2c:**

- [ ] Konstanten/Helfer einführen für: Favorites-Ordnername, `favorites.txt`, Konsolen-Titel,
      Scroll-Anteile, `AvailableLines`-Helfer.
- [ ] Default-ArgsTemplate-Fallback entfernen; Config muss `ArgsTemplate` immer liefern.
- [ ] Alle vorkommenden String-Literale auf die neuen Konstanten zurückführen (kein doppeltes `"Favorites"` mehr).
- [ ] Kommentare ergänzen, die erklären, WARUM der Wert fest ist (z.B. `WindowHeight-1` als Policy).
- [ ] Win32-Konstanten (Punkt 7) NICHT anfassen, nur per Kommentar als „bewusst hartkodiert" markieren.
- [ ] README/agents nicht um diese rein implementativen Werte erweitern (keine Config-Felder dokumentieren);
      Doku bleibt bei nutzersichtbaren, konfigurierbaren Werten (Farben, Titel, RootDir/Patch/Hatari).

---

## 4. Abschlusskriterien

- [ ] Commit mit aussagekräftiger Message (nur echter Autor, kein Co-Author).
- [ ] Nach Doku- und Code-Änderungen: `build.cmd` (Windows) bzw. `build.sh` (Linux) läuft fehlerfrei.
