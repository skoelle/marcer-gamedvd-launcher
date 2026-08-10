// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    // Manages loading, saving and querying favorite ZIP paths.
    public class FavoritesService
    {
        private readonly string _filePath;
        // Use a SortedSet so favorites are kept in sorted order in memory.
        private SortedSet<string> _favorites = new(StringComparer.OrdinalIgnoreCase);

        public FavoritesService(string filePath)
        {
            _filePath = filePath ?? throw new ArgumentNullException(nameof(filePath));
        }

        // Load favorites from disk (no-op if file missing)
        public void Load()
        {
            _favorites = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            if (!File.Exists(_filePath)) return;
            var lines = File.ReadAllLines(_filePath, System.Text.Encoding.UTF8);
            foreach (var l in lines)
            {
                var t = l?.Trim();
                if (string.IsNullOrEmpty(t)) continue;
                try
                {
                    var full = Path.GetFullPath(t);
                    _favorites.Add(full);
                }
                catch
                {
                    // ignore invalid paths in the file
                }
            }
        }

        public bool IsFavorite(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return false;
            try
            {
                var full = Path.GetFullPath(path);
                return _favorites.Contains(full);
            }
            catch
            {
                return false;
            }
        }

        // Returns true if any favorites are present
        public bool HasFavorites() => _favorites.Count > 0;

        // Returns all favorites as absolute paths in sorted order
        public IReadOnlyList<string> GetAll() => _favorites.ToList();

        // Toggle favorite state. Returns true if added, false if removed.
        public bool Toggle(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) throw new ArgumentNullException(nameof(path));
            var full = Path.GetFullPath(path);
            bool added;
            if (_favorites.Contains(full))
            {
                _favorites.Remove(full);
                added = false;
            }
            else
            {
                _favorites.Add(full);
                added = true;
            }
            Save();
            return added;
        }

        private void Save()
        {
            try
            {
                var dir = Path.GetDirectoryName(_filePath) ?? AppContext.BaseDirectory;
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                File.WriteAllLines(_filePath, _favorites.OrderBy(x => x), System.Text.Encoding.UTF8);
            }
            catch
            {
                // Let callers surface errors (we swallow here to avoid throwing on write failures during UI operations)
            }
        }
    }
}
