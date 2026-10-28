// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import 'close_button.dart';

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

/// Shows the cached AtariLegend metadata/images and (lazily) the reviews,
/// magazines and comments.
Future<void> showAtariLegendDialog(
  BuildContext context, {
  required AtariLegendGame game,
  AtariLegendUrlLauncher? launcher,
  AtariLegendImageBuilder? imageBuilder,
  Future<AtariLegendTexts> Function()? textsLoader,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => AtariLegendDialog(
      game: game,
      launcher: launcher,
      imageBuilder: imageBuilder,
      textsLoader: textsLoader,
    ),
  );
}

class AtariLegendDialog extends StatefulWidget {
  const AtariLegendDialog({
    super.key,
    required this.game,
    this.launcher,
    this.imageBuilder,
    this.textsLoader,
  });

  final AtariLegendGame game;
  final AtariLegendUrlLauncher? launcher;
  final AtariLegendImageBuilder? imageBuilder;

  /// Lazily loads `atarilegend-texts.json` when a text tab is opened.
  final Future<AtariLegendTexts> Function()? textsLoader;

  @override
  State<AtariLegendDialog> createState() => _AtariLegendDialogState();
}

class _AtariLegendDialogState extends State<AtariLegendDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Future<AtariLegendTexts>? _textsFuture;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    // Reviews/Magazines/Comments are tabs 1..3 (Info is 0).
    if (_tabs.index >= 1) _ensureTexts();
  }

  void _ensureTexts() {
    if (_textsFuture != null) return;
    setState(() {
      _textsFuture =
          widget.textsLoader?.call() ?? Future.value(AtariLegendTexts.empty());
    });
  }

  AtariLegendGame get game => widget.game;

  Future<bool> _launch(Uri uri) async {
    try {
      final launch = widget.launcher ??
          (u) => launchUrl(u, mode: LaunchMode.externalApplication);
      return await launch(uri);
    } catch (_) {
      return false;
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await _launch(uri);
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = math.min(1000.0, size.width - 40);
    final height = math.min(860.0, size.height - 40);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: const Color(0xFF0D0D0D),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            TabBar(
              controller: _tabs,
              labelColor: kAtariLegendTeal,
              unselectedLabelColor: Colors.grey,
              indicatorColor: kAtariLegendTeal,
              labelStyle:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              tabs: [
                const Tab(text: 'Info'),
                Tab(text: 'Reviews (${game.reviewCount})'),
                Tab(text: 'Magazines (${game.magazineCount})'),
                Tab(text: 'Comments (${game.commentCount})'),
              ],
            ),
            const Divider(height: 1, color: Color(0xFF2A2A2A)),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _infoTab(),
                  _reviewsTab(),
                  _magazinesTab(),
                  _commentsTab(),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A2A)),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
      child: Row(
        children: [
          const Icon(Icons.open_in_new, size: 18, color: kAtariLegendTeal),
          const SizedBox(width: 8),
          const Text('AtariLegend',
              style: TextStyle(
                  color: kAtariLegendTeal, fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              game.year == null ? game.name : '${game.name} (${game.year})',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold),
            ),
          ),
          DialogCloseButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          const SizedBox(width: 8),
          if (game.slug.isNotEmpty)
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: kAtariLegendTeal,
                foregroundColor: Colors.black,
              ),
              onPressed: () => _openUrl(atariLegendGameUrl(game.slug)),
              child: const Text('Open on atarilegend.com'),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ info

  Widget _infoTab() {
    // Fallback for older caches that only carry names.
    final developers = game.developerCredits.isNotEmpty
        ? game.developerCredits
        : [for (final n in game.developers) AtariLegendCredit(name: n)];
    final authors = game.authorCredits.isNotEmpty
        ? game.authorCredits
        : [for (final n in game.authors) AtariLegendCredit(name: n)];
    final builder = widget.imageBuilder ?? _defaultImageBuilder;
    final hasImages = game.boxscans.isNotEmpty || game.screenshots.isNotEmpty;

    final publisherLogo =
        (game.publisherCompanyId != null && game.publisherImgext.isNotEmpty)
            ? atariLegendCompanyLogoUrl(
                game.publisherCompanyId!, game.publisherImgext)
            : null;
    final developerLogo =
        (game.developerCompanyId != null && game.developerImgext.isNotEmpty)
            ? atariLegendCompanyLogoUrl(
                game.developerCompanyId!, game.developerImgext)
            : null;
    final hasScore = game.score != null && game.voteCount > 0;

    final metaRows = <Widget>[
      if (game.publisher.isNotEmpty) _row('Publisher', game.publisher),
      if (game.genres.isNotEmpty) _row('Genres', game.genres.join(', ')),
      if (game.conversion.isNotEmpty) _row('Conversion', game.conversion),
    ];

    final hasLogos = publisherLogo != null || developerLogo != null;
    final header = (!hasLogos && !hasScore)
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: metaRows)
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: metaRows,
                ),
              ),
              if (hasLogos)
                Expanded(
                  flex: 3,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (publisherLogo != null)
                        Tooltip(
                          message: 'Publisher: ${game.publisher}',
                          child: _logo(builder, publisherLogo),
                        ),
                      if (publisherLogo != null && developerLogo != null)
                        const SizedBox(width: 8),
                      if (developerLogo != null)
                        Tooltip(
                          message: 'Developer',
                          child: _logo(builder, developerLogo),
                        ),
                    ],
                  ),
                ),
              if (hasScore) _scoreBlock(),
            ],
          );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 8),
          if (developers.isNotEmpty) _credits('Developers', developers),
          if (authors.isNotEmpty) _credits('Authors', authors),
          if (game.aliases.isNotEmpty) _row('A.k.a.', game.aliases.join(', ')),
          if (hasImages) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: Color(0xFF2A2A2A)),
            const SizedBox(height: 10),
          ],
          if (game.boxscans.isNotEmpty) ...[
            _sectionHeading('Boxscans (${game.boxscans.length})'),
            const SizedBox(height: 6),
            _boxscanRow(builder),
          ],
          if (game.screenshots.isNotEmpty) ...[
            const SizedBox(height: 14),
            _sectionHeading('Screenshots (${game.screenshots.length})'),
            const SizedBox(height: 6),
            _screenshotGrid(builder),
          ],
          if (hasImages) ...[
            const SizedBox(height: 12),
            const Text('Images: atarilegend.com — CC BY-NC-SA 4.0',
                style: TextStyle(color: Colors.grey, fontSize: 10)),
          ],
        ],
      ),
    );
  }

  /// One publisher/developer logo tile (hotlinked, no disk cache).
  Widget _logo(AtariLegendImageBuilder builder, String url) {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      clipBehavior: Clip.antiAlias,
      child: builder(context, url, cacheWidth: 152, fit: BoxFit.contain),
    );
  }

  /// Community score on the right (`4.11 / 5`, `7 votes`).
  Widget _scoreBlock() {
    return SizedBox(
      width: 108,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            game.score!.toStringAsFixed(2),
            style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: kAtariLegendTeal),
          ),
          const Text('/ 5',
              style: TextStyle(color: Colors.grey, fontSize: 10)),
          Text('${game.voteCount} votes',
              style: const TextStyle(color: Colors.grey, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _boxscanRow(AtariLegendImageBuilder builder) {
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
              onTap: () =>
                  _openViewer(builder, boxscans: true, initialIndex: i),
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

  Widget _screenshotGrid(AtariLegendImageBuilder builder) {
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
                onTap: () =>
                    _openViewer(builder, boxscans: false, initialIndex: i),
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
                isScreenshot: true,
              ),
          ];
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _AtariLegendImageViewer(
        items: items,
        initialIndex: initialIndex,
        imageBuilder: builder,
        launcher: widget.launcher,
        gameUrl: game.slug.isEmpty ? null : atariLegendGameUrl(game.slug),
        onOpenUrl: _openUrl,
      ),
    );
  }

  // ----------------------------------------------------------------- texts

  Widget _textsBuilder(Widget Function(AtariLegendTexts texts) build) {
    final future = _textsFuture;
    if (future == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return FutureBuilder<AtariLegendTexts>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final texts = snapshot.data;
        if (texts == null || !texts.available) {
          return _empty('AtariLegend text data unavailable — download it '
              'again in Settings.');
        }
        return build(texts);
      },
    );
  }

  Widget _reviewsTab() => _textsBuilder((texts) {
        final reviews = texts.forGame(game.id)?.reviews ?? const [];
        if (reviews.isEmpty) return _empty('No reviews');
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: reviews.length,
          itemBuilder: (context, i) => _reviewCard(reviews[i]),
        );
      });

  Widget _reviewCard(AtariLegendReview review) {
    final scores = <String>[
      if (review.graphics != null) 'Graphics ${review.graphics}',
      if (review.sound != null) 'Sound ${review.sound}',
      if (review.gameplay != null) 'Gameplay ${review.gameplay}',
      if (review.overall != null) 'Overall ${review.overall}',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  review.publishedAt.isEmpty
                      ? 'Review'
                      : _shortDate(review.publishedAt),
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ),
              if (review.id > 0)
                TextButton(
                  onPressed: () => _openUrl(atariLegendReviewUrl(review.id)),
                  child: const Text('Open review'),
                ),
            ],
          ),
          if (scores.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(scores.join('  ·  '),
                style: const TextStyle(color: kAtariLegendTeal, fontSize: 11)),
          ],
          const SizedBox(height: 6),
          _RichText(review.text, onOpenUrl: _openUrl),
          for (final comment in review.comments)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_shortDate(comment.createdAt),
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 10)),
                  _RichText(comment.text, onOpenUrl: _openUrl),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _magazinesTab() => _textsBuilder((texts) {
        final magazines = texts.forGame(game.id)?.magazines ?? const [];
        if (magazines.isEmpty) return _empty('No magazine references');
        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: magazines.length,
          itemBuilder: (context, i) {
            final m = magazines[i];
            final title = [
              m.magazine,
              if (m.issue.isNotEmpty) '#${m.issue}',
              if (m.type.isNotEmpty) '(${m.type})',
            ].where((s) => s.isNotEmpty).join(' ');
            final details = [
              if (m.published.isNotEmpty) _shortDate(m.published),
              if (m.page.isNotEmpty) 'p${m.page}',
              if (m.score.isNotEmpty) m.score,
            ].join('  ·  ');
            return ListTile(
              dense: true,
              title: Text(title.isEmpty ? 'Magazine' : title,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12)),
              subtitle: details.isEmpty
                  ? null
                  : Text(details,
                      style:
                          const TextStyle(color: Colors.grey, fontSize: 11)),
              trailing: m.archiveUrl.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Open in archive.org',
                      onPressed: () => _openUrl(m.archiveUrl),
                      icon: const Icon(Icons.menu_book_outlined, size: 18),
                      color: Colors.grey,
                    ),
            );
          },
        );
      });

  Widget _commentsTab() => _textsBuilder((texts) {
        final comments = texts.forGame(game.id)?.comments ?? const [];
        if (comments.isEmpty) return _empty('No comments');
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: comments.length,
          itemBuilder: (context, i) {
            final c = comments[i];
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF161616),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF2A2A2A)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (c.createdAt.isNotEmpty)
                    Text(_shortDate(c.createdAt),
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 10)),
                  const SizedBox(height: 2),
                  _RichText(c.text, onOpenUrl: _openUrl),
                ],
              ),
            );
          },
        );
      });

  // ---------------------------------------------------------------- helpers

  Widget _sectionHeading(String text) => Text(
        text,
        style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            decoration: TextDecoration.underline),
      );

  Widget _empty(String message) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ),
      );

  /// Credits as a 3-column grid (name above its role), aligned under the
  /// 100px label column. Developers and Authors share the same grid, so the
  /// columns line up vertically.
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                const columns = 3;
                const gap = 12.0;
                final cellWidth = math.max(
                    0.0,
                    (constraints.maxWidth - gap * (columns - 1)) / columns);
                return Wrap(
                  spacing: gap,
                  runSpacing: 8,
                  children: [
                    for (final credit in credits)
                      SizedBox(
                        width: cellWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(credit.name,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                            if (credit.role.isNotEmpty)
                              Text(credit.role,
                                  style: const TextStyle(
                                      color: Colors.grey, fontSize: 11)),
                          ],
                        ),
                      ),
                  ],
                );
              },
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

