// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace MarcerGameDvdLauncher
{
    /// <summary>
    /// Handles user input (key events) and the associated navigation / drawing logic.
    /// Extracted from AppHost so that LauncherApp stays focused on lifecycle management.
    /// No functional change - all key-handling behaviour is preserved exactly.
    /// </summary>
    internal class InputController
    {
        private readonly OverlayDirectoryBrowser _directoryBrowser;
        private readonly MenuRenderer _menuRenderer;
        private readonly NavigationController _navigationController;
        private readonly HatariLauncher _hatariLauncher;
        private readonly FavoritesService _favoritesService;
        private readonly UIErrorService _errorService;

        private List<GameEntry> _gameEntries = new();

        public IReadOnlyList<GameEntry> GameEntries => _gameEntries;

        public InputController(OverlayDirectoryBrowser directoryBrowser, MenuRenderer menuRenderer,
            NavigationController navigationController, HatariLauncher hatariLauncher,
            FavoritesService favoritesService, UIErrorService errorService)
        {
            _directoryBrowser = directoryBrowser;
            _menuRenderer = menuRenderer;
            _navigationController = navigationController;
            _hatariLauncher = hatariLauncher;
            _favoritesService = favoritesService;
            _errorService = errorService;
        }

        private bool IsFavorite(GameEntry e)
        {
            return e.Kind == EntryKind.Zip
                ? _favoritesService.IsFavorite(e.InPatch ? e.PatchPath : e.RootPath)
                : false;
        }

        private void DrawMenu(int availableLines)
        {
            _menuRenderer.DrawMenu(_gameEntries, _navigationController.ScrollOffset,
                _navigationController.SelectedIndex, availableLines, IsFavorite);
        }

        /// <summary>
        /// Updates scroll offset and redraws the full menu. Called on initial load and console resize.
        /// </summary>
        public void RefreshView(int availableLines)
        {
            _navigationController.UpdateScrollOffset(_gameEntries.Count, availableLines);
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
                if (string.Equals(_navigationController.CurrentRelativePath, FavoritesService.FavoritesRootName, StringComparison.OrdinalIgnoreCase))
                {
                    var favs = _favoritesService.GetAll();
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
                    _navigationController.SetEntriesCount(_gameEntries.Count);
                    return;
                }

                // Otherwise use the overlay directory browser for normal folders
                _gameEntries = _directoryBrowser.GetEntries(_navigationController.CurrentRelativePath);

                // If we are at the root and there are favorites, prepend a virtual Favorites folder
                if (string.IsNullOrEmpty(_navigationController.CurrentRelativePath) && _favoritesService.HasFavorites())
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

        /// <summary>
        /// Handles a key press. Returns true if the application should exit.
        /// </summary>
        public bool HandleKey(ConsoleKeyInfo key, int availableLines)
        {
            if (key.KeyChar == '?')
            {
                _menuRenderer.ShowHelpBox(availableLines);
                Console.ReadKey(intercept: true);
                _menuRenderer.InvalidateCache();
                DrawMenu(availableLines);
                ProgramHelpers.FlushInputBuffer();
                return false;
            }

            switch (key.Key)
            {
                case ConsoleKey.UpArrow:
                    {
                        int previousSelectedIndex = _navigationController.SelectedIndex;
                        bool didScroll = _navigationController.MoveUp(_gameEntries, availableLines);
                        if (didScroll)
                        {
                            DrawMenu(availableLines);
                        }
                        else
                        {
                            _menuRenderer.RedrawEntry(_gameEntries, previousSelectedIndex, previousSelectedIndex - _navigationController.ScrollOffset, false, availableLines, IsFavorite);
                            _menuRenderer.RedrawEntry(_gameEntries, _navigationController.SelectedIndex, _navigationController.SelectedIndex - _navigationController.ScrollOffset, true, availableLines, IsFavorite);
                        }
                        // flush input to avoid key repeat
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.DownArrow:
                    {
                        int previousSelectedIndex = _navigationController.SelectedIndex;
                        bool didScroll = _navigationController.MoveDown(_gameEntries, availableLines);
                        if (didScroll)
                        {
                            DrawMenu(availableLines);
                        }
                        else
                        {
                            _menuRenderer.RedrawEntry(_gameEntries, previousSelectedIndex, previousSelectedIndex - _navigationController.ScrollOffset, false, availableLines, IsFavorite);
                            _menuRenderer.RedrawEntry(_gameEntries, _navigationController.SelectedIndex, _navigationController.SelectedIndex - _navigationController.ScrollOffset, true, availableLines, IsFavorite);
                        }
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.Enter:
                case ConsoleKey.RightArrow:
                    {
                        var oldRelativePath = _navigationController.CurrentRelativePath;
                        var isDirectory = _gameEntries.Count > 0 && _gameEntries[_navigationController.SelectedIndex].Kind == EntryKind.Directory;
                        _navigationController.HandleEnter(_gameEntries);
                        if (isDirectory && oldRelativePath != _navigationController.CurrentRelativePath)
                        {
                            ReloadGameEntries();
                            _navigationController.UpdateScrollOffset(_gameEntries.Count, availableLines);
                        }
                        DrawMenu(availableLines);
                        // Only start a ZIP if NOT switching to a directory
                        if (!isDirectory && _gameEntries.Count > 0 && _gameEntries[_navigationController.SelectedIndex].Kind == EntryKind.Zip)
                        {
                            string zipToLaunch = _gameEntries[_navigationController.SelectedIndex].InPatch ? _gameEntries[_navigationController.SelectedIndex].PatchPath : _gameEntries[_navigationController.SelectedIndex].RootPath;
                            try
                            {
                                _hatariLauncher.Launch(zipToLaunch);
                            }
                            catch (Exception ex)
                            {
                                _errorService.ShowError(ex.Message);
                            }
                        }
                        // flush input to avoid leftover key events after an enter/navigation
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.Backspace:
                case ConsoleKey.LeftArrow:
                    {
                        _navigationController.GoUpDirectory();
                        ReloadGameEntries();
                        _navigationController.UpdateScrollOffset(_gameEntries.Count, availableLines);
                        DrawMenu(availableLines);
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.PageDown:
                    {
                        _navigationController.PageDown(_gameEntries, availableLines);
                        DrawMenu(availableLines);
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.PageUp:
                    {
                        _navigationController.PageUp(_gameEntries, availableLines);
                        DrawMenu(availableLines);
                        ProgramHelpers.FlushInputBuffer();
                    }
                    break;
                case ConsoleKey.Multiply:
                case ConsoleKey.Oem8:
                    {
                        // Toggle favorite for selected ZIP (handles numpad * and some layouts)
                        if (_gameEntries.Count > 0 && _gameEntries[_navigationController.SelectedIndex].Kind == EntryKind.Zip)
                        {
                            var ge = _gameEntries[_navigationController.SelectedIndex];
                            string path = ge.InPatch ? ge.PatchPath : ge.RootPath;
                            try
                            {
                                _favoritesService.Toggle(path);
                            }
                            catch (Exception ex)
                            {
                                _errorService.ShowError("Failed to toggle favorite: " + ex.Message);
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
