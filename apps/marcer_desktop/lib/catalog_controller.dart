// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

import 'cosmos_ex.dart';
import 'falcon_launcher.dart';
import 'favorites_paths.dart';
import 'favorites_service.dart';
import 'ftp_downloader.dart';
import 'hatari_launcher.dart';
import 'index_editor.dart';
import 'local_assets.dart';
import 'piratefinder_data.dart';
import 'piratefinder_zip.dart';
import 'st_gemdos_launcher.dart';

/// Sentinel rel-path prefix for the per-section virtual `Favorites` views.
/// NUL cannot collide with a real directory name.
const String kFavoritesRelPrefix = '\u0000favorites:';

/// Sentinel rel-path of the virtual `Favorites` view of [section].
String favoritesRelFor(String section) => '$kFavoritesRelPrefix$section';

/// Top-level view of the app: the global gallery-like catalog grid (default)
/// or the optional overlay folder browser.
enum AppView { catalog, folders }

/// Application state for Surface A: navigation (SPEC §8), favorites (§11),
/// the gallery-style global filters (catalog mode) and the joins into
/// gameinfo + screenshot index.
///
/// Read-only towards all data roots except `favorites.txt`; manual status/
/// kind curation (`C` + Save) additionally writes `index.json` and the
/// mirror meta under the screenshot-gen lock (see `index_editor.dart`).
class CatalogController extends ChangeNotifier {
  CatalogController(this.config) {
    // gallery `default_status` config: the factory state of the filter.
    filter.factoryStatus = config.defaultStatus;
    filter.status = config.defaultStatus;
  }

  DesktopConfig config;

  /// Replaces the config in place without rebuilding the catalog. Intended for
  /// changes that do **not** affect the catalog data (e.g. updating
  /// `Hatari.Executable` after installing Hatari); data-root changes must go
  /// through a fresh controller (see `HomePage._applyConfig`).
  void replaceConfig(DesktopConfig cfg) {
    config = cfg;
    _cardFolderLayersCache.clear();
  }

  late final OverlayBrowser browser;
  late ScreenshotIndices screenshots;
  late GameInfoIndex gameinfo;
  AtariLegendIndex atariLegend = AtariLegendIndex.empty();

  /// Optional PirateFinder-Catalog data controller (set by the home page);
  /// drives the title-only detail-button match below.
  PirateFinderDataController? _pirateFinderData;

  PirateFinderDataController? get pirateFinderData => _pirateFinderData;

  set pirateFinderData(PirateFinderDataController? value) {
    if (identical(_pirateFinderData, value)) return;
    _pirateFinderData?.removeListener(_onPirateFinderDataChanged);
    _pirateFinderData = value;
    _pirateFinderTitleMatches.clear();
    _lastPirateFinderVersion = value?.local?.sha256;
    _lastPirateFinderIndexReady = value?.hasIndex ?? false;
    value?.addListener(_onPirateFinderDataChanged);
  }

  final Map<String, PirateFinderMatch?> _pirateFinderTitleMatches = {};
  String? _lastPirateFinderVersion;
  bool _lastPirateFinderIndexReady = false;

  void _onPirateFinderDataChanged() {
    final version = _pirateFinderData?.local?.sha256;
    final indexReady = _pirateFinderData?.hasIndex ?? false;
    if (version == _lastPirateFinderVersion &&
        indexReady == _lastPirateFinderIndexReady) {
      return;
    }
    _lastPirateFinderVersion = version;
    _lastPirateFinderIndexReady = indexReady;
    _pirateFinderTitleMatches.clear();
    if (!_disposed) notifyListeners();
  }

  late CatalogUniverse universe;
  late CrewIndex crews;
  late CrewImageIndex crewImages;
  FavoritesService? favorites;

  /// Section → tree directory rel path (e.g.
  /// `Title Sorted/Cracked Games - Title Sorted`), discovered from the
  /// overlay root (see `discoverSectionTrees`).
  late Map<String, String> sectionTrees;

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

  List<GameCard>? _crewCardsBase;
  Map<String, ({GameCard card, int index})>? _releaseLookupCache;

  /// Catalog-only "★ Favorites" filter (not part of [CatalogFilter]).
  bool favoritesOnly = false;

  final Map<String, List<Entry>> _entryCache = {};
  final Map<String, List<Entry>> _dirCache = {};

  // ---------------------------------------------------------------- loading

  Future<void> init() async {
    initError = null;
    progress = 'Loading catalog…';
    _localAssetsCache.clear();
    _cardFolderLayersCache.clear();
    _pirateFinderTitleMatches.clear();
    _indexTreeCache.clear();
    _releaseLookupCache = null;
    _crewCardsBase = null;
    notifyListeners();
    try {
      // Capture a plain config value (not `this`) so the loader stays
      // independent of the controller's listeners. The bundle is loaded in a
      // background isolate that streams coarse phase messages (sources +
      // catalog build) back for the loading screen.
      final cfg = config;
      final bundle = await CatalogBundle.load(
        screenshotDir: cfg.screenshotDirectory,
        gameinfoDir: cfg.resolveGameinfoDirectory(),
        atariLegendDir: cfg.resolveAtariLegendDirectory(),
        onProgress: (message) {
          progress = message;
          notifyListeners();
        },
      );
      notices.addAll(bundle.warnings);
      screenshots = bundle.index;
      gameinfo = bundle.info;
      crews = bundle.crews;
      crewImages = bundle.crewImages;
      atariLegend = bundle.atariLegend;
      universe = bundle.universe;
      _statusLineCache.clear();

      if (!Directory(config.rootDirectory).existsSync()) {
        notices.add('RootDirectory missing: ${config.rootDirectory}');
      }

      browser = OverlayBrowser(
        rootDir: config.rootDirectory,
        patchDir: config.patchDirectory.isEmpty ? null : config.patchDirectory,
      );

      // Section trees (`Title Sorted/Cracked…`, `PD…`, `Util…`) — they define
      // where the per-section favorites files live (console layout) and the
      // folder rel of every card (favorite matching, pd/utils ZIP resolution).
      sectionTrees = discoverSectionTrees(browser);

      // SPEC §11.1: one favorites file per section tree (console layout), plus
      // the legacy/unknown-section file resolved patchDir → appDir → CWD so a
      // single `favorites.txt` written by an older build or the console
      // launcher is still honored.
      final patch = config.patchDirectory;
      final appDir = File(Platform.resolvedExecutable).parent.path;
      final cwd = Directory.current.path;
      final favoritesCodec = FavoritesPathCodec(
        rootDirectory: config.rootDirectory,
        patchDirectory: patch,
        sectionTrees: sectionTrees,
      );
      favorites = FavoritesService.load(
        fileForSection: {
          for (final section in kSections)
            if (patch.isEmpty)
              section: p.join(appDir, favoritesSectionFileName(section))
            else if (sectionTrees[section] != null)
              section: p.join(
                patch,
                sectionTrees[section]!,
                kFavoritesFileName,
              ),
          kMiscFavoritesSection: resolveFavoritesPath(
            patchDir: patch.isEmpty ? null : patch,
            appDir: appDir,
            cwd: cwd,
            exists: (path) => File(path).existsSync(),
          ),
        },
        extraFiles: [
          p.join(appDir, kFavoritesFileName),
          p.join(cwd, kFavoritesFileName),
        ],
        sectionOfPath: _sectionOfFavoritePath,
        decodePath: favoritesCodec.decode,
        encodePath: favoritesCodec.encode,
      );
      favorites!.migrateMisplacedFavorites((path) {
        final section = _sectionOfFavoritePath(path);
        return section == kMiscFavoritesSection ? null : section;
      });

      ready = true;
      progress = '';
    } catch (e) {
      // Never leave the app stuck on the loading screen: surface the failure
      // with a retry option instead.
      initError = '$e';
      progress = '';
    }
    notifyListeners();
  }

  /// Human-readable message when the last [init] failed, else `null`. While it
  /// is set the UI shows an error/retry screen instead of the catalog.
  String? initError;

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

  /// True when AtariLegend data is loaded; the Genre/Developers filter
  /// dropdowns are only shown then (otherwise they would offer just `any`).
  bool get hasAtariLegend => atariLegend.length > 0;

  Future<AtariLegendTexts>? _atariLegendTextsFuture;

  /// Lazily loads the reviews/comments/magazines cache the first time the
  /// AtariLegend details text tabs are opened (kept for the session).
  Future<AtariLegendTexts> atariLegendTexts() => _atariLegendTextsFuture ??=
      Future(() => AtariLegendTexts.load(config.resolveAtariLegendDirectory()));

  bool get crewFocusActive =>
      !favoritesOnly &&
      filter.crew != 'any' &&
      kindFilters(filter.section).contains('crew');
  bool get crackerFocusActive =>
      !favoritesOnly &&
      filter.cracker != 'any' &&
      kindFilters(filter.section).contains('cracker');

  /// True while a crew/cracker focus filter is active (gallery
  /// `focusActive`); drives the grid miss/2×2 bodies and lightbox labels.
  bool get focusActive => crackerFocusActive || crewFocusActive;

  String? get _preferredPreviewStatus {
    if (favoritesOnly || focusActive) return null;
    return switch (filter.status) {
      'desktop' || 'desktop_any' => 'desktop',
      'desktop_text' || 'desktop_black' => 'desktop',
      'no_usable_shots' || 'no_usable_shots_any' => 'no_usable_shots',
      'pending' || 'interrupted' || 'skipped_disk_n' => filter.status,
      _ => null,
    };
  }

  String? get _preferredPreviewKind => switch (filter.status) {
    'desktop_text' => 'textscreen',
    'desktop_black' => 'darkscreen',
    _ => null,
  };

  /// True when a concrete status filter should drive the card preview (and
  /// the 2×2 thumb order) instead of the done-first default.
  bool get statusPreviewActive =>
      !favoritesOnly && !focusActive && _preferredPreviewStatus != null;

