// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

import 'favorites_service.dart';
import 'hatari_launcher.dart';

/// Sentinel rel-path for the virtual `Favorites` view (`SPEC.md` §11.3);
/// cannot collide with a real directory name (NUL is invalid in paths).
const String kFavoritesRel = '\u0000favorites';

/// Top-level view of the app: the global gallery-like catalog grid (default)
/// or the optional overlay folder browser.
enum AppView { catalog, folders }

/// Application state for Surface A: navigation (SPEC §8), favorites (§11),
/// the gallery-style global filters (catalog mode) and the joins into
/// gameinfo + screenshot index.
///
/// Read-only towards all data roots; only `favorites.txt` is written.
class CatalogController extends ChangeNotifier {
  CatalogController(this.config) {
    // gallery `default_status` config: the factory state of the filter.
    filter.factoryStatus = config.defaultStatus;
    filter.status = config.defaultStatus;
  }

  final DesktopConfig config;

  late final OverlayBrowser browser;
  late ScreenshotIndex screenshots;
  late GameInfoIndex gameinfo;
  late CatalogUniverse universe;
  FavoritesService? favorites;

  bool ready = false;
  String progress = '';
  final List<String> notices = [];

  /// True while a Hatari process launched from the app is running.
  bool launching = false;

  /// Last launch error (SPEC.md E3/E4/E7), shown as a modal and cleared on
  /// acknowledgement.
  String? launchError;

  /// Active top-level view; the gallery-like catalog grid is the default.
  AppView view = AppView.catalog;

  // --- navigation state (SPEC §8.1) ---
  String currentRel = '';
  int selectedIndex = 0;
  final Map<String, _SelMemory> _lastSelections = {};

  /// Gallery-style global filter state; [CatalogFilter.isActive] switches
  /// the app into catalog (global) mode (user decision 2026-10-11).
  final CatalogFilter filter = CatalogFilter();
  List<GameCard>? _catalogCache;
  bool _catalogDirty = true;

  /// Catalog-only "★ Favorites" filter (not part of [CatalogFilter]).
  bool favoritesOnly = false;

  final Map<String, List<Entry>> _entryCache = {};
  final Map<String, List<Entry>> _dirCache = {};

  // ---------------------------------------------------------------- loading

  Future<void> init() async {
    progress = 'Loading catalog…';
    notifyListeners();
    // Capture a plain config value (not `this`) so the isolate closure stays
    // sendable even when listeners are attached to the controller.
    final cfg = config;
    final bundle = await Isolate.run(() => CatalogBundle.loadSync(
          outDir: cfg.outDirectory,
          dataDir: cfg.resolveDataDirectory(),
        ));
    notices.addAll(bundle.warnings);
    screenshots = bundle.index;
    gameinfo = bundle.info;
    universe = bundle.universe;

    if (!Directory(config.rootDirectory).existsSync()) {
      notices.add('RootDirectory missing: ${config.rootDirectory}');
    }

    // SPEC §11.1: PatchDirectory → application directory → CWD; the console
    // launcher writes to PatchDirectory or next to its EXE with the same
    // format (one absolute effective path per line).
    favorites = FavoritesService.load(resolveFavoritesPath(
      patchDir: config.patchDirectory.isEmpty ? null : config.patchDirectory,
      appDir: File(Platform.resolvedExecutable).parent.path,
      cwd: Directory.current.path,
      exists: (path) => File(path).existsSync(),
    ));

    browser = OverlayBrowser(
      rootDir: config.rootDirectory,
      patchDir: config.patchDirectory.isEmpty ? null : config.patchDirectory,
    );
    ready = true;
    progress = '';
    notifyListeners();
  }

  // ------------------------------------------------------- catalog (global)

  /// True in the default gallery-like catalog grid (vs. the optional
  /// overlay folder browser).
  bool get catalogMode => view == AppView.catalog;

  /// `T`: toggle between the catalog grid (default) and the folder browser.
  void toggleView() {
    view = catalogMode ? AppView.folders : AppView.catalog;
    selectedIndex = 0;
    notifyListeners();
  }

  CatalogFacets get facets => universe.facetsFor(filter.section);

  bool get crewFocusActive =>
      filter.crew != 'any' && kindFilters(filter.section).contains('crew');
  bool get crackerFocusActive =>
      filter.cracker != 'any' && kindFilters(filter.section).contains('cracker');

