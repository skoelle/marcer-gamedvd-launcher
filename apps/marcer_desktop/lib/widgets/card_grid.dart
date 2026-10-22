// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';

/// Center panel in grid (icon) mode: catalog cards in catalog mode, folder
/// tiles + ZIP cards with previews in browse mode. Keyboard follows the
/// list bindings (arrows move by one item / one row, PgUp/PgDn by a page,
/// Enter opens the lightbox, `V` toggles the view).
class CenterGrid extends StatefulWidget {
  const CenterGrid({
    super.key,
    required this.controller,
    required this.onToggleHelp,
    required this.onOpenLightbox,
    required this.onFocusSearch,
    this.focusNode,
  });

  final CatalogController controller;
  final VoidCallback onToggleHelp;

  /// Opens the lightbox for the selection: variant index (crew focus) and
  /// image index (0 = preview, gallery `openLightbox` semantics).
  final void Function(int variant, int image) onOpenLightbox;
  final VoidCallback onFocusSearch;

  /// Optional externally-owned focus node (the home page can hand focus
  /// back here after leaving the search field); otherwise one is created
  /// internally.
  final FocusNode? focusNode;

  @override
  State<CenterGrid> createState() => _CenterGridState();
}

class _CenterGridState extends State<CenterGrid> {
  static const double _spacing = 10;
  static const double _cardWidth = 220;
  static const double _footerHeight = 52;

