// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Compact dropdown used by the filter bar and the crew lightbox. It opens a
/// virtualized, type-to-filter menu (`↑`/`↓` + `Enter`) instead of a plain
/// `DropdownButton`.
class SelectMenu extends StatefulWidget {
  const SelectMenu({
    super.key,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
    this.width = 140,
  });

  final String value;
  final List<String> items;
  final String Function(String) labelOf;
  final ValueChanged<String> onChanged;
  final double width;

  @override
  State<SelectMenu> createState() => _SelectMenuState();
}

class _SelectMenuState extends State<SelectMenu> {
  final MenuController _menu = MenuController();

  void _select(String value) {
    _menu.close();
    if (value != widget.value) widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final menuWidth = math.min(280.0, MediaQuery.sizeOf(context).width - 32);
    // Up to ¾ of the screen, but shrink for short lists.
    final menuHeight = math.min(
      screenHeight * 0.75,
      widget.items.length * 28.0 + 64.0,
    );
    return SizedBox(
      width: widget.width,
      height: 28,
      child: MenuAnchor(
        controller: _menu,
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll<Color>(
            Color(0xFF1B1B1B),
          ),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.zero,
          ),
          minimumSize: WidgetStatePropertyAll<Size>(Size(menuWidth, 0)),
          maximumSize: WidgetStatePropertyAll<Size>(
            Size(menuWidth, screenHeight * 0.75),
          ),
        ),
        menuChildren: [
          _SelectMenuPanel(
            width: menuWidth,
            height: menuHeight,
            items: widget.items,
            value: widget.value,
            labelOf: widget.labelOf,
            onSelected: _select,
            onClose: _menu.close,
          ),
        ],
        builder: (context, controller, child) {
          return Semantics(
            button: true,
            label: widget.labelOf(widget.value),
            excludeSemantics: true,
            child: InkWell(
              onTap: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFF3A3A3A)),
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.labelOf(widget.value),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.arrow_drop_down,
                      size: 20,
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Menu body: filter field + lazily built `ListView` of the matching entries.
/// Up/Down move a highlight (and scroll it into view), Enter selects it.
class _SelectMenuPanel extends StatefulWidget {
  const _SelectMenuPanel({
    required this.width,
    required this.height,
    required this.items,
    required this.value,
    required this.labelOf,
    required this.onSelected,
    required this.onClose,
  });

  final double width;
  final double height;
  final List<String> items;
  final String value;
  final String Function(String) labelOf;
  final ValueChanged<String> onSelected;
  final VoidCallback onClose;

  @override
  State<_SelectMenuPanel> createState() => _SelectMenuPanelState();
}

class _SelectMenuPanelState extends State<_SelectMenuPanel> {
  final TextEditingController _filter = TextEditingController();
  late final ScrollController _scroll;
  String _query = '';
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    // Open at the selected entry.
    final index = widget.items.indexOf(widget.value);
    _highlight = index < 0 ? 0 : index;
    _scroll = ScrollController(
      initialScrollOffset: _highlight <= 0 ? 0.0 : _highlight * 28.0,
    );
  }

  @override
  void dispose() {
    _filter.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<String> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    return [
      for (final v in widget.items)
        if (widget.labelOf(v).toLowerCase().contains(q)) v,
    ];
  }

  void _moveHighlight(int delta, List<String> items) {
    if (items.isEmpty) return;
    final next = (_highlight + delta).clamp(0, items.length - 1);
    if (next == _highlight) return;
    setState(() => _highlight = next);
    _reveal(next);
  }

  void _reveal(int index) {
    if (!_scroll.hasClients) return;
    final offset = index * 28.0;
    final pos = _scroll.position;
    if (offset < pos.pixels) {
      _scroll.animateTo(
        offset,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    } else if (offset + 28 > pos.pixels + pos.viewportDimension) {
      _scroll.animateTo(
        offset + 28 - pos.viewportDimension,
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
      );
    }
  }

  void _choose(List<String> items) {
    if (items.isEmpty) return;
    final q = _query.trim().toLowerCase();
    final exact = items.indexWhere((v) => widget.labelOf(v).toLowerCase() == q);
    final index = exact >= 0 ? exact : _highlight.clamp(0, items.length - 1);
    widget.onSelected(items[index]);
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    final highlight = items.isEmpty ? 0 : _highlight.clamp(0, items.length - 1);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _moveHighlight(1, items),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _moveHighlight(-1, items),
        const SingleActivator(LogicalKeyboardKey.enter): () => _choose(items),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
            _choose(items),
      },
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: TextField(
                controller: _filter,
                autofocus: true,
                style: const TextStyle(fontSize: 12, color: Colors.white),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Type to filter…',
                  hintStyle: TextStyle(fontSize: 12, color: Colors.grey),
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                ),
                onChanged: (v) {
                  setState(() {
                    _query = v;
                    _highlight = 0;
                  });
                  if (_scroll.hasClients) _scroll.jumpTo(0);
                },
              ),
            ),
            const Divider(height: 1, color: Color(0xFF2A2A2A)),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Text(
                        'No matches',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      primary: false,
                      itemCount: items.length,
                      itemExtent: 28,
                      itemBuilder: (context, i) {
                        final v = items[i];
                        final selected = v == widget.value;
                        final active = i == highlight;
                        return Semantics(
                          selected: selected,
                          button: true,
                          child: InkWell(
                            onTap: () => widget.onSelected(v),
                            child: Container(
                              color: active
                                  ? const Color(0xFF2A3A3A)
                                  : (selected
                                        ? const Color(0xFF1E3A3A)
                                        : Colors.transparent),
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              child: Text(
                                widget.labelOf(v),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: selected
                                      ? Colors.cyan
                                      : (active
                                            ? Colors.white
                                            : Colors.white70),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