  /// True while a crew/cracker focus filter is active (gallery
  /// `focusActive`); drives the grid miss/2×2 bodies and lightbox labels.
  bool get focusActive => crackerFocusActive || crewFocusActive;

  /// Filtered + sorted cards of the active section (memoized until the next
  /// filter change); narrowed to favorites while [favoritesOnly] is on.
  List<GameCard> get catalogCards {
    if (!_catalogDirty && _catalogCache != null) return _catalogCache!;
    var cards = queryCards(universe.cardsFor(filter.section), filter);
    if (favoritesOnly) {
      cards = [for (final card in cards) if (isFavoriteCard(card)) card];
    }
    _catalogCache = cards;
    _catalogDirty = false;
    return _catalogCache!;
  }

  GameCard? get selectedCard {
    if (!catalogMode) return null;
    final cards = catalogCards;
    if (cards.isEmpty) return null;
    return cards[selectedIndex.clamp(0, cards.length - 1)];
  }

  void _filtersChanged() {
    _catalogDirty = true;
    selectedIndex = 0;
    notifyListeners();
  }

  void setSection(String value) {
    if (filter.section == value) return;
    filter.section = value;
    // Gallery section switch: reset incompatible filters.
    filter.status = config.defaultStatus;
    filter.raw = 'any';
    filter.pasti = 'any';
    filter.boxscan = 'any';
    filter.tos = 'any';
    filter.crew = 'any';
    filter.cracker = 'any';
    // `cracker` sort is not meaningful for pd — fall back to name.
    if (value == 'pd' && filter.sort == 'cracker') filter.sort = 'name';
    _filtersChanged();
  }

  void setStatus(String value) {
    filter.status = value;
    _filtersChanged();
  }

  void setLetter(String value) {
    filter.letter = value;
    _filtersChanged();
  }

  void setPublisher(String value) {
    filter.publisher = value;
    _filtersChanged();
  }

  void setCrew(String value) {
    filter.crew = value;
    _filtersChanged();
  }

  void setCracker(String value) {
    filter.cracker = value;
    _filtersChanged();
  }

  void setLanguage(String value) {
    filter.language = value;
    _filtersChanged();
  }

  void setYear(String value) {
    filter.year = value;
    _filtersChanged();
  }

  /// Tri-state flags: `raw`, `pasti`, `boxscan` (`any` | `yes` | `no`).
  void setFlag(String field, String value) {
    switch (field) {
      case 'raw':
        filter.raw = value;
      case 'pasti':
        filter.pasti = value;
      case 'boxscan':
        filter.boxscan = value;
      default:
        return;
    }
    _filtersChanged();
  }

  void setTos(String value) {
    filter.tos = value;
    _filtersChanged();
  }

  /// Combined sort dropdown: sort key and direction in one step
  /// (replaces the former `setSort` + `toggleOrder` pair).
  void setSortOrder(String sort, String order) {
    filter.sort = sort;
    filter.order = order;
    _filtersChanged();
  }

  void setQuery(String value) {
    if (filter.q == value) return;
    filter.q = value;
    _filtersChanged();
  }

  /// Gallery `clear`: keep the section, reset everything else.
  void resetFilters() {
    filter.reset();
    favoritesOnly = false;
    _catalogDirty = true;
    selectedIndex = 0;
    notifyListeners();
  }

  // ------------------------------------------------------------ entry lists

  bool get inFavoritesView => currentRel == kFavoritesRel;

  /// Favorites folder visible at root and first (SPEC §11.3 / C24).
  bool get showFavoritesFolder =>
      currentRel.isEmpty && (favorites?.isEmpty ?? true) == false;

  List<Entry> get _baseEntries {
    if (inFavoritesView) return _favoritesEntries();
    final cached = _entryCache[currentRel] ?? browser.list(currentRel);
    _entryCache[currentRel] = cached;
    // Virtual Favorites folder at root, first entry (SPEC §11.3 / C24).
    if (currentRel.isEmpty && showFavoritesFolder) {
      return [virtualFavoritesEntry, ...cached];
    }
    return cached;
  }

  List<Entry> _favoritesEntries() {
    final favs = favorites;
    if (favs == null) return const [];
    final out = <Entry>[];
    for (final path in favs.paths) {
      final rel = _relFromAbsolute(path);
      final inRoot = rel != null &&
          File(p.join(config.rootDirectory, rel)).existsSync();
      final inPatch = rel != null &&
          config.patchDirectory.isNotEmpty &&
          File(p.join(config.patchDirectory, rel)).existsSync();
      final name = p.basenameWithoutExtension(path);
      out.add(Entry(
        name: name,
        kind: EntryKind.zip,
        inRoot: inRoot || !inPatch,
        inPatch: inPatch,
        rootPath: inRoot ? p.join(config.rootDirectory, rel) : null,
        patchPath: inPatch ? p.join(config.patchDirectory, rel) : null,
        isVirtual: false,
      ));
    }
    return out;
  }