  /// Variant whose preview should be shown on [card] for the active status
  /// filter. The card's canonical done/desktop preview is the fallback.
  CardVariant? displayVariantForCard(GameCard card) => card.previewVariantFor(
    status: statusPreviewActive ? _preferredPreviewStatus : null,
    kind: statusPreviewActive ? _preferredPreviewKind : null,
  );

  String? displayPreviewPathForCard(GameCard card) {
    final variant = displayVariantForCard(card);
    // Synthetic crew cards have no CardVariant list but do carry a chosen
    // preview path.
    return variant?.previewPath ?? card.previewPath;
  }

  List<int> displayThumbIndices(GameCard card, {int limit = 4}) =>
      card.thumbIndices(
        limit: limit,
        preferredStatus: statusPreviewActive ? _preferredPreviewStatus : null,
        preferredKind: statusPreviewActive ? _preferredPreviewKind : null,
      );

  /// Filtered + sorted cards of the active section (memoized until the next
  /// filter change); the ★ [favoritesOnly] filter lists favorites of the
  /// **active section** — status/facets/flags are ignored then, the text
  /// search and the sort stay active.
  List<GameCard> get catalogCards {
    if (!_catalogDirty && _catalogCache != null) return _catalogCache!;
    if (filter.section == 'crew') {
      final q = filter.q.trim().toLowerCase();
      final base = _crewCards;
      _catalogCache = q.isEmpty
          ? base
          : base.where((card) => card.searchText.contains(q)).toList();
      _catalogDirty = false;
      return _catalogCache!;
    }
    final List<GameCard> cards;
    if (favoritesOnly) {
      final favCards = [
        for (final card in universe.cardsFor(filter.section))
          if (isFavoriteCard(card)) card,
      ];
      final f = filter.copy()
        ..status = 'any'
        ..letter = 'any'
        ..publisher = 'any'
        ..genre = 'any'
        ..developer = 'any'
        ..crew = 'any'
        ..cracker = 'any'
        ..language = 'any'
        ..year = 'any'
        ..raw = 'any'
        ..pasti = 'any'
        ..boxscan = 'any'
        ..tos = 'any';
      cards = queryCards(favCards, f);
    } else {
      cards = queryCards(universe.cardsFor(filter.section), filter);
    }
    _catalogCache = cards;
    _catalogDirty = false;
    return _catalogCache!;
  }

  // ------------------------------------------------------------ crew view

  /// Release ZIP lookup (`rel` -> cracked card + variant index), built once
  /// from the cracked universe. Used for crew card previews and for opening a
  /// crew release in the existing game lightbox.
  Map<String, ({GameCard card, int index})> get _releaseLookup {
    final cached = _releaseLookupCache;
    if (cached != null) return cached;
    final out = <String, ({GameCard card, int index})>{};
    for (final card in universe.cardsFor('cracked')) {
      for (var i = 0; i < card.variants.length; i++) {
        out[card.variants[i].rel] = (card: card, index: i);
      }
    }
    return _releaseLookupCache = out;
  }

  /// Cracked card + variant index for a crew release rel path. Accepts both
  /// the full index rel and the legacy section-relative form written by older
  /// `crews.json` artifacts (prefixes the discovered cracked tree).
  ({GameCard card, int index})? releaseCardFor(String rel) {
    final direct = _releaseLookup[rel];
    if (direct != null) return direct;
    final tree = sectionTrees['cracked'];
    if (tree != null && !rel.startsWith('$tree/')) {
      return _releaseLookup['$tree/$rel'];
    }
    return null;
  }

  /// Synthetic catalog cards for the Crews tab (top [kCrewInitialLimit] groups
  /// by ZIP count; `crews.json` still contains every group).
  List<GameCard> get _crewCards => _crewCardsBase ??= _buildCrewCards();

  List<GameCard> _buildCrewCards() {
    final cards = <GameCard>[];
    for (final group in crews.top(kCrewInitialLimit)) {
      final preview = _crewPreview(group);
      final searchParts = <String>[group.name, group.kind, ...group.aliases];
      for (final release in group.releases) {
        searchParts
          ..add(release.title)
          ..add(release.folder)
          ..add(release.zip)
          ..add(release.year)
          ..add(release.publisher)
          ..add(release.crackedBy)
          ..add(release.crew);
      }
      cards.add(
        GameCard(
          id: 'crew:${group.id}',
          name: group.name,
          kind: 'crew',
          letter: '',
          folder: group.id,
          displayStatus: '',
          screenshots: preview != null,
          statusCounts: const {},
          layer: '',
          year: 'unknown',
          previewPath: preview,
          variants: const [],
          info: null,
          yearNum: 0,
          publishers: const [],
          crews: const [],
          crackers: const [],
          languages: const [],
          raw: null,
          pasti: null,
          boxscan: null,
          tos: false,
          publisherSort: '',
          crewSort: group.name.toLowerCase(),
          crackerSort: '',
          languageSort: '',
          searchText: searchParts
              .where((part) => part.isNotEmpty)
              .join(' ')
              .toLowerCase(),
          sortName: group.name.toLowerCase(),
          crew: group,
        ),
      );
    }
    return cards;
  }

  /// Best available screenshot of a crew's releases (temporary card image
  /// until the curated cracktro image phase lands).
  String? _crewPreview(CrewGroup group) {
    final curated = crewImages.imageFor(group);
    if (curated != null) {
      final path = _curatedCrewImagePath(curated);
      if (path != null) return path;
    }
    if (group.image != null && group.image!.isNotEmpty) return group.image;
    String? best;
    var bestRank = 99;
    for (final release in group.releases) {
      final hit = releaseCardFor(release.rel);
      if (hit == null) continue;
      final variant = hit.card.variants[hit.index];
      final path = variant.previewPath;
      if (path == null) continue;
      final rank = _previewRank(variant);
      if (rank < bestRank) {
        best = path;
        bestRank = rank;
        if (rank == 0) break;
      }
    }
    return best;
  }

