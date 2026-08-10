namespace HatariZipLauncher
{
    public enum EntryKind { Directory, Zip }

    public class GameEntry
    {
        public string Name { get; set; } = string.Empty;
        public EntryKind Kind { get; set; }
        public bool InRoot { get; set; }
        public bool InPatch { get; set; }
        public string RootPath { get; set; } = string.Empty;
        public string PatchPath { get; set; } = string.Empty;
        // When true this entry is virtual (not backed by filesystem), e.g. the Favorites root.
        public bool IsVirtual { get; set; } = false;
    }

    public class OverlayDirectoryBrowser(string root, string patch)
    {
        public List<GameEntry> GetEntries(string currentRelativePath)
        {
            try
            {
                // Normalize and protect against path traversal or absolute paths in the relative path
                string rel = currentRelativePath ?? string.Empty;
                // Remove any leading directory separators
                rel = rel.TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                // If the relative path is rooted or contains parent directory segments, reset to root
                if (Path.IsPathRooted(rel) || rel.Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries).Any(p => p == ".."))
                {
                    rel = string.Empty;
                }

                string rootFull = Path.GetFullPath(root);

                // Patch is optional. If not provided or empty, treat as no patch layer.
                bool hasPatch = !string.IsNullOrWhiteSpace(patch);
                string patchFull = hasPatch ? Path.GetFullPath(patch) : string.Empty;

                string rootPath = Path.GetFullPath(Path.Combine(rootFull, rel));
                if (!IsSubPathOf(rootPath, rootFull)) rootPath = rootFull;

                string patchPath = string.Empty;
                if (hasPatch)
                {
                    patchPath = Path.GetFullPath(Path.Combine(patchFull, rel));
                    if (!IsSubPathOf(patchPath, patchFull)) patchPath = patchFull;
                }

                var directoriesRoot = Directory.Exists(rootPath) ? new DirectoryInfo(rootPath).GetDirectories()
                    .Where(d => (d.Attributes & FileAttributes.Hidden) == 0).Select(d => d.Name).ToHashSet(StringComparer.OrdinalIgnoreCase) : new HashSet<string>();

                // If there's no patch configured, keep patch sets empty
                var directoriesPatch = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                var zipsPatch = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                if (!string.IsNullOrEmpty(patchPath) && Directory.Exists(patchPath))
                {
                    directoriesPatch = new DirectoryInfo(patchPath).GetDirectories()
                        .Where(d => (d.Attributes & FileAttributes.Hidden) == 0).Select(d => d.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
                    zipsPatch = new DirectoryInfo(patchPath).GetFiles("*.zip")
                        .Where(f => (f.Attributes & FileAttributes.Hidden) == 0).Select(f => f.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
                }

                var zipsRoot = Directory.Exists(rootPath) ? new DirectoryInfo(rootPath).GetFiles("*.zip")
                    .Where(f => (f.Attributes & FileAttributes.Hidden) == 0).Select(f => f.Name).ToHashSet(StringComparer.OrdinalIgnoreCase) : new HashSet<string>();

                var allDirectories = directoriesRoot.Union(directoriesPatch).OrderBy(x => x, StringComparer.OrdinalIgnoreCase);
                var allZips = zipsRoot.Union(zipsPatch).OrderBy(x => x, StringComparer.OrdinalIgnoreCase);
                var result = new List<GameEntry>();
                foreach (var dir in allDirectories)
                {
                    result.Add(new GameEntry
                    {
                        Name = dir,
                        Kind = EntryKind.Directory,
                        InRoot = directoriesRoot.Contains(dir),
                        InPatch = directoriesPatch.Contains(dir),
                        RootPath = Path.Combine(rootPath, dir),
                        PatchPath = Path.Combine(patchPath, dir)
                    });
                }
                foreach (var zip in allZips)
                {
                    result.Add(new GameEntry
                    {
                        Name = zip,
                        Kind = EntryKind.Zip,
                        InRoot = zipsRoot.Contains(zip),
                        InPatch = zipsPatch.Contains(zip),
                        RootPath = Path.Combine(rootPath, zip),
                        PatchPath = Path.Combine(patchPath, zip)
                    });
                }
                return result;
            }
            catch (Exception ex)
            {
                // Do not silently swallow filesystem exceptions; propagate with context
                throw new InvalidOperationException($"Failed to read entries for relative path '{currentRelativePath}': {ex.Message}", ex);
            }
        }

        private static bool IsSubPathOf(string path, string basePath)
        {
            var comparison = StringComparison.OrdinalIgnoreCase;
            // Ensure basePath ends with directory separator for correct prefix check
            if (!basePath.EndsWith(Path.DirectorySeparatorChar))
                basePath = basePath + Path.DirectorySeparatorChar;
            if (!path.EndsWith(Path.DirectorySeparatorChar))
                path = path + Path.DirectorySeparatorChar;
            return path.StartsWith(basePath, comparison);
        }
    }
}
