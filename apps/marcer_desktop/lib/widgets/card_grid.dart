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
  });

  final CatalogController controller;
  final VoidCallback onToggleHelp;
  final VoidCallback onOpenLightbox;
  final VoidCallback onFocusSearch;

  @override
  State<CenterGrid> createState() => _CenterGridState();
}

class _CenterGridState extends State<CenterGrid> {
  static const double _spacing = 10;
  static const double _cardWidth = 220;
  static const double _footerHeight = 52;

  final FocusNode _focusNode = FocusNode(debugLabel: 'card-grid');
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
    _focusNode.dispose();
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
    setState(() {});
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
      if (c.activate()) widget.onOpenLightbox();
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
    if (char == '*') {
      c.toggleFavoriteSelected();
      return KeyEventResult.handled;
    }
    if (char == '?') {
      widget.onToggleHelp();
      return KeyEventResult.handled;
    }
    if (char == '/') {
      widget.onFocusSearch();
      return KeyEventResult.handled;
    }
    if (char == 'v' || char == 'V') {
      c.toggleViewOverride();
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

  Widget _cardTile(
      CatalogController c, GameCard card, bool selected, int index) {
    return _tileFrame(
      selected: selected,
      index: index,
      onTap: () => c.moveSelectionTo(index),
      onDoubleTap: () {
        c.moveSelectionTo(index);
        if (c.activate()) widget.onOpenLightbox();
      },
      image: _previewImage(card.previewPath),
      badges: [
        if (card.layer.isNotEmpty) card.layer,
        if (card.displayStatus.isNotEmpty) card.displayStatus,
        if (card.year != 'unknown') card.year,
      ],
      title: card.name,
      dim: card.previewPath == null,
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
    return _tileFrame(
      selected: selected,
      index: index,
      onTap: () => c.moveSelectionTo(index),
      onDoubleTap: () {
        c.moveSelectionTo(index);
        if (c.activate()) widget.onOpenLightbox();
      },
      image: _previewImage(preview),
      badges: [
        e.layerStatus.name.toUpperCase(),
        if (fav) 'FAVORITE',
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
                        : (image ??
                            const Center(
                              child: Icon(Icons.videogame_asset,
                                  size: 42, color: Colors.white24),
                            )),
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
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: [
                          for (final b in badges.take(3))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                b,
                                style: const TextStyle(
                                    fontSize: 9, color: Colors.grey),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
