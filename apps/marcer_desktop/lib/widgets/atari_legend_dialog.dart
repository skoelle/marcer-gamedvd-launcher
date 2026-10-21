// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// Injectable URL launcher (tests).
typedef AtariLegendUrlLauncher = Future<bool> Function(Uri uri);

/// Injectable image builder so widget tests do not hit the network. The
/// default is `Image.network` with loading/error placeholders.
typedef AtariLegendImageBuilder = Widget Function(
  BuildContext context,
  String url, {
  int? cacheWidth,
  BoxFit? fit,
});

Widget _defaultImageBuilder(
  BuildContext context,
  String url, {
  int? cacheWidth,
  BoxFit? fit,
}) {
  return Image.network(
    url,
    cacheWidth: cacheWidth,
    fit: fit ?? BoxFit.contain,
    gaplessPlayback: true,
    loadingBuilder: (context, child, progress) {
      if (progress == null) return child;
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    },
    errorBuilder: (context, error, stack) => const Center(
      child: Icon(Icons.broken_image_outlined, size: 22, color: Colors.grey),
    ),
  );
}

/// Shows the cached AtariLegend metadata and the web boxscans/screenshots
/// (hotlinked from atarilegend.com; nothing is bundled or cached on disk).
Future<void> showAtariLegendDialog(
  BuildContext context, {
  required AtariLegendGame game,
  AtariLegendUrlLauncher? launcher,
  AtariLegendImageBuilder? imageBuilder,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => AtariLegendDialog(
      game: game,
      launcher: launcher,
      imageBuilder: imageBuilder,
    ),
  );
}

class AtariLegendDialog extends StatelessWidget {
  const AtariLegendDialog({
    super.key,
    required this.game,
    this.launcher,
    this.imageBuilder,
  });

  final AtariLegendGame game;
  final AtariLegendUrlLauncher? launcher;
  final AtariLegendImageBuilder? imageBuilder;

  Uri get _gameUri => Uri.parse(atariLegendGameUrl(game.slug));

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
    final builder = imageBuilder ?? _defaultImageBuilder;
    final size = MediaQuery.sizeOf(context);
    final width = math.min(860.0, size.width - 80);
    // Fallback for v1/v2 caches that only carry names.
    final developers = game.developerCredits.isNotEmpty
        ? game.developerCredits
        : [for (final n in game.developers) AtariLegendCredit(name: n)];
    final authors = game.authorCredits.isNotEmpty
        ? game.authorCredits
        : [for (final n in game.authors) AtariLegendCredit(name: n)];

