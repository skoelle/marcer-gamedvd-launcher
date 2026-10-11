// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';

import '../theme.dart';

/// Help overlay with the exact text of `SPEC.md` §9.4 (DarkGray background,
/// White text, any key dismisses).
class HelpOverlay extends StatefulWidget {
  const HelpOverlay({super.key, required this.onClose});

  final VoidCallback onClose;

  static void show(BuildContext context, VoidCallback onClose) {
    showDialog<void>(
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
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('  Help — Key Bindings',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                  SizedBox(height: 12),
                  Text('''   ↑ / ↓          Move selection (row in grid view)
   ← / →          Move selection left / right (grid)
   PgUp / PgDn    Jump one page up / down
   Enter / →      Open folder / show gallery lightbox
   Backspace      Parent directory (clears filters in catalog view)
   *              Toggle favorite on selected ZIP
   P              Launch the selected ZIP with Hatari
   /              Focus the search field
   T              Toggle catalog grid / folder view
   ?              Show this help
   ESC / q        Exit the program

  The default view is the gallery-style catalog grid (section tabs,
  search, dropdowns). Press T (or the Folders button) for the optional
  overlay folder browser. Navigation is strictly limited to RootDirectory.
  In the lightbox Space/P launches the shown ZIP.

  Press any key to continue...''',
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
