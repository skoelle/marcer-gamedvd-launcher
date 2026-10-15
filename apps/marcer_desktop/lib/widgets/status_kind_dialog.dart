// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Result of [showStatusKindDialog]: the picked status/kind pair.
typedef StatusKindChoice = ({String status, String? kind});

/// One selectable status/kind combination.
class StatusKindOption {
  const StatusKindOption(this.label, this.status, this.kind);

  final String label;
  final String status;
  final String? kind;
}

/// All combinations offered by the manual curation dialog (`C`): every
/// done/desktop kind pairing plus the pipeline-only statuses (kind null).
const List<StatusKindOption> kStatusKindOptions = [
  StatusKindOption('done (game)', 'done', 'game'),
  StatusKindOption('done (textscreen)', 'done', 'textscreen'),
  StatusKindOption('done (darkscreen)', 'done', 'darkscreen'),
  StatusKindOption('desktop (desktop)', 'desktop', 'desktop'),
  StatusKindOption('desktop (textscreen)', 'desktop', 'textscreen'),
  StatusKindOption('desktop (darkscreen)', 'desktop', 'darkscreen'),
  StatusKindOption('no usable shots', 'no_usable_shots', null),
  StatusKindOption('interrupted', 'interrupted', null),
  StatusKindOption('pending', 'pending', null),
  StatusKindOption('skipped (disk 2+)', 'skipped_disk_n', null),
];

/// Modal list of status/kind combinations (`C` in the lightbox / detail
/// view). Returns null on cancel. The current pair is highlighted.
Future<StatusKindChoice?> showStatusKindDialog(
  BuildContext context, {
  required String title,
  String? currentStatus,
  String? currentKind,
}) {
  final normKind = (currentKind == null || currentKind.isEmpty)
      ? null
      : currentKind;
  return showDialog<StatusKindChoice>(
    context: context,
    barrierDismissible: true,
    builder: (_) => StatusKindDialog(
      title: title,
      currentStatus: currentStatus,
      currentKind: normKind,
    ),
  );
}

class StatusKindDialog extends StatefulWidget {
  const StatusKindDialog({
    super.key,
    required this.title,
    this.currentStatus,
    this.currentKind,
  });

  final String title;
  final String? currentStatus;
  final String? currentKind;

  @override
  State<StatusKindDialog> createState() => _StatusKindDialogState();
}

class _StatusKindDialogState extends State<StatusKindDialog> {
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

  bool _isCurrent(StatusKindOption o) =>
      o.status == widget.currentStatus && o.kind == widget.currentKind;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.keyC) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            color: Colors.black.withValues(alpha: 0.6),
            alignment: Alignment.center,
            child: GestureDetector(
              onTap: () {}, // keep taps on the dialog itself
              child: Container(
                width: 340,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0D0D),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF2A2A2A)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Set status / kind',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    for (final o in kStatusKindOptions) ...[
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () =>
                            Navigator.of(context).pop<StatusKindChoice>(
                                (status: o.status, kind: o.kind)),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                            color: _isCurrent(o)
                                ? Colors.cyan.withValues(alpha: 0.18)
                                : null,
                            borderRadius: BorderRadius.circular(4),
                            border: _isCurrent(o)
                                ? Border.all(color: Colors.cyan)
                                : null,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(o.label,
                                    style: TextStyle(
                                      color: _isCurrent(o)
                                          ? Colors.cyan
                                          : Colors.white,
                                      fontSize: 12,
                                      fontWeight: _isCurrent(o)
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    )),
                              ),
                              if (_isCurrent(o))
                                const Icon(Icons.check,
                                    size: 14, color: Colors.cyan),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    const SizedBox(height: 8),
                    const Text(
                      'In-memory until Save (n) · ESC cancels',
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                    ),
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
