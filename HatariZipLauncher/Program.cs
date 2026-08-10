namespace HatariZipLauncher
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
