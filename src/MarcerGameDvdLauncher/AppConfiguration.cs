// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    // Configuration POCOs separated into their own file for clarity

    /// <summary>
    /// Color configuration for the menu renderer.
    /// All properties have default values matching the original hardcoded scheme,
    /// so omitting any value (or the entire "Colors" section) preserves existing behaviour.
    /// </summary>
    public class AppColorConfig
    {
        public ConsoleColor FolderBoth { get; set; } = ConsoleColor.Yellow;
        public ConsoleColor FolderPatchOnly { get; set; } = ConsoleColor.DarkYellow;
        public ConsoleColor FolderRootOnly { get; set; } = ConsoleColor.Gray;
        public ConsoleColor ZipBoth { get; set; } = ConsoleColor.Green;
        public ConsoleColor ZipRootOnly { get; set; } = ConsoleColor.DarkGreen;
        public ConsoleColor ZipPatchOnly { get; set; } = ConsoleColor.Magenta;
        public ConsoleColor SelectedForeground { get; set; } = ConsoleColor.Black;
        public ConsoleColor SelectedBackground { get; set; } = ConsoleColor.DarkCyan;
        public ConsoleColor VirtualEntry { get; set; } = ConsoleColor.White;
    }

    public class AppHatariConfig
    {
        public string? Executable { get; set; }
        public string? ConfigFile { get; set; }
        public string? ArgsTemplate { get; set; }
    }

    public class AppConfig
    {
        public string? RootDirectory { get; set; }
        public string? PatchDirectory { get; set; }
        public AppHatariConfig? Hatari { get; set; }
        // Ignored during JSON deserialization — parsed manually in LoadConfiguration so that
        // invalid color strings fall back to defaults instead of throwing.
        [System.Text.Json.Serialization.JsonIgnore]
        public AppColorConfig? Colors { get; set; }
    }
}
