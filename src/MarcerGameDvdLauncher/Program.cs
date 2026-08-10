// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    class Program
    {
        // Console window title. Not configurable — fixed application display name.
        private const string DefaultTitle = "Marcer GameDVD Launcher";

        static void Main(string[] args)
        {
            Console.Title = DefaultTitle;
            var app = new LauncherApp();
            app.Run();
        }
    }
}
