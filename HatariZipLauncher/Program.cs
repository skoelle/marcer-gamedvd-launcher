namespace HatariZipLauncher
{
    class Program
    {
        static void Main(string[] args)
        {
            Console.Title = "Hatari ZIP Launcher";
            var app = new LauncherApp();
            app.Run();
        }
    }
}