String _shortDate(String value) {
  final v = value.trim();
  if (v.length >= 10 && v[4] == '-' && v[7] == '-') return v.substring(0, 10);
  return v;
}

class _ViewerItem {
  const _ViewerItem({
    required this.url,
    required this.label,
    this.isScreenshot = false,
  });

  final String url;
  final String label;

  /// Screenshots are 320×200 and shown at exactly 2× (640×400); boxscans keep
  /// their intrinsic size.
  final bool isScreenshot;
}

/// Full-size AtariLegend image viewer: `←/→` navigate, `Esc` closes.
class _AtariLegendImageViewer extends StatefulWidget {
  const _AtariLegendImageViewer({
    required this.items,
    required this.initialIndex,
    required this.imageBuilder,
    required this.onOpenUrl,
    this.gameUrl,
    this.launcher,
  });

  final List<_ViewerItem> items;
  final int initialIndex;
  final AtariLegendImageBuilder imageBuilder;
  final Future<void> Function(String url) onOpenUrl;
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

  /// Screenshots are 320×200 PNGs: show them at exactly 2× (640×400), shrinking
  /// to fit smaller windows (the AspectRatio keeps them undistorted). Boxscans
  /// keep their intrinsic size.
  Widget _viewerImage(_ViewerItem item) {
    final image = widget.imageBuilder(context, item.url, fit: BoxFit.contain);
    if (!item.isScreenshot) return Center(child: image);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 400),
        child: AspectRatio(
          aspectRatio: 16 / 10, // Atari ST 320×200
          child: image,
        ),
      ),
    );
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
                    DialogCloseButton(
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                Expanded(
                  child: InteractiveViewer(
                    maxScale: 4,
                    child: _viewerImage(item),
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
                          onPressed: () => widget.onOpenUrl(widget.gameUrl!),
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

/// Renders AtariLegend text (BBCode-like markup) as rich text: `[b]`, `[i]`,
/// `[u]`, `[url]`/`[url=…]` links; unknown tags are stripped.
class _RichText extends StatefulWidget {
  const _RichText(this.text, {this.onOpenUrl});

  final String text;
  final Future<void> Function(String url)? onOpenUrl;

  @override
  State<_RichText> createState() => _RichTextState();
}

class _RichTextState extends State<_RichText> {
  final List<TapGestureRecognizer> _recognizers = [];
  late List<InlineSpan> _spans;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void didUpdateWidget(covariant _RichText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _build();
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  void _build() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    _spans = _parseRichText(widget.text, (url) {
      final recognizer = TapGestureRecognizer();
      _recognizers.add(recognizer);
      recognizer.onTap = () => widget.onOpenUrl?.call(url);
      return recognizer;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(
      TextSpan(
        style: const TextStyle(
            color: Colors.white70, fontSize: 12, height: 1.35),
        children: _spans,
      ),
    );
  }
}

List<InlineSpan> _parseRichText(
  String text,
  TapGestureRecognizer Function(String url) linkFor,
) {
  final spans = <InlineSpan>[];
  var bold = false, italic = false, underline = false;
  String? linkUrl;
  final linkText = StringBuffer();
  final tagRe = RegExp(r'\[(\/?)([a-zA-Z]+)(?:=([^\]]*))?\]');
  var last = 0;

  void addText(String value) {
    if (value.isEmpty) return;
    spans.add(TextSpan(
      text: value,
      style: TextStyle(
        fontWeight: bold ? FontWeight.bold : null,
        fontStyle: italic ? FontStyle.italic : null,
        decoration: underline ? TextDecoration.underline : null,
      ),
    ));
  }

  void flushLink() {
    if (linkUrl == null) return;
    final label = linkText.toString();
    linkText.clear();
    if (label.isNotEmpty) {
      final url = linkUrl!.isEmpty ? label : linkUrl!;
      spans.add(TextSpan(
        text: label,
        style: const TextStyle(
            color: Colors.lightBlue, decoration: TextDecoration.underline),
        recognizer: linkFor(url),
      ));
    }
    linkUrl = null;
  }

  for (final match in tagRe.allMatches(text)) {
    final before = text.substring(last, match.start);
    if (linkUrl != null) {
      linkText.write(before);
    } else {
      addText(before);
    }
    last = match.end;

    final closing = match.group(1) == '/';
    final tag = match.group(2)!.toLowerCase();
    final arg = match.group(3);
    if (tag == 'url') {
      if (!closing) {
        flushLink();
        linkUrl = arg ?? '';
        linkText.clear();
      } else {
        flushLink();
      }
      continue;
    }
    if (linkUrl != null) continue; // no nested formatting inside links
    switch (tag) {
      case 'b':
        bold = !closing;
      case 'i':
        italic = !closing;
      case 'u':
        underline = !closing;
      default:
        // strip unknown AtariLegend tags (frontpage, screenstar, game, …)
        break;
    }
  }

  final tail = text.substring(last);
  if (linkUrl != null) {
    linkText.write(tail);
    flushLink();
  } else {
    addText(tail);
  }
  return spans;
}
