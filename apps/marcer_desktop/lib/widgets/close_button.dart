// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';

/// Breakpoint below which header close buttons collapse to the bare ×.
const double kDialogCloseLabelMinWidth = 720;

/// Shared close control for lightbox and dialog headers.
///
/// A labeled `× Close (Esc)` button at normal window widths, an icon-only
/// button with the same tooltip on narrow windows. The callback keeps the
/// dialog-specific dismissal logic at the call site.
class DialogCloseButton extends StatelessWidget {
  const DialogCloseButton({
    super.key,
    required this.onPressed,
    this.label = 'Close (Esc)',
    this.labelMinWidth = kDialogCloseLabelMinWidth,
  });

  final VoidCallback onPressed;
  final String label;
  final double labelMinWidth;

  @override
  Widget build(BuildContext context) {
    final showLabel = MediaQuery.sizeOf(context).width >= labelMinWidth;
    return Tooltip(
      message: label,
      child: SizedBox(
        height: 28,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: Colors.white70,
            backgroundColor: const Color(0xFF1B1B1B),
            overlayColor: const Color(0x14FFFFFF),
            minimumSize: Size.zero,
            padding: EdgeInsets.symmetric(horizontal: showLabel ? 9 : 7),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: const BorderSide(color: Color(0xFF3A3A3A)),
            ),
            textStyle: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.close, size: 15),
              if (showLabel) ...[const SizedBox(width: 5), Text(label)],
            ],
          ),
        ),
      ),
    );
  }
}
