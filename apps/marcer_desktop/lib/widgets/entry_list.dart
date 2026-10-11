// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';
import '../theme.dart';

const double kItemExtent = 22.0;

/// Center panel: virtualized entry list with the SPEC §9.1 line format,
/// SPEC §10 keyboard bindings and 1/3–2/3-independent plain clamping
/// (desktop pointer input additionally allowed, R8).
class EntryList extends StatefulWidget {
  const EntryList({
    super.key,
    required this.controller,
    required this.onToggleHelp,
    required this.onOpenLightbox,
    required this.onFocusSearch,
  });

  final CatalogController controller;
  final VoidCallback onToggleHelp;

  /// Opens the lightbox for the selection (variant/image indices, see
  /// `GameLightbox.show` — entries are single-variant, always (0, 0)).
  final void Function(int variant, int image) onOpenLightbox;
  final VoidCallback onFocusSearch;

  @override
  State<EntryList> createState() => _EntryListState();
}

class _EntryListState extends State<EntryList> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'entry-list');
  final ScrollController _scroll = ScrollController();
  int _lastLength = 0;
  int _lastSelected = 0;

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
    final length = c.visibleEntries.length;
    final sel = c.selectedIndex;
    if (length != _lastLength || sel != _lastSelected) {
      _lastLength = length;
      _lastSelected = sel;
      _ensureVisible(sel);
      setState(() {});
    } else {
      setState(() {});
    }
  }

  void _ensureVisible(int index) {
    if (!_scroll.hasClients) return;
    final first = _scroll.offset / kItemExtent;
    final visibleCount = _scroll.position.viewportDimension / kItemExtent;
    if (index < first) {
      _scroll.animateTo(index * kItemExtent,
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut);
    } else if (index >= first + visibleCount - 1) {
      _scroll.animateTo((index - visibleCount + 2) * kItemExtent,
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut);
    }
  }

  int get _pageSize {
    if (!_scroll.hasClients || _scroll.position.viewportDimension <= 0) {
      return 10;
    }
    final n = (_scroll.position.viewportDimension / kItemExtent).floor();
    return n < 1 ? 1 : n;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final c = widget.controller;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowDown) {
      c.moveSelection(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      c.moveSelection(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      c.moveSelection(_pageSize);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      c.moveSelection(-_pageSize);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.arrowRight) {
      if (c.activate()) widget.onOpenLightbox(0, 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.arrowLeft) {
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
    if (char == 't' || char == 'T') {
      c.toggleView();
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
    final entries = c.visibleEntries;

    return Container(
      color: Colors.black,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: const Color(0xFF1B1B1B),
            child: Text(
              c.displayPath,
              style: const TextStyle(
                  fontSize: 12, color: Colors.grey, fontFamily: 'monospace'),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Focus(
              focusNode: _focusNode,
              onKeyEvent: _onKey,
              child: GestureDetector(
                onTap: () => _focusNode.requestFocus(),
                child: entries.isEmpty
                    ? const Center(
                        child: Text('Empty directory',
                            style:
                                TextStyle(color: Colors.grey, fontSize: 13)),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        itemExtent: kItemExtent,
                        itemCount: entries.length,
                        itemBuilder: (context, index) =>
                            _row(c, entries[index], index),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(CatalogController c, Entry e, int index) {
    final selected = index == c.selectedIndex;
    final favorite = e.kind == EntryKind.zip && c.isFavorite(e);
    final color = selected ? kSelectedForeground : colorForEntry(e);
    final prefix = linePrefix(e, favorite: favorite);
    return Material(
      color: selected ? kSelectedBackground : Colors.black,
      child: InkWell(
        onTap: () {
          c.moveSelectionTo(index);
          _focusNode.requestFocus();
        },
        onDoubleTap: () {
          c.moveSelectionTo(index);
          if (c.activate()) widget.onOpenLightbox(0, 0);
        },
        child: Container(
          height: kItemExtent,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              Text(
                prefix,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.2,
                  color: color,
                ),
              ),
              Expanded(
                child: Text(
                  e.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.2,
                    color: color,
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
