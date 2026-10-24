// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';
import 'atari_legend_dialog.dart';
import 'game_info_panel.dart';
import 'game_lightbox.dart';
import 'local_assets_chips.dart';
import 'piratefinder_dialog.dart';

/// Crew release browser: all releases of a crew as a vertical screenshot list
/// on the left, the normal lightbox info sidebar for the selected ZIP on the
/// right. Up/down move through the releases; P/Space launches, Enter opens the
/// normal game lightbox, Esc closes.
class CrewLightbox extends StatefulWidget {
  const CrewLightbox({super.key, required this.controller, required this.crew});

  final CatalogController controller;
  final CrewGroup crew;

  static Future<void> show(
    BuildContext context,
    CatalogController controller,
    CrewGroup crew,
  ) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black87,
      builder: (_) => CrewLightbox(controller: controller, crew: crew),
    );
  }

  @override
  State<CrewLightbox> createState() => _CrewLightboxState();
}

class _CrewLightboxState extends State<CrewLightbox> {
  static const double _sidebarWidth = 330;
  static const double _minCardWidth = 190;
  static const double _gridSpacing = 8;
  static const double _gridPadding = 8;
  int _columns = 4;
  double _rowExtent = 210;

  final FocusNode _focus = FocusNode(debugLabel: 'crew-lightbox');
  final FocusNode _searchFocus = FocusNode(debugLabel: 'crew-lightbox-search');
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();

  late List<CrewRelease> _releases;
  int _selected = 0;
  String _query = '';
  String _sort = 'year_asc';

