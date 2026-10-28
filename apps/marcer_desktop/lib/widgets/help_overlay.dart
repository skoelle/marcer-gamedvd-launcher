// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'close_button.dart';

/// Desktop help overlay (DarkGray background, White text, any key dismisses).
/// Catalog/folder and lightbox controls sit side by side, mouse/details and
/// notes below.
class HelpOverlay extends StatefulWidget {
  const HelpOverlay({super.key, required this.onClose});

  final VoidCallback onClose;

  static Future<void> show(BuildContext context, VoidCallback onClose) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => HelpOverlay(onClose: onClose),
    );
  }

  @override
  State<HelpOverlay> createState() => _HelpOverlayState();
}

class _HelpOverlayState extends State<HelpOverlay> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: (node, event) {
          // Only a real key press dismisses — ignoring KeyUp/KeyRepeat
          // keeps the overlay open while the `?` that opened it is still
          // held down.
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          widget.onClose();
          return KeyEventResult.handled;
        },
        child: GestureDetector(
          onTap: widget.onClose,
          child: Container(
            color: kConsoleColors['DarkGray']!.withValues(alpha: 0.95),
            alignment: Alignment.center,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: SingleChildScrollView(
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1.25,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 840;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Help — Keys & Controls',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const Text(
                                  'Press any key to close',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                DialogCloseButton(onPressed: widget.onClose),
                              ],
                            ),
                            const SizedBox(height: 18),
                            if (wide)
                              const Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _HelpSection(
                                      key: Key('help-catalog'),
                                      title: 'CATALOG / FOLDER VIEW',
                                      shortcuts: _catalogShortcuts,
                                    ),
                                  ),
                                  SizedBox(width: 36),
                                  Expanded(
                                    child: _HelpSection(
                                      key: Key('help-lightbox'),
                                      title: 'LIGHTBOX',
                                      shortcuts: _lightboxShortcuts,
                                    ),
                                  ),
                                ],
                              )
                            else
                              const Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _HelpSection(
                                    key: Key('help-catalog'),
                                    title: 'CATALOG / FOLDER VIEW',
                                    shortcuts: _catalogShortcuts,
                                  ),
                                  SizedBox(height: 20),
                                  _HelpSection(
                                    key: Key('help-lightbox'),
                                    title: 'LIGHTBOX',
                                    shortcuts: _lightboxShortcuts,
                                  ),
                                ],
                              ),
                            const SizedBox(height: 22),
                            if (wide)
                              const Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _HelpSection(
                                      key: Key('help-mouse'),
                                      title: 'MOUSE / DETAILS',
                                      shortcuts: _mouseShortcuts,
                                    ),
                                  ),
                                  SizedBox(width: 36),
                                  Expanded(
                                    child: _HelpSection(
                                      key: Key('help-notes'),
                                      title: 'NOTES',
                                      shortcuts: _noteShortcuts,
                                    ),
                                  ),
                                ],
                              )
                            else
                              const Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _HelpSection(
                                    key: Key('help-mouse'),
                                    title: 'MOUSE / DETAILS',
                                    shortcuts: _mouseShortcuts,
                                  ),
                                  SizedBox(height: 20),
                                  _HelpSection(
                                    key: Key('help-notes'),
                                    title: 'NOTES',
                                    shortcuts: _noteShortcuts,
                                  ),
                                ],
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HelpSection extends StatelessWidget {
  const _HelpSection({
    super.key,
    required this.title,
    required this.shortcuts,
  });

  final String title;
  final List<_Shortcut> shortcuts;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 8),
        for (final shortcut in shortcuts)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 132,
                  child: Text(
                    shortcut.keys,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(child: Text(shortcut.description)),
              ],
            ),
          ),
      ],
    );
  }
}

class _Shortcut {
  const _Shortcut(this.keys, this.description);

  final String keys;
  final String description;
}

const List<_Shortcut> _catalogShortcuts = [
  _Shortcut('↑ / ↓', 'Move selection (row in grid view)'),
  _Shortcut('← / →', 'Move selection / parent in folder view'),
  _Shortcut('Home / End', 'First / last card (grid)'),
  _Shortcut('PgUp / PgDn', 'Jump one page up / down'),
  _Shortcut('Enter / →', 'Open folder / show the lightbox'),
  _Shortcut('Backspace / ←', 'Parent directory (clears filters in catalog view)'),
  _Shortcut('*', 'Toggle favorite'),
  _Shortcut('P', 'Launch the selected ZIP with Hatari'),
  _Shortcut('/', 'Focus the search field'),
  _Shortcut('T', 'Toggle catalog grid / folder view'),
  _Shortcut('?', 'Show this help'),
  _Shortcut('ESC / q', 'Exit the program'),
];

const List<_Shortcut> _lightboxShortcuts = [
  _Shortcut('← / →', 'Previous / next card'),
  _Shortcut('↑ / ↓', 'Previous / next variant'),
  _Shortcut('PgUp / PgDn', 'Previous / next image'),
  _Shortcut('Space / P', 'Launch the shown ZIP'),
  _Shortcut('*', 'Favorite the shown variant'),
  _Shortcut('M', 'Make the shown candidate the main image'),
  _Shortcut('C', "Edit the shown ZIP's status/kind"),
  _Shortcut('ESC', 'Close the lightbox'),
  _Shortcut('?', 'Show this help'),
];

const List<_Shortcut> _mouseShortcuts = [
  _Shortcut('Filmstrip', 'Thumbnail switches variant; star toggles favorite'),
  _Shortcut('Candidate strip', 'Selects an image'),
  _Shortcut('AtariLegend', 'Metadata, box scans, screenshots, reviews, magazines'),
  _Shortcut('Box scans / Manuals', 'Curated local assets (viewer / OS default app)'),
  _Shortcut('ROOT / PATCH', 'Open the game folder in the file manager'),
];

const List<_Shortcut> _noteShortcuts = [
  _Shortcut('VIEW', 'Catalog grid is the default; T / Folders opens the folder browser'),
  _Shortcut('★', 'Favorites of the active section (search applies; facets/status ignored)'),
  _Shortcut('CURATION', 'M swaps a candidate; C edits status/kind until Save (n)'),
  _Shortcut('ROOT', 'Navigation is strictly limited to RootDirectory'),
];