    return AlertDialog(
      backgroundColor: const Color(0xFF0D0D0D),
      insetPadding: const EdgeInsets.all(20),
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
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: size.height * 0.82),
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
                if (game.conversion.isNotEmpty)
                  _row('Conversion', game.conversion),
                if (developers.isNotEmpty) _credits('Developers', developers),
                if (authors.isNotEmpty) _credits('Authors', authors),
                if (game.boxscans.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _sectionHeading('Boxscans (${game.boxscans.length})'),
                  const SizedBox(height: 6),
                  _boxscanRow(context, builder),
                ],
                if (game.screenshots.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _sectionHeading('Screenshots (${game.screenshots.length})'),
                  const SizedBox(height: 6),
                  _screenshotGrid(context, builder),
                ],
                if (game.boxscans.isNotEmpty || game.screenshots.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text('Images: atarilegend.com — CC BY-NC-SA 4.0',
                      style: TextStyle(color: Colors.grey, fontSize: 10)),
                ],
              ],
            ),
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

  Widget _sectionHeading(String text) => Text(
        text,
        style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            decoration: TextDecoration.underline),
      );

  Widget _boxscanRow(BuildContext context, AtariLegendImageBuilder builder) {
    return SizedBox(
      height: 186,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: game.boxscans.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final scan = game.boxscans[i];
          final label = scan.type.isEmpty ? 'Boxscan' : scan.type;
          return SizedBox(
            width: 132,
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => _openViewer(context, builder, boxscans: true,
                  initialIndex: i),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFF2A2A2A)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: builder(
                        context,
                        atariLegendBoxscanThumbUrl(scan),
                        cacheWidth: 300,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 10)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _screenshotGrid(
      BuildContext context, AtariLegendImageBuilder builder) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < game.screenshots.length; i++)
          SizedBox(
            width: 176,
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => _openViewer(context, builder, boxscans: false,
                    initialIndex: i),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFF2A2A2A)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: builder(
                    context,
                    atariLegendScreenshotUrl(game.slug, game.screenshots[i]),
                    cacheWidth: 400,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _openViewer(
    BuildContext context,
    AtariLegendImageBuilder builder, {
    required bool boxscans,
    required int initialIndex,
  }) {
    final items = boxscans
        ? [
            for (final scan in game.boxscans)
              _ViewerItem(
                url: atariLegendBoxscanUrl(scan),
                label: scan.type.isEmpty ? 'Boxscan' : scan.type,
              ),
          ]
        : [
            for (final image in game.screenshots)
              _ViewerItem(
                url: atariLegendScreenshotUrl(game.slug, image),
                label: 'Screenshot',
              ),
          ];
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _AtariLegendImageViewer(
        items: items,
        initialIndex: initialIndex,
        imageBuilder: builder,
        gameUrl: game.slug.isEmpty ? null : atariLegendGameUrl(game.slug),
        launcher: launcher,
      ),
    );
  }

  /// Multi-line credits: each name on its own line with the role directly
  /// below it (e.g. `Taito` / `Arcade`, `Tatsumi` / `Game Conversion`).
  Widget _credits(String label, List<AtariLegendCredit> credits) {
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < credits.length; i++) ...[
                  Text(credits[i].name,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12)),
                  if (credits[i].role.isNotEmpty)
                    Text(credits[i].role,
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 11)),
                  if (i < credits.length - 1) const SizedBox(height: 4),
                ],
              ],
            ),
          ),
        ],
      ),
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

class _ViewerItem {
  const _ViewerItem({required this.url, required this.label});

  final String url;
  final String label;
}

/// Full-size AtariLegend image viewer: `←/→` navigate, `Esc` closes.
class _AtariLegendImageViewer extends StatefulWidget {
  const _AtariLegendImageViewer({
    required this.items,
    required this.initialIndex,
    required this.imageBuilder,
    this.gameUrl,
    this.launcher,
  });

  final List<_ViewerItem> items;
  final int initialIndex;
  final AtariLegendImageBuilder imageBuilder;
  final String? gameUrl;
  final AtariLegendUrlLauncher? launcher;

  @override
  State<_AtariLegendImageViewer> createState() =>
      _AtariLegendImageViewerState();
}

class _AtariLegendImageViewerState extends State<_AtariLegendImageViewer> {
  late int _index =
      widget.initialIndex.clamp(0, math.max(0, widget.items.length - 1));

  void _prev() {
    if (_index > 0) setState(() => _index--);
  }

  void _next() {
    if (_index < widget.items.length - 1) setState(() => _index++);
  }

  Future<void> _openPage() async {
    final url = widget.gameUrl;
    if (url == null) return;
    final uri = Uri.parse(url);
    var ok = false;
    try {
      final launch = widget.launcher ??
          (u) => launchUrl(u, mode: LaunchMode.externalApplication);
      ok = await launch(uri);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final item = widget.items[_index];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _prev,
        const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          insetPadding: const EdgeInsets.all(16),
          backgroundColor: const Color(0xFF0D0D0D),
          child: SizedBox(
            width: math.min(1200.0, size.width - 32),
            height: size.height - 64,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                        child: Text(
                          '${item.label}   ${_index + 1} / ${widget.items.length}',
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close (Esc)',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18),
                      color: Colors.grey,
                    ),
                  ],
                ),
                Expanded(
                  child: InteractiveViewer(
                    maxScale: 4,
                    child: Center(
                      child: widget.imageBuilder(context, item.url,
                          fit: BoxFit.contain),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Previous (←)',
                        onPressed: _index > 0 ? _prev : null,
                        icon: const Icon(Icons.chevron_left),
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Next (→)',
                        onPressed:
                            _index < widget.items.length - 1 ? _next : null,
                        icon: const Icon(Icons.chevron_right),
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 24),
                      if (widget.gameUrl != null)
                        TextButton(
                          onPressed: _openPage,
                          child: const Text('Open on atarilegend.com'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