  final FocusNode _internalFocusNode = FocusNode(debugLabel: 'card-grid');
  FocusNode get _focusNode => widget.focusNode ?? _internalFocusNode;
  final ScrollController _scroll = ScrollController();
  int _lastSelected = 0;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    if (widget.focusNode == null) _internalFocusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final c = widget.controller;
    final count = c.itemCount;
    final sel = c.selectedIndex;
    if (count != _lastCount || sel != _lastSelected) {
      _lastCount = count;
      _lastSelected = sel;
      _ensureVisible(sel);
    }
    // HomePage no longer wraps the whole page in a ListenableBuilder, so the
    // grid rebuilds itself on controller changes (filter, selection, badges).
    if (mounted) setState(() {});
  }

  double _itemExtent(double width, int columns) {
    final cardW = (width - (columns - 1) * _spacing) / columns;
    return cardW * 2 / 3 + _footerHeight + _spacing;
  }

  void _ensureVisible(int index) {
    if (!_scroll.hasClients) return;
    final columns = _lastColumns > 0 ? _lastColumns : 4;
    final extent = _lastItemExtent > 0 ? _lastItemExtent : 200.0;
    final rowsVisible =
        (_scroll.position.viewportDimension / extent).ceil().clamp(1, 1000).toInt();
    final row = index ~/ columns;
    final firstRow = (_scroll.offset / extent).floor();
    if (row < firstRow) {
      _scroll.animateTo(row * extent,
          duration: const Duration(milliseconds: 80), curve: Curves.easeOut);
    } else if (row >= firstRow + rowsVisible - 1) {
      _scroll.animateTo((row - rowsVisible + 2) * extent,
          duration: const Duration(milliseconds: 80), curve: Curves.easeOut);
    }
  }

  int _lastColumns = 0;
  double _lastItemExtent = 0;

  int get _pageItems {
    final columns = _lastColumns > 0 ? _lastColumns : 4;
    final extent = _lastItemExtent > 0 ? _lastItemExtent : 200.0;
    final rows = (_scroll.position.viewportDimension / extent)
        .floor()
        .clamp(1, 1000);
    return columns * rows;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final c = widget.controller;
    final key = event.logicalKey;
    final columns = _lastColumns > 0 ? _lastColumns : 4;

    if (key == LogicalKeyboardKey.arrowDown) {
      c.moveSelection(columns);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      c.moveSelection(-columns);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      c.moveSelection(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (c.catalogMode) {
        c.moveSelection(-1);
      } else {
        c.parent();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      c.moveSelection(_pageItems);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      c.moveSelection(-_pageItems);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      c.moveSelectionTo(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      c.moveSelectionTo(c.itemCount - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (c.activate()) _openLightboxForSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      c.parent();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      io.exit(0);
    }
    final char = event.character;
    if (char == '*' || key == LogicalKeyboardKey.asterisk) {
      c.toggleFavoriteSelected();
      return KeyEventResult.handled;
    }
    if (char == '?') {
      widget.onToggleHelp();
      return KeyEventResult.handled;
    }
    if (char == '/' || key == LogicalKeyboardKey.slash) {
      widget.onFocusSearch();
      return KeyEventResult.handled;
    }
    if (char == 't' || char == 'T') {
      c.toggleView();
      return KeyEventResult.handled;
    }
    if (char == 'p' || char == 'P') {
      c.launchSelected();
      return KeyEventResult.handled;
    }
    if (char == 'q' || char == 'Q') {
      io.exit(0);
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Container(
      color: Colors.black,
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _onKey,
        child: GestureDetector(
          onTap: () => _focusNode.requestFocus(),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final columns =
                  ((width - 16) / (_cardWidth + _spacing)).floor().clamp(1, 12);
              final itemExtent = _itemExtent(width, columns);
              _lastColumns = columns;
              _lastItemExtent = itemExtent;

              final count = c.itemCount;
              if (count == 0) {
                return Center(
                  child: Text(
                    c.catalogMode ? 'No results' : 'Empty directory',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                );
              }
              return GridView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(8),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: _spacing,
                  crossAxisSpacing: _spacing,
                  mainAxisExtent: itemExtent - _spacing,
                ),
                itemCount: count,
                itemBuilder: (context, index) {
                  final selected = index == c.selectedIndex;
                  return c.catalogMode
                      ? _cardTile(c, c.catalogCards[index], selected, index)
                      : _entryTile(c, c.visibleEntries[index], selected, index);
                },
              );
            },
          ),
        ),
      ),
    );
  }

  /// Opens the lightbox for the selection: the crew/cracker-focused variant
  /// when a focus filter is active, otherwise the **best** variant (the one
  /// whose screenshot is used as the card preview), falling back to the
  /// first.
  void _openLightboxForSelection({int image = 0}) {
    final c = widget.controller;
    final card = c.selectedCard;
    widget.onOpenLightbox(card == null ? 0 : _bestVariant(c, card), image);
  }

  int _bestVariant(CatalogController c, GameCard card) {
    if ((card.focusVariant ?? -1) >= 0) return card.focusVariant!;
    final display = c.displayVariantForCard(card);
    if (display != null) {
      final idx = card.variants.indexOf(display);
      if (idx >= 0) return idx;
    }
    return 0;
  }

  /// Number of variants that have a screenshot preview
  /// (gallery `countPreviews`).
  int _countPreviews(GameCard card) =>
      card.variants.where((v) => v.previewPath != null).length;

  /// Number of shown variant thumbs that are real game screenshots
  /// (status `done` / "done (game)"); the rest are e.g. `desktop` shots.
  int _doneThumbCount(CatalogController c, GameCard card) =>
      _variantThumbs(c, card)
          .where((t) => card.variants[t.index].status == 'done')
          .length;

  /// True when the no-focus 2×2 variant grid applies. With a concrete status
  /// filter, ≥2 previews are enough (the selected status is ordered first).
  /// Otherwise the single-game-shot exception still shows one done image.
  bool _multiThumbBody(CatalogController c, GameCard card) {
    if (card.focusActive || _countPreviews(card) < 2) return false;
    if (c.statusPreviewActive) return true;
    return _doneThumbCount(c, card) != 1;
  }

  /// Up to 4 clickable variant screenshots, best first
  /// ([GameCard.thumbIndices] with the active status filter prioritized,
  /// then status tier and `kind: game` before other kinds).
  List<({int index, String path})> _variantThumbs(
          CatalogController c, GameCard card) =>
      [
        for (final i in c.displayThumbIndices(card))
          (index: i, path: card.variants[i].previewPath!),
      ];

  Widget _thumbGrid(
      CatalogController c, GameCard card, int index,
      List<({int index, String path})> thumbs) {
    Widget cell(({int index, String path}) t) => GestureDetector(
          onTap: () {
            c.moveSelectionTo(index);
            widget.onOpenLightbox(t.index, 0);
          },
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF2A2A2A)),
                borderRadius: BorderRadius.circular(2),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.file(
                io.File(t.path),
                key: ValueKey('${t.path}#${c.imageVersionOf(t.path)}'),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(color: Colors.black),
              ),
            ),
          ),
        );

    // Two columns, at most two rows, evenly split over the available area
    // (so all four thumbnails fit without clipping).
    final rows = <Widget>[];
    for (var i = 0; i < thumbs.length && rows.length < 2; i += 2) {
      rows.add(Expanded(
        child: Row(
          children: [
            Expanded(child: cell(thumbs[i])),
            if (i + 1 < thumbs.length)
              Expanded(child: cell(thumbs[i + 1]))
            else
              const Expanded(child: SizedBox()),
          ],
        ),
      ));
    }
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Column(children: rows),
    );
  }

  /// Grid card body (gallery `renderGrid` branch order):
  /// focus miss → hint + 4 other shots; no focus + ≥2 previews → 2×2
  /// (the single `done`-thumb exception only applies without a concrete
  /// status filter); preview → single selected-status image (+ candidate
  /// strip); else placeholder.
  Widget _cardBody(CatalogController c, GameCard card, int index) {
    if (card.focusVariant == -1) {
      final thumbs = _variantThumbs(c, card);
      if (thumbs.isEmpty) return _placeholder();
      final label = c.crackerFocusActive
          ? 'no cracker ZIP — other variants'
          : 'no crew ZIP — other variants';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
            child: Text(label,
                style: const TextStyle(fontSize: 10, color: Color(0xFFE6A23C))),
          ),
          Expanded(child: _thumbGrid(c, card, index, thumbs)),
        ],
      );
    }
    if (_multiThumbBody(c, card)) {
      return _thumbGrid(c, card, index, _variantThumbs(c, card));
    }
    final preview = c.displayPreviewPathForCard(card);
    if (preview != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _previewImage(preview),
          ?_candidatesOverlay(c, card, index),
        ],
      );
    }
    return _placeholder();
  }

  Widget _placeholder() => const Center(
        child: Icon(Icons.videogame_asset, size: 42, color: Colors.white24),
      );

  Widget _cardTile(
      CatalogController c, GameCard card, bool selected, int index) {
    // Never touch the filesystem while building a tile: read the async layer
    // cache and request a background scan for unknown folders. Badges appear
    // as soon as the scan result arrives (throttled notify).
    c.ensureCardScanned(card);
    final layer = c.cachedCardLayer(card);
    final missing = c.cachedCardMissing(card);
    final chips = <String>[
      if (c.isFavoriteCard(card)) 'FAVORITE',
      if (card.variants.length > 1) '×${card.variants.length}',
      if (layer != null && layer.isNotEmpty) layer,
      if (missing == true) 'MISSING',
      if (card.tosVersion != null && card.tosVersion!.isNotEmpty)
        'TOS ${card.tosVersion}',
      if (card.displayStatus.isNotEmpty) card.displayStatus,
      if (card.year != 'unknown') card.year,
    ];
    final preview = c.displayPreviewPathForCard(card);
    final thumbsBody = card.focusVariant == -1
        ? _variantThumbs(c, card).isNotEmpty
        : _multiThumbBody(c, card);
    return _tileFrame(
      selected: selected,
      index: index,
      onTap: () => c.moveSelectionTo(index),
      onDoubleTap: () {
        c.moveSelectionTo(index);
        if (c.activate()) _openLightboxForSelection();
      },
      image: _cardBody(c, card, index),
      badges: chips,
      title: card.name,
      dim: preview == null && !thumbsBody,
    );
  }

  /// Gallery grid `.cands`: thumbnails of the preview variant's candidates on
  /// top of the preview (hidden when a focus filter is active). The preview
  /// variant is used even when multiple ZIPs apply, so a done/game preview
  /// keeps its candidate shots.
  Widget? _candidatesOverlay(CatalogController c, GameCard card, int index) {
    if (!c.config.showCandidates) return null;
    if (card.focusActive) return null;
    final variant = c.displayVariantForCard(card);
    if (variant == null) return null;
    final cands = variant.candidatePaths;
    if (cands.isEmpty) return null;
    final variantIndex = card.variants.indexOf(variant);
    return _candidateThumbs(
      cands,
      onPick: (i) {
        widget.controller.moveSelectionTo(index);
        widget.onOpenLightbox(variantIndex, i + 1);
      },
    );
  }

  Widget _entryCandidatesOverlay(CatalogController c, Entry e, int index) {
    if (!c.config.showCandidates) return const SizedBox.shrink();
    final preview = c.previewPathFor(e);
    if (preview == null) return const SizedBox.shrink();
    final cands = c.candidatePathsFor(e);
    if (cands.isEmpty) return const SizedBox.shrink();
    return _candidateThumbs(
      cands,
      onPick: (i) {
        c.moveSelectionTo(index);
        widget.onOpenLightbox(0, i + 1);
      },
    );
  }

  Widget _candidateThumbs(List<String> cands,
      {required void Function(int index) onPick}) {
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (var i = 0; i < cands.length && i < 6; i++)
              GestureDetector(
                onTap: () => onPick(i),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF2A2A2A)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.file(
                    io.File(cands[i]),
                    key: ValueKey(
                        '${cands[i]}#${widget.controller.imageVersionOf(cands[i])}'),
                    width: 44,
                    height: 26,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.none,
                    errorBuilder: (_, _, _) => Container(
                        width: 44, height: 26, color: Colors.black),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(
      CatalogController c, Entry e, bool selected, int index) {
    if (e.kind == EntryKind.directory) {
      return _tileFrame(
        selected: selected,
        index: index,
        onTap: () => c.moveSelectionTo(index),
        onDoubleTap: () {
          c.moveSelectionTo(index);
          c.activate();
        },
        icon: e.isVirtual ? Icons.star : Icons.folder,
        iconColor: e.isVirtual ? Colors.amber : Colors.amber,
        badges: [e.layerStatus.name.toUpperCase()],
        title: e.name,
      );
    }
    final preview = c.previewPathFor(e);
    final fav = c.isFavorite(e);
    // Flat favorites view: keep the ZIP's folder on the tile (the list
    // would otherwise strip all path context).
    final folder = CatalogController.shortFolder(c.folderRelOf(e));
    return _tileFrame(
      selected: selected,
      index: index,
      onTap: () => c.moveSelectionTo(index),
      onDoubleTap: () {
        c.moveSelectionTo(index);
        if (c.activate()) widget.onOpenLightbox(0, 0);
      },
      image: _previewImage(preview),
      overlay: _entryCandidatesOverlay(c, e, index),
      badges: [
        e.layerStatus.name.toUpperCase(),
        if (fav) 'FAVORITE',
        if (folder.isNotEmpty) folder,
      ],
      title: e.name,
      dim: preview == null,
    );
  }

  Widget _previewImage(String? path) {
    if (path == null) {
      return const Center(
        child: Icon(Icons.videogame_asset, size: 42, color: Colors.white24),
      );
    }
    return Image.file(
      io.File(path),
      key: ValueKey('$path#${widget.controller.imageVersionOf(path)}'),
      fit: BoxFit.cover,
      cacheWidth: 440,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.broken_image, size: 36, color: Colors.white24),
      ),
    );
  }

  Widget _tileFrame({
    required bool selected,
    required int index,
    required VoidCallback onTap,
    required VoidCallback onDoubleTap,
    Widget? image,
    Widget? overlay,
    required List<String> badges,
    required String title,
    IconData? icon,
    Color? iconColor,
    bool dim = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF101010),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? Colors.cyan : const Color(0xFF2A2A2A),
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  color: Colors.black,
                  child: Opacity(
                    opacity: dim ? 0.55 : 1,
                    child: icon != null
                        ? Center(
                            child: Icon(icon, size: 56, color: iconColor),
                          )
                        : Stack(
                            fit: StackFit.expand,
                            children: [
                              image ??
                                  const Center(
                                    child: Icon(Icons.videogame_asset,
                                        size: 42, color: Colors.white24),
                                  ),
                              ?overlay,
                            ],
                          ),
                  ),
                ),
              ),
              SizedBox(
                height: _footerHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 16,
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.centerLeft,
                            maxWidth: double.infinity,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final b in badges.take(4))
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: Colors.white
                                            .withValues(alpha: 0.08),
                                        borderRadius:
                                            BorderRadius.circular(3),
                                      ),
                                      child: Text(
                                        b,
                                        style: const TextStyle(
                                            fontSize: 9,
                                            color: Colors.grey),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                          fontSize: 12,
                          color: selected ? Colors.cyan : Colors.white,
                          fontWeight:
                              selected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
