namespace MarcerGameDvdLauncher
{
    // Encapsulates application lifecycle: load config, initialize components, run navigation
    public class LauncherApp
    {
        public AppConfig? Configuration { get; private set; }

        public void Run()
        {
            try
            {
                Configuration = LoadConfiguration();
            }
            catch (Exception ex)
            {
                ProgramHelpers.ShowConsoleMessage(["Error loading configuration: " + ex.Message, "Please place a valid launcher.config.json in the same folder as the EXE.", "Press any key to exit."
                ], ConsoleColor.Red);
                return;
            }

            // Setup required components
            var appHost = new AppHost(Configuration);
            appHost.InitializeComponents();
            appHost.RunDirectoryNavigation();
        }

        private AppConfig LoadConfiguration()
        {
            string exeDir = AppContext.BaseDirectory;
            string configPath = Path.Combine(exeDir, "launcher.config.json");
            if (!File.Exists(configPath))
                throw new FileNotFoundException($"Configuration file not found: {configPath}");

            string json = File.ReadAllText(configPath);
            var options = new System.Text.Json.JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            };
            var cfg = System.Text.Json.JsonSerializer.Deserialize<AppConfig>(json, options);
            if (cfg == null)
                throw new InvalidOperationException("Invalid configuration file (empty or malformed)");
            if (string.IsNullOrWhiteSpace(cfg.RootDirectory))
                throw new InvalidOperationException("RootDirectory must be set in the configuration.");

            // Resolve RootDirectory relative to the EXE directory and validate existence
            cfg.RootDirectory = ProgramHelpers.ResolveIfRelative(cfg.RootDirectory, exeDir);
            if (!Directory.Exists(cfg.RootDirectory))
                throw new InvalidOperationException($"RootDirectory not found: {cfg.RootDirectory}");
            // Resolve PatchDirectory relative to the EXE directory as well. PatchDirectory is optional
            // and may be empty; ResolveIfRelative returns an empty string for null/whitespace inputs.
            cfg.PatchDirectory = ProgramHelpers.ResolveIfRelative(cfg.PatchDirectory, exeDir);
            if (cfg.Hatari == null)
                throw new InvalidOperationException("Hatari configuration must be present in launcher.config.json.");

            cfg.Hatari.Executable = ProgramHelpers.ResolveIfRelative(cfg.Hatari.Executable, exeDir);
            cfg.Hatari.ConfigFile = ProgramHelpers.ResolveIfRelative(cfg.Hatari.ConfigFile, exeDir);

            if (string.IsNullOrWhiteSpace(cfg.Hatari.Executable))
                throw new InvalidOperationException("Hatari.Executable must be set in the configuration.");
            if (!File.Exists(cfg.Hatari.Executable))
                throw new InvalidOperationException($"Hatari executable not found: {cfg.Hatari.Executable}");

            // Also validate the Hatari config file (if provided)
            if (!string.IsNullOrWhiteSpace(cfg.Hatari.ConfigFile) && !File.Exists(cfg.Hatari.ConfigFile))
                throw new InvalidOperationException($"Hatari configuration file not found: {cfg.Hatari.ConfigFile}");
            if (string.IsNullOrWhiteSpace(cfg.Hatari.ArgsTemplate) || !cfg.Hatari.ArgsTemplate.Contains("{zip}"))
                throw new InvalidOperationException("Hatari.ArgsTemplate must contain the {zip} placeholder.");

