// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';

import '../open_local_file.dart';

/// Icon button that opens [path] in the operating system's file manager.
/// Reports a missing folder or a failed launch in a snackbar.
class OpenFolderButton extends StatefulWidget {
  const OpenFolderButton({
    super.key,
    required this.path,
    required this.label,
    this.color = Colors.grey,
    this.open = openLocalDirectory,
  });

  /// Absolute folder path; `null` disables the button.
  final String? path;

  /// Layer label used in the tooltip and error messages (`ROOT`/`PATCH`).
  final String label;

  final Color color;

  /// Injectable launcher (tests); defaults to [openLocalDirectory].
  final Future<bool> Function(String path) open;

  @override
  State<OpenFolderButton> createState() => _OpenFolderButtonState();
}

class _OpenFolderButtonState extends State<OpenFolderButton> {
  /// Never takes keyboard focus: the detail/lightbox shortcuts (Space, P, …)
  /// must keep working after a click.
  final FocusNode _focusNode =
      FocusNode(canRequestFocus: false, skipTraversal: true);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final path = widget.path;
    if (path == null || path.trim().isEmpty) {
      _snack('Game folder not found (${widget.label})');
      return;
    }
    if (!Directory(path).existsSync()) {
      _snack('Game folder not found (${widget.label}): $path');
      return;
    }
    final ok = await widget.open(path);
    if (!ok) {
      _snack('Could not open game folder (${widget.label}): $path');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.path == null
          ? 'Game folder not found (${widget.label})'
          : 'Open ${widget.label} game folder\n${widget.path}',
      child: IconButton(
        focusNode: _focusNode,
        onPressed: widget.path == null ? null : _open,
        icon: Icon(Icons.folder_open, size: 18, color: widget.color),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      ),
    );
  }
}

/// ROOT/PATCH folder buttons; only layers present in [layers] get an icon.
class CardFolderButtons extends StatelessWidget {
  const CardFolderButtons({
    super.key,
    required this.layers,
    required this.pathFor,
  });

  /// Layers in which the card's folder exists (`ROOT`/`PATCH`).
  final Future<Set<String>> layers;

  /// Absolute folder path for a layer (`ROOT`/`PATCH`).
  final String? Function(String layer) pathFor;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Set<String>>(
      key: ObjectKey(layers),
      future: layers,
      builder: (context, snapshot) {
        final existing = snapshot.data;
        if (existing == null || existing.isEmpty) {
          return const SizedBox.shrink();
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (existing.contains('ROOT'))
              OpenFolderButton(
                path: pathFor('ROOT'),
                label: 'ROOT',
                color: Colors.grey,
              ),
            if (existing.contains('PATCH'))
              OpenFolderButton(
                path: pathFor('PATCH'),
                label: 'PATCH',
                color: Colors.amber,
              ),
          ],
        );
      },
    );
  }
}
