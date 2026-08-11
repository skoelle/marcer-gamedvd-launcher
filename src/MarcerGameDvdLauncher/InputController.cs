// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    /// <summary>
    /// Handles user input (key events) and the associated navigation / drawing logic.
    /// Extracted from AppHost so that LauncherApp stays focused on lifecycle management.
    /// No functional change - all key-handling behaviour is preserved exactly.
    /// </summary>
    internal class InputController(
        OverlayDirectoryBrowser directoryBrowser,
        MenuRenderer menuRenderer,
        NavigationController navigationController,
        HatariLauncher hatariLauncher,
        FavoritesService favoritesService,
        UIErrorService errorService)
    {
        private List<GameEntry> _gameEntries = new();

        private bool IsFavorite(GameEntry e)
        {
            return e.Kind == EntryKind.Zip && favoritesService.IsFavorite(e.InPatch ? e.PatchPath : e.RootPath);
        }

        private void DrawMenu(int availableLines)
        {
            menuRenderer.DrawMenu(_gameEntries, navigationController.ScrollOffset,
                navigationController.SelectedIndex, availableLines, IsFavorite);
        }

        /// <summary>
        /// Updates scroll offset and redraws the full menu. Called on initial load and console resize.
        /// </summary>
        public void RefreshView(int availableLines)
        {
            navigationController.UpdateScrollOffset(_gameEntries.Count, availableLines);
            DrawMenu(availableLines);
        }

        /// <summary>
        /// Loads entries for the current directory (or the virtual Favorites folder).
        /// </summary>
        public void ReloadGameEntries()
        {
            try
            {
                // If we are at the virtual Favorites folder, produce the flat list from the favorites service
                if (string.Equals(navigationController.CurrentRelativePath, FavoritesService.FavoritesRootName, StringComparison.OrdinalIgnoreCase))
                {
                    var favs = favoritesService.GetAll();
                    _gameEntries = new List<GameEntry>();
                    foreach (var p in favs)
                    {
                        _gameEntries.Add(new GameEntry
                        {
                            Name = Path.GetFileName(p),
                            Kind = EntryKind.Zip,
                            InRoot = true,
                            InPatch = false,
                            RootPath = p,
                            PatchPath = string.Empty,
                            IsVirtual = false
                        });
                    }
                    navigationController.SetEntriesCount(_gameEntries.Count);
                    return;
                }

                // Otherwise use the overlay directory browser for normal folders
                _gameEntries = directoryBrowser.GetEntries(navigationController.CurrentRelativePath);

                // If we are at the root and there are favorites, prepend a virtual Favorites folder
                if (string.IsNullOrEmpty(navigationController.CurrentRelativePath) && favoritesService.HasFavorites())
                {
                    var virtualEntry = new GameEntry
                    {
                        Name = FavoritesService.FavoritesRootName,
                        Kind = EntryKind.Directory,
                        InRoot = true,
                        InPatch = false,
                        RootPath = string.Empty,
                        PatchPath = string.Empty,
                        IsVirtual = true
                    };
                    _gameEntries.Insert(0, virtualEntry);
                }

                navigationController.SetEntriesCount(_gameEntries.Count);
            }
            catch (Exception ex)
            {
                // Show the error to the user and continue with an empty list
                errorService.ShowError(ex.Message);
                _gameEntries = new List<GameEntry>();
                navigationController.SetEntriesCount(0);
            }
        }

        /// <summary>
        /// Handles a key press. Returns true if the application should exit.
        /// </summary>
        public bool HandleKey(ConsoleKeyInfo key, int availableLines)
        {
            if (key.KeyChar == '?')
            {
                menuRenderer.ShowHelpBox(availableLines);
                Console.ReadKey(intercept: true);
                menuRenderer.InvalidateCache();
                DrawMenu(availableLines);
                ProgramHelpers.FlushInputBuffer();
                return false;
            }

            switch (key.Key)
            {
                case ConsoleKey.UpArrow:
                    {
                        int previousSelectedIndex = navigationController.SelectedIndex;
                        bool didScroll = navigationController.MoveUp(_gameEntries, availableLines);
                        if (didScroll)
                        {
                            DrawMenu(availableLines);
                        }
                        else
                        {
                            menuRenderer.RedrawEntry(_gameEntries, previousSelectedIndex, previousSelectedIndex - navigationController.ScrollOffset, false, availableLines, IsFavorite);
                            menuRenderer.RedrawEntry(_gameEntries, navigationController.SelectedIndex, navigationController.SelectedIndex - navigationController.ScrollOffset, true, availableLines, IsFavorite);
                        }
                        // flush input to avoid key repeat
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.DownArrow:
                    {
                        int previousSelectedIndex = navigationController.SelectedIndex;
                        bool didScroll = navigationController.MoveDown(_gameEntries, availableLines);
                        if (didScroll)
                        {
                            DrawMenu(availableLines);
                        }
                        else
                        {
                            menuRenderer.RedrawEntry(_gameEntries, previousSelectedIndex, previousSelectedIndex - navigationController.ScrollOffset, false, availableLines, IsFavorite);
                            menuRenderer.RedrawEntry(_gameEntries, navigationController.SelectedIndex, navigationController.SelectedIndex - navigationController.ScrollOffset, true, availableLines, IsFavorite);
                        }
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.Enter:
                case ConsoleKey.RightArrow:
                    {
                        var oldRelativePath = navigationController.CurrentRelativePath;
                        var isDirectory = _gameEntries.Count > 0 && _gameEntries[navigationController.SelectedIndex].Kind == EntryKind.Directory;
                        navigationController.HandleEnter(_gameEntries);
                        if (isDirectory && oldRelativePath != navigationController.CurrentRelativePath)
                        {
                            ReloadGameEntries();
                            navigationController.UpdateScrollOffset(_gameEntries.Count, availableLines);
                        }
                        DrawMenu(availableLines);
                        // Only start a ZIP if NOT switching to a directory
                        if (!isDirectory && _gameEntries.Count > 0 && _gameEntries[navigationController.SelectedIndex].Kind == EntryKind.Zip)
                        {
                            string zipToLaunch = _gameEntries[navigationController.SelectedIndex].InPatch ? _gameEntries[navigationController.SelectedIndex].PatchPath : _gameEntries[navigationController.SelectedIndex].RootPath;
                            try
                            {
                                hatariLauncher.Launch(zipToLaunch);
                            }
                            catch (Exception ex)
                            {
                                errorService.ShowError(ex.Message);
                            }
                            // Redraw menu after Hatari has exited
                            DrawMenu(availableLines);
                        }
                        // flush input to avoid leftover key events after an enter/navigation
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.Backspace:
                case ConsoleKey.LeftArrow:
                    {
                        navigationController.GoUpDirectory();
                        ReloadGameEntries();
                        navigationController.UpdateScrollOffset(_gameEntries.Count, availableLines);
                        DrawMenu(availableLines);
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.PageDown:
                    {
                        navigationController.PageDown(_gameEntries, availableLines);
                        DrawMenu(availableLines);
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.PageUp:
                    {
                        navigationController.PageUp(_gameEntries, availableLines);
                        DrawMenu(availableLines);
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.Multiply:
                case ConsoleKey.Oem8:
                    {
                        // Toggle favorite for selected ZIP (handles numpad * and some layouts)
                        if (_gameEntries.Count > 0 && _gameEntries[navigationController.SelectedIndex].Kind == EntryKind.Zip)
                        {
                            var ge = _gameEntries[navigationController.SelectedIndex];
                            string path = ge.InPatch ? ge.PatchPath : ge.RootPath;
                            try
                            {
                                favoritesService.Toggle(path);
                            }
                            catch (Exception ex)
                            {
                                errorService.ShowError("Failed to toggle favorite: " + ex.Message);
                            }
                            // Redraw the whole menu so the '*' marker updates immediately
                            DrawMenu(availableLines);
                        }
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.Escape:
                case ConsoleKey.Q:
                    return true;
            }

            return false;
        }
    }
}
