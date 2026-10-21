// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../asset_updater.dart';
import '../catalog_controller.dart';
import '../self_updater.dart';

/// Global filter bar in two rows plus section tabs and letter row, matching
/// the gallery webapp layout (`SPEC-gallery-webapp.md` §5): tabs + clear +
/// view toggle, then search / status / facet dropdowns / tri-state flags /
/// combined sort+order dropdown, and the letter row below.
class FilterBar extends StatefulWidget {
  const FilterBar({
    super.key,
    required this.controller,
    required this.searchFocus,
    this.onExitSearch,
    this.onOpenSettings,
    this.updater,
    this.assetUpdater,
    this.onOpenAssetUpdates,
  });

  final CatalogController controller;

  /// Owned by the home page so the list/grid can hand focus over on `/`.
  /// Attached directly to the search `TextField` so typing works.
  final FocusNode searchFocus;

  /// Called when Escape leaves an empty search field (focus goes back to
  /// the grid/list).
  final VoidCallback? onExitSearch;

  /// Opens the in-app settings editor (path fields of `desktop.config.json`);
  /// rendered as a gear button left of the Folders toggle.
  final VoidCallback? onOpenSettings;

  /// Self-update state; when a release build found a newer version, the
  /// first row shows an amber update badge left of the Folders button.
  final SelfUpdateController? updater;

  /// Catalog-data (screenshots/gameinfo) update state; a green badge appears
  /// when newer asset archives are available.
  final AssetUpdateController? assetUpdater;

  /// Opens the catalog-data update dialog (from the green badge).
  final VoidCallback? onOpenAssetUpdates;

  @override
  State<FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<FilterBar> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  /// Last query seen from the controller; used to detect external resets
  /// (`clear`, Backspace, a reloaded controller) without fighting the user's
  /// in-flight typing.
  late String _lastQuery;

  /// Cached facet dropdown entries (static per section) and the section they
  /// were built for.
  final Map<String, List<DropdownMenuEntry<String>>> _facetEntries = {};
  String? _facetEntriesSection;

  @override
  void initState() {
    super.initState();
    _lastQuery = widget.controller.filter.q;
    _search.text = _lastQuery;
    widget.controller.addListener(_syncSearch);
  }

