// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// Base URL of an AtariLegend game page (`<base>/<slug>`).
const String kAtariLegendGameUrlBase = 'https://www.atarilegend.com/games/';

/// Injectable URL launcher (tests).
typedef AtariLegendUrlLauncher = Future<bool> Function(Uri uri);

/// Shows the cached AtariLegend metadata for [game] (the data fetched by
/// "Download AtariLegend data") with a button to open the AtariLegend page.
Future<void> showAtariLegendDialog(
  BuildContext context, {
  required AtariLegendGame game,
  AtariLegendUrlLauncher? launcher,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => AtariLegendDialog(game: game, launcher: launcher),
  );
}

class AtariLegendDialog extends StatelessWidget {
  const AtariLegendDialog({super.key, required this.game, this.launcher});

  final AtariLegendGame game;
  final AtariLegendUrlLauncher? launcher;

  Uri get _gameUri => Uri.parse('$kAtariLegendGameUrlBase${game.slug}');

  Future<void> _openPage(BuildContext context) async {
    var ok = false;
    try {
      final launch = launcher ??
          (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
      ok = await launch(_gameUri);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not open ${_gameUri.toString()}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0D0D0D),
      title: Row(
        children: [
          const Icon(Icons.open_in_new, size: 18, color: kAtariLegendTeal),
          const SizedBox(width: 8),
          const Text('AtariLegend',
              style: TextStyle(
                  color: kAtariLegendTeal, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                game.year == null ? game.name : '${game.name} (${game.year})',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              if (game.publisher.isNotEmpty)
                _row('Publisher', game.publisher),
              if (game.genres.isNotEmpty)
                _row('Genres', game.genres.join(', ')),
              if (game.developers.isNotEmpty)
                _row('Developers', game.developers.join(', ')),
              if (game.authors.isNotEmpty)
                _row('Authors', game.authors.join(', ')),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (game.slug.isNotEmpty)
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: kAtariLegendTeal,
              foregroundColor: Colors.black,
            ),
            onPressed: () => _openPage(context),
            child: const Text('Open on atarilegend.com'),
          ),
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
