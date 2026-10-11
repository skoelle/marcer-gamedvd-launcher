// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

import 'favorites_service.dart';

/// Sentinel rel-path for the virtual `Favorites` view (`SPEC.md` §11.3);
/// cannot collide with a real directory name (NUL is invalid in paths).
const String kFavoritesRel = '\u0000favorites';

/// Application state for Surface A: navigation (SPEC §8), favorites (§11),
/// filters and the joins into gameinfo + screenshot index.
///
/// Read-only towards all data roots; only `favorites.txt` is written.
class CatalogController extends ChangeNotifier {
  CatalogController(this.config);

  final DesktopConfig config;

  late final OverlayBrowser browser;
  ScreenshotIndex? screenshots;
  GameInfoIndex? gameinfo;
  FavoritesService? favorites;

  bool ready = false;
  String progress = '';
  final List<String> notices = [];

  // --- navigation state (SPEC §8.1) ---
  String currentRel = '';
  int selectedIndex = 0;
  final Map<String, _SelMemory> _lastSelections = {};

  // --- filters (desktop extension) ---
  String query = '';
  String layerFilter = 'ALL'; // ALL | BOTH | ROOT | PTCH
  String shotsFilter = 'ALL'; // ALL | WITH | WITHOUT
  String publisherFilter = 'ALL';
  String yearFilter = 'ALL';

  final Map<String, List<Entry>> _entryCache = {};
  final Map<String, List<Entry>> _dirCache = {};
  List<String> _publisherOptions = const [];
  List<String> _yearOptions = const [];

  // ---------------------------------------------------------------- loading

  Future<void> init() async {
    progress = 'Loading screenshot index…';
    notifyListeners();
    final outDir = config.outDirectory;
    if (outDir.isNotEmpty) {
      try {
        screenshots = await Isolate.run(() => ScreenshotIndex.load(outDir));
        final err = screenshots?.loadError;
        if (err != null) notices.add('Screenshots: $err');
      } catch (e) {
        notices.add('Screenshots: $e');
      }
    } else {
      notices.add('Screenshots: OutDirectory not configured');
    }

    progress = 'Loading game metadata…';
    notifyListeners();
    final dataDir = config.resolveDataDirectory();
    if (dataDir.isNotEmpty) {
      try {
        gameinfo = await Isolate.run(() => GameInfoIndex.load(dataDir));
        if (gameinfo!.length == 0) {
          notices.add('Game metadata: no games found in $dataDir');
        }
      } catch (e) {
        notices.add('Game metadata: $e');
      }
    } else {
      notices.add('Game metadata: DataDirectory not configured');
    }

    if (!Directory(config.rootDirectory).existsSync()) {
      notices.add('RootDirectory missing: ${config.rootDirectory}');
    }

    final favDir = config.patchDirectory.isNotEmpty
        ? config.patchDirectory
        : Directory.current.path;
    favorites = FavoritesService.load(p.join(favDir, 'favorites.txt'));

    browser = OverlayBrowser(
      rootDir: config.rootDirectory,
      patchDir: config.patchDirectory.isEmpty ? null : config.patchDirectory,
    );
    ready = true;
    progress = '';
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

  /// Visible entries after filters; also refreshes facet options.
  List<Entry> get visibleEntries {
    final base = _baseEntries;
    _refreshFacets(base);
    return base.where((e) => _passes(e)).toList();
  }

  bool _passes(Entry e) {
    // Layer filter
    if (layerFilter != 'ALL') {
      final label = e.isVirtual ? 'ROOT' : e.layerStatus.name.toUpperCase();
      if (label != layerFilter) return false;
    }
    // Search query (entry name + gameinfo title/publisher)
    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      final info = e.kind == EntryKind.zip ? infoFor(e) : null;
      final title = info != null ? _titleOf(info).toLowerCase() : '';
      final pub = info != null ? _publisherOf(info).toLowerCase() : '';
      if (!e.name.toLowerCase().contains(q) &&
          !title.contains(q) &&
          !pub.contains(q)) {
        return false;
      }
    }
    if (e.kind == EntryKind.zip) {
      if (shotsFilter == 'WITH' && !hasPreview(e)) return false;
      if (shotsFilter == 'WITHOUT' && hasPreview(e)) return false;
      final info = infoFor(e);
      if (publisherFilter != 'ALL') {
        if (info == null || _publisherOf(info) != publisherFilter) return false;
      }
      if (yearFilter != 'ALL') {
        if (info == null || _yearOf(info) != yearFilter) return false;
      }
    }
    return true;
  }

