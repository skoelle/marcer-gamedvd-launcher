using System;
using System.Runtime.InteropServices;

namespace MarcerGameDvdLauncher
{
    // Small helpers refactored into their own file to keep Program.cs focused.
    internal static class ProgramHelpers
    {
        // Flushes the console input buffer to avoid processing leftover key events
        // Uses Win32 FlushConsoleInputBuffer on the standard input handle. On non-Windows
        // environments this will be a no-op.
        public static void FlushInputBuffer()
        {
            try
            {
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                {
                    var handle = GetStdHandle(STD_INPUT_HANDLE);
                    if (handle != IntPtr.Zero)
                    {
                        FlushConsoleInputBuffer(handle);
                    }
                }
            }
            catch
            {
                // swallowing is OK here; flushing input is a best-effort UX improvement
            }
        }

        private const int STD_INPUT_HANDLE = -10;

        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
        private static extern bool FlushConsoleInputBuffer(IntPtr hConsoleInput);

        // P/Invoke to query key state (used to detect physical key release)
        private const int VK_RETURN = 0x0D;

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        // Shows a simple modal message on the reserved last console line and
        // blocks until the Return key is physically released. The message is
        // then removed and the method returns. This is designed to be a
        // lightweight modal for the console UI and uses the last console line
        // which the application reserves for transient messages.
        public static void ShowModalUntilReturnReleased(string message)
        {
            try
            {
                int lastRow = Math.Max(0, Console.WindowHeight - 1);
                int width = Console.WindowWidth;
                string text = message ?? string.Empty;
                if (text.Length > width) text = text.Substring(0, Math.Max(0, width - 3)) + "...";
                int padding = Math.Max(0, width - text.Length);
                string line = text + new string(' ', padding);

                Console.BackgroundColor = ConsoleColor.DarkGray;
                Console.ForegroundColor = ConsoleColor.White;
                try { Console.SetCursorPosition(0, lastRow); } catch { }
                try { Console.Write(line); } catch { }
                Console.ResetColor();

                // Wait until Return key is not pressed
                // GetAsyncKeyState returns a short where the high-order bit is set when key is down
                while ((GetAsyncKeyState(VK_RETURN) & 0x8000) != 0)
                {
                    Thread.Sleep(10);
                }

                // Clear the line
                try { Console.SetCursorPosition(0, lastRow); } catch { }
                try { Console.Write(new string(' ', width)); } catch { }
            }
            catch
            {
                // ignore any console errors here
            }
            finally
            {
                Console.ResetColor();
            }
        }

        public static string ResolveIfRelative(string? path, string exeDir)
        {
            if (string.IsNullOrWhiteSpace(path))
                return string.Empty;
            if (Path.IsPathRooted(path))
                return path;
            return Path.GetFullPath(Path.Combine(exeDir, path));
        }

        // Centralized console message printer to avoid duplicated Console.WriteLine/ReadKey blocks.
        public static void ShowConsoleMessage(string[] lines, ConsoleColor fg = ConsoleColor.Gray, bool clear = true, bool waitForKey = true)
        {
            if (clear) Console.Clear();
            var prev = Console.ForegroundColor;
            try
            {
                Console.ForegroundColor = fg;
                foreach (var l in lines) Console.WriteLine(l);
            }
            finally
            {
                Console.ForegroundColor = prev;
            }
            if (waitForKey) Console.ReadKey(intercept: true);
        }
    }
}
