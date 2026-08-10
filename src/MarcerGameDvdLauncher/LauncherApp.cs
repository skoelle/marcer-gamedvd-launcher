// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

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

            // Parse Colors section manually so invalid values fall back to defaults
            // instead of crashing the deserialization.
            cfg.Colors = ParseAppColors(json);

            return cfg;
        }

        // Parses the optional "Colors" JSON section into an AppColorConfig.
        // Each field is resolved with Enum.TryParse<ConsoleColor>; unparseable or
        // missing values silently fall back to the defaults defined in AppColorConfig.
        private static AppColorConfig ParseAppColors(string json)
        {
            var colors = new AppColorConfig();
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("Colors", out var colorsEl) && colorsEl.ValueKind == System.Text.Json.JsonValueKind.Object)
                {
                    ParseColorField(colorsEl, "FolderBoth", v => colors.FolderBoth = v);
                    ParseColorField(colorsEl, "FolderPatchOnly", v => colors.FolderPatchOnly = v);
                    ParseColorField(colorsEl, "FolderRootOnly", v => colors.FolderRootOnly = v);
                    ParseColorField(colorsEl, "ZipBoth", v => colors.ZipBoth = v);
                    ParseColorField(colorsEl, "ZipRootOnly", v => colors.ZipRootOnly = v);
                    ParseColorField(colorsEl, "ZipPatchOnly", v => colors.ZipPatchOnly = v);
                    ParseColorField(colorsEl, "SelectedForeground", v => colors.SelectedForeground = v);
                    ParseColorField(colorsEl, "SelectedBackground", v => colors.SelectedBackground = v);
                    ParseColorField(colorsEl, "VirtualEntry", v => colors.VirtualEntry = v);
                }
            }
            catch
            {
                // On any JSON error, fall back to default colors (already set above)
            }
            return colors;
        }

        private static void ParseColorField(System.Text.Json.JsonElement colorsEl, string name, Action<ConsoleColor> setter)
        {
            if (colorsEl.TryGetProperty(name, out var prop) && prop.ValueKind == System.Text.Json.JsonValueKind.String)
            {
                var str = prop.GetString();
                if (Enum.TryParse<ConsoleColor>(str ?? string.Empty, ignoreCase: true, out var parsed))
                    setter(parsed);
                // Invalid color names are silently ignored — defaults are preserved
            }
        }
    }

    // Internal host that keeps state and lifecycle management for the application.
    // Key-handling logic has been extracted into InputController; this class
    // focuses on component wiring, initialization and the main loop (resize detection + key polling).
    internal class AppHost(AppConfig cfg)
    {
        private InputController? _inputController;
        private MenuRenderer? _menuRenderer;
        private HatariLauncher? _hatariLauncher;
        private int _currentAvailableLines;
        private int _currentWidth;

    public void InitializeComponents()
    {
        var directoryBrowser = new OverlayDirectoryBrowser(cfg.RootDirectory ?? string.Empty, cfg.PatchDirectory ?? string.Empty);

        // Initialize favorites service. Use PatchDirectory if present, otherwise exe dir fallback.
        string favPath;
        if (!string.IsNullOrWhiteSpace(cfg.PatchDirectory))
        {
            favPath = Path.Combine(cfg.PatchDirectory!, FavoritesService.DefaultFileName);
        }
        else
        {
            favPath = Path.Combine(AppContext.BaseDirectory, FavoritesService.DefaultFileName);
        }
        var favoritesService = new FavoritesService(favPath);
        try { favoritesService.Load(); } catch { /* ignore load errors */ }

        var errorService = new UIErrorService();
        try
        {
            // ArgsTemplate is validated in LoadConfiguration — it must always contain {zip}.
            // No hardcoded fallback is needed; the config file is the single source of truth.
            _hatariLauncher = new HatariLauncher(cfg.Hatari?.Executable ?? throw new InvalidOperationException("Hatari.Executable not configured"), cfg.Hatari?.ConfigFile ?? string.Empty, cfg.Hatari?.ArgsTemplate ?? string.Empty);
        }
        catch (Exception ex)
        {
            ProgramHelpers.ShowConsoleMessage(["Hatari initialization error: " + ex.Message, "Press any key to exit."
            ], ConsoleColor.Red);
            Environment.Exit(1);
        }

        _menuRenderer = new MenuRenderer(cfg.Colors);
        var navigationController = new NavigationController();

        _inputController = new InputController(directoryBrowser, _menuRenderer, navigationController,
            _hatariLauncher!, favoritesService, errorService);

        Console.CursorVisible = false;
    }

        public void RunDirectoryNavigation()
        {
            _currentAvailableLines = ProgramHelpers.AvailableLines;
            _currentWidth = Console.WindowWidth;

            _inputController!.ReloadGameEntries();
            _inputController.RefreshView(_currentAvailableLines);

            bool exitRequested = false;
            while (!exitRequested)
            {
                // Reloads are performed explicitly by InputController when entering/leaving directories
                // Do NOT hit the filesystem here on every loop iteration.

                // detect a change in console height and/or width and redraw immediately
                int latestAvailableLines = ProgramHelpers.AvailableLines;
                int latestWidth = Console.WindowWidth;
            if (latestAvailableLines != _currentAvailableLines || latestWidth != _currentWidth)
            {
                _currentAvailableLines = latestAvailableLines;
                _currentWidth = latestWidth;
                _inputController.RefreshView(_currentAvailableLines);
            }

            // Only block if there's actually a key; otherwise allow resize detection
            if (!Console.KeyAvailable)
            {
                Thread.Sleep(50);
                continue;
            }

            var key = Console.ReadKey(intercept: true);
            exitRequested = _inputController.HandleKey(key, _currentAvailableLines);
        }
    }
    }
}
