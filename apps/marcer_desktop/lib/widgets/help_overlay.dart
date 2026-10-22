// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Desktop help overlay (DarkGray background, White text, any key dismisses).
/// Lists the catalog/folder, lightbox and mouse controls.
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
            child: Container(
              padding: const EdgeInsets.all(24),
              constraints: const BoxConstraints(maxWidth: 780),
              child: const SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('  Help — Keys & Controls',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    SizedBox(height: 12),
                    Text('''   CATALOG / FOLDER VIEW
   ↑ / ↓            Move selection (row in grid view)
   ← / →            Move selection / parent in folder view
   Home / End       First / last card (grid)
   PgUp / PgDn      Jump one page up / down
   Enter / →        Open folder / show the lightbox
   Backspace / ←    Parent directory (clears filters in catalog view)
   *                Toggle favorite
   P                Launch the selected ZIP with Hatari
   /                Focus the search field
   T                Toggle catalog grid / folder view
   ?                Show this help
   ESC / q          Exit the program

   LIGHTBOX
   ← / →            Previous / next card
   ↑ / ↓            Previous / next variant
   PgUp / PgDn      Previous / next image
   Space / P        Launch the shown ZIP
   *                Favorite the shown variant
   M                Make the shown candidate the main image
   C                Edit the shown ZIP's status/kind
   ESC              Close the lightbox
   ?                Show this help

   MOUSE / DETAILS
   Filmstrip        Thumbnail switches variant; star toggles favorite
   Candidate strip  Selects an image
   AtariLegend      Metadata, box scans, screenshots, reviews, magazines
   Box scans /      Curated local assets (viewer / OS default app)
   Manuals
   ROOT / PATCH     Open the game folder in the file manager

  The default view is the gallery-style catalog grid (section tabs,
  search, dropdowns). Press T (or the Folders button) for the optional
  overlay folder browser. Navigation is strictly limited to RootDirectory.
  The ★ Favorites filter lists the favorite games of the active section
  (search still applies; facets and status are ignored). The folder
  browser shows one Favorites folder per section.
  M swaps the shown candidate into the main image; C edits a ZIP's
  status/kind (pending until the Save (n) button in the filter bar).

  Press any key to continue...''',
                        style: TextStyle(color: Colors.white, fontSize: 14)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
