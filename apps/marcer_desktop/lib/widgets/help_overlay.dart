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
                  Text('''   ↑ / ↓          Move selection up / down
   PgUp / PgDn    Jump one page up / down
   Enter / →      Open folder (launch comes in a later phase)
   *              Toggle favorite on selected ZIP
   ← / Backspace  Go up one directory (never exceeds root)
   ?              Show this help
   ESC / q        Exit the program

  Navigation is strictly limited to RootDirectory.
  The overlay shows both root and patch layers combined.

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