  @override
  void initState() {
    super.initState();
    _releases = _applyFilter();
    _selected = _initialIndex();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _ensureVisible(_selected, animate: false);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  CrewRelease? get _current => _releases.isEmpty
      ? null
      : _releases[_selected.clamp(0, _releases.length - 1)];

  List<CrewRelease> _applyFilter() {
    final query = _query.trim().toLowerCase();
    final list = widget.crew.releases.where((release) {
      if (query.isEmpty) return true;
      final haystack = [
        release.title,
        release.folder,
        release.zip,
        release.year,
        release.publisher,
        release.crackedBy,
        release.crew,
        release.language,
        release.specialFlag,
        release.specialNote,
      ].join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList();
    switch (_sort) {
      case 'year_desc':
        list.sort((a, b) {
          final ay = int.tryParse(a.year);
          final by = int.tryParse(b.year);
          if (ay == null && by != null) return 1;
          if (ay != null && by == null) return -1;
          if (ay != null && by != null && ay != by) return by.compareTo(ay);
          return _titleCompare(a, b);
        });
      case 'title_asc':
        list.sort(_titleCompare);
      default:
        // `crews.json` already contains year asc / unknown last / title / ZIP.
        break;
    }
    return list;
  }

  static int _titleCompare(CrewRelease a, CrewRelease b) {
    final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    if (byTitle != 0) return byTitle;
    return a.zip.toLowerCase().compareTo(b.zip.toLowerCase());
  }

  int _initialIndex() {
    if (_releases.isEmpty) return 0;
    final curated = widget.controller.crewImages.imageFor(widget.crew);
    if (curated != null) {
      final index = _releases.indexWhere(
        (release) => release.rel == curated.rel,
      );
      if (index >= 0) return index;
    }
    final withPreview = _releases.indexWhere((release) {
      final entry = widget.controller.screenshots[release.rel];
      return entry != null && (entry.preview?.isNotEmpty ?? false);
    });
    return withPreview >= 0 ? withPreview : 0;
  }

  void _rebuild({bool keepSelection = true}) {
    final selectedRel = _current?.rel;
    setState(() {
      _releases = _applyFilter();
      if (keepSelection && selectedRel != null) {
        final index = _releases.indexWhere(
          (release) => release.rel == selectedRel,
        );
        _selected = index >= 0 ? index : 0;
      } else {
        _selected = 0;
      }
    });
    _ensureVisible(_selected, animate: false);
  }

  void _select(int index) {
    if (_releases.isEmpty) return;
    final next = index.clamp(0, _releases.length - 1);
    if (next == _selected) return;
    setState(() => _selected = next);
    _ensureVisible(next);
  }

  void _moveBy(int delta) => _select(_selected + delta);

  void _moveRow(int rows) => _moveBy(rows * _columns);

  int get _pageSize {
    if (!_scroll.hasClients || _rowExtent <= 0) {
      return math.max(1, _columns);
    }
    final rows = math.max(
      1,
      (_scroll.position.viewportDimension / _rowExtent).floor(),
    );
    return rows * _columns;
  }

  void _ensureVisible(int index, {bool animate = true}) {
    if (!_scroll.hasClients || _releases.isEmpty || _columns <= 0) return;
    final viewport = _scroll.position.viewportDimension;
    final row = index ~/ _columns;
    final target = (row * _rowExtent) - (viewport - _rowExtent) / 2;
    final clamped = target.clamp(0.0, _scroll.position.maxScrollExtent);
    if (animate) {
      _scroll.animateTo(
        clamped,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(clamped);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveRow(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveRow(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _moveBy(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveBy(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _moveBy(_pageSize);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _moveBy(-_pageSize);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _select(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _select(_releases.length - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _openGameLightbox();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space ||
        event.character == 'p' ||
        event.character == 'P') {
      _playSelected();
      return KeyEventResult.handled;
    }
    if (event.character == '/' || key == LogicalKeyboardKey.slash) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openGameLightbox() {
    final release = _current;
    if (release == null) return;
    final hit = widget.controller.releaseCardFor(release.rel);
    if (hit == null) return;
    GameLightbox.showCard(
      context,
      widget.controller,
      card: hit.card,
      variant: hit.index,
    );
  }

  void _playSelected() {
    final release = _current;
    if (release == null) return;
    _play(release.rel);
  }

  void _play(String rel) {
    final hit = widget.controller.releaseCardFor(rel);
    if (hit == null) return;
    widget.controller.launchCardVariant(
      hit.card,
      hit.index,
      variant: widget.controller.defaultVariantForCard(hit.card),
    );
  }

  void _selectGroup(String value, String kind, GameCard card) {
    final index = focusVariant(card, value, kind);
    if (index < 0) return;
    final rel = card.variants[index].rel;
    final found = _releases.indexWhere((release) => release.rel == rel);
    if (found >= 0) _select(found);
  }

  String? _previewPath(CrewRelease release) {
    final preview = widget.controller.screenshots.previewPathFor(release.rel);
    if (preview != null) return preview;
    final candidates = widget.controller.screenshots.candidatePathsFor(
      release.rel,
    );
    return candidates.isEmpty ? null : candidates.first;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = math.min(size.width - 48, 1500.0);
    final height = math.max(360.0, size.height - 48);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF0D0D0D),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2A2A2A)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _onKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                const Divider(height: 1),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _releaseGrid(context)),
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: _sidebarWidth,
                        child: _sidePanel(context),
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

  Widget _header(BuildContext context) {
    final aliases = widget.crew.aliases
        .where((alias) => alias != widget.crew.name)
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.crew.name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${widget.crew.kind == 'cracker' ? 'Individual cracker' : 'Crew'}'
                  ' · ${widget.crew.zips} ZIPs · ${widget.crew.releases.length} releases',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                if (aliases.isNotEmpty)
                  Text(
                    'Also known as: ${aliases.join(', ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 210,
            height: 30,
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  if (_search.text.isNotEmpty) {
                    _search.clear();
                    _query = '';
                    _rebuild(keepSelection: false);
                  } else {
                    _focus.requestFocus();
                  }
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                focusNode: _searchFocus,
                controller: _search,
                onChanged: (value) {
                  _query = value;
                  _rebuild();
                },
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filter releases',
                  prefixIcon: const Icon(Icons.search, size: 15),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 7,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(width: 10),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _sort,
              dropdownColor: const Color(0xFF1B1B1B),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
              items: const [
                DropdownMenuItem(value: 'year_asc', child: Text('Jahr ↑')),
                DropdownMenuItem(value: 'year_desc', child: Text('Jahr ↓')),
                DropdownMenuItem(value: 'title_asc', child: Text('Titel A–Z')),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _sort = value);
                _rebuild();
              },
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _releases.isEmpty
                ? '0 / 0'
                : '${_selected + 1} / ${_releases.length}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          IconButton(
            tooltip: 'Close (Esc)',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 18, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _releaseGrid(BuildContext context) {
    if (_releases.isEmpty) {
      return const Center(
        child: Text(
          'No releases match the filter',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - _gridPadding * 2;
        final columns = math.max(
          1,
          math.min(
            4,
            ((available + _gridSpacing) / (_minCardWidth + _gridSpacing))
                .floor(),
          ),
        );
        final cardWidth = (available - _gridSpacing * (columns - 1)) / columns;
        final imageHeight = cardWidth * 0.625;
        final cardHeight = imageHeight + 74;
        _columns = columns;
        _rowExtent = cardHeight + _gridSpacing;
        return GridView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(_gridPadding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: _gridSpacing,
            crossAxisSpacing: _gridSpacing,
            mainAxisExtent: cardHeight,
          ),
          itemCount: _releases.length,
          itemBuilder: (context, index) => _releaseCard(context, index),
        );
      },
    );
  }

  Widget _releaseCard(BuildContext context, int index) {
    final release = _releases[index];
    final selected = index == _selected;
    final entry = widget.controller.screenshots[release.rel];
    final layer = widget.controller.zipLayer(release.rel);
    final preview = _previewPath(release);
    final credits = {
      if (release.crackedBy.isNotEmpty) release.crackedBy,
      if (release.crew.isNotEmpty) release.crew,
    }.join(' · ');
    return Tooltip(
      message: release.zip,
      child: InkWell(
        onTap: () {
          _focus.requestFocus();
          _select(index);
        },
        onDoubleTap: () {
          _focus.requestFocus();
          _select(index);
          _openGameLightbox();
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          decoration: BoxDecoration(
            color: selected
                ? Colors.cyan.withValues(alpha: 0.10)
                : const Color(0xFF111111),
            border: Border.all(
              color: selected ? Colors.cyan : const Color(0xFF242424),
              width: selected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    preview == null
                        ? _thumbPlaceholder()
                        : Image.file(
                            File(preview),
                            fit: BoxFit.cover,
                            cacheWidth: 480,
                            errorBuilder: (_, _, _) => _thumbPlaceholder(),
                          ),
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Wrap(
                        spacing: 4,
                        children: [
                          if (entry?.status.isNotEmpty ?? false)
                            _badge(entry!.status, Colors.blueGrey),
                          if (entry?.kind != null && entry!.kind!.isNotEmpty)
                            _badge(entry.kind!, Colors.teal),
                        ],
                      ),
                    ),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Wrap(
                        spacing: 4,
                        children: [
                          if (layer.isNotEmpty) _badge(layer, Colors.indigo),
                          if (layer.isEmpty)
                            _badge('MISSING', Colors.redAccent),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      release.title.isEmpty ? release.folder : release.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (release.year.isNotEmpty) ...[
                          Text(
                            release.year,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (release.ambiguous)
                          _badge('ambiguous', Colors.orangeAccent),
                      ],
                    ),
                    if (credits.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        credits,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sidePanel(BuildContext context) {
    final release = _current;
    if (release == null) {
      return const Center(
        child: Text('No release', style: TextStyle(color: Colors.grey)),
      );
    }
    final hit = widget.controller.releaseCardFor(release.rel);
    if (hit == null) return _fallbackInfo(release);

    final card = hit.card;
    final variant = card.variants[hit.index];
    final atariLegend = widget.controller.atariLegendForCard(card);
    final pfMatch = widget.controller.pirateFinderTitleMatchForCard(card);
    return GameInfoPanel(
      info: card.info,
      variant: ZipVariantView(
        name: variant.name,
        status: variant.status,
        kind: variant.kind,
        layer: widget.controller.variantLayer(variant),
        rel: variant.rel,
        size: variant.size,
        missing: widget.controller.variantMissing(variant),
        tos: variant.tos,
      ),
      filter: widget.controller.filter,
      variants: card.kind == 'falcon' ? kFalconVariants : kHatariVariants,
      atariLegend: atariLegend,
      onAtariLegend: atariLegend == null
          ? null
          : () => showAtariLegendDialog(
              context,
              game: atariLegend,
              textsLoader: widget.controller.atariLegendTexts,
            ),
      pirateFinderMatch: pfMatch,
      onPirateFinder: pfMatch == null
          ? null
          : () => showPirateFinderDialog(
              context,
              controller: widget.controller,
              card: card,
            ),
      extras: LocalAssetsChips(
        assets: widget.controller.localAssetsForCard(card),
        service: widget.controller.localAssetsService,
      ),
      onPlay: () => _play(release.rel),
      onPlayVariant: (variant) => widget.controller.launchCardVariant(
        card,
        hit.index,
        variant: variant,
      ),
      onSelectGroup: (value, kind) => _selectGroup(value, kind, card),
    );
  }

  Widget _fallbackInfo(CrewRelease release) {
    final entry = widget.controller.screenshots[release.rel];
    final layer = widget.controller.zipLayer(release.rel);
    final rows = <(String, String)>[
      if (release.title.isNotEmpty) ('Title', release.title),
      if (release.year.isNotEmpty) ('Release', release.year),
      if (release.publisher.isNotEmpty) ('Publisher', release.publisher),
      if (release.crackedBy.isNotEmpty) ('Cracked by', release.crackedBy),
      if (release.crew.isNotEmpty) ('Crew', release.crew),
      if (release.language.isNotEmpty) ('Language', release.language),
      if (release.disks > 0) ('Disks', '${release.disks}'),
      if (release.tosBad.isNotEmpty) ('TOS/BAD', release.tosBad),
      if (release.specialFlag.isNotEmpty) ('Special', release.specialFlag),
      if (release.specialNote.isNotEmpty) ('Note', release.specialNote),
      ('ZIP', release.zip),
      if (entry?.status.isNotEmpty ?? false) ('Status', entry!.status),
      if (entry?.kind != null && entry!.kind!.isNotEmpty) ('Kind', entry.kind!),
      if (layer.isNotEmpty) ('Layer', layer) else ('Layer', 'MISSING'),
    ];
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        const Text(
          'Release info',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.white70,
            decoration: TextDecoration.underline,
          ),
        ),
        const SizedBox(height: 8),
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 82,
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(fontSize: 11, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _thumbPlaceholder() => Container(
    color: Colors.black,
    child: const Center(
      child: Icon(Icons.videogame_asset, size: 36, color: Colors.white24),
    ),
  );

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.w600),
    ),
  );
}