  String? _relFromAbsolute(String absPath) {
    final roots = [
      if (config.rootDirectory.isNotEmpty) config.rootDirectory,
      if (config.patchDirectory.isNotEmpty) config.patchDirectory,
    ];
    for (final root in roots) {
      final normRoot = p.normalize(root);
      if (p.isWithin(normRoot, absPath) || p.equals(normRoot, absPath)) {
        return p.relative(absPath, from: normRoot);
      }
    }
    return null;
  }

  /// Rel path used for screenshot/gameinfo joins. Normal navigation is
  /// root-relative by construction; the favorites view derives it from the
  /// stored absolute path.
  String relOf(Entry e) {
    if (inFavoritesView) {
      final eff = e.effectivePath;
      if (eff == null) return '';
      return _relFromAbsolute(eff) ?? '';
    }
    return currentRel.isEmpty ? e.name : '$currentRel/${e.name}';
  }

  /// Visible entries of the current directory (browse mode; catalog mode
  /// uses [catalogCards] instead).
  List<Entry> get visibleEntries => _baseEntries;

  // ----------------------------------------------------------- joins (reads)

  ScreenshotEntry? screenshotFor(Entry e) => screenshots[relOf(e)];

  bool hasPreview(Entry e) {
    final entry = screenshotFor(e);
    return entry != null && entry.preview != null && entry.preview!.isNotEmpty;
  }

  String? previewPathFor(Entry e) => screenshots.previewPathFor(relOf(e));

  List<String> candidatePathsFor(Entry e) =>
      screenshots.candidatePathsFor(relOf(e));

  GameInfo? infoFor(Entry e) => gameinfo.lookupByRel(relOf(e));

  String sectionOf(Entry e) {
    if (inFavoritesView) return '';
    final parts = relOf(e).split('/');
    if (parts.length < 2) return '';
    final tree = parts[1];
    if (tree.startsWith('Cracked')) return 'Cracked';
    if (tree.startsWith('PD')) return 'PD';
    if (tree.startsWith('Util')) return 'Utils';
    return tree;
  }

  static String _titleOf(GameInfo info) {
    if (info.matchedTitle.isNotEmpty) return info.matchedTitle;
    final v = info.variants.isEmpty ? null : info.variants.first;
    return (v?['title'] as String?) ?? info.folder;
  }

  String titleFor(Entry e) {
    final info = infoFor(e);
    if (info != null) return _titleOf(info);
    return e.name;
  }

  // ------------------------------------------------------------------ launch

  /// Absolute path of a catalog card's ZIP variant (patch wins; SPEC.md R14).
  String zipPathForVariant(CardVariant v) {
    final rel = v.rel;
    final patch = config.patchDirectory;
    if (patch.isNotEmpty && (v.layer == 'PATCH' || v.layer == 'BOTH')) {
      final patchPath = p.join(patch, rel);
      if (File(patchPath).existsSync()) return patchPath;
    }
    return p.join(config.rootDirectory, rel);
  }

  /// The ZIP a catalog card should launch: the crew/cracker-focused variant
  /// when a focus filter is active, otherwise the variant whose preview is the
  /// card preview (falling back to the first).
  CardVariant? launchVariantForCard(GameCard card) {
    if (card.variants.isEmpty) return null;
    var idx = (card.focusVariant ?? -1) >= 0 ? card.focusVariant! : -1;
    if (idx < 0 && card.previewPath != null) {
      final match =
          card.variants.indexWhere((v) => v.previewPath == card.previewPath);
      if (match >= 0) idx = match;
    }
    return card.variants[idx < 0 ? 0 : idx];
  }

  /// Launches [zipPath] with Hatari (non-blocking). Sets [launchError] when the
  /// configuration or ZIP is invalid; [launching] while the process runs.
  Future<void> launchZip(String zipPath) async {
    final result = await launchHatari(config, zipPath);
    if (result.error != null) {
      launchError = result.error;
      notifyListeners();
      return;
    }
    launchError = null;
    launching = true;
    notifyListeners();
    final code = await result.process!.exitCode;
    launching = false;
    if (code != 0) launchError = 'Hatari exited with code $code.';
    notifyListeners();
  }