  void _refreshFacets(List<Entry> base) {
    final pubs = <String>{};
    final years = <String>{};
    for (final e in base) {
      if (e.kind != EntryKind.zip) continue;
      final info = infoFor(e);
      if (info == null) continue;
      final pub = _publisherOf(info);
      if (pub.isNotEmpty) pubs.add(pub);
      final year = _yearOf(info);
      if (year != 'unknown') years.add(year);
    }
    final pubList = pubs.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final yearList = years.toList()..sort();
    _publisherOptions = pubList;
    _yearOptions = yearList;
    if (publisherFilter != 'ALL' && !pubList.contains(publisherFilter)) {
      publisherFilter = 'ALL';
    }
    if (yearFilter != 'ALL' && !yearList.contains(yearFilter)) {
      yearFilter = 'ALL';
    }
  }

  List<String> get publisherOptions => _publisherOptions;
  List<String> get yearOptions => _yearOptions;

  // ----------------------------------------------------------- joins (reads)

  ScreenshotEntry? screenshotFor(Entry e) => screenshots?[relOf(e)];

  bool hasPreview(Entry e) {
    final entry = screenshotFor(e);
    return entry != null && entry.preview != null && entry.preview!.isNotEmpty;
  }

  String? previewPathFor(Entry e) => screenshots?.previewPathFor(relOf(e));

  List<String> candidatePathsFor(Entry e) =>
      screenshots?.candidatePathsFor(relOf(e)) ?? const [];

  GameInfo? infoFor(Entry e) => gameinfo?.lookupByRel(relOf(e));

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

  static String _publisherOf(GameInfo info) {
    for (final v in info.variants) {
      final pub = (v['publisher'] ?? v['company']) as String?;
      if (pub != null && pub.isNotEmpty) return pub;
    }
    return '';
  }

  static String _yearOf(GameInfo info) {
    for (final v in info.variants) {
      final rel = (v['release'] ?? '') as String;
      final m = RegExp(r'\d{4}').firstMatch(rel);
      if (m != null) return m.group(0)!;
    }
    return 'unknown';
  }

  String titleFor(Entry e) {
    final info = infoFor(e);
    if (info != null) return _titleOf(info);
    return e.name;
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
    final visible = visibleEntries;
    if (visible.isEmpty) return null;
    final idx = selectedIndex.clamp(0, visible.length - 1);
    return visible[idx];
  }

  int get entryCount => visibleEntries.length;

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

  void activate() {
    final e = selectedEntry;
    if (e == null) return;
    if (e.kind == EntryKind.directory) {
      _saveSelection();
      if (e.isVirtual) {
        currentRel = kFavoritesRel;
      } else {
        currentRel = currentRel.isEmpty ? e.name : '$currentRel/${e.name}';
      }
      selectedIndex = 0;
      notifyListeners();
    }
    // ZIP activation (launch) is Phase 5 — intentionally a no-op for now.
  }

  void parent() {
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

  void moveSelection(int delta) {
    final visible = visibleEntries;
    if (visible.isEmpty) return;
    final next = (selectedIndex + delta).clamp(0, visible.length - 1);
    if (next != selectedIndex) {
      selectedIndex = next;
      notifyListeners();
    }
  }

  void moveSelectionTo(int index) {
    final visible = visibleEntries;
    if (visible.isEmpty) return;
    final next = index.clamp(0, visible.length - 1);
    if (next != selectedIndex) {
      selectedIndex = next;
      notifyListeners();
    }
  }

  // -------------------------------------------------------------- favorites

  bool isFavorite(Entry e) {
    final eff = e.effectivePath;
    if (eff == null) return false;
    return favorites?.contains(eff) ?? false;
  }

  /// R26: toggle keyed by the effective path (patch path when present).
  void toggleFavoriteSelected() {
    final e = selectedEntry;
    if (e == null || e.kind != EntryKind.zip) return;
    final eff = e.effectivePath;
    if (eff == null) return;
    favorites?.toggle(eff);
    _entryCache.remove(kFavoritesRel);
    notifyListeners();
  }

  // ----------------------------------------------------------------- filters

  void setQuery(String value) {
    query = value;
    selectedIndex = 0;
    notifyListeners();
  }

  void setLayerFilter(String value) {
    layerFilter = value;
    selectedIndex = 0;
    notifyListeners();
  }

  void setShotsFilter(String value) {
    shotsFilter = value;
    selectedIndex = 0;
    notifyListeners();
  }

  void setPublisherFilter(String value) {
    publisherFilter = value;
    selectedIndex = 0;
    notifyListeners();
  }

  void setYearFilter(String value) {
    yearFilter = value;
    selectedIndex = 0;
    notifyListeners();
  }

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
