// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../asset_updater.dart';
import '../catalog_controller.dart';
import '../piratefinder_data.dart';
import '../piratefinder_names.dart';
import '../self_updater.dart';
import 'select_menu.dart';

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
    this.pirateFinderUpdater,
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

  /// Optional PF catalogue data state; its pending update is counted in the
  /// same dataset badge/dialog as the Marcer catalog assets.
  final PirateFinderDataController? pirateFinderUpdater;

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

  /// Last seen filter revision; the bar only rebuilds when the filter state
  /// changes (not on every controller notification such as selection moves or
  /// the async layer-scan updates).
  int _lastFilterRevision = -1;

  /// Additional state the bar displays: the pending-curation count (Save (n))
  /// and whether the AtariLegend cache is loaded (Genre/Developers facets).
  int _lastPendingCount = -1;
  bool _lastHasAtariLegend = false;

  @override
  void initState() {
    super.initState();
    _lastQuery = widget.controller.filter.q;
    _lastFilterRevision = widget.controller.filterRevision;
    _lastPendingCount = widget.controller.pendingStatusCount;
    _lastHasAtariLegend = widget.controller.hasAtariLegend;
    _search.text = _lastQuery;
    widget.controller.addListener(_onControllerChanged);
    widget.updater?.addListener(_onUpdaterChanged);
    widget.assetUpdater?.addListener(_onUpdaterChanged);
    widget.pirateFinderUpdater?.addListener(_onUpdaterChanged);
  }

  @override
  void didUpdateWidget(covariant FilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _lastQuery = widget.controller.filter.q;
      _lastFilterRevision = widget.controller.filterRevision;
      _lastPendingCount = widget.controller.pendingStatusCount;
      _lastHasAtariLegend = widget.controller.hasAtariLegend;
      _applyQueryToField(_lastQuery);
      if (mounted) setState(() {});
    }
    if (oldWidget.updater != widget.updater) {
      oldWidget.updater?.removeListener(_onUpdaterChanged);
      widget.updater?.addListener(_onUpdaterChanged);
    }
    if (oldWidget.assetUpdater != widget.assetUpdater) {
      oldWidget.assetUpdater?.removeListener(_onUpdaterChanged);
      widget.assetUpdater?.addListener(_onUpdaterChanged);
    }
    if (oldWidget.pirateFinderUpdater != widget.pirateFinderUpdater) {
      oldWidget.pirateFinderUpdater?.removeListener(_onUpdaterChanged);
      widget.pirateFinderUpdater?.addListener(_onUpdaterChanged);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    widget.updater?.removeListener(_onUpdaterChanged);
    widget.assetUpdater?.removeListener(_onUpdaterChanged);
    widget.pirateFinderUpdater?.removeListener(_onUpdaterChanged);
    _search.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    _syncSearch();
    final c = widget.controller;
    var changed = false;
    final rev = c.filterRevision;
    if (rev != _lastFilterRevision) {
      _lastFilterRevision = rev;
      changed = true;
    }
    final pending = c.pendingStatusCount;
    if (pending != _lastPendingCount) {
      _lastPendingCount = pending;
      changed = true;
    }
    final hasAtariLegend = c.hasAtariLegend;
    if (hasAtariLegend != _lastHasAtariLegend) {
      _lastHasAtariLegend = hasAtariLegend;
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  void _onUpdaterChanged() {
    if (mounted) setState(() {});
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
    final isCrew = f.section == 'crew';
    // AtariLegend-only facets: hidden until the cache has been downloaded.
    final withAtariLegend = c.hasAtariLegend;

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
                    _tabButton(
                      _sectionLabel(s),
                      f.section == s,
                      () => c.setSection(s),
                    ),
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
                _labelButton(
                  c.catalogMode ? 'Folders (T)' : 'Catalog (T)',
                  c.toggleView,
                  width: 92,
                ),
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
                              horizontal: 8,
                              vertical: 10,
                            ),
                          ),
                          style: const TextStyle(fontSize: 12),
                          onChanged: _onSearchChanged,
                        ),
                      ),
                    ),
                  ),
                  // Status filter is available for every section now that
                  // pd/utils carry index-derived statuses; all sections start
                  // with the configured `DefaultStatus`. Crew cards are not
                  // screenshot-status driven.
                  if (!isCrew)
                    SelectMenu(
                      value: f.status,
                      items: ['with_screenshot', 'any', ...kStatusFilterKeys],
                      labelOf: (v) => kStatusLabels[v] ?? v,
                      onChanged: c.setStatus,
                      width: 150,
                    ),
                  if (isCrew)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        c.crews.length == 0
                            ? 'No crew data'
                            : 'Top ${c.crews.length < kCrewInitialLimit ? c.crews.length : kCrewInitialLimit} by ZIPs',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  if (withAtariLegend && fields.contains('genre'))
                    SelectMenu(
                      value: f.genre,
                      items: ['any', ...facets.genres],
                      labelOf: (v) => v == 'any' ? 'Genre: any' : v,
                      onChanged: c.setGenre,
                      width: 130,
                    ),
                  if (fields.contains('publisher'))
                    SelectMenu(
                      value: f.publisher,
                      items: ['any', ...facets.publishers],
                      labelOf: (v) => v == 'any' ? 'Publisher: any' : v,
                      onChanged: c.setPublisher,
                      width: 140,
                    ),
                  if (withAtariLegend && fields.contains('developer'))
                    SelectMenu(
                      value: f.developer,
                      items: ['any', ...facets.developers],
                      labelOf: (v) => v == 'any' ? 'Developers: any' : v,
                      onChanged: c.setDeveloper,
                      width: 140,
                    ),
                  if (fields.contains('crew'))
                    SelectMenu(
                      value: f.crew,
                      items: ['any', ...facets.crews],
                      labelOf: (v) => v == 'any' ? 'Crew: any' : v,
                      onChanged: c.setCrew,
                      width: 120,
                    ),
                  if (fields.contains('cracker'))
                    SelectMenu(
                      value: f.cracker,
                      items: ['any', ...facets.crackers],
                      labelOf: (v) => v == 'any' ? 'Cracker: any' : v,
                      onChanged: c.setCracker,
                      width: 105,
                    ),
                  if (fields.contains('language'))
                    SelectMenu(
                      value: f.language,
                      items: ['any', ...facets.languages],
                      labelOf: (v) => v == 'any' ? 'Language: any' : v,
                      onChanged: c.setLanguage,
                      width: 130,
                    ),
                  if (fields.contains('year'))
                    SelectMenu(
                      value: f.year,
                      items: ['any', ...facets.years],
                      labelOf: (v) => v == 'any' ? 'Year: any' : v,
                      onChanged: c.setYear,
                      width: 100,
                    ),
                  if (fields.contains('raw'))
                    SelectMenu(
                      value: f.raw,
                      items: const ['any', 'yes', 'no'],
                      labelOf: (v) => 'raw: $v',
                      onChanged: (v) => c.setFlag('raw', v),
                      width: 100,
                    ),
                  if (fields.contains('pasti'))
                    SelectMenu(
                      value: f.pasti,
                      items: const ['any', 'yes', 'no'],
                      labelOf: (v) => 'pasti: $v',
                      onChanged: (v) => c.setFlag('pasti', v),
                      width: 100,
                    ),
                  if (fields.contains('boxscan'))
                    SelectMenu(
                      value: f.boxscan,
                      items: const ['any', 'yes', 'no'],
                      labelOf: (v) => 'boxscan: $v',
                      onChanged: (v) => c.setFlag('boxscan', v),
                      width: 100,
                    ),
                  if (fields.contains('tos'))
                    SelectMenu(
                      value: f.tos,
                      items: const ['any', 'has'],
                      labelOf: (v) => 'TOS/Bad: $v',
                      onChanged: c.setTos,
                      width: 120,
                    ),
                  if (!isCrew)
                    SelectMenu(
                      value: '${f.sort}:${f.order}',
                      items: [
                        for (final k in kSortKeys)
                          for (final o in const ['asc', 'desc']) '$k:$o',
                      ],
                      labelOf: (v) => v.replaceFirst(':', ' '),
                      onChanged: (v) {
                        final i = v.lastIndexOf(':');
                        c.setSortOrder(v.substring(0, i), v.substring(i + 1));
                      },
                      width: 120,
                    ),
                ],
              ),
              if (!isCrew) ...[
                const SizedBox(height: 4),
                _letterRow(
                  facets.letters,
                  f.letter,
                  c.setLetter,
                  trailing: [
                    const SizedBox(width: 8),
                    _labelButton(
                      '★ Favorites',
                      c.toggleFavoritesOnly,
                      width: 96,
                      active: c.favoritesOnly,
                    ),
                    const SizedBox(width: 2),
                    _labelButton('clear', c.resetFilters, width: 52),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Display label for a section tab: the `cracked` section shows as
  /// `games` (the filter value / section key itself stays unchanged).
  String _sectionLabel(String section) => switch (section) {
    'cracked' => 'games',
    'crew' => 'crews',
    'magazine' => 'magazines',
    _ => section,
  };

  Widget _tabButton(String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: active ? Colors.cyan.withValues(alpha: 0.25) : Colors.black,
          border: Border.all(
            color: active ? Colors.cyan : Colors.grey.withValues(alpha: 0.4),
          ),
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
            message:
                'Save $n manual status/kind change(s)\n'
                'to index.json (shotgen lock)',
            child: TextButton(
              onPressed: _savePending,
              style: TextButton.styleFrom(
                foregroundColor: Colors.cyan,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 28),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
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

  /// Runs a manual self-update check and reports the outcome in a snackbar.
  Future<void> _checkForUpdates(SelfUpdateController u) async {
    await u.check(manual: true);
    if (!mounted) return;
    final error = u.checkError;
    final info = u.available;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error ??
              (info == null
                  ? 'You are running the latest version '
                        '(v${u.currentVersion}).'
                  : 'Update v${info.version} available.'),
        ),
        // The App-Translocation guidance is several lines long.
        duration: Duration(seconds: error == null ? 4 : 10),
      ),
    );
  }

  /// Self-update control left of the Folders button: a gray check icon while
  /// no update is known, a spinner while checking, and the amber update badge
  /// (install on click) once a newer release was found. Hidden in dev builds.
  Widget _updateBadge(SelfUpdateController u) {
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        if (!u.isEnabled) return const SizedBox.shrink();
        final info = u.available;
        final phase = u.phase;
        final busy =
            phase == UpdatePhase.downloading ||
            phase == UpdatePhase.installing ||
            phase == UpdatePhase.restarting;
        if (phase == UpdatePhase.checking) {
          return const SizedBox(
            width: 32,
            height: 28,
            child: Tooltip(
              message: 'Checking for updates…',
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          );
        }
        if (info == null && !busy) {
          return SizedBox(
            width: 32,
            height: 28,
            child: Tooltip(
              message: 'Check for updates (v${u.currentVersion})',
              child: TextButton(
                onPressed: () => _checkForUpdates(u),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(32, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  alignment: Alignment.center,
                ),
                child: const Icon(Icons.system_update_alt, size: 16),
              ),
            ),
          );
        }
        final String label;
        if (phase == UpdatePhase.downloading) {
          final pct = u.progress == null
              ? ''
              : ' ${(u.progress! * 100).round()}%';
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
                disabledForegroundColor: const Color(0xFFFFD54A)
                    .withValues(alpha: 0.6),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 28),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
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
        final n =
            a.pendingAssets().length +
            (widget.pirateFinderUpdater?.hasPending == true ? 1 : 0);
        final button = SizedBox(
          width: 32,
          height: 28,
          child: Tooltip(
            message:
                'Check catalog assets (screenshots / game info / '
                '$kPirateFinderCatalogShortName)',
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

  Widget _labelButton(
    String text,
    VoidCallback onTap, {
    double width = 48,
    bool active = false,
  }) {
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
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// Facet dropdown with type-to-filter: tapping opens an editable field,
  /// typing narrows the list and Enter picks the match (`DropdownMenu`
  /// `enableFilter`). Keeps the compact look of the other controls.
  Widget _letterRow(
    List<String> facetLetters,
    String current,
    ValueChanged<String> onPick, {
    List<Widget> trailing = const [],
  }) {
    const all = [
      'any',
      '0-9',
      'A',
      'B',
      'C',
      'D',
      'E',
      'F',
      'G',
      'H',
      'I',
      'J',
      'K',
      'L',
      'M',
      'N',
      'O',
      'P',
      'Q',
      'R',
      'S',
      'T',
      'U',
      'V',
      'W',
      'X',
      'Y',
      'Z',
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
