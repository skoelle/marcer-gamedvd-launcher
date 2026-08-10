// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

namespace MarcerGameDvdLauncher
{
    public class NavigationController
    {
        public int SelectedIndex { get; private set; } = 0;
        public int ScrollOffset { get; private set; } = 0;
        public string CurrentRelativePath { get; private set; } = "";
        // Stores the last selection & scroll position for each directory
        private readonly Dictionary<string, (int sel, int scroll)> _lastSelections = new();

        public void ResetSelection()
        {
            SelectedIndex = 0;
            ScrollOffset = 0;
        }

        public void SetEntriesCount(int count)
        {
            if (SelectedIndex >= count || SelectedIndex < 0) ResetSelection();
            if (ScrollOffset > count - 1) ScrollOffset = Math.Max(0, count - 1);
        }

        public bool MoveUp(List<GameEntry> entries, int availableLines)
        {
            int oldScroll = ScrollOffset;
            if (SelectedIndex > 0) SelectedIndex--;
            UpdateScrollOffset(entries.Count, availableLines);
            return oldScroll != ScrollOffset;
        }

        public bool MoveDown(List<GameEntry> entries, int availableLines)
        {
            int oldScroll = ScrollOffset;
            if (SelectedIndex < entries.Count - 1) SelectedIndex++;
            UpdateScrollOffset(entries.Count, availableLines);
            return oldScroll != ScrollOffset;
        }

        public void PageUp(List<GameEntry> entries, int availableLines)
        {
            if (entries.Count == 0) return;
            int newSelected = SelectedIndex - availableLines;
            if (newSelected < 0) newSelected = 0;
            SelectedIndex = newSelected;
            UpdateScrollOffset(entries.Count, availableLines);
        }

        public void PageDown(List<GameEntry> entries, int availableLines)
        {
            if (entries.Count == 0) return;
            int newSelected = SelectedIndex + availableLines;
            if (newSelected >= entries.Count) newSelected = entries.Count - 1;
            SelectedIndex = newSelected;
            UpdateScrollOffset(entries.Count, availableLines);
        }

        public void HandleEnter(List<GameEntry> entries)
        {
            if (entries.Count == 0) return;
            var entry = entries[SelectedIndex];
            if (entry.Kind == EntryKind.Directory)
            {
                _lastSelections[CurrentRelativePath] = (SelectedIndex, ScrollOffset);
                CurrentRelativePath = Path.Combine(CurrentRelativePath, entry.Name);
                if (_lastSelections.TryGetValue(CurrentRelativePath, out var tuple))
                {
                    SelectedIndex = tuple.sel;
                    ScrollOffset = tuple.scroll;
                }
                else
                {
                    ResetSelection();
                }
            }
            // Actual file launch is still caller's responsibility!
        }

        public void GoUpDirectory()
        {
            if (string.IsNullOrEmpty(CurrentRelativePath)) return;
            _lastSelections[CurrentRelativePath] = (SelectedIndex, ScrollOffset);
            CurrentRelativePath = Path.GetDirectoryName(CurrentRelativePath) ?? "";
            if (_lastSelections.TryGetValue(CurrentRelativePath, out var tuple))
            {
                SelectedIndex = tuple.sel;
                ScrollOffset = tuple.scroll;
            }
            else
            {
                ResetSelection();
            }
        }

        public void UpdateScrollOffset(int entryCount, int availableLines)
        {
            if (availableLines < 1) availableLines = 1;
            if (entryCount <= availableLines) { ScrollOffset = 0; return; }
            if (SelectedIndex == 0) { ScrollOffset = 0; return; }
            int bottomScrollTrigger = ScrollOffset + (int)(availableLines * 2 / 3.0);
            int topScrollTrigger = ScrollOffset + (int)(availableLines * 1 / 3.0);
            if (SelectedIndex >= bottomScrollTrigger && (ScrollOffset + availableLines) < entryCount)
                ScrollOffset = SelectedIndex - (int)(availableLines * 2 / 3.0);
            else if (SelectedIndex < topScrollTrigger && ScrollOffset > 0)
                ScrollOffset = SelectedIndex - (int)(availableLines * 1 / 3.0);
            if (ScrollOffset < 0) ScrollOffset = 0;
            if (ScrollOffset > entryCount - availableLines)
                ScrollOffset = entryCount - availableLines;
        }
    }
}
