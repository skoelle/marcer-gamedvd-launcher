// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    public class MenuRenderer
    {
        // Simple line-based double buffer to avoid full Clear() flicker.
        // cachedBuffer holds the last rendered text and colors for each visible row.
        private struct LineState { public string Text; public ConsoleColor Fg; public ConsoleColor Bg; }
        private LineState[] _cachedBuffer = Array.Empty<LineState>();
        private int _cachedWidth = -1;

        // Color configuration (injected; defaults to built-in scheme if null)
        private readonly AppColorConfig _colors;

        public MenuRenderer(AppColorConfig? colors = null)
        {
            _colors = colors ?? new AppColorConfig();
        }

        // availableLines is provided per-draw so the renderer adapts to console resizes
        public void DrawMenu(List<GameEntry> entries, int scrollOffset, int selectedIndex, int availableLines, Func<GameEntry, bool>? isFavorite = null)
        {
            availableLines = Math.Max(1, availableLines);
            int width = Console.WindowWidth;
            // Ensure cache matches current dimensions
            EnsureCache(width, availableLines);

            var newBuffer = new LineState[availableLines];
            for (int row = 0; row < availableLines; row++)
            {
                int idx = scrollOffset + row;
                if (idx < entries.Count)
                {
                    var e = entries[idx];
                    bool selected = (selectedIndex == idx);
                    // format the line text and colors
                    string text = BuildLineText(e, width, isFavorite?.Invoke(e) ?? false);
                    var (fg, bg) = GetColors(e, selected);
                    newBuffer[row].Text = text;
                    newBuffer[row].Fg = fg;
                    newBuffer[row].Bg = bg;
                }
                else
                {
                    newBuffer[row].Text = new string(' ', width);
                    newBuffer[row].Fg = ConsoleColor.Gray;
                    newBuffer[row].Bg = ConsoleColor.Black;
                }
            }

            // Diff & write only changed lines
            for (int row = 0; row < availableLines; row++)
            {
                var newLine = newBuffer[row];
                var oldLine = _cachedBuffer[row];
                if (oldLine.Text != newLine.Text || oldLine.Fg != newLine.Fg || oldLine.Bg != newLine.Bg)
                {
                    WriteConsoleLine(row, newLine);
                    _cachedBuffer[row] = newLine;
                }
            }
        }

        // Now accepts availableLines so the caller remains the single source of truth
        public void RedrawEntry(List<GameEntry> entries, int entryIdx, int row, bool selected, int availableLines, Func<GameEntry, bool>? isFavorite = null)
        {
            if (entryIdx < 0 || entryIdx >= entries.Count) return;
            availableLines = Math.Max(1, availableLines);
            // row is a visual row within the visible window; validate against availableLines
            if (row < 0 || row >= availableLines) return;

            int width = Console.WindowWidth;
            // Ensure the cache matches the current dimensions (same as DrawMenu)
            EnsureCache(width, availableLines);

            var e = entries[entryIdx];
            var (fg, bg) = GetColors(e, selected);
            string text = BuildLineText(e, width, isFavorite?.Invoke(e) ?? false);

            var newLine = new LineState { Text = text, Fg = fg, Bg = bg };
            // If cache differs, write
            if (row < _cachedBuffer.Length)
            {
                var old = _cachedBuffer[row];
                if (old.Text != newLine.Text || old.Fg != newLine.Fg || old.Bg != newLine.Bg)
                {
                    WriteConsoleLine(row, newLine);
                    _cachedBuffer[row] = newLine;
                }
            }
            else
            {
                // out of cache bounds - attempt a direct write
                // Validate row against current console height to prevent ArgumentOutOfRangeException
                if (row < Console.WindowHeight)
                {
                    WriteConsoleLine(row, newLine);
                }
            }
        }

        // Ensures the cached buffer has exactly availableLines entries and matches width.
        private void EnsureCache(int width, int availableLines)
        {
            if (_cachedBuffer.Length != availableLines || _cachedWidth != width)
            {
                _cachedBuffer = new LineState[availableLines];
                for (int i = 0; i < availableLines; i++) _cachedBuffer[i].Text = null!;
                _cachedWidth = width;
            }
        }

        // Write a line to the console using the centralized logic (handles concurrent resizes safely)
        private void WriteConsoleLine(int row, LineState newLine)
        {
            try
            {
                Console.SetCursorPosition(0, row);
                Console.BackgroundColor = newLine.Bg;
                Console.ForegroundColor = newLine.Fg;
                Console.Write(newLine.Text);
                Console.ResetColor();
            }
            catch
            {
                // ignore potential SetCursorPosition errors due to concurrent resize
            }
        }

        // Invalidates the internal line cache so the next DrawMenu call
        // performs a full redraw of every line. Useful after an overlay
        // (e.g. help box) has overwritten the console directly.
        public void InvalidateCache()
        {
            for (int i = 0; i < _cachedBuffer.Length; i++)
                _cachedBuffer[i].Text = null!;
        }

        // Renders a centered, bordered help box with key bindings inside the
        // available console area. The caller is responsible for waiting on a
        // key and redrawing the menu afterwards.
        public void ShowHelpBox(int availableLines)
        {
            try
            {
                int width = Console.WindowWidth;
                string[] helpLines = GetHelpLines();
                int boxHeight = Math.Min(helpLines.Length + 2, Math.Max(3, availableLines));
                int boxWidth = Math.Max(1, width);
                int topRow = Math.Max(0, (availableLines - boxHeight) / 2);

                Console.BackgroundColor = ConsoleColor.DarkGray;
                Console.ForegroundColor = ConsoleColor.White;

                string topBorder = "+" + new string('-', Math.Max(0, boxWidth - 2)) + "+";
                Console.SetCursorPosition(0, topRow);
                Console.Write(topBorder);

                for (int i = 0; i < boxHeight - 2; i++)
                {
                    int row = topRow + 1 + i;
                    string content;
                    if (i < helpLines.Length)
                    {
                        content = PadToWidth(helpLines[i], boxWidth - 2);
                    }
                    else
                    {
                        content = new string(' ', Math.Max(0, boxWidth - 2));
                    }
                    Console.SetCursorPosition(0, row);
                    Console.Write("|" + content + "|");
                }

                int bottomRow = topRow + boxHeight - 1;
                if (bottomRow < Console.WindowHeight)
                {
                    string bottomBorder = "+" + new string('-', Math.Max(0, boxWidth - 2)) + "+";
                    Console.SetCursorPosition(0, bottomRow);
                    Console.Write(bottomBorder);
                }

                Console.ResetColor();
            }
            catch
            {
            }
        }

        private static string[] GetHelpLines()
        {
            return [
                "  Help — Key Bindings",
                "  ",
                "   ↑ / ↓      Move selection up / down",
                "   Enter / →  Open folder / launch ZIP with Hatari",
                "   ← / BS     Go up one directory (never exceeds root)",
                "   ESC / Q    Exit the program",
                "   PgUp       Jump one page up",
                "   PgDn       Jump one page down",
                "   *          Toggle favorite on selected ZIP",
                "   ?          Show this help",
                "  ",
                "  Navigation is strictly limited to RootDirectory.",
                "  The overlay shows both root and patch layers combined.",
                "  ",
                "  Press any key to continue...",
            ];
        }

        private static string PadToWidth(string text, int width)
        {
            if (text.Length > width) return text.Substring(0, width);
            return text + new string(' ', width - text.Length);
        }

        // Returns foreground and background colors for an entry depending on selection state.
        // Selected colors and entry colors come from the injected AppColorConfig.
        private (ConsoleColor fg, ConsoleColor bg) GetColors(GameEntry e, bool selected)
        {
            if (selected)
            {
                return (_colors.SelectedForeground, _colors.SelectedBackground);
            }
            else
            {
                return (GetColorForEntry(e), ConsoleColor.Black);
            }
        }

        // Build the visible line text for an entry, ensuring it never exceeds the given width.
        private string BuildLineText(GameEntry e, int width, bool isFavorite)
        {
            if (width <= 0) return string.Empty;

            string label = GetLabel(e, isFavorite);

            // If the console width is smaller than the label, truncate the label
            if (width <= label.Length)
            {
                return label.Substring(0, width);
            }

            int maxNameLen = width - label.Length; // space left for name
            string displayName;
            if (e.Name.Length <= maxNameLen)
            {
                displayName = e.Name;
            }
            else
            {
                if (maxNameLen > 3)
                    displayName = e.Name.Substring(0, maxNameLen - 3) + "...";
                else
                    displayName = e.Name.Substring(0, Math.Max(0, maxNameLen));
            }

            int padding = Math.Max(0, width - label.Length - displayName.Length);
            var result = label + displayName + new string(' ', padding);
            // Ensure exact width (defensive): truncate or pad if needed
            if (result.Length > width) return result.Substring(0, width);
            if (result.Length < width) return result + new string(' ', width - result.Length);
            return result;
        }

        // Returns the left label for an entry based on kind, layer status and favorite state.
        // Format: [LayerLabel][TypeIndicator] where
        //   LayerLabel = [BOTH] / [ROOT] / [PTCH] (7 chars)
        //   TypeIndicator = [DIR]  for dirs, "    * " or "      " for ZIPs (6 chars)
        private static string GetLabel(GameEntry e, bool isFavorite)
        {
            // Layer label (7 chars)
            string layer;
            if (e.InRoot && e.InPatch) layer = "[BOTH] ";
            else if (e.InPatch) layer = "[PTCH] ";
            else if (e.InRoot) layer = "[ROOT] ";
            else layer = "       ";

            // Type indicator (6 chars)
            string type;
            if (e.Kind == EntryKind.Directory)
            {
                type = "[DIR] ";
            }
            else
            {
                type = isFavorite ? "    * " : "      ";
            }

            return layer + type;  // 13 chars total
        }

        private ConsoleColor GetColorForEntry(GameEntry e)
        {
            // Virtual entries (like the Favorites pseudo-folder) use the configured VirtualEntry color
            if (e.IsVirtual) return _colors.VirtualEntry;

            if (e.Kind == EntryKind.Directory)
            {
                if (e.InRoot && e.InPatch) return _colors.FolderBoth;       // Both layers
                if (e.InPatch && !e.InRoot) return _colors.FolderPatchOnly;  // Only patch
                if (e.InRoot && !e.InPatch) return _colors.FolderRootOnly;   // Only root
            }
            else if (e.Kind == EntryKind.Zip)
            {
                if (e.InRoot && e.InPatch) return _colors.ZipBoth;           // Both layers
                if (e.InRoot && !e.InPatch) return _colors.ZipRootOnly;     // Only root
                if (e.InPatch && !e.InRoot) return _colors.ZipPatchOnly;     // Only patch
            }
            return ConsoleColor.DarkGray;
        }
    }
}
