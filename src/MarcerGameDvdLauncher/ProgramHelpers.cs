// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

using System.Runtime.InteropServices;

namespace MarcerGameDvdLauncher
{
    // Small helpers refactored into their own file to keep Program.cs focused.
    internal static class ProgramHelpers
    {
        // The console window height minus one. The last row is reserved to prevent
        // auto-scroll / flicker when the cursor reaches the bottom row (project policy).
        // Centralized here so the policy lives in exactly one place.
        public static int AvailableLines => Math.Max(0, Console.WindowHeight - 1);

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

        // Win32 API constants — intentionally hardcoded (bewusst hartkodiert).
        // These are defined by the Windows API and do not change.
        private const int STD_INPUT_HANDLE = -10;

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FlushConsoleInputBuffer(IntPtr hConsoleInput);

        // P/Invoke to query key state (used to detect physical key release)
        // Win32 virtual-key code — intentionally hardcoded (bewusst hartkodiert).
        private const int VK_RETURN = 0x0D;

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        // Shows a simple modal message in the center of the console and
        // blocks until the given process has exited. The message is then
        // removed and the method returns.
        public static void ShowModalUntilProcessExited(System.Diagnostics.Process? process, string? message)
        {
            try
            {
                int width = Console.WindowWidth;
                int height = Console.WindowHeight;
                int centerRow = height / 2;

                var text = message ?? string.Empty;
                if (text.Length > width - 4) text = text.Substring(0, Math.Max(0, width - 7)) + "...";
                int leftPad = Math.Max(0, (width - text.Length) / 2);
                var line = new string(' ', leftPad) + text;

                Console.BackgroundColor = ConsoleColor.DarkGray;
                Console.ForegroundColor = ConsoleColor.White;
                try { Console.SetCursorPosition(0, centerRow); } catch { }
                try { Console.Write(line.PadRight(width)); } catch { }
                Console.ResetColor();

                // Wait until the external process has exited
                while (process != null && !process.HasExited)
                {
                    Thread.Sleep(100);
                }

                // Clear the line
                try { Console.SetCursorPosition(0, centerRow); } catch { }
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
