// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import 'settings_form.dart';

/// Modal editor for the path fields of `desktop.config.json` (opened via the
/// gear button in the filter bar, or the "Setup" button on the config error
/// page). Returns the edited [DesktopConfig] on save, or `null` on cancel
/// (ESC / barrier tap / Cancel). Save stays disabled until every field is
/// valid (see [SettingsForm]); while a download/extraction runs, Save, Cancel
/// and dismissal are blocked so the transfer is not interrupted.
Future<DesktopConfig?> showSettingsDialog(
  BuildContext context, {
  required DesktopConfig config,
  String title = 'Settings',
  String subtitle = 'desktop.config.json — paths',
}) {
  return showDialog<DesktopConfig>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        SettingsDialog(config: config, title: title, subtitle: subtitle),
  );
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.config,
    this.title = 'Settings',
    this.subtitle = 'desktop.config.json — paths',
  });

  final DesktopConfig config;
  final String title;
  final String subtitle;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final FocusNode _focus = FocusNode();
  DesktopConfig? _latest;
  bool _valid = false;

  /// True while a download/extraction runs in the form (blocks Save/Cancel/
  /// dismissal so the running transfer is not interrupted).
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final edited = _latest;
    if (edited == null || !_valid || _busy) return;
    Navigator.of(context).pop(edited);
  }

  void _cancel() {
    if (_busy) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            if (_busy) return KeyEventResult.handled;
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: GestureDetector(
          onTap: () {
            if (_busy) return;
            Navigator.of(context).pop();
          },
          child: Container(
            color: Colors.black.withValues(alpha: 0.6),
            alignment: Alignment.center,
            child: GestureDetector(
              onTap: () {}, // keep taps on the dialog itself
              child: Container(
                width: math.min(
                    1100, MediaQuery.sizeOf(context).width - 64),
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height - 80),
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
                      widget.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: SingleChildScrollView(
                        child: SettingsForm(
                          initial: widget.config,
                          onChanged: (config, valid) {
                            _latest = config;
                            _valid = valid;
                            setState(() {});
                          },
                          onBusyChanged: (busy) {
                            if (mounted) setState(() => _busy = busy);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: _busy ? null : _cancel,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: (_valid && !_busy) ? _save : null,
                          child: const Text('Save'),
                        ),
                      ],
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