  String? _curatedCrewImagePath(CrewImage image) {
    final base = config.screenshotDirectory.trim();
    if (base.isEmpty) return null;
    final rels = <String>[image.rel];
    final tree = sectionTrees['cracked'];
    if (tree != null && !image.rel.startsWith('$tree/')) {
      rels.add('$tree/${image.rel}');
    }
    for (final rel in rels) {
      final path = p.normalize(p.join(base, p.dirname(rel), image.name));
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static int _previewRank(CardVariant variant) {
    if (variant.status == 'done' && variant.kind == 'game') return 0;
    if (variant.status == 'done') return 1;
    if (variant.status == 'desktop') return 2;
    return 3;
  }

  GameCard? get selectedCard {
    if (!catalogMode) return null;
    final cards = catalogCards;
    if (cards.isEmpty) return null;
    return cards[selectedIndex.clamp(0, cards.length - 1)];
  }

  /// Incremented whenever the filter state changes. The filter bar listens to
  /// this (instead of rebuilding on every controller notification) so that
  /// selection moves and the async layer-scan notifications do not rebuild the
  /// large facet dropdowns.
  int filterRevision = 0;

  void _filtersChanged() {
    _catalogDirty = true;
    selectedIndex = 0;
    filterRevision++;
    notifyListeners();
  }

  void setSection(String value) {
    if (filter.section == value) return;
    filter.section = value;
    if (value == 'crew') favoritesOnly = false;
    // Gallery section switch: reset incompatible filters.
    filter.status = config.defaultStatus;
    filter.raw = 'any';
    filter.pasti = 'any';
    filter.boxscan = 'any';
    filter.tos = 'any';
    filter.genre = 'any';
    filter.developer = 'any';
    filter.crew = 'any';
    filter.cracker = 'any';
    // `cracker` sort is not meaningful for pd/magazine — fall back to name.
    if (filter.sort == 'cracker' && value != 'cracked' && value != 'utils') {
      filter.sort = 'name';
    }
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

  void setGenre(String value) {
    filter.genre = value;
    _filtersChanged();
  }

  void setDeveloper(String value) {
    filter.developer = value;
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
    // Keep the configured status preset for every section.
    filter.status = config.defaultStatus;
    favoritesOnly = false;
    _catalogDirty = true;
    selectedIndex = 0;
    filterRevision++;
    notifyListeners();
  }

  // ------------------------------------------------------------ entry lists

  bool get inFavoritesView => currentRel.startsWith(kFavoritesRelPrefix);

  /// Section of the current virtual Favorites view, or `''`.
  String get favoritesViewSection =>
      inFavoritesView ? currentRel.substring(kFavoritesRelPrefix.length) : '';

  /// Display name of the virtual Favorites folder of [section].
  String favoritesFolderLabel(String section) =>
      'Favorites (${section == 'cracked' ? 'games' : section})';

  /// Rel-path of a virtual Favorites [entry], or null for other entries.
  String? favoritesRelForEntry(Entry entry) {
    if (!entry.isVirtual) return null;
    for (final section in kSections) {
      if (entry.name == favoritesFolderLabel(section)) {
        return favoritesRelFor(section);
      }
    }
    return null;
  }

  /// One virtual Favorites folder per section that currently has favorites.
  List<Entry> get virtualFavoritesEntries => [
    for (final section in kSections)
      if (favorites?.pathsForSection(section).isNotEmpty ?? false)
        Entry(
          name: favoritesFolderLabel(section),
          kind: EntryKind.directory,
          inRoot: true,
          inPatch: false,
          isVirtual: true,
        ),
  ];

  /// Favorites folders visible at root and first (one per section).
  bool get showFavoritesFolder =>
      currentRel.isEmpty && virtualFavoritesEntries.isNotEmpty;

  List<Entry> get _baseEntries {
    if (inFavoritesView) return _favoritesEntries();
    final cached = _entryCache[currentRel] ?? browser.list(currentRel);
    _entryCache[currentRel] = cached;
    if (showFavoritesFolder) {
      return [...virtualFavoritesEntries, ...cached];
    }
    return cached;
  }

  List<Entry> _favoritesEntries() {
    final favs = favorites;
    final section = favoritesViewSection;
    if (favs == null || section.isEmpty) return const [];
    final out = <Entry>[];
    for (final path in favs.pathsForSection(section)) {
      final rel = _relFromAbsolute(path);
      // Foreign line (other OS/other roots, kept in the file for console
      // interop): not reachable here — no entry is built for it.
      if (rel == null) continue;
      final rootAbs = p.join(config.rootDirectory, rel);
      final patchAbs = config.patchDirectory.isEmpty
          ? null
          : p.join(config.patchDirectory, rel);
      final inRoot = File(rootAbs).existsSync();
      final inPatch = patchAbs != null && File(patchAbs).existsSync();
      out.add(
        Entry(
          name: p.basename(path),
          kind: EntryKind.zip,
          inRoot: inRoot,
          inPatch: inPatch,
          // Keep the stored path when the file vanished, so the entry stays
          // selectable and removable (`*`) and launching reports the missing
          // ZIP instead of doing nothing.
          rootPath: inRoot ? rootAbs : (inPatch ? null : path),
          patchPath: inPatch ? patchAbs : null,
          isVirtual: false,
        ),
      );
    }
    return out;
  }

  /// Section key of an absolute favorite path (per-section favorites files):
  /// the section tree of its root-relative location, else
  /// [kMiscFavoritesSection].
  String _sectionOfFavoritePath(String path) {
    final rel = _relFromAbsolute(path);
    if (rel == null) return kMiscFavoritesSection;
    return sectionOfRel(sectionTrees, rel) ?? kMiscFavoritesSection;
  }

  String? _relFromAbsolute(String absPath) {
    final roots = [
      if (config.rootDirectory.isNotEmpty) config.rootDirectory,
      if (config.patchDirectory.isNotEmpty) config.patchDirectory,
    ];
    for (final root in roots) {
      final normRoot = p.normalize(root);
      if (p.isWithin(normRoot, absPath) || p.equals(normRoot, absPath)) {
        return normalizeRelSeparators(p.relative(absPath, from: normRoot));
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

  /// AtariLegend match for a catalog card (matched by folder name, like the
  /// `tools/atarilegend-gen` matcher). `null` when there is no data/match —
  /// and always `null` for magazine cards (their synthetic folders are not
  /// game titles).
  AtariLegendGame? atariLegendForCard(GameCard card) {
    if (card.kind == 'magazine') return null;
    return atariLegend.matchFolder(card.folder);
  }

  /// PirateFinder crew info for a Crews-tab group (matched by name/alias);
  /// `null` when the PF catalogue is not loaded or has no such crew.
  PirateFinderCrew? pirateFinderCrewForGroup(CrewGroup crew) {
    final index = _pirateFinderData?.index;
    if (index == null) return null;
    for (final name in [crew.name, ...crew.aliases]) {
      final match = index.crewByName(name);
      if (match != null) return match;
    }
    return null;
  }

  /// AtariLegend match for a folder-browser entry: the folder is
  /// `<letter>/<folder>` of its rel path (same join as the screenshot index).
  AtariLegendGame? atariLegendForEntry(Entry e) {
    final rel = relOf(e);
    final section = sectionOfRel(sectionTrees, rel);
    if (section == 'magazine') return null;
    final parts = rel.split('/');
    if (parts.length >= 4) return atariLegend.matchFolder(parts[3]);
    return atariLegend.matchFolder(e.name);
  }

  /// Lazily discovered local `Boxscan/`/`Manual/` assets per game folder.
  final LocalAssetsService localAssetsService = LocalAssetsService();
  final Map<String, Future<LocalGameAssets>> _localAssetsCache = {};

  /// Local box-scan/manual assets of [card]'s game folder. Discovered on the
  /// first use (background isolate, paths only) and cached for the controller's
  /// lifetime; the whole tree is never scanned.
  Future<LocalGameAssets> localAssetsForCard(GameCard card) {
    final rel = cardFolderRel(card);
    if (rel == null || rel.isEmpty) {
      return Future.value(LocalGameAssets.empty);
    }
    return _localAssetsCache.putIfAbsent(
      rel,
      () => localAssetsService
          .discover(
            rootDirectory: config.rootDirectory,
            patchDirectory: config.patchDirectory,
            gameRel: rel,
          )
          .catchError((Object _) => LocalGameAssets.empty),
    );
  }

  String sectionOf(Entry e) {
    final rel = relOf(e);
    if (rel.isEmpty) return '';
    // Known section tree (also works for the flat favorites list, which
    // mixes all sections).
    final section = sectionOfRel(sectionTrees, rel);
    if (section != null) {
      return switch (section) {
        'cracked' => 'Cracked',
        'pd' => 'PD',
        'magazine' => 'Magazine',
        'falcon' => 'Falcon',
        _ => 'Utils',
      };
    }
    final parts = rel.split('/');
    if (parts.length < 2) return '';
    return parts[1];
  }

  /// Folder rel path of an entry inside the flat favorites view (e.g.
  /// `Title Sorted/Cracked Games - Title Sorted/A/Alpha`), so the grid tile
  /// keeps the folder context the ZIP was favorites-toggled from. Empty
  /// outside the favorites view.
  String folderRelOf(Entry e) {
    if (!inFavoritesView) return '';
    final rel = relOf(e);
    final idx = rel.lastIndexOf('/');
    return idx <= 0 ? '' : rel.substring(0, idx);
  }

  /// Short form of [folderRelOf] for badges: the last two path segments
  /// (`A/Alpha`), prefixed with `…` when longer.
  static String shortFolder(String folder) {
    final parts = folder.split('/');
    if (parts.length <= 2) return folder;
    return '…/${parts[parts.length - 2]}/${parts.last}';
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

  /// Absolute path of a catalog card's ZIP variant: the patch copy wins when
  /// it exists (SPEC.md R14), otherwise the root copy. Driven by the local
  /// filesystem (not the published index layer), so a ZIP moved between
  /// layers is still launched from wherever it actually lives.
  String zipPathForVariant(CardVariant v) => zipPathForRel(v.rel);

  /// Absolute path of a root-relative ZIP (patch copy wins when it exists).
  String zipPathForRel(String rel) {
    final patch = config.patchDirectory;
    if (patch.isNotEmpty) {
      final patchPath = p.join(patch, rel);
      if (File(patchPath).existsSync()) return patchPath;
    }
    return p.join(config.rootDirectory, rel);
  }

  /// Title-only match for a card (no ZIP I/O). Cached until the PF data or
  /// catalog universe changes. Returns null while the index is still loading.
  PirateFinderMatch? pirateFinderTitleMatchForCard(GameCard card) {
    final index = _pirateFinderData?.index;
    if (index == null) {
      _requestPirateFinderIndex();
      return null;
    }
    final key = 'card:${card.kind}:${card.folder}:${card.name}';
    if (_pirateFinderTitleMatches.containsKey(key)) {
      return _pirateFinderTitleMatches[key];
    }
    final inputs = _pirateFinderCardInputs(card);
    final match = index.matchByTitles(
      inputs.titles,
      labels: inputs.labels,
      years: inputs.years,
      publishers: inputs.publishers,
    );
    _pirateFinderTitleMatches[key] = match;
    return match;
  }

  /// Title-only match for a browse-mode ZIP entry.
  PirateFinderMatch? pirateFinderTitleMatchForEntry(Entry entry) {
    final index = _pirateFinderData?.index;
    if (index == null) {
      _requestPirateFinderIndex();
      return null;
    }
    final key = 'entry:${relOf(entry)}';
    if (_pirateFinderTitleMatches.containsKey(key)) {
      return _pirateFinderTitleMatches[key];
    }
    final inputs = _pirateFinderEntryInputs(entry);
    final match = index.matchByTitles(
      inputs.titles,
      labels: inputs.labels,
      years: inputs.years,
      publishers: inputs.publishers,
    );
    _pirateFinderTitleMatches[key] = match;
    return match;
  }

  void _requestPirateFinderIndex() {
    final data = _pirateFinderData;
    if (data == null || data.hasIndex || data.local == null) return;
    unawaited(data.ensureIndex());
  }

  /// Matches a card against the downloaded PirateFinder catalogue. The
  /// selected ZIP is tried by exact disk-image hashes first; title + gameinfo
  /// crew/cracker/year is the fallback. The UI uses the title-only methods
  /// above, so the detail button only appears for a confirmed title match.
  Future<PirateFinderMatch?> pirateFinderMatchForCard(
    GameCard card, {
    String? rel,
  }) {
    final inputs = _pirateFinderCardInputs(card);
    return _pirateFinderMatch(
      titles: inputs.titles,
      rel: rel,
      labels: inputs.labels,
      years: inputs.years,
      publishers: inputs.publishers,
    );
  }

  /// Same as [pirateFinderMatchForCard] for a browse-mode ZIP entry.
  Future<PirateFinderMatch?> pirateFinderMatchForEntry(
    Entry entry, {
    String? rel,
  }) {
    final inputs = _pirateFinderEntryInputs(entry);
    return _pirateFinderMatch(
      titles: inputs.titles,
      rel: rel ?? relOf(entry),
      labels: inputs.labels,
      years: inputs.years,
      publishers: inputs.publishers,
    );
  }

  ({
    List<String> titles,
    Set<String> labels,
    Set<int> years,
    Set<String> publishers,
  })
  _pirateFinderCardInputs(GameCard card) {
    final labels = <String>{};
    final years = <int>{};
    final publishers = <String>{};
    for (final value in [...card.crews, ...card.crackers]) {
      final label = PirateFinderIndex.normalizeLabel(value);
      if (label.isNotEmpty) labels.add(label);
    }
    for (final variant in card.info?.variants ?? const []) {
      for (final field in const ['crew', 'cracked_by']) {
        final label = PirateFinderIndex.normalizeLabel(
          (variant[field] ?? '').toString(),
        );
        if (label.isNotEmpty && label != 'original') labels.add(label);
      }
      final year = int.tryParse(
        RegExp(r'(19|20)\d{2}')
                .firstMatch((variant['release'] ?? '').toString())
                ?.group(0) ??
            '',
      );
      if (year != null) years.add(year);
      final publisher = PirateFinderIndex.normalizeLabel(
        (variant['publisher'] ?? '').toString(),
      );
      if (publisher.isNotEmpty) publishers.add(publisher);
    }
    if (card.yearNum > 0) years.add(card.yearNum);
    for (final publisher in card.publishers) {
      final value = PirateFinderIndex.normalizeLabel(publisher);
      if (value.isNotEmpty) publishers.add(value);
    }
    return (
      titles: [card.folder, card.name, card.info?.title ?? ''],
      labels: labels,
      years: years,
      publishers: publishers,
    );
  }

  ({
    List<String> titles,
    Set<String> labels,
    Set<int> years,
    Set<String> publishers,
  })
  _pirateFinderEntryInputs(Entry entry) {
    final info = infoFor(entry);
    final labels = <String>{};
    final years = <int>{};
    final publishers = <String>{};
    for (final variant in info?.variants ?? const []) {
      for (final field in const ['crew', 'cracked_by']) {
        final label = PirateFinderIndex.normalizeLabel(
          (variant[field] ?? '').toString(),
        );
        if (label.isNotEmpty && label != 'original') labels.add(label);
      }
      final year = int.tryParse(
        RegExp(r'(19|20)\d{2}')
                .firstMatch((variant['release'] ?? '').toString())
                ?.group(0) ??
            '',
      );
      if (year != null) years.add(year);
      final publisher = PirateFinderIndex.normalizeLabel(
        (variant['publisher'] ?? '').toString(),
      );
      if (publisher.isNotEmpty) publishers.add(publisher);
    }
    final name = entry.name;
    final withoutExtension = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    return (
      titles: [withoutExtension, name, info?.matchedTitle ?? ''],
      labels: labels,
      years: years,
      publishers: publishers,
    );
  }

  Future<PirateFinderMatch?> _pirateFinderMatch({
    required List<String> titles,
    String? rel,
    Set<String> labels = const {},
    Set<int> years = const {},
    Set<String> publishers = const {},
  }) async {
    final controller = _pirateFinderData;
    if (controller == null) return null;
    final index = await controller.ensureIndex();
    if (index == null) return null;
    if (rel != null && rel.isNotEmpty) {
      try {
        final hashes = await pirateFinderHashesForZip(zipPathForRel(rel));
        final exact = index.matchByHashes(hashes);
        if (exact != null) return exact;
      } catch (_) {
        // Unreadable/undecodable ZIP: fall through to the title match.
      }
    }
    return index.matchByTitles(
      titles.where((title) => title.trim().isNotEmpty),
      labels: labels,
      years: years,
      publishers: publishers,
    );
  }

  // ------------------------------------------------- missing / layer (sync)

  /// Lazily cached local layer per rel path (`ROOT`/`PATCH`/`BOTH`; empty when
  /// the ZIP exists in neither layer). The catalog is built without any
  /// filesystem scan (`CatalogUniverse`), so an index/gameinfo entry can
  /// reference a ZIP the user has not synced yet; the layer and missing
  /// helpers resolve that on demand from the actual files (app-only
  /// divergence from the published index layer). The cache is per controller;
  /// a settings reload builds a fresh controller (`HomePage._applyConfig`),
  /// so files that appear or vanish while the app runs are reflected after a
  /// reload.
  final Map<String, String> _zipLayerCache = {};

  /// Async local-layer resolution state. Folders are listed in the background
  /// (bounded concurrency) and their ZIP names/layers cached; the grid only
  /// reads [cachedCardLayer]/[cachedCardMissing] and never blocks a frame on
  /// the (possibly network) filesystem. The cache is per controller and not
  /// persisted (a reload rebuilds it).
  final Set<String> _scannedDirs = {};
  final Map<String, List<String>> _scannedFolderZips = {};
  final Set<String> _scanRequested = {};
  final Queue<String> _scanQueue = Queue<String>();
  int _scanWorkers = 0;
  static const int _maxScanWorkers = 6;
  bool _scanNotifyScheduled = false;
  bool _disposed = false;

  /// Normalizes a rel path to the '/'-separated index form (cache keys).
  static String _relKey(String rel) => rel.replaceAll('\\', '/');

  /// Directory part of a '/'-separated rel path ('' at the top level).
  static String _dirOfRel(String rel) {
    final norm = _relKey(rel);
    final i = norm.lastIndexOf('/');
    return i == -1 ? '' : norm.substring(0, i);
  }

  /// Cached local layer of [rel], or `null` while its folder has not been
  /// scanned yet. Pure map lookup — safe to call from a tile builder.
  String? cachedZipLayer(String rel) {
    if (rel.isEmpty) return '';
    final key = _relKey(rel);
    if (!_scannedDirs.contains(_dirOfRel(key))) return null;
    return _zipLayerCache[key] ?? '';
  }

  /// Local overlay layer of the ZIP at [rel]: `BOTH` when present in root and
  /// patch, `ROOT`/`PATCH` when present in only one, `''` when absent. Both
  /// layers are checked regardless of the published layer field.
  String zipLayer(String rel) {
    if (rel.isEmpty) return '';
    final key = _relKey(rel);
    return _zipLayerCache.putIfAbsent(key, () {
      final inRoot = File(p.join(config.rootDirectory, rel)).existsSync();
      final patch = config.patchDirectory;
      final inPatch = patch.isNotEmpty && File(p.join(patch, rel)).existsSync();
      if (inRoot && inPatch) return 'BOTH';
      if (inPatch) return 'PATCH';
      if (inRoot) return 'ROOT';
      return '';
    });
  }

  /// True when the ZIP at overlay rel [rel] exists in either layer.
  bool zipExists(String rel) => zipLayer(rel).isNotEmpty;

  /// Local layer of a card's ZIP variant (`ROOT`/`PATCH`/`BOTH`, `''` missing).
  String variantLayer(CardVariant v) => zipLayer(v.rel);

  /// True when a card's ZIP variant is not present locally (neither layer).
  bool variantMissing(CardVariant v) => zipLayer(v.rel).isEmpty;

  /// Aggregate local layer of [card]'s ZIP variants: the shared layer when all
  /// present variants agree, `BOTH` when they are split across layers, and `''`
  /// when no variant exists locally (the card then shows `MISSING`).
  String cardLayer(GameCard card) {
    final layers = <String>{};
    for (final v in variantsOfCard(card)) {
      final l = zipLayer(v.rel);
      if (l.isNotEmpty) layers.add(l);
    }
    if (layers.isEmpty) return '';
    return layers.length == 1 ? layers.first : 'BOTH';
  }

  /// True when none of [card]'s ZIP variants exists locally. Cards without a
  /// resolvable ZIP (e.g. a gameinfo-only pd/utils folder missing on disk)
  /// count as missing too.
  bool cardMissing(GameCard card) {
    final variants = variantsOfCard(card);
    if (variants.isEmpty) return true;
    return variants.every(variantMissing);
  }

  static String _aggregateLayers(Set<String> layers) {
    if (layers.isEmpty) return '';
    return layers.length == 1 ? layers.first : 'BOTH';
  }

  /// Cache-only variant of [cardLayer]: returns `null` while the card's
  /// folder(s) have not been scanned yet (the grid shows no badge then and a
  /// background scan is requested via [ensureCardScanned]). Never touches the
  /// filesystem, so it is safe to call from a tile builder.
  String? cachedCardLayer(GameCard card) {
    if (card.variants.isNotEmpty) {
      final layers = <String>{};
      for (final v in card.variants) {
        final l = cachedZipLayer(v.rel);
        if (l == null) return null;
        if (l.isNotEmpty) layers.add(l);
      }
      return _aggregateLayers(layers);
    }
    final dir = cardFolderRel(card);
    if (dir == null) return '';
    final key = _relKey(dir);
    if (!_scannedDirs.contains(key)) return null;
    final layers = <String>{};
    for (final rel in _scannedFolderZips[key] ?? const <String>[]) {
      final l = _zipLayerCache[rel] ?? '';
      if (l.isNotEmpty) layers.add(l);
    }
    return _aggregateLayers(layers);
  }

  /// Cache-only variant of [cardMissing]: `null` while unknown. Metadata-only
  /// cards (no index variants) need their folder listing, which the background
  /// scan provides.
  bool? cachedCardMissing(GameCard card) {
    if (card.variants.isNotEmpty) {
      var allMissing = true;
      for (final v in card.variants) {
        final l = cachedZipLayer(v.rel);
        if (l == null) return null;
        if (l.isNotEmpty) allMissing = false;
      }
      return allMissing;
    }
    final dir = cardFolderRel(card);
    if (dir == null) return true;
    final key = _relKey(dir);
    if (!_scannedDirs.contains(key)) return null;
    final zips = _scannedFolderZips[key] ?? const <String>[];
    if (zips.isEmpty) return true;
    return zips.every((rel) => (_zipLayerCache[rel] ?? '').isEmpty);
  }

  /// Requests a background listing for the folder(s) of [card]. The result is
  /// cached and a throttled [notifyListeners] refreshes the visible tiles.
  void ensureCardScanned(GameCard card) {
    if (_disposed) return;
    if (card.variants.isNotEmpty) {
      for (final v in card.variants) {
        _enqueueScan(_dirOfRel(v.rel));
      }
    }
    final dir = cardFolderRel(card);
    if (dir != null) _enqueueScan(dir);
  }

  void _enqueueScan(String dir) {
    if (_disposed) return;
    final key = _relKey(dir);
    if (key.isEmpty || key == '.' || key.contains('..')) return;
    if (_scannedDirs.contains(key) || _scanRequested.contains(key)) return;
    _scanRequested.add(key);
    _scanQueue.add(key);
    _pumpScan();
  }

  void _pumpScan() {
    while (!_disposed &&
        _scanWorkers < _maxScanWorkers &&
        _scanQueue.isNotEmpty) {
      final dir = _scanQueue.removeFirst();
      _scanWorkers++;
      _scanDir(dir).whenComplete(() {
        _scanWorkers--;
        _scanRequested.remove(dir);
        _scheduleScanNotify();
        if (!_disposed && _scanQueue.isNotEmpty) _pumpScan();
      });
    }
  }

  Future<void> _scanDir(String dir) async {
    final rootNames = await _listZipNames(p.join(config.rootDirectory, dir));
    final patch = config.patchDirectory;
    final patchNames = patch.isEmpty
        ? const <String>{}
        : await _listZipNames(p.join(patch, dir));
    final rels = <String>[];
    for (final name in {...rootNames, ...patchNames}) {
      final rel = dir.isEmpty ? name : '$dir/$name';
      final inRoot = rootNames.contains(name);
      final inPatch = patchNames.contains(name);
      _zipLayerCache[rel] = (inRoot && inPatch)
          ? 'BOTH'
          : (inPatch ? 'PATCH' : 'ROOT');
      rels.add(rel);
    }
    rels.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    _scannedFolderZips[dir] = List<String>.unmodifiable(rels);
    _scannedDirs.add(dir);
  }

  Future<Set<String>> _listZipNames(String dirPath) async {
    final out = <String>{};
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return out;
      await for (final e in dir.list(followLinks: false)) {
        final name = p.basename(e.path);
        if (name.isEmpty || name.startsWith('.') || name == '@eaDir') continue;
        if (e is File && name.toLowerCase().endsWith('.zip')) out.add(name);
      }
    } catch (_) {
      // Unreadable/missing folder — treated as empty (the card then shows
      // MISSING once the scan is recorded).
    }
    return out;
  }

  void _scheduleScanNotify() {
    if (_disposed || _scanNotifyScheduled) return;
    _scanNotifyScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 120), () {
      _scanNotifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pirateFinderData?.removeListener(_onPirateFinderDataChanged);
    _scanQueue.clear();
    super.dispose();
  }

  /// The ZIP a catalog card should launch: the crew/cracker-focused variant
  /// when a focus filter is active, otherwise the variant whose preview is the
  /// card preview (falling back to the first).
  CardVariant? launchVariantForCard(GameCard card) {
    final variants = variantsOfCard(card);
    if (variants.isEmpty) return null;
    var idx = (card.focusVariant ?? -1) >= 0 ? card.focusVariant! : -1;
    if (idx < 0 && card.previewPath != null) {
      final match = variants.indexWhere(
        (v) => v.previewPath == card.previewPath,
      );
      if (match >= 0) idx = match;
    }
    return variants[idx < 0 ? 0 : idx];
  }

  /// Folder rel path of [card] (`<tree>/<letter>/<folder>`). Resolved from the
  /// card's index rels first, so a first ZIP nested in a subfolder
  /// (`Original/`, `STX/`, …) can never shorten the folder to that subfolder
  /// (bug 2026-10-25: Download folder fetched only `…/Original` when the
  /// section tree was not discovered, e.g. on an empty RootDirectory).
  String? cardFolderRel(GameCard card) {
    final firstRel = card.variants.isEmpty
        ? null
        : normalizeRelSeparators(card.variants.first.rel);
    final kind = card.kind;

    if (kind == 'magazine' && firstRel != null) {
      // Magazine cards group several ZIPs of one issue below
      // `<tree>/<magazine>/<issue>`; the card's `<letter>/<folder>` is not a
      // real directory path. A ZIP directly in the magazine folder sits at
      // index 3, a nested one in the issue directory below it.
      final parts = firstRel.split('/');
      final depth = parts.length >= 5 ? 4 : 3;
      if (parts.length > depth) return parts.take(depth).join('/');
    }

    // Locate the `<letter>/<folder>` pair inside an index rel: the index path
    // keeps the section tree spelling and stays valid even when no tree could
    // be discovered on disk. The pair starts below the two tree segments, so
    // an earlier look-alike cannot win.
    if (firstRel != null && card.letter.isNotEmpty && card.folder.isNotEmpty) {
      final parts = firstRel.split('/');
      final letter = card.letter.toLowerCase();
      final folder = card.folder.toLowerCase();
      for (var i = 2; i + 1 < parts.length; i++) {
        if (parts[i].toLowerCase() == letter &&
            parts[i + 1].toLowerCase() == folder) {
          return parts.take(i + 2).join('/');
        }
      }
    }

    final tree = sectionTrees[kind] ?? _indexTreeFor(kind);
    if (tree != null && card.letter.isNotEmpty && card.folder.isNotEmpty) {
      return '$tree/${card.letter}/${card.folder}';
    }
    if (firstRel != null) return p.posix.dirname(firstRel);
    return null;
  }

  final Map<String, String?> _indexTreeCache = {};

  /// Section tree prefix (`<dir>/<dir>`) taken from the index rels of [kind],
  /// used when [sectionTrees] has no entry (e.g. the RootDirectory is still
  /// empty while the published index is browsed). Cached per section.
  String? _indexTreeFor(String kind) {
    if (_indexTreeCache.containsKey(kind)) return _indexTreeCache[kind];
    String? tree;
    for (final card in universe.cardsFor(kind)) {
      if (card.variants.isEmpty) continue;
      final parts = normalizeRelSeparators(card.variants.first.rel).split('/');
      if (parts.length >= 4) {
        tree = parts.take(2).join('/');
        break;
      }
    }
    return _indexTreeCache[kind] = tree;
  }

  /// Absolute path of [card]'s game folder in the ROOT (default) or PATCH
  /// layer. No existence check: callers validate before opening.
  String? cardFolderPath(GameCard card, {bool patch = false}) {
    final rel = cardFolderRel(card);
    if (rel == null || rel.isEmpty) return null;
    final base = patch ? config.patchDirectory : config.rootDirectory;
    if (base.trim().isEmpty) return null;
    return p.normalize(p.join(base, normalizeRelSeparators(rel)));
  }

  static final Future<Set<String>> _emptyFolderLayers = Future.value(
    const <String>{},
  );

  final Map<String, Future<Set<String>>> _cardFolderLayersCache = {};

  /// Layers (`ROOT`/`PATCH`) in which [card]'s game folder actually exists.
  /// Cached per folder; cleared on init, config replacement and downloads.
  Future<Set<String>> cardFolderLayers(GameCard card) {
    final rel = cardFolderRel(card);
    if (rel == null || rel.isEmpty) {
      return _emptyFolderLayers;
    }
    return _cardFolderLayersCache.putIfAbsent(rel, () async {
      final layers = <String>{};
      Future<void> check(String base, String layer) async {
        if (base.trim().isEmpty) return;
        try {
          if (await Directory(p.join(base, rel)).exists()) layers.add(layer);
        } catch (_) {}
      }

      await Future.wait([
        check(config.rootDirectory, 'ROOT'),
        check(config.patchDirectory, 'PATCH'),
      ]);
      return layers;
    });
  }

  /// ZIP variants of [card], resolving pd/utils folder ZIPs lazily on first
  /// use (one overlay listing per folder, cached — a NAS-wide scan would take
  /// tens of seconds, so it must never run eagerly). Cracked cards return
  /// their index-derived variants without any I/O.
  List<CardVariant> variantsOfCard(GameCard card) {
    final raw = card.variants;
    if (raw.isNotEmpty) return raw;
    final cached = _resolvedCardVariants[card];
    if (cached != null) return cached;
    final dir = cardFolderRel(card);
    if (dir == null) return const [];
    final key = _relKey(dir);
    final scanned = _scannedFolderZips[key];
    if (scanned != null) {
      final out = [
        for (final rel in scanned)
          CardVariant(
            rel: rel,
            name: p.basename(rel),
            status: '',
            layer: _zipLayerCache[rel] ?? '',
          ),
      ];
      _resolvedCardVariants[card] = out;
      return out;
    }
    final out = <CardVariant>[];
    for (final e in browser.list(dir)) {
      if (e.kind != EntryKind.zip) continue;
      out.add(
        CardVariant(
          rel: '$dir/${e.name}',
          name: e.name,
          status: '',
          layer: e.layerStatus.name.toUpperCase(),
        ),
      );
    }
    _resolvedCardVariants[card] = out;
    return out;
  }

  final Map<GameCard, List<CardVariant>> _resolvedCardVariants = {};

  /// Cache-only [variantsOfCard]: returns `null` while a metadata-only card's
  /// folder is still being scanned (never touches the filesystem). Cracked
  /// cards return their index variants immediately.
  List<CardVariant>? cachedVariantsOfCard(GameCard card) {
    if (card.variants.isNotEmpty) return card.variants;
    final cached = _resolvedCardVariants[card];
    if (cached != null) return cached;
    final dir = cardFolderRel(card);
    if (dir == null) return const [];
    final key = _relKey(dir);
    final scanned = _scannedFolderZips[key];
    if (scanned == null) return null;
    final out = [
      for (final rel in scanned)
        CardVariant(
          rel: rel,
          name: p.basename(rel),
          status: '',
          layer: _zipLayerCache[rel] ?? '',
        ),
    ];
    _resolvedCardVariants[card] = out;
    return out;
  }

  /// Optional pre-launch guard (set by the UI): when it returns `false` the
  /// launch is aborted. Used to offer a TOS ROM download before the first start
  /// (the [HatariVariant] selects which TOS the run needs; [falcon] requests
  /// the Falcon TOS 4.04 instead of the ST TOS).
  Future<bool> Function(HatariVariant? variant, bool falcon)? beforeLaunch;

  /// True when [path] (absolute or root/patch-relative) lies inside the Falcon
  /// section tree, so the Falcon launch path is used instead of the ST one.
  bool isFalconPath(String path) {
    final rel = _relFromAbsolute(path) ?? normalizeRelSeparators(path);
    return sectionOfRel(sectionTrees, rel) == 'falcon';
  }

  /// True for magazine cover disks (ST-Computer GEMDOS archives need the
  /// extract + `-d`/`--auto` launch instead of `--disk-a`).
  bool isMagazinePath(String path) {
    final rel = _relFromAbsolute(path) ?? normalizeRelSeparators(path);
    return sectionOfRel(sectionTrees, rel) == 'magazine';
  }

  /// Launches [zipPath] with Hatari (non-blocking). Falcon titles use the
  /// dedicated Falcon launch path (own machine/TOS, GEMDOS autostart). Sets
  /// [launchError] when the configuration or ZIP is invalid; [launching] while
  /// the process runs.
  Future<void> launchZip(
    String zipPath, {
    HatariVariant? variant,
    bool? falcon,
  }) async {
    final useFalcon = falcon ?? isFalconPath(zipPath);
    if (beforeLaunch != null && !await beforeLaunch!(variant, useFalcon)) {
      return;
    }
    final result = useFalcon
        ? await launchFalcon(config, zipPath, variant: variant)
        : isMagazinePath(zipPath)
        ? await launchStGemdos(config, zipPath, variant: variant)
        : await launchHatari(config, zipPath, variant: variant);
    if (result.error != null) {
      launchError = result.error;
      notifyListeners();
      return;
    }
    launchError = null;
    launching = true;
    notifyListeners();
    final process = result.process!;
    final code = await process.exitCode;
    launching = false;
    if (code != 0) {
      final detail = process.output;
      launchError = detail.isEmpty
          ? 'Hatari exited with code $code.'
          : 'Hatari exited with code $code.\n\n$detail';
    }
    notifyListeners();
  }

  /// Default launch variant for [card] when none is chosen explicitly: old
  /// titles the screenshot generator could only capture with a non-default
  /// TOS (index marker `tos`, e.g. `1.02`) preselect the matching Play
  /// variant (`SPEC-screenshot-generator.md` §7.5), so the primary Play
  /// action does not fail on the default TOS. Null for the default TOS.
  HatariVariant? defaultVariantForCard(GameCard card) {
    final tos = card.tosVersion;
    if (tos == null || tos.isEmpty) return null;
    for (final v in kHatariVariants) {
      if (v.tosVersions.contains(tos)) return v;
    }
    return null;
  }

  /// Launches the ZIP of a catalog card's variant [index] — an index into
  /// [variantsOfCard] (lightbox "Play").
  Future<void> launchCardVariant(
    GameCard card,
    int index, {
    HatariVariant? variant,
  }) async {
    final variants = variantsOfCard(card);
    if (index < 0 || index >= variants.length) return;
    await launchZip(
      zipPathForVariant(variants[index]),
      variant: variant ?? defaultVariantForCard(card),
    );
  }

  /// Absolute ZIP path of the current selection (catalog card or browse
  /// entry): the single favorited variant, otherwise the primary/launch
  /// variant; null when nothing launchable is selected.
  String? _selectedZipPath() {
    if (catalogMode) {
      final card = selectedCard;
      if (card == null) return null;
      final favoriteKeys = favoriteKeysOfCard(card);
      if (favoriteKeys.length == 1) return favoriteKeys.first;
      final v = launchVariantForCard(card);
      return v == null ? null : zipPathForVariant(v);
    }
    final e = selectedEntry;
    if (e == null || e.kind != EntryKind.zip) return null;
    return e.effectivePath;
  }

  /// Launches the current selection: a ZIP in browse mode, the card's ZIP in
  /// catalog mode. A card with exactly one favorited variant launches that
  /// favorited ZIP (user decision 2026-10-15), otherwise [launchVariantForCard].
  Future<void> launchSelected({HatariVariant? variant}) async {
    final card = catalogMode ? selectedCard : null;
    final effective = card == null
        ? variant
        : (variant ?? defaultVariantForCard(card));
    final path = _selectedZipPath();
    if (path == null) {
      if (card != null) {
        launchError = 'No ZIP to launch.';
        notifyListeners();
      }
      return;
    }
    await launchZip(path, variant: effective);
  }

  void clearLaunchError() {
    if (launchError == null) return;
    launchError = null;
    notifyListeners();
  }

  // ------------------------------------------------------- CosmosEx (send)

  /// Pluggable sender (HTTP in production, a fake in tests).
  CosmosExUploader cosmosExUploader = const HttpCosmosExUploader();

  /// True while a "Send to CosmosEx" run is active.
  bool cosmosExSending = false;

  /// Human-readable progress of the running send.
  String cosmosExProgress = '';

  /// Last send error, surfaced as a modal and cleared on acknowledgement.
  String? cosmosExError;

  /// Last send success message, surfaced as a snackbar and cleared after.
  String? cosmosExNotice;

  /// True when the CosmosEx host is configured (enables the Play-dropdown
  /// action).
  bool get cosmosExConfigured => config.cosmosExConfigured;

  /// Sends the current selection (card ZIP / browse entry) to CosmosEx.
  Future<void> sendSelectedToCosmosEx() async {
    final path = _selectedZipPath();
    if (path == null) {
      cosmosExError = 'No ZIP to send to CosmosEx.';
      notifyListeners();
      return;
    }
    await sendZipToCosmosEx(path);
  }

  /// Sends [zipPath] to CosmosEx (classic upload or cosmo2ex path insert,
  /// depending on the configured mode).
  Future<void> sendZipToCosmosEx(String zipPath) async {
    if (cosmosExSending) return;
    cosmosExSending = true;
    cosmosExProgress = 'Preparing…';
    cosmosExError = null;
    cosmosExNotice = null;
    notifyListeners();
    try {
      final result = await cosmosExUploader.send(
        config: config,
        zipPath: zipPath,
        onProgress: (message) {
          cosmosExProgress = message;
          if (!_disposed) notifyListeners();
        },
      );
      cosmosExNotice = result.message;
    } catch (e) {
      cosmosExError = e is CosmosExException ? e.message : '$e';
    } finally {
      cosmosExSending = false;
      cosmosExProgress = '';
      if (!_disposed) notifyListeners();
    }
  }

  void clearCosmosExError() {
    if (cosmosExError == null) return;
    cosmosExError = null;
    notifyListeners();
  }

  void clearCosmosExNotice() {
    if (cosmosExNotice == null) return;
    cosmosExNotice = null;
    notifyListeners();
  }

  // --------------------------------------------------- missing (FTP download)

  /// Pluggable downloader (FTP in production, a fake in tests).
  Downloader downloader = const FtpDownloader();

  /// True while a "download missing" run transfers a card's folder; the
  /// DetailPanel shows progress + Cancel for [downloadingCard] then.
  bool downloading = false;

  /// The card whose folder is currently being downloaded (null when idle).
  GameCard? downloadingCard;

  /// Human-readable download progress ("Connecting…", "12/34 files").
  String downloadProgress = '';

  /// Last download error, surfaced as a modal and cleared on acknowledgement.
  String? downloadError;

  VoidCallback? _cancelDownload;

  /// True when the FTP connection settings are present (host set).
  bool get ftpConfigured => config.ftpConfigured;

  /// Requests cancellation of the running download (best effort; the run stops
  /// between file transfers).
  void cancelDownload() => _cancelDownload?.call();

  void clearDownloadError() {
    if (downloadError == null) return;
    downloadError = null;
    notifyListeners();
  }

  /// Downloads [card]'s whole folder (all ZIP variants + subdirectories) from
  /// the configured FTP server into the patch layer (or root when no patch
  /// directory is set) and refreshes the local layer/missing caches so the
  /// badges clear without a full reload. No-op while another run is active.
  Future<void> downloadMissing(GameCard card) async {
    if (downloading) return;
    final folder = cardFolderRel(card);
    if (folder == null || folder.isEmpty) {
      downloadError = 'No folder to download for this card.';
      notifyListeners();
      return;
    }
    if (!config.ftpConfigured) {
      downloadError =
          'FTP not configured — set Host/User/Password in Settings.';
      notifyListeners();
      return;
    }

    var cancelled = false;
    _cancelDownload = () => cancelled = true;
    downloading = true;
    downloadingCard = card;
    downloadProgress = 'Connecting…';
    downloadError = null;
    notifyListeners();

    try {
      await downloader.downloadDirectory(
        host: config.ftpHostName,
        port: config.ftpPort,
        user: config.ftpUser,
        password: config.ftpPassword,
        remoteDir: _remoteDirFor(folder),
        localDir: p.join(config.downloadTargetDirectory, folder),
        onProgress: (done, total) {
          downloadProgress = total <= 0
              ? 'Downloading…'
              : 'Downloading $done/$total files';
          notifyListeners();
        },
        isCancelled: () => cancelled,
      );
      downloadProgress = 'Download finished.';
      _refreshAfterDownload(folder);
    } on DownloadCancelledException {
      downloadProgress = 'Download cancelled.';
      _refreshAfterDownload(folder);
    } catch (e) {
      downloadError = 'Download failed: $e';
    } finally {
      downloading = false;
      downloadingCard = null;
      _cancelDownload = null;
      notifyListeners();
    }
  }

  /// Remote path of [folder] (relative to the catalog root), prefixed with the
  /// configured `Ftp.RemoteBase` when set.
  String _remoteDirFor(String folder) {
    final base = config.ftpRemoteBase.trim().replaceAll(RegExp(r'/+$'), '');
    return base.isEmpty ? folder : '$base/$folder';
  }

  /// Drops the cached local-layer state for [folder] (and clears the lazily
  /// resolved pd/utils variants) so the next `cardMissing`/`cardLayer` call
  /// re-reads the freshly downloaded files from disk.
  void _refreshAfterDownload(String folder) {
    final key = _relKey(folder);
    _zipLayerCache.removeWhere(
      (rel, _) => rel == key || rel.startsWith('$key/'),
    );
    _scannedFolderZips.removeWhere(
      (dir, _) => dir == key || dir.startsWith('$key/'),
    );
    _scannedDirs.removeWhere((dir) => dir == key || dir.startsWith('$key/'));
    _scanRequested.removeWhere((dir) => dir == key || dir.startsWith('$key/'));
    _cardFolderLayersCache.removeWhere(
      (dir, _) => dir == key || dir.startsWith('$key/'),
    );
    _resolvedCardVariants.clear();
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

  Entry? get selectedEntry {
    if (catalogMode) return null;
    final visible = visibleEntries;
    if (visible.isEmpty) return null;
    final idx = selectedIndex.clamp(0, visible.length - 1);
    return visible[idx];
  }

  /// Number of selectable items in the center view (entries or cards).
  int get itemCount =>
      catalogMode ? catalogCards.length : visibleEntries.length;

  /// Count text for the status bar.
  String get countText {
    if (catalogMode) {
      if (filter.section == 'crew') {
        final n = catalogCards.length;
        return '$n crew${n == 1 ? '' : 's'}';
      }
      if (favoritesOnly) return '${catalogCards.length} favorites';
      final n = catalogCards.length;
      return '$n result${n == 1 ? '' : 's'}';
    }
    return '${visibleEntries.length} entries';
  }

  /// Gallery-style status line (`renderStats` + `renderFooter`), app-only
  /// divergence: counts are shown as games (cards) plus their ZIP entries —
  /// `N folders`, `M with screenshot`, `done 2635 (8979 zips)` etc. so
  /// the done segment matches the dropdown result count. Every segment is
  /// scoped to the **active section** (per-section screenshot indices, user
  /// decision 2026-10-16); `gameinfo N folders` coverage stays cracked-only.
  ///
  /// Memoized per section: it is called on every rebuild (including each
  /// selection move) and its counts scan the whole section, so recomputing it
  /// repeatedly was a significant per-frame cost. Cleared when the universe is
  /// rebuilt (curation) or reloaded.
  List<String> get statusLine {
    final section = filter.section;
    if (section == 'crew') {
      final err = crews.loadError;
      if (err != null) return List<String>.unmodifiable(['crew data: $err']);
      return List<String>.unmodifiable([
        '${crews.totalReleases} releases',
        if (crews.length > kCrewInitialLimit)
          'top $kCrewInitialLimit of ${crews.length}',
        if (crews.generatedAt.isNotEmpty) 'crews: ${crews.generatedAt}',
      ]);
    }
    final cached = _statusLineCache[section];
    if (cached != null) return cached;
    return _statusLineCache[section] = List<String>.unmodifiable(
      _computeStatusLine(section),
    );
  }

  final Map<String, List<String>> _statusLineCache = {};

  List<String> _computeStatusLine(String section) {
    final parts = <String>[];
    final sectionIndex = screenshots.forSection(section);
    final sectionCards = universe.cardsFor(section);
    if (catalogMode && gameinfo.length > 0) {
      parts.add('${sectionCards.length} folders');
      parts.add('${universe.withScreenshotFor(section)} with screenshot');
    } else if (sectionIndex.length > 0) {
      parts.add('${sectionIndex.length} index entries');
    }
    if (catalogMode) {
      final zipCounts = screenshots.statusCountsFor(section);
      final gameCounts = universe.statusCountsFor(section);
      void addSegment(String label, int games, int zips) {
        if (games > 0 || zips > 0) parts.add('$label $games ($zips zips)');
      }

      addSegment(
        'done',
        universe.anyVariantCountFor(section, 'done'),
        universe.anyVariantZipCountFor(section, 'done'),
      );
      final desktopOnly = gameCounts['desktop'] ?? 0;
      final desktopZips = universe.onlyVariantZipCountFor(section, 'desktop');
      final desktopAny = universe.anyVariantCountFor(section, 'desktop');
      final desktopAnyZips = universe.anyVariantZipCountFor(section, 'desktop');
      addSegment('desktop', desktopOnly, desktopZips);
      if (desktopAny != desktopOnly || desktopAnyZips != desktopZips) {
        addSegment('desktop any', desktopAny, desktopAnyZips);
      }
      addSegment(
        'pending',
        universe.pendingAnyVariantCountFor(section),
        zipCounts['pending'] ?? 0,
      );
      addSegment(
        'skipped_disk_n',
        universe.anyVariantCountFor(section, 'skipped_disk_n'),
        universe.anyVariantZipCountFor(section, 'skipped_disk_n'),
      );
      final noUsableOnly = gameCounts['no_usable_shots'] ?? 0;
      final noUsableZips = universe.onlyVariantZipCountFor(
        section,
        'no_usable_shots',
      );
      final noUsableAny = universe.anyVariantCountFor(
        section,
        'no_usable_shots',
      );
      final noUsableAnyZips = universe.anyVariantZipCountFor(
        section,
        'no_usable_shots',
      );
      addSegment('no usable shots', noUsableOnly, noUsableZips);
      if (noUsableAny != noUsableOnly || noUsableAnyZips != noUsableZips) {
        addSegment('no usable shots any', noUsableAny, noUsableAnyZips);
      }
      addSegment(
        'interrupted',
        universe.anyVariantCountFor(section, 'interrupted'),
        universe.anyVariantZipCountFor(section, 'interrupted'),
      );
      // Cracked gameinfo coverage from the manifest (matched folders).
      if (section == 'cracked') {
        final matched = gameinfo.matchedFolders;
        if (matched != null) parts.add('gameinfo $matched folders');
      }
      // Magazine/falcon cards are index-only by design — never report them
      // as missing gameinfo.
      final noInfo = (section == 'magazine' || section == 'falcon')
          ? 0
          : universe.noInfoFor(section);
      if (noInfo > 0) {
        parts.add('$noInfo without gameinfo');
      }
    }
    final mtime = screenshots.mtimeFor(section);
    if (mtime != null) {
      parts.add('${screenshots.indexNameFor(section)}: ${_fmtTime(mtime)}');
    }
    if (gameinfo.generatedAt.isNotEmpty) {
      parts.add('gameinfo: ${gameinfo.generatedAt}');
    }
    if (gameinfo.length == 0) {
      parts.add('gameinfo unavailable — screenshots only');
    }
    return parts;
  }

  /// Actionable hint shown as a banner when the active section has **no**
  /// catalog cards at all because the screenshot index and/or the gameinfo
  /// data is missing (the catalog is artifact-driven). `null` when there is
  /// data.
  String? get catalogDataNotice {
    if (!catalogMode) return null;
    final section = filter.section;
    if (section == 'crew') {
      if (crews.groups.isNotEmpty) return null;
      return 'No crew data loaded — run tools/crew-analysis/run.sh to '
          'generate crews.json in the GameinfoDirectory.';
    }
    if (universe.cardsFor(section).isNotEmpty) return null;
    final noIndex = screenshots.forSection(section).loadError != null;
    final noInfo = gameinfo.length == 0;
    if (!noIndex && !noInfo) return null;
    final missing = <String>[
      if (noIndex)
        'the screenshot index (${screenshots.indexNameFor(section)})',
      if (noInfo) 'the game metadata',
    ].join(' and ');
    return 'No catalog data loaded — missing $missing. Open Settings (⚙) and '
        'use “Download from FTP” to fetch it, then set the status filter to '
        '“any” to show games without screenshots.';
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
    _lastSelections[currentRel] = _SelMemory(selectedIndex, name);
  }

  void _restoreSelection() {
    final mem = _lastSelections[currentRel];
    final visible = visibleEntries;
    if (visible.isEmpty) {
      selectedIndex = 0;
      return;
    }
    if (mem != null) {
      final byName = visible.indexWhere(
        (e) => e.name == mem.name && mem.name.isNotEmpty,
      );
      selectedIndex = byName >= 0
          ? byName
          : mem.index.clamp(0, visible.length - 1);
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
        final rel = favoritesRelForEntry(e);
        if (rel == null) return false;
        currentRel = rel;
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
    if (inFavoritesView) {
      currentRel = '';
    } else {
      currentRel = browser.parent(currentRel);
    }
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

  /// Effective paths (R26) of [card]'s ZIP variants that currently are
  /// favorites — both layers are checked, the stored key decides. Used to
  /// launch/play the favorited ZIP when exactly one variant is favorited and
  /// to make `*` un-favorite the single favorited variant of a card.
  List<String> favoriteKeysOfCard(GameCard card) {
    final favs = favorites;
    if (favs == null || favs.isEmpty) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final v in variantsOfCard(card)) {
      final rootPath = p.join(config.rootDirectory, v.rel);
      final patchPath = config.patchDirectory.isEmpty
          ? null
          : p.join(config.patchDirectory, v.rel);
      final hit =
          favs.contains(rootPath) ||
          (patchPath != null && favs.contains(patchPath));
      if (!hit) continue;
      final effective = zipPathForVariant(v);
      if (seen.add(effective.toLowerCase())) out.add(effective);
    }
    return out;
  }

  /// ZIP path of a card's variant [index] — an index into [variantsOfCard]
  /// (patch wins); null when the index is out of range.
  String? zipPathForCardVariant(GameCard card, int index) {
    final variants = variantsOfCard(card);
    if (index < 0 || index >= variants.length) return null;
    return zipPathForVariant(variants[index]);
  }

  bool isFavorite(Entry e) {
    final eff = e.effectivePath;
    if (eff == null) return false;
    return favorites?.contains(eff) ?? false;
  }

  /// True when the ZIP at overlay rel [rel] is stored as a favorite in
  /// either layer (root or patch path key). Pure string comparison — no
  /// filesystem access, so it is safe to call per filmstrip thumb.
  bool isFavoriteRel(String rel) {
    if (rel.isEmpty) return false;
    final favs = favorites;
    if (favs == null || favs.isEmpty) return false;
    if (favs.contains(p.join(config.rootDirectory, rel))) return true;
    final patch = config.patchDirectory;
    return patch.isNotEmpty && favs.contains(p.join(patch, rel));
  }

  /// True when any ZIP of the card's folder is a favorite (folder-keyed, so
  /// multi-variant cards stay visible in the ★ filter — user decision
  /// 2026-10-15). Membership is checked against a precomputed set of
  /// favorite folder rels (no per-card filesystem access). Candidate
  /// folders are the card's actual variant directories (index-derived —
  /// covers nested folders like `…/Original`) plus its [cardFolderRel];
  /// a hit counts when the paths are equal or nested in either direction
  /// (favorite ZIP sits deeper than, or directly above, the card folder).
  bool isFavoriteCard(GameCard card) {
    final favs = _favoriteFolderRels;
    if (favs.isEmpty) return false;
    final dirs = <String>{
      for (final v in card.variants) _favoriteDirKey(p.dirname(v.rel)),
    };
    final folder = cardFolderRel(card);
    if (folder != null) dirs.add(_favoriteDirKey(folder));
    if (dirs.isEmpty) return false;
    for (final dir in dirs) {
      if (favs.contains(dir)) return true;
      for (final fav in favs) {
        if (fav.startsWith('$dir/') || dir.startsWith('$fav/')) return true;
      }
    }
    return false;
  }

  String _favoriteDirKey(String dir) =>
      normalizeRelSeparators(dir).toLowerCase();

  Set<String>? _favoriteFolderRelsCache;

  /// Lowercased folder rel paths that hold at least one favorite ZIP
  /// (rebuilt after every toggle).
  Set<String> get _favoriteFolderRels {
    final cached = _favoriteFolderRelsCache;
    if (cached != null) return cached;
    final out = <String>{};
    for (final path in favorites?.paths ?? const <String>[]) {
      final rel = _relFromAbsolute(path);
      if (rel == null) continue;
      final dir = p.posix.dirname(rel);
      if (dir.isEmpty || dir == '.') continue;
      out.add(_favoriteDirKey(dir));
    }
    return _favoriteFolderRelsCache = out;
  }

  /// R26: toggle keyed by the effective path (patch path when present).
  /// Works in both views: on the selected ZIP entry (browse) or on the
  /// selected card (catalog) — a card with exactly one favorited variant
  /// toggles that variant (so `*` always removes a single star), otherwise
  /// the launch variant is toggled.
  void toggleFavoriteSelected() {
    String? key;
    if (catalogMode) {
      final card = selectedCard;
      if (card == null) return;
      final favoriteKeys = favoriteKeysOfCard(card);
      key = favoriteKeys.length == 1
          ? favoriteKeys.first
          : favoriteKeyOfCard(card);
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
    _entryCache.removeWhere((key, _) => key.startsWith(kFavoritesRelPrefix));
    _favoriteFolderRelsCache = null;
    _catalogDirty = true;
    notifyListeners();
  }

  /// "★ Favorites" catalog filter toggle.
  void toggleFavoritesOnly() {
    favoritesOnly = !favoritesOnly;
    _filtersChanged();
  }

  // -------------------------------------------------------------- curation

  /// Pending manual status/kind changes (`C` in the lightbox/detail view):
  /// rel ZIP path → original pair (for discard). Applied to the in-memory
  /// [ScreenshotEntry] objects immediately; written to `index.json` + mirror
  /// meta only by [savePendingStatusChanges] under the shotgen lock.
  final Map<String, StatusKindChange> _pendingStatus = {};

  bool get hasPendingStatusChanges => _pendingStatus.isNotEmpty;
  int get pendingStatusCount => _pendingStatus.length;

  /// Applies a status/kind pair in memory and remembers the original values
  /// for discard. The universe bakes cards at build time, so it is rebuilt
  /// from the mutated index entries; cards/badges/status histogram refresh
  /// via the dirty rebuild. The disk files change only on Save.
  void applyStatusChange(String rel, String status, String? kind) {
    final entry = screenshots[rel];
    if (entry == null) return;
    _pendingStatus.putIfAbsent(
      rel,
      () => (status: entry.status, kind: entry.kind),
    );
    final normKind = (kind == null || kind.isEmpty) ? null : kind;
    entry.applyStatusKind(status, normKind);
    _rebuildUniverse();
    _catalogDirty = true;
    notifyListeners();
  }

  /// Reverts all pending changes to their original values.
  void discardPendingStatusChanges() {
    _pendingStatus.forEach((rel, orig) {
      screenshots[rel]?.applyStatusKind(orig.status, orig.kind);
    });
    _pendingStatus.clear();
    _rebuildUniverse();
    _catalogDirty = true;
    notifyListeners();
  }

  /// Rebuilds the card universe from the (possibly mutated) in-memory index
  /// entries plus the loaded gameinfo; the entry objects themselves stay
  /// identical, so the pending map keeps working.
  void _rebuildUniverse() {
    universe = CatalogUniverse.build(
      indices: screenshots,
      info: gameinfo,
      screenshotDir: config.screenshotDirectory,
      // Keep the AtariLegend matches: without this a manual curation (C +
      // Save/Discard) silently dropped the genre/developer data, the
      // Publisher merge and the AtariLegend button until a reload.
      atariLegend: atariLegend,
    );
    // New card objects — drop the lazy pd/utils variant cache (identity-keyed).
    _resolvedCardVariants.clear();
    _indexTreeCache.clear();
    _statusLineCache.clear();
    _pirateFinderTitleMatches.clear();
    // The crew release lookup holds the old card objects; rebuild it so
    // `C` (status/kind) also refreshes releases opened from the Crews tab.
    _releaseLookupCache = null;
  }

  /// Persists the pending changes (shotgen lock, atomic `index.json` +
  /// mirror meta); returns null on success or an error message on failure
  /// (the pending list stays intact then).
  Future<String?> savePendingStatusChanges() async {
    if (_pendingStatus.isEmpty) return null;
    try {
      await applyStatusChanges(
        screenshotDir: config.screenshotDirectory,
        changes: {
          for (final e in _pendingStatus.entries)
            e.key: (
              status: screenshots[e.key]?.status ?? e.value.status,
              kind: screenshots[e.key]?.kind,
            ),
        },
      );
      _pendingStatus.clear();
      notifyListeners();
      return null;
    } on ShotgenLockedException catch (e) {
      return e.toString();
    } on FileSystemException catch (e) {
      return 'Save failed: ${e.message}'
          '${e.path == null || e.path!.isEmpty ? '' : ' (${e.path})'}';
    } catch (e) {
      return 'Save failed: $e';
    }
  }

  // ------------------------------------------------------- preview image swap

  /// Per-path image versions for `M`: the swap keeps the file names (and
  /// thus the `FileImage` cache keys) fixed, only the contents trade places.
  /// Path-keyed `Image.file` widgets therefore take
  /// `ValueKey('$path#${imageVersionOf(path)}')` so that exactly the two
  /// affected images are recreated and re-read after [swapPreviewImage],
  /// while every other widget keeps its key (no thumbnail flash).
  final Map<String, int> _imageVersions = {};
  int _imageBump = 0;

  /// Version token for [path]; `'0'` until the path was swapped once.
  String imageVersionOf(String path) => '${_imageVersions[path] ?? 0}';

  /// Swaps the preview main image with a candidate on disk (lightbox `M`):
  /// shotgen lock check → rename pair → drop the decoded image cache
  /// (keepAlive **and** live refs — see below) → bump both paths' versions →
  /// refresh all views. Returns null on success or an error message (lock
  /// taken, IO failure); the disk state and the versions stay untouched
  /// then.
  String? swapPreviewImage({
    required String previewPath,
    required String candidatePath,
  }) {
    try {
      if (isShotgenActive(config.screenshotDirectory)) {
        throw ShotgenLockedException(
          readShotgenLockPid(config.screenshotDirectory),
        );
      }
      swapPreviewCandidate(
        previewPath: previewPath,
        candidatePath: candidatePath,
      );
      // Order matters: clear the caches first, bump afterwards, so widgets
      // recreated by the notify re-read from disk instead of stale entries.
      //
      // `clear()` alone is NOT enough: it drops `_cache` (keepAlive) and
      // `_pendingImages` but keeps `_liveImages`, and `putIfAbsent` falls
      // through to `_liveImages[key]` — during the very rebuild that
      // recreates the keyed widgets, the old `ImageState`s are still
      // mounted (their listeners detach later in the same frame), so every
      // re-resolve of the swapped path would get the OLD completer back
      // and keep painting stale pixels. `clearLiveImages()` (key-agnostic,
      // also covers `cacheWidth`'s ResizeImage keys) makes those lookups
      // miss and forces a fresh disk read.
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      final v = ++_imageBump;
      _imageVersions[previewPath] = v;
      _imageVersions[candidatePath] = v;
      notifyListeners();
      return null;
    } on ShotgenLockedException catch (e) {
      return e.toString();
    } on FileSystemException catch (e) {
      return 'Swap failed: ${e.message}'
          '${e.path == null || e.path!.isEmpty ? '' : ' (${e.path})'}';
    } catch (e) {
      return 'Swap failed: $e';
    }
  }

  // -------------------------------------------------------------- statusbar

  /// Path shown in the status bar.
  String get displayPath => inFavoritesView
      ? favoritesFolderLabel(favoritesViewSection)
      : (currentRel.isEmpty ? '/' : '/$currentRel');
}

class _SelMemory {
  _SelMemory(this.index, this.name);
  final int index;
  final String name;
}
