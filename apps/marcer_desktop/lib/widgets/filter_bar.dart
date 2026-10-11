// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';

/// Global filter bar in two rows plus section tabs and letter row, matching
/// the gallery webapp layout (`SPEC-gallery-webapp.md` §5): tabs + clear +
/// view toggle, then search / status / facet dropdowns / tri-state flags /
/// sort + order, and the letter row below.
class FilterBar extends StatefulWidget {
  const FilterBar({
    super.key,
    required this.controller,
    required this.searchFocus,
  });

  final CatalogController controller;

  /// Owned by the home page so the list/grid can hand focus over on `/`.
  final FocusNode searchFocus;

  @override
  State<FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<FilterBar> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search.text = widget.controller.filter.q;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      widget.controller.setQuery(value);
    });
  }

  KeyEventResult _searchKeys(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_search.text.isNotEmpty) {
        _search.clear();
        widget.controller.setQuery('');
        return KeyEventResult.handled;
      }
      widget.searchFocus.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final f = c.filter;
    final facets = c.facets;
    final fields = kindFilters(f.section);

    return Material(
      color: const Color(0xFF1B1B1B),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (final s in kSections) ...[
                  _tabButton(s, f.section == s, () => c.setSection(s)),
                  const SizedBox(width: 6),
                ],
                const Spacer(),
                _labelButton('clear', c.resetFilters),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Toggle list / grid view (V)',
                  onPressed: c.toggleViewOverride,
                  icon: Icon(
                    c.gridMode ? Icons.view_list : Icons.grid_view,
                    size: 18,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                SizedBox(
                  width: 240,
                  child: Focus(
                    focusNode: widget.searchFocus,
                    onKeyEvent: _searchKeys,
                    child: TextField(
                      controller: _search,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Search  ( / )',
                        prefixIcon: const Icon(Icons.search, size: 16),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 5),
                      ),
                      style: const TextStyle(fontSize: 12),
                      onChanged: _onSearchChanged,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (fields.contains('publisher'))
                  _facetDropdown(
                    'Publisher: any',
                    f.publisher,
                    ['any', ...facets.publishers],
                    c.setPublisher,
                    width: 170,
                  ),
                if (fields.contains('crew')) ...[
                  const SizedBox(width: 8),
                  _facetDropdown(
                    'Crew: any',
                    f.crew,
                    ['any', ...facets.crews],
                    c.setCrew,
                    width: 150,
                  ),
                ],
                if (fields.contains('language')) ...[
                  const SizedBox(width: 8),
                  _facetDropdown(
                    'Language: any',
                    f.language,
                    ['any', ...facets.languages],
                    c.setLanguage,
                    width: 130,
                  ),
                ],
                if (fields.contains('year')) ...[
                  const SizedBox(width: 8),
                  _facetDropdown(
                    'Year: any',
                    f.year,
                    ['any', ...facets.years],
                    c.setYear,
                    width: 100,
                  ),
                ],
                const Spacer(),
                if (f.section == 'cracked') ...[
                  _statusDropdown(f.status, c.setStatus),
                  const SizedBox(width: 8),
                ],
                if (fields.contains('raw')) ...[
                  _triDropdown('raw', f.raw, (v) => c.setFlag('raw', v)),
                  const SizedBox(width: 8),
                ],
                if (fields.contains('pasti')) ...[
                  _triDropdown('pasti', f.pasti, (v) => c.setFlag('pasti', v)),
                  const SizedBox(width: 8),
                ],
                if (fields.contains('boxscan')) ...[
                  _triDropdown(
                      'boxscan', f.boxscan, (v) => c.setFlag('boxscan', v)),
                  const SizedBox(width: 8),
                ],
                if (fields.contains('tos')) ...[
                  _tosDropdown(f.tos, c.setTos),
                  const SizedBox(width: 8),
                ],
                _facetDropdown(
                  'Sort: ',
                  f.sort,
                  [for (final k in kSortKeys) k],
                  c.setSort,
                  width: 120,
                  labelOf: (v) => 'Sort: $v',
                ),
                const SizedBox(width: 6),
                _labelButton(f.order == 'asc' ? 'asc' : 'desc',
                    c.toggleOrder, width: 36),
              ],
            ),
            const SizedBox(height: 4),
            _letterRow(facets.letters, f.letter, c.setLetter),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: active ? Colors.cyan.withValues(alpha: 0.25) : Colors.black,
          border: Border.all(
              color: active ? Colors.cyan : Colors.grey.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? Colors.cyan : Colors.grey,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _labelButton(String text, VoidCallback onTap, {double width = 48}) {
    return SizedBox(
      width: width,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          minimumSize: Size(width, 28),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _facetDropdown(
    String anyLabel,
    String value,
    List<String> items,
    ValueChanged<String> onChanged, {
    double width = 140,
    String Function(String)? labelOf,
  }) {
    String label(String v) {
      if (labelOf != null) return labelOf(v);
      if (v == anyLabel || v == 'any') return anyLabel;
      return v;
    }

    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        key: ValueKey('$anyLabel:$value'),
        initialValue: items.contains(value) ? value : items.first,
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        ),
        style: const TextStyle(fontSize: 12, color: Colors.white),
        items: [
          for (final v in items)
            DropdownMenuItem(
              value: v,
              child: Text(label(v), overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _statusDropdown(String value, ValueChanged<String> onChanged) {
    final keys = ['with_screenshot', 'any', ...kStatusOrder];
    return SizedBox(
      width: 150,
      child: DropdownButtonFormField<String>(
        key: ValueKey('status:$value'),
        initialValue: keys.contains(value) ? value : 'with_screenshot',
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        ),
        style: const TextStyle(fontSize: 12, color: Colors.white),
        items: [
          for (final k in keys)
            DropdownMenuItem(
              value: k,
              child: Text(kStatusLabels[k] ?? k,
                  overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _triDropdown(
      String flag, String value, ValueChanged<String> onChanged) {
    return SizedBox(
      width: 100,
      child: DropdownButtonFormField<String>(
        key: ValueKey('$flag:$value'),
        initialValue: value,
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        ),
        style: const TextStyle(fontSize: 12, color: Colors.white),
        items: [
          for (final v in const ['any', 'yes', 'no'])
            DropdownMenuItem(
                value: v, child: Text('$flag: $v', overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _tosDropdown(String value, ValueChanged<String> onChanged) {
    return SizedBox(
      width: 110,
      child: DropdownButtonFormField<String>(
        key: ValueKey('tos:$value'),
        initialValue: value,
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        ),
        style: const TextStyle(fontSize: 12, color: Colors.white),
        items: const [
          DropdownMenuItem(value: 'any', child: Text('TOS/Bad: any')),
          DropdownMenuItem(value: 'has', child: Text('TOS/Bad: has')),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _letterRow(
      List<String> facetLetters, String current, ValueChanged<String> onPick) {
    const all = [
      'any',
      '0-9',
      'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
      'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    ];
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (final l in all)
          InkWell(
            onTap: () => onPick(l),
            borderRadius: BorderRadius.circular(3),
            child: Container(
              width: 24,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: current == l
                    ? Colors.cyan.withValues(alpha: 0.3)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                l,
                style: TextStyle(
                  fontSize: 11,
                  color: current == l
                      ? Colors.cyan
                      : (l != 'any' && !facetLetters.contains(l)
                          ? Colors.grey.withValues(alpha: 0.5)
                          : Colors.grey),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
