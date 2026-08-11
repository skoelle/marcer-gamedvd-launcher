// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    class Program
    {
        // Console window title. Not configurable — fixed application display name.
        private const string DEFAULT_TITLE = "Marcer GameDVD Launcher";

        static void Main(string[] args)
        {
            Console.Title = DEFAULT_TITLE;
            var app = new LauncherApp();
            app.Run();
        }
    }
}
