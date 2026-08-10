// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    // Configuration POCOs separated into their own file for clarity
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
    }
}
