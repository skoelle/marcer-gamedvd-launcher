namespace HatariZipLauncher
{
    public class MenuRenderer
    {
        // Simple line-based double buffer to avoid full Clear() flicker.
        // cachedBuffer holds the last rendered text and colors for each visible row.
        private struct LineState { public string Text; public ConsoleColor Fg; public ConsoleColor Bg; }
        private LineState[] _cachedBuffer = Array.Empty<LineState>();
        private int _cachedWidth = -1;

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
            // Use the caller-provided availableLines (which should be Console.WindowHeight - 1)
            int maxRow = Math.Max(0, availableLines - 1);
            for (int row = 0; row < availableLines; row++)
            {
                if (row > maxRow) break;
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
            int maxRow = Math.Max(0, availableLines - 1);
            if (row < 0 || row > maxRow) return;

            int width = Console.WindowWidth;
            // ensure cache is valid for current width/height and the target row
            EnsureCacheForRow(width, Math.Min(availableLines, Math.Max(1, _cachedBuffer.Length == 0 ? 1 : _cachedBuffer.Length)));

            var e = entries[entryIdx];
            string text = BuildLineText(e, width, isFavorite?.Invoke(e) ?? false);
            ConsoleColor fg, bg;
            if (selected)
            {
                bg = ConsoleColor.DarkCyan;
                fg = ConsoleColor.Black;
            }
            else
            {
                bg = ConsoleColor.Black;
                fg = GetColorForEntry(e);
            }

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
                WriteConsoleLine(row, newLine);
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

        // Ensures the cached buffer has at least requiredRows entries and matches width.
        private void EnsureCacheForRow(int width, int requiredRows)
        {
            if (_cachedBuffer.Length < requiredRows || _cachedWidth != width)
            {
                int newLen = Math.Max(requiredRows, 1);
                _cachedBuffer = new LineState[newLen];
                for (int i = 0; i < newLen; i++) _cachedBuffer[i].Text = null!;
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

        // Returns foreground and background colors for an entry depending on selection state
        private (ConsoleColor fg, ConsoleColor bg) GetColors(GameEntry e, bool selected)
        {
            if (selected)
            {
                return (ConsoleColor.Black, ConsoleColor.DarkCyan);
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
            // Reserve 6 characters for the label area. For directories we show "[DIR] ",
            // for ZIPs we use the same width and optionally show a leading '*' when favorited.
            string label;
            if (e.Kind == EntryKind.Directory)
            {
                label = "[DIR] ";
            }
            else
            {
                // For ZIPs, show '*' after 4 spaces when favorited (keeps 6-char label area).
                label = isFavorite ? "    * " : new string(' ', 6);
            }

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

        private ConsoleColor GetColorForEntry(GameEntry e)
        {
            // Virtual entries (like the Favorites pseudo-folder) should be white
            if (e.IsVirtual) return ConsoleColor.White;
            if (e.Kind == EntryKind.Directory)
            {
                if (e.InRoot && e.InPatch) return ConsoleColor.Yellow; // Both layers
                if (e.InPatch && !e.InRoot) return ConsoleColor.DarkYellow; // Only patch
                if (e.InRoot && !e.InPatch) return ConsoleColor.Gray; // Only root
            }
            else if (e.Kind == EntryKind.Zip)
            {
                if (e.InRoot && e.InPatch) return ConsoleColor.Green;
                if (e.InRoot && !e.InPatch) return ConsoleColor.DarkGreen;
                if (e.InPatch && !e.InRoot) return ConsoleColor.Magenta;
            }
            return ConsoleColor.DarkGray;
        }
    }
}