            return cfg;
        }
    }

    // Internal host that keeps state previously stored in Program.cs
    internal class AppHost(AppConfig cfg)
    {
        OverlayDirectoryBrowser? _directoryBrowser;
        MenuRenderer _menuRenderer = new MenuRenderer();
        NavigationController _navigationController = new NavigationController();
        List<GameEntry> _gameEntries = new List<GameEntry>();
        HatariLauncher? _hatariLauncher;
        readonly UIErrorService _errorService = new UIErrorService();
        FavoritesService? _favoritesService;

        public void InitializeComponents()
        {
            _directoryBrowser = new OverlayDirectoryBrowser(cfg.RootDirectory ?? string.Empty, cfg.PatchDirectory ?? string.Empty);
            // Initialize favorites service. Use PatchDirectory if present, otherwise exe dir fallback.
            string favPath;
            if (!string.IsNullOrWhiteSpace(cfg.PatchDirectory))
            {
                favPath = Path.Combine(cfg.PatchDirectory!, "favorites.txt");
            }
            else
            {
                favPath = Path.Combine(AppContext.BaseDirectory, "favorites.txt");
            }
            _favoritesService = new FavoritesService(favPath);
            try { _favoritesService.Load(); } catch { /* ignore load errors */ }
            try
            {
                _hatariLauncher = new HatariLauncher(cfg.Hatari?.Executable ?? throw new InvalidOperationException("Hatari.Executable not configured"), cfg.Hatari?.ConfigFile ?? string.Empty, cfg.Hatari?.ArgsTemplate ?? "-c \"{cfg}\" --disk-a \"{zip}\"");
            }
            catch (Exception ex)
            {
                ProgramHelpers.ShowConsoleMessage(["Hatari initialization error: " + ex.Message, "Press any key to exit."
                ], ConsoleColor.Red);
                Environment.Exit(1);
            }
            Console.CursorVisible = false;
        }

        public void RunDirectoryNavigation()
        {
            bool exitRequested = false;
            ReloadGameEntries();
            int currentAvailableLines = Console.WindowHeight - 1;
            int currentWidth = Console.WindowWidth;
            _navigationController.UpdateScrollOffset(_gameEntries.Count, currentAvailableLines);
            var isFav = new Func<GameEntry, bool>(e => _favoritesService?.IsFavorite(e.Kind == EntryKind.Zip ? (e.InPatch ? e.PatchPath : e.RootPath) ?? string.Empty : string.Empty) ?? false);
            _menuRenderer.DrawMenu(_gameEntries, _navigationController.ScrollOffset, _navigationController.SelectedIndex, currentAvailableLines, isFav);
            while (!exitRequested)
            {
                // Reloads are performed explicitly when entering or leaving directories (Enter/Backspace)
                // Do NOT hit the filesystem here on every loop iteration.

                // detect a change in console height and/or width and redraw immediately
                int latestAvailableLines = Console.WindowHeight - 1;
                int latestWidth = Console.WindowWidth;
                if (latestAvailableLines != currentAvailableLines || latestWidth != currentWidth)
                {
                    currentAvailableLines = latestAvailableLines;
                    currentWidth = latestWidth;
                    _navigationController.UpdateScrollOffset(_gameEntries.Count, currentAvailableLines);
                    _menuRenderer.DrawMenu(_gameEntries, _navigationController.ScrollOffset, _navigationController.SelectedIndex, currentAvailableLines, isFav);
                }

                // Only block if there's actually a key; otherwise allow resize detection
                if (!Console.KeyAvailable)
                {
                    Thread.Sleep(50);
                    continue;
                }

                var key = Console.ReadKey(intercept: true);
                switch (key.Key)
                {
                    case ConsoleKey.UpArrow:
                        int previousSelectedIndexUp = _navigationController.SelectedIndex;
                        bool didScrollUp = _navigationController.MoveUp(_gameEntries, currentAvailableLines);
                        if (didScrollUp)
                        {
                            _menuRenderer.DrawMenu(_gameEntries, _navigationController.ScrollOffset, _navigationController.SelectedIndex, currentAvailableLines, isFav);
                        }
                        else
                        {
                            _menuRenderer.RedrawEntry(_gameEntries, previousSelectedIndexUp, previousSelectedIndexUp - _navigationController.ScrollOffset, false, currentAvailableLines, isFav);
                            _menuRenderer.RedrawEntry(_gameEntries, _navigationController.SelectedIndex, _navigationController.SelectedIndex - _navigationController.ScrollOffset, true, currentAvailableLines, isFav);
                        }
                        // flush input to avoid key repeat
                        ProgramHelpers.FlushInputBuffer();
                        break;
                    case ConsoleKey.DownArrow:
                        int previousSelectedIndexDown = _navigationController.SelectedIndex;
                        bool didScrollDown = _navigationController.MoveDown(_gameEntries, currentAvailableLines);
                            if (didScrollDown)
                            {
                                _menuRenderer.DrawMenu(_gameEntries, _navigationController.ScrollOffset, _navigationController.SelectedIndex, currentAvailableLines, isFav);
                            }
                            else
                            {
                                _menuRenderer.RedrawEntry(_gameEntries, previousSelectedIndexDown, previousSelectedIndexDown - _navigationController.ScrollOffset, false, currentAvailableLines, isFav);
                                _menuRenderer.RedrawEntry(_gameEntries, _navigationController.SelectedIndex, _navigationController.SelectedIndex - _navigationController.ScrollOffset, true, currentAvailableLines, isFav);
                            }
                        ProgramHelpers.FlushInputBuffer();
                        break;
                    case ConsoleKey.Enter:
                        var oldRelativePath = _navigationController.CurrentRelativePath;
                        var isDirectory = _gameEntries.Count > 0 && _gameEntries[_navigationController.SelectedIndex].Kind == EntryKind.Directory;
                        _navigationController.HandleEnter(_gameEntries);
                        if (isDirectory && oldRelativePath != _navigationController.CurrentRelativePath) {
                            ReloadGameEntries();
                            _navigationController.UpdateScrollOffset(_gameEntries.Count, currentAvailableLines);
                        }
                        _menuRenderer.DrawMenu(_gameEntries, _navigationController.ScrollOffset, _navigationController.SelectedIndex, currentAvailableLines, isFav);
                        // Only start a ZIP if NOT switching to a directory
                        if (!isDirectory && _gameEntries.Count > 0 && _gameEntries[_navigationController.SelectedIndex].Kind == EntryKind.Zip)
                        {
                            string zipToLaunch = _gameEntries[_navigationController.SelectedIndex].InPatch ? _gameEntries[_navigationController.SelectedIndex].PatchPath : _gameEntries[_navigationController.SelectedIndex].RootPath;
                            try
                            {
                                _hatariLauncher!.Launch(zipToLaunch);
                            }
                            catch (Exception ex)
                            {
                                _errorService.ShowError(ex.Message);
                            }
                        }
                        // flush input to avoid leftover key events after an enter/navigation
                        ProgramHelpers.FlushInputBuffer();
                        break;
                    case ConsoleKey.Backspace:
                        _navigationController.GoUpDirectory();
                        ReloadGameEntries();
                        _navigationController.UpdateScrollOffset(_gameEntries.Count, currentAvailableLines);
                        _menuRenderer.DrawMenu(_gameEntries, _navigationController.ScrollOffset, _navigationController.SelectedIndex, currentAvailableLines, isFav);
                        // flush input to avoid leftover key events after directory change
                        ProgramHelpers.FlushInputBuffer();
                        break;
                    case ConsoleKey.PageDown:
                        _navigationController.PageDown(_gameEntries, currentAvailableLines);
                        _menuRenderer.DrawMenu(_gameEntries, _navigationController.ScrollOffset, _navigationController.SelectedIndex, currentAvailableLines, isFav);
                        ProgramHelpers.FlushInputBuffer();
                        break;
                    case ConsoleKey.PageUp:
                        _navigationController.PageUp(_gameEntries, currentAvailableLines);
                        _menuRenderer.DrawMenu(_gameEntries, _navigationController.ScrollOffset, _navigationController.SelectedIndex, currentAvailableLines, isFav);
                        ProgramHelpers.FlushInputBuffer();
                        break;
                    case ConsoleKey.Multiply:
                    case ConsoleKey.Oem8:
                        // Toggle favorite for selected ZIP (handles numpad * and some layouts)
                        if (_gameEntries.Count > 0 && _gameEntries[_navigationController.SelectedIndex].Kind == EntryKind.Zip)
                        {
                            var ge = _gameEntries[_navigationController.SelectedIndex];
                            string path = ge.InPatch ? ge.PatchPath : ge.RootPath;
                            try
                            {
                                _favoritesService?.Toggle(path);
                            }
                            catch (Exception ex)
                            {
                                _errorService.ShowError("Failed to toggle favorite: " + ex.Message);
                            }
                            // Redraw the whole menu so the '*' marker updates immediately
                            _menuRenderer.DrawMenu(_gameEntries, _navigationController.ScrollOffset, _navigationController.SelectedIndex, currentAvailableLines, isFav);
                        }
                        ProgramHelpers.FlushInputBuffer();
                        break;
                    case ConsoleKey.Escape:
                        exitRequested = true;
                        break;
                }
            }
        }

        void ReloadGameEntries()
        {
            try
            {
                // If we are at the virtual Favorites folder, produce the flat list from the favorites service
                if (string.Equals(_navigationController.CurrentRelativePath, "Favorites", StringComparison.OrdinalIgnoreCase))
                {
                    var favs = _favoritesService?.GetAll() ?? new List<string>();
                    _gameEntries = favs.Select(p => new GameEntry
                    {
                        Name = Path.GetFileName(p),
                        Kind = EntryKind.Zip,
                        InRoot = true,
                        InPatch = false,
                        RootPath = p,
                        PatchPath = string.Empty,
                        IsVirtual = false
                    }).ToList();
                    _navigationController.SetEntriesCount(_gameEntries.Count);
                    return;
                }

                // Otherwise use the overlay directory browser for normal folders
                _gameEntries = _directoryBrowser!.GetEntries(_navigationController.CurrentRelativePath);

                // If we are at the root and there are favorites, prepend a virtual "Favorites" folder
                if (string.IsNullOrEmpty(_navigationController.CurrentRelativePath) && (_favoritesService?.HasFavorites() ?? false))
                {
                    var virtualEntry = new GameEntry
                    {
                        Name = "Favorites",
                        Kind = EntryKind.Directory,
                        InRoot = true,
                        InPatch = false,
                        RootPath = string.Empty,
                        PatchPath = string.Empty,
                        IsVirtual = true
                    };
                    // insert at the beginning
                    _gameEntries.Insert(0, virtualEntry);
                }

                _navigationController.SetEntriesCount(_gameEntries.Count);
            }
            catch (Exception ex)
            {
                // Show the error to the user and continue with an empty list
                _errorService.ShowError(ex.Message);
                _gameEntries = new List<GameEntry>();
                _navigationController.SetEntriesCount(0);
            }
        }
    }
}