  /// Launches the ZIP of a catalog card's variant [index] (lightbox "Play").
  Future<void> launchCardVariant(GameCard card, int index) async {
    if (index < 0 || index >= card.variants.length) return;
    await launchZip(zipPathForVariant(card.variants[index]));
  }

  /// Launches the current selection: a ZIP in browse mode, the card's ZIP in
  /// catalog mode.
  Future<void> launchSelected() async {
    if (catalogMode) {
      final card = selectedCard;
      if (card == null) return;
      final v = launchVariantForCard(card);
      if (v == null) {
        launchError = 'No ZIP to launch.';
        notifyListeners();
        return;
      }
      await launchZip(zipPathForVariant(v));
      return;
    }
    final e = selectedEntry;
    if (e == null || e.kind != EntryKind.zip) return;
    final path = e.effectivePath;
    if (path == null) return;
    await launchZip(path);
  }

  void clearLaunchError() {
    if (launchError == null) return;
    launchError = null;
    notifyListeners();
  }

  // ------------------------------------------------------------- navigation

  /// Directory children for the tree (dirs only, virtual Favorites at root).
  List<Entry> childrenOf(String rel) {
    final key = 'dir:$rel';
    final cached = _dirCache[key];
    if (cached != null) return cached;
    final dirs = browser
        .list(rel)
        .where((e) => e.kind == EntryKind.directory)
        .toList();
    _dirCache[key] = dirs;
    return dirs;
  }

  Entry get virtualFavoritesEntry => Entry(
        name: 'Favorites',
        kind: EntryKind.directory,
        inRoot: true,
        inPatch: false,
        isVirtual: true,
      );

  Entry? get selectedEntry {
    if (catalogMode) return null;
    final visible = visibleEntries;
    if (visible.isEmpty) return null;
    final idx = selectedIndex.clamp(0, visible.length - 1);
    return visible[idx];
  }

  /// Number of selectable items in the center view (entries or cards).
  int get itemCount => catalogMode ? catalogCards.length : visibleEntries.length;

  /// Count text for the status bar.
  String get countText => catalogMode
      ? '${catalogCards.length} results'
      : '${visibleEntries.length} entries';

  /// Gallery-style status line (`renderStats` + `renderFooter`):
  /// `N / M with screenshot`, status counts, `info X folders`,
  /// `index.json: …`, `gameinfo: …`, `gallery …`.
  List<String> get statusLine {
    final parts = <String>[];
    if (catalogMode && filter.section == 'cracked' && gameinfo.length > 0) {
      parts.add('${universe.crackedWithScreenshot} / ${screenshots.length} '
          'with screenshot');
    } else if (screenshots.length > 0) {
      parts.add('${screenshots.length} index entries');
    }
    if (catalogMode) {
      final sc = screenshots.statusCounts;
      for (final k in const [
        'done',
        'desktop',
        'pending',
        'skipped_disk_n',
        'no_usable_shots',
        'interrupted',
      ]) {
        if ((sc[k] ?? 0) > 0) parts.add('$k ${sc[k]}');
      }
      final matched = gameinfo.matchedFolders;
      if (matched != null) parts.add('info $matched folders');
      if (universe.crackedNoInfo > 0) {
        parts.add('${universe.crackedNoInfo} without info');
      }
    }
    if (screenshots.mtime != null) {
      parts.add('index.json: ${_fmtTime(screenshots.mtime!)}');
    }
    if (gameinfo.generatedAt.isNotEmpty) {
      parts.add('gameinfo: ${gameinfo.generatedAt}');
    }
    if (gameinfo.length == 0) {
      parts.add('gameinfo unavailable — screenshots only');
    }
    return parts;
  }

  static String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  void _saveSelection() {
    final visible = visibleEntries;
    final name = visible.isEmpty
        ? ''
        : visible[selectedIndex.clamp(0, visible.length - 1)].name;
    _lastSelections[inFavoritesView ? kFavoritesRel : currentRel] =
        _SelMemory(selectedIndex, name);
  }

  void _restoreSelection() {
    final mem =
        _lastSelections[inFavoritesView ? kFavoritesRel : currentRel];
    final visible = visibleEntries;
    if (visible.isEmpty) {
      selectedIndex = 0;
      return;
    }
    if (mem != null) {
      final byName =
          visible.indexWhere((e) => e.name == mem.name && mem.name.isNotEmpty);
      selectedIndex = byName >= 0 ? byName : mem.index.clamp(0, visible.length - 1);
    } else {
      selectedIndex = 0;
    }
  }

