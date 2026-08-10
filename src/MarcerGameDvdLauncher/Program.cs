// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    class Program
    {
        static void Main(string[] args)
        {
            Console.Title = "Marcer GameDVD Launcher";
            var app = new LauncherApp();
            app.Run();
        }
    }
}
