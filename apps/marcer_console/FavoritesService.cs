// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

using System.Text;

namespace MarcerGameDvdConsole
{
    // Manages loading, saving and querying favorite ZIP paths.
    public class FavoritesService(string filePath, string? rootDirectory = null, string? patchDirectory = null)
    {
        // Virtual folder name displayed at the root when favorites exist.
        // Not configurable — fixed UI element.
        public const string FavoritesRootName = "Favorites";

        // Filename used for persisting favorites to disk.
        // Not configurable — fixed persistence file.
        public const string DefaultFileName = "favorites.txt";

        private readonly string _filePath = filePath ?? throw new ArgumentNullException(nameof(filePath));
        private readonly string? _rootDirectory = rootDirectory;
        private readonly string? _patchDirectory = patchDirectory;
        // Use a SortedSet so favorites are kept in sorted order in memory.
        private SortedSet<string> _favorites = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, string> _originals = new(StringComparer.OrdinalIgnoreCase);
        private bool _needsMigration;

        // Load favorites from disk (no-op if file missing)
        public void Load()
        {
            _favorites = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            _originals.Clear();
            _needsMigration = false;
            if (!File.Exists(_filePath)) return;
            var raw = File.ReadAllText(_filePath, Encoding.UTF8);
            if (raw.StartsWith('\uFEFF')) _needsMigration = true;
            if (raw.Contains('\r')) _needsMigration = true;
            var lines = File.ReadAllLines(_filePath, Encoding.UTF8);
            foreach (var l in lines)
            {
                var t = l.Trim().TrimStart('\uFEFF');
                if (string.IsNullOrEmpty(t)) continue;
                try
                {
                    var full = Resolve(t);
                    _favorites.Add(full);
                    _originals[full] = t;
                    var encoded = Encode(full);
                    if (!IsAbsolute(encoded) && !string.Equals(encoded, t, StringComparison.OrdinalIgnoreCase))
                        _needsMigration = true;
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
            if (!_favorites.Add(full))
            {
                _favorites.Remove(full);
                added = false;
            }
            else
            {
                added = true;
            }
            Save();
            return added;
        }

        private string Resolve(string value)
        {
            var t = value.Trim().TrimStart('\uFEFF');
            if (IsAbsolute(t))
            {
                if (Path.IsPathRooted(t))
                {
                    var full = Path.GetFullPath(t);
                    if (IsUnderBase(full)) return full;
                }
                var foreign = t.Replace('\\', '/');
                return ResolveForeign(foreign) ?? foreign;
            }
            var rel = t.Replace('\\', Path.DirectorySeparatorChar)
                .Replace('/', Path.DirectorySeparatorChar);
            foreach (var baseDir in Bases())
            {
                var candidate = Path.GetFullPath(Path.Combine(baseDir, rel));
                if (IsUnderBase(candidate) && File.Exists(candidate)) return candidate;
            }
            var fallback = !string.IsNullOrWhiteSpace(_rootDirectory) ? _rootDirectory : _patchDirectory;
            var fallbackPath = fallback != null
                ? Path.GetFullPath(Path.Combine(fallback, rel))
                : Path.GetFullPath(t);
            return IsUnderBase(fallbackPath) ? fallbackPath : t.Replace('\\', '/');
        }

        private string? ResolveForeign(string value)
        {
            var lower = value.ToLowerInvariant();
            foreach (var marker in new[] { "Title Sorted/", "Utilitys - Title Sorted/" })
            {
                var index = lower.IndexOf(marker.ToLowerInvariant(), StringComparison.Ordinal);
                if (index < 0) continue;
                var rel = value.Substring(index);
                var local = rel.Replace('\\', Path.DirectorySeparatorChar)
                    .Replace('/', Path.DirectorySeparatorChar);
                foreach (var baseDir in Bases())
                {
                    var candidate = Path.GetFullPath(Path.Combine(baseDir, local));
                    if (IsUnderBase(candidate) && File.Exists(candidate)) return candidate;
                }
            }
            return null;
        }

        private string Encode(string absolute)
        {
            string? best = null;
            var bestLength = -1;
            foreach (var baseDir in new[] { _rootDirectory, _patchDirectory })
            {
                if (string.IsNullOrWhiteSpace(baseDir)) continue;
                var fullBase = Path.GetFullPath(baseDir);
                var rel = Path.GetRelativePath(fullBase, absolute);
                if (rel == "." || rel == ".." || rel.StartsWith(".." + Path.DirectorySeparatorChar) ||
                    Path.IsPathRooted(rel)) continue;
                if (fullBase.Length > bestLength)
                {
                    bestLength = fullBase.Length;
                    best = rel;
                }
            }
            return best != null
                ? best.Replace(Path.DirectorySeparatorChar, '/')
                : absolute.Replace('\\', '/');
        }

        private bool IsUnderBase(string path)
        {
            foreach (var baseDir in Bases())
            {
                var fullBase = Path.GetFullPath(baseDir);
                var rel = Path.GetRelativePath(fullBase, path);
                if (rel == "." || (rel != ".." && !rel.StartsWith(".." + Path.DirectorySeparatorChar) &&
                    !Path.IsPathRooted(rel))) return true;
            }
            return false;
        }

        private IEnumerable<string> Bases()
        {
            if (!string.IsNullOrWhiteSpace(_patchDirectory)) yield return _patchDirectory!;
            if (!string.IsNullOrWhiteSpace(_rootDirectory)) yield return _rootDirectory!;
        }

        private static bool IsAbsolute(string value) =>
            value.StartsWith("/") ||
            (value.Length >= 3 && char.IsLetter(value[0]) && value[1] == ':' &&
             (value[2] == '/' || value[2] == '\\'));

        private void Save()
        {
            try
            {
                var dir = Path.GetDirectoryName(_filePath) ?? AppContext.BaseDirectory;
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                if (_needsMigration && File.Exists(_filePath))
                {
                    var stamp = DateTime.UtcNow.ToString("yyyyMMdd-HHmmssfff");
                    File.Copy(_filePath, $"{_filePath}.bak-{stamp}", overwrite: true);
                    _needsMigration = false;
                }
                var lines = _favorites
                    .OrderBy(x => x, StringComparer.OrdinalIgnoreCase)
                    .Select(path =>
                    {
                        var encoded = Encode(path);
                        return IsAbsolute(encoded) && _originals.TryGetValue(path, out var original)
                            ? original
                            : encoded;
                    })
                    .ToList();
                var content = lines.Count == 0 ? string.Empty : string.Join("\n", lines) + "\n";
                File.WriteAllText(_filePath, content, new UTF8Encoding(false));
            }
            catch
            {
                // Swallowed intentionally ("bewusst still"): a persistence failure
                // (e.g. disk full, read-only directory) must not crash or interrupt
                // the UI. The in-memory state is still updated so the user sees
                // immediate feedback; only the on-disk write is lost. On next
                // application start the favorites reflect the last successful save.
            }
        }
    }
}