  /// Enter: navigates into directories; returns true when the caller should
  /// open the lightbox (ZIP in browse mode or any card in catalog mode).
  bool activate() {
    if (catalogMode) return catalogCards.isNotEmpty;
    final e = selectedEntry;
    if (e == null) return false;
    if (e.kind == EntryKind.directory) {
      _saveSelection();
      if (e.isVirtual) {
        currentRel = kFavoritesRel;
      } else {
        currentRel = currentRel.isEmpty ? e.name : '$currentRel/${e.name}';
      }
      selectedIndex = 0;
      notifyListeners();
      return false;
    }
    return true; // ZIP → lightbox (launch comes in a later phase)
  }

  /// Backspace: parent directory in browse mode; `clear` (reset filters) in
  /// catalog mode.
  void parent() {
    if (catalogMode) {
      resetFilters();
      return;
    }
    if (currentRel.isEmpty) return; // R17: silent no-op at root
    _saveSelection();
    currentRel = browser.parent(currentRel);
    _restoreSelection();
    notifyListeners();
  }

  /// Direct tree navigation.
  void setPath(String rel) {
    if (rel == currentRel) return;
    _saveSelection();
    currentRel = rel;
    _restoreSelection();
    notifyListeners();
  }

  void moveSelection(int delta) => moveSelectionTo(selectedIndex + delta);

  void moveSelectionTo(int index) {
    final n = itemCount;
    if (n == 0) return;
    final next = index.clamp(0, n - 1);
    if (next != selectedIndex) {
      selectedIndex = next;
      notifyListeners();
    }
  }

  // -------------------------------------------------------------- view mode

  /// Grid (icon) view vs. list view. Auto: grid in catalog mode or when the
  /// current folder contains at least one ZIP.
  bool get gridMode {
    if (catalogMode) return true;
    return visibleEntries.any((e) => e.kind == EntryKind.zip);
  }

  // -------------------------------------------------------------- favorites

  /// Effective favorite key of a catalog card: the launch variant's ZIP path
  /// (patch wins), matching what the console launcher would key.
  String? favoriteKeyOfCard(GameCard card) {
    final v = launchVariantForCard(card);
    return v == null ? null : zipPathForVariant(v);
  }

  /// ZIP path of a card's variant [index] (patch wins); null when the index
  /// is out of range.
  String? zipPathForCardVariant(GameCard card, int index) {
    if (index < 0 || index >= card.variants.length) return null;
    return zipPathForVariant(card.variants[index]);
  }

  bool isFavorite(Entry e) {
    final eff = e.effectivePath;
    if (eff == null) return false;
    return favorites?.contains(eff) ?? false;
  }

  bool isFavoriteCard(GameCard card) {
    final key = favoriteKeyOfCard(card);
    if (key == null) return false;
    return favorites?.contains(key) ?? false;
  }

  /// R26: toggle keyed by the effective path (patch path when present).
  /// Works in both views: on the selected ZIP entry (browse) or on the
  /// selected card's launch ZIP (catalog).
  void toggleFavoriteSelected() {
    String? key;
    if (catalogMode) {
      final card = selectedCard;
      if (card == null) return;
      key = favoriteKeyOfCard(card);
    } else {
      final e = selectedEntry;
      if (e == null || e.kind != EntryKind.zip) return;
      key = e.effectivePath;
    }
    if (key == null) return;
    toggleFavoritePath(key);
  }

  /// Toggles the favorite for an absolute ZIP path and refreshes all views
  /// (grid badges, ★ filter, virtual Favorites folder).
  void toggleFavoritePath(String path) {
    favorites?.toggle(path);
    _entryCache.remove(kFavoritesRel);
    _catalogDirty = true;
    notifyListeners();
  }

  /// "★ Favorites" catalog filter toggle.
  void toggleFavoritesOnly() {
    favoritesOnly = !favoritesOnly;
    _filtersChanged();
  }

  // -------------------------------------------------------------- statusbar

  /// Path shown in the status bar.
  String get displayPath => inFavoritesView
      ? 'Favorites'
      : (currentRel.isEmpty ? '/' : '/$currentRel');
}

class _SelMemory {
  _SelMemory(this.index, this.name);
  final int index;
  final String name;
}