  @override
  void didUpdateWidget(covariant FilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncSearch);
      widget.controller.addListener(_syncSearch);
      _lastQuery = widget.controller.filter.q;
      _applyQueryToField(_lastQuery);
      _facetEntries.clear();
      _facetEntriesSection = null;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_syncSearch);
    _search.dispose();
    super.dispose();
  }

  /// Reflects an externally changed query (reset/reload) in the search field.
  /// Only reacts when `filter.q` actually changed, so the debounce-delayed
  /// typing is not overwritten by unrelated notifications.
  void _syncSearch() {
    final q = widget.controller.filter.q;
    if (q == _lastQuery) return;
    _lastQuery = q;
    _applyQueryToField(q);
  }

  void _applyQueryToField(String q) {
    // Drop a pending typed query so it cannot re-apply after a reset.
    _debounce?.cancel();
    if (_search.text != q) {
      _search.value = TextEditingValue(
        text: q,
        selection: TextSelection.collapsed(offset: q.length),
      );
    }
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
        // Cancel a pending debounce: otherwise it could re-apply the text
        // after the query was reset here.
        _debounce?.cancel();
        _search.clear();
        widget.controller.setQuery('');
        return KeyEventResult.handled;
      }
      widget.searchFocus.unfocus();
      widget.onExitSearch?.call();
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
    // AtariLegend-only facets: hidden until the cache has been downloaded.
    final withAtariLegend = c.hasAtariLegend;
    // The facet entry lists are static per section; rebuild them only when the
    // section changes (the FilterBar rebuilds on every controller notify, and
    // recreating thousands of DropdownMenuEntry objects each time was pure
    // waste).
    if (_facetEntriesSection != f.section) {
      _facetEntriesSection = f.section;
      _facetEntries.clear();
    }

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
                if (c.catalogMode) ...[
                  for (final s in kSections) ...[
                    _tabButton(_sectionLabel(s), f.section == s,
                        () => c.setSection(s)),
                    const SizedBox(width: 6),
                  ],
                ],
                const Spacer(),
                if (c.hasPendingStatusChanges) ...[
                  _saveBadge(c),
                  const SizedBox(width: 6),
                ],
                if (widget.updater != null) ...[
                  _updateBadge(widget.updater!),
                  const SizedBox(width: 6),
                ],
                if (widget.assetUpdater != null) ...[
                  _catalogAssetsButton(widget.assetUpdater!),
                  const SizedBox(width: 6),
                ],
                if (widget.onOpenSettings != null) ...[
                  _settingsButton(widget.onOpenSettings!),
                  const SizedBox(width: 6),
                ],
                _labelButton(c.catalogMode ? 'Folders (T)' : 'Catalog (T)',
                    c.toggleView, width: 92),
              ],
            ),
            if (c.catalogMode) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _fixed(
                    SizedBox(
                      width: 174,
                      // Escape handling on the wrapper: key events bubble up
                      // from the TextField's own focus node below.
                      child: Focus(
                        onKeyEvent: _searchKeys,
                        child: TextField(
                          key: const ValueKey('catalog-search'),
                          focusNode: widget.searchFocus,
                          controller: _search,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Search  ( / )',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 10),
                          ),
                          style: const TextStyle(fontSize: 12),
                          onChanged: _onSearchChanged,
                        ),
                      ),
                    ),
                  ),
                  // Status filter is available for every section now that
                  // pd/utils carry index-derived statuses (default `any`
                  // there, `default_status` for cracked).
                  _statusDropdown(f.status, c.setStatus),
                  if (withAtariLegend && fields.contains('genre'))
                    _facetMenu(
                      'Genre: any',
                      f.genre,
                      ['any', ...facets.genres],
                      c.setGenre,
                      width: 130,
                    ),
                  if (fields.contains('publisher'))
                    _facetMenu(
                      'Publisher: any',
                      f.publisher,
                      ['any', ...facets.publishers],
                      c.setPublisher,
                      width: 140,
                    ),
                  if (withAtariLegend && fields.contains('developer'))
                    _facetMenu(
                      'Developers: any',
                      f.developer,
                      ['any', ...facets.developers],
                      c.setDeveloper,
                      width: 140,
                    ),
                  if (fields.contains('crew'))
                    _facetMenu(
                      'Crew: any',
                      f.crew,
                      ['any', ...facets.crews],
                      c.setCrew,
                      width: 120,
                    ),
                  if (fields.contains('cracker'))
                    _facetMenu(
                      'Cracker: any',
                      f.cracker,
                      ['any', ...facets.crackers],
                      c.setCracker,
                      width: 105,
                    ),
                  if (fields.contains('language'))
                    _facetMenu(
                      'Language: any',
                      f.language,
                      ['any', ...facets.languages],
                      c.setLanguage,
                      width: 130,
                    ),
                  if (fields.contains('year'))
                    _facetMenu(
                      'Year: any',
                      f.year,
                      ['any', ...facets.years],
                      c.setYear,
                      width: 100,
                    ),
                  if (fields.contains('raw'))
                    _triDropdown('raw', f.raw, (v) => c.setFlag('raw', v)),
                  if (fields.contains('pasti'))
                    _triDropdown('pasti', f.pasti, (v) => c.setFlag('pasti', v)),
                  if (fields.contains('boxscan'))
                    _triDropdown(
                        'boxscan', f.boxscan, (v) => c.setFlag('boxscan', v)),
                  if (fields.contains('tos'))
                    _tosDropdown(f.tos, c.setTos),
                  _sortDropdown(f.sort, f.order, c.setSortOrder),
                ],
              ),
              const SizedBox(height: 4),
              _letterRow(
                facets.letters,
                f.letter,
                c.setLetter,
                trailing: [
                  const SizedBox(width: 8),
                  _labelButton('★ Favorites', c.toggleFavoritesOnly,
                      width: 96, active: c.favoritesOnly),
                  const SizedBox(width: 2),
                  _labelButton('clear', c.resetFilters, width: 52),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Display label for a section tab: the `cracked` section shows as
  /// `games` (the filter value / section key itself stays unchanged).
  String _sectionLabel(String section) =>
      section == 'cracked' ? 'games' : section;

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

  /// Fixed 28px height so every control in the wrapping filter row lines up.
  Widget _fixed(Widget child) => SizedBox(height: 28, child: child);

  /// Cyan save button (with discard ✕) left of the update badge: appears
  /// while manual curation changes (`C` in the lightbox/detail view) are
  /// pending and writes them to `index.json` + mirror meta under the
  /// shotgen lock.
  Widget _saveBadge(CatalogController c) {
    final n = c.pendingStatusCount;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 28,
          child: Tooltip(
            message: 'Save $n manual status/kind change(s)\n'
                'to index.json (shotgen lock)',
            child: TextButton(
              onPressed: _savePending,
              style: TextButton.styleFrom(
                foregroundColor: Colors.cyan,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 28),
                textStyle:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              child: Text('Save ($n)'),
            ),
          ),
        ),
        SizedBox(
          height: 28,
          child: Tooltip(
            message: 'Discard the pending changes',
            child: TextButton(
              onPressed: c.discardPendingStatusChanges,
              style: TextButton.styleFrom(
                foregroundColor: Colors.grey,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28),
              ),
              child: const Text('✕', style: TextStyle(fontSize: 12)),
            ),
          ),
        ),
      ],
    );
  }

  /// Persists the pending curation changes; errors (e.g. a live shotgen
  /// run holding the lock) surface as a snackbar and keep the pending list.
  Future<void> _savePending() async {
    final err = await widget.controller.savePendingStatusChanges();
    if (err == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(err), duration: const Duration(seconds: 4)),
    );
  }

  /// Amber update badge left of the Folders button: shows the newer
  /// version and, on click, downloads + installs it and relaunches the
  /// app. Hidden when no newer release was found (or in dev builds).
  Widget _updateBadge(SelfUpdateController u) {
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        final info = u.available;
        final phase = u.phase;
        final busy = phase == UpdatePhase.downloading ||
            phase == UpdatePhase.installing ||
            phase == UpdatePhase.restarting;
        if (info == null && !busy) return const SizedBox.shrink();
        final String label;
        if (phase == UpdatePhase.downloading) {
          final pct =
              u.progress == null ? '' : ' ${(u.progress! * 100).round()}%';
          label = '⬇ updating$pct';
        } else if (phase == UpdatePhase.installing) {
          label = 'installing…';
        } else if (phase == UpdatePhase.restarting) {
          label = 'restarting…';
        } else {
          label = '⬆ ${info!.version}';
        }
        return SizedBox(
          height: 28,
          child: Tooltip(
            message: busy
                ? 'Installing update ${info?.version}…'
                : 'Update ${u.currentVersion} → ${info!.version}\n'
                    'Download, install and restart the app',
            child: TextButton(
              onPressed: busy ? null : () => u.install(),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFFD54A),
                disabledForegroundColor:
                    const Color(0xFFFFD54A).withValues(alpha: 0.6),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 28),
                textStyle: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold),
              ),
              child: Text(label),
            ),
          ),
        );
      },
    );
  }

  /// Always-visible gray button (top right, left of the gear) that opens the
  /// catalog-data update dialog; a small green badge shows how many assets have
  /// updates available.
  Widget _catalogAssetsButton(AssetUpdateController a) {
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) {
        final n = a.pendingAssets().length;
        final button = SizedBox(
          width: 32,
          height: 28,
          child: Tooltip(
            message: 'Check catalog assets (screenshots / game info)',
            child: TextButton(
              onPressed: widget.onOpenAssetUpdates,
              style: TextButton.styleFrom(
                foregroundColor: Colors.grey,
                padding: EdgeInsets.zero,
                minimumSize: const Size(32, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                alignment: Alignment.center,
              ),
              child: const Icon(Icons.dataset, size: 16),
            ),
          ),
        );
        if (n == 0) return button;
        return Badge(
          label: Text('$n'),
          backgroundColor: const Color(0xFF66BB6A),
          offset: const Offset(-4, -2),
          child: button,
        );
      },
    );
  }

  /// Gear button left of the Folders toggle: opens the settings editor for
  /// the `desktop.config.json` path fields.
  Widget _settingsButton(VoidCallback onTap) {
    return SizedBox(
      width: 32,
      height: 28,
      child: Tooltip(
        message: 'Settings — edit desktop.config.json paths',
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: Colors.grey,
            padding: EdgeInsets.zero,
            minimumSize: const Size(32, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            alignment: Alignment.center,
          ),
          child: const Icon(Icons.settings, size: 16),
        ),
      ),
    );
  }

  Widget _labelButton(String text, VoidCallback onTap,
      {double width = 48, bool active = false}) {
    return SizedBox(
      width: width,
      height: 28,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: active ? const Color(0xFFFFD54A) : null,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size(width, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: Alignment.center,
        ),
        child: Text(text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
            )),
      ),
    );
  }

  /// Facet dropdown with type-to-filter: tapping opens an editable field,
  /// typing narrows the list and Enter picks the match (`DropdownMenu`
  /// `enableFilter`). Keeps the compact look of the other controls.
  Widget _facetMenu(
    String anyLabel,
    String value,
    List<String> items,
    ValueChanged<String> onChanged, {
    double width = 140,
    String Function(String)? labelOf,
  }) {
    String label(String v) {
      if (labelOf != null) return labelOf(v);
      return v == 'any' ? anyLabel : v;
    }

    return SizedBox(
      width: width,
      height: 28,
      child: DropdownMenu<String>(
        key: ValueKey('$anyLabel:$value'),
        width: width,
        initialSelection: items.contains(value) ? value : items.first,
        enableFilter: true,
        requestFocusOnTap: true,
        // Open menu ≈ 3/4 of the screen height (shrinks for short lists).
        menuHeight: MediaQuery.sizeOf(context).height * 0.75,
        // Exact label match wins (reopening after a selection jumps to that
        // entry); while typing the partial substring match keeps the
        // highlight + Enter selection. Empty query → no highlight.
        searchCallback: (entries, query) {
          if (query.isEmpty) return null;
          final exact =
              entries.indexWhere((e) => e.label.toLowerCase() == query.toLowerCase());
          if (exact != -1) return exact;
          final q = query.toLowerCase();
          return entries
              .indexWhere((e) => e.label.toLowerCase().contains(q));
        },
        textStyle: const TextStyle(fontSize: 12, color: Colors.white),
        inputDecorationTheme: const InputDecorationTheme(
          isDense: true,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(4))),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        ),
        // A plain centered arrow (the default suffix IconButton's 8px padding
        // gets squeezed by the tight box and pushes the glyph to the corner).
        // The whole field stays tappable and opens the menu.
        decorationBuilder: (context, controller) => const InputDecoration(
          suffixIcon: Icon(Icons.arrow_drop_down, size: 20),
          suffixIconConstraints: BoxConstraints(
              minWidth: 28, maxWidth: 28, minHeight: 28, maxHeight: 28),
        ),
        dropdownMenuEntries: _facetEntries.putIfAbsent(anyLabel, () => [
          for (final v in items)
            DropdownMenuEntry<String>(value: v, label: label(v)),
        ]),
        onSelected: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _statusDropdown(String value, ValueChanged<String> onChanged) {
    final keys = ['with_screenshot', 'any', ...kStatusFilterKeys];
    return SizedBox(
      width: 150,
      height: 28,
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

  /// Combined sort + order dropdown in the style of the other dropdowns,
  /// entries `<key> asc` / `<key> desc` (e.g. `year desc`). Same width as
  /// the TOS/Bad dropdown. Replaces the former sort facet menu plus the
  /// separate asc/desc button.
  Widget _sortDropdown(
      String sort, String order, void Function(String, String) onChanged) {
    const orders = ['asc', 'desc'];
    final value = kSortKeys.contains(sort)
        ? '$sort:$order'
        : '${kSortKeys.first}:$order';
    return SizedBox(
      width: 120,
      height: 28,
      child: DropdownButtonFormField<String>(
        key: ValueKey('sort:$value'),
        initialValue: value,
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        ),
        style: const TextStyle(fontSize: 12, color: Colors.white),
        items: [
          for (final k in kSortKeys)
            for (final o in orders)
              DropdownMenuItem(
                value: '$k:$o',
                child: Text('$k $o', overflow: TextOverflow.ellipsis),
              ),
        ],
        onChanged: (v) {
          if (v == null) return;
          final i = v.lastIndexOf(':');
          onChanged(v.substring(0, i), v.substring(i + 1));
        },
      ),
    );
  }

  Widget _triDropdown(
      String flag, String value, ValueChanged<String> onChanged) {
    return SizedBox(
      width: 100,
      height: 28,
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
      width: 120,
      height: 28,
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
          DropdownMenuItem(
              value: 'any',
              child: Text('TOS/Bad: any',
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          DropdownMenuItem(
              value: 'has',
              child: Text('TOS/Bad: has',
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  Widget _letterRow(
    List<String> facetLetters,
    String current,
    ValueChanged<String> onPick, {
    List<Widget> trailing = const [],
  }) {
    const all = [
      'any',
      '0-9',
      'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
      'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    ];
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
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
        ...trailing,
      ],
    );
  }
}
