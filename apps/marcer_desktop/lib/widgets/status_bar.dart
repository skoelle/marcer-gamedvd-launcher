// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';

import '../catalog_controller.dart';

/// Bottom status bar of the catalog view.
///
/// The running app version is pinned to the bottom-right so it stays visible
/// on narrow windows. The status/warning text truncates before it; the full
/// text is available as a tooltip.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.controller, this.version});

  final CatalogController controller;

  /// Running app version, right-aligned in the bar (`null` while the async
  /// `PackageInfo` read has not finished / failed).
  final String? version;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final messages = <String>[
      if (!c.catalogMode) c.displayPath,
      c.countText,
      ...c.statusLine,
    ];
    final notices = [...c.notices];
    final favErr = c.favorites?.lastSaveError;
    if (favErr != null) notices.add('favorites save failed: $favErr');
    return Container(
      color: const Color(0xFF1B1B1B),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                if (c.launching) ...[
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 6),
                  const Flexible(
                    child: _EllipsizedText(
                      'Hatari is running…',
                      color: Colors.lightGreen,
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                if (c.downloading) ...[
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: _EllipsizedText(
                      'Downloading… ${c.downloadProgress}',
                      color: Colors.orangeAccent,
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                if (c.cosmosExSending) ...[
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: _EllipsizedText(
                      'Sending to CosmosEx… ${c.cosmosExProgress}',
                      color: Colors.lightBlue,
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                Expanded(child: _StatusText(messages, notices)),
              ],
            ),
          ),
          if (version != null) ...[
            const SizedBox(width: 16),
            Text(
              'v$version',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Joined status message + notices on one line, ellipsized at the end. The
/// full text is shown as a tooltip.
class _StatusText extends StatelessWidget {
  const _StatusText(this.messages, this.notices);

  final List<String> messages;
  final List<String> notices;

  @override
  Widget build(BuildContext context) {
    final message = messages.join('  ·  ');
    final notice = notices.join('  |  ');
    if (message.isEmpty && notice.isEmpty) return const SizedBox.shrink();
    final full = [
      message,
      notice,
    ].where((part) => part.isNotEmpty).join('  |  ');
    return Tooltip(
      message: full,
      waitDuration: const Duration(milliseconds: 400),
      child: Text.rich(
        TextSpan(
          children: [
            if (message.isNotEmpty)
              TextSpan(
                text: message,
                style: const TextStyle(color: Colors.grey),
              ),
            if (notice.isNotEmpty)
              TextSpan(
                text: '${message.isEmpty ? '' : '  |  '}$notice',
                style: const TextStyle(color: Colors.orange),
              ),
          ],
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
    );
  }
}

/// Single-line label that ellipsizes on narrow windows and exposes the full
/// text as a tooltip.
class _EllipsizedText extends StatelessWidget {
  const _EllipsizedText(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: text,
      waitDuration: const Duration(milliseconds: 400),
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}
