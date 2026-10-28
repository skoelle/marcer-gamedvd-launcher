// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:isolate';

import 'atarilegend.dart';
import 'card.dart';
import 'crews.dart';
import 'full_index.dart';
import 'gameinfo.dart';
import 'magazine.dart';
import 'screenshot_index.dart';

/// Facet option lists of one section (gallery `/api/meta` `facets[section]`).
class CatalogFacets {
  const CatalogFacets({
    this.publishers = const [],
    this.crews = const [],
    this.crackers = const [],
    this.languages = const [],
    this.years = const [],
    this.letters = const [],
    this.genres = const [],
    this.developers = const [],
  });

  final List<String> publishers;
  final List<String> crews;
  final List<String> crackers;
  final List<String> languages;
  final List<String> years;
  final List<String> letters;

  /// AtariLegend genres/developers (available from the downloaded cache).
  final List<String> genres;
  final List<String> developers;
}

/// All catalog cards grouped per section plus their facets — the global
/// "universe" of the desktop app, derived from the per-section screenshot
/// indices (`index.json` / `index-pd.json` / `index-utils.json` /
/// `index-magazine.json`) + gameinfo
/// without any filesystem scan (user decision 2026-10-11; per-section
/// indices + pd/utils union 2026-10-16; magazine section 2026-10-22).
///
/// - `cracked` cards come from its index entries grouped by (letter, folder)
///   joined with `games-cracked.json`.
/// - `pd`/`utils` cards are the union of index groups (with status counts /
///   screenshots / variants) and gameinfo-only folders without an index entry
///   (metadata-only cards, the pre-index behaviour).
/// - `magazine` cards come from `index-magazine.json` only, grouped per issue
///   by a filename parser (`magazine.dart`).
class CatalogUniverse {
  CatalogUniverse._({
    required this.cracked,
    required this.pd,
    required this.utils,
    required this.magazine,
    required this.falcon,
    required this.crackedFacets,
    required this.pdFacets,
    required this.utilsFacets,
    required this.magazineFacets,
    required this.falconFacets,
    required Map<String, Map<String, int>> statusCountsBySection,
  }) : _countsBySection = statusCountsBySection;

  factory CatalogUniverse.build({
    required ScreenshotIndices indices,
    required GameInfoIndex info,
    required String screenshotDir,
    AtariLegendIndex? atariLegend,
    void Function(String message)? onProgress,
  }) {
    final fullPng = _fullPngFn(screenshotDir);

    onProgress?.call('Building catalog — cracked…');
    final cracked = _buildIndexedSection(
      kind: 'cracked',
      index: indices.forSection('cracked'),
      info: info,
      fullPng: fullPng,
      unionGameinfo: false,
      atariLegend: atariLegend,
      onProgress: onProgress,
    );
    onProgress?.call('Building catalog — pd…');
    final pd = _buildIndexedSection(
      kind: 'pd',
      index: indices.forSection('pd'),
      info: info,
      fullPng: fullPng,
      unionGameinfo: true,
      atariLegend: atariLegend,
      onProgress: onProgress,
    );
    onProgress?.call('Building catalog — utils…');
    final utils = _buildIndexedSection(
      kind: 'utils',
      index: indices.forSection('utils'),
      info: info,
      fullPng: fullPng,
      unionGameinfo: true,
      atariLegend: atariLegend,
      onProgress: onProgress,
    );
    onProgress?.call('Building catalog — magazine…');
    final magazine = _buildIndexedSection(
      kind: 'magazine',
      index: indices.forSection('magazine'),
      info: info,
      fullPng: fullPng,
      unionGameinfo: false,
      atariLegend: null,
      onProgress: onProgress,
    );
    onProgress?.call('Building catalog — falcon…');
    final falcon = _buildIndexedSection(
      kind: 'falcon',
      index: indices.forSection('falcon'),
      info: info,
      fullPng: fullPng,
      unionGameinfo: false,
      atariLegend: atariLegend,
      onProgress: onProgress,
    );

    onProgress?.call('Building catalog — facets…');
    return CatalogUniverse._(
      cracked: cracked.cards,
      pd: pd.cards,
      utils: utils.cards,
      magazine: magazine.cards,
      falcon: falcon.cards,
      crackedFacets: _facets(cracked.cards, 'cracked'),
      pdFacets: _facets(pd.cards, 'pd'),
      utilsFacets: _facets(utils.cards, 'utils'),
      magazineFacets: _facets(magazine.cards, 'magazine'),
      falconFacets: _facets(falcon.cards, 'falcon'),
      statusCountsBySection: {
        'cracked': cracked.statusCounts,
        'pd': pd.statusCounts,
        'utils': utils.statusCounts,
        'magazine': magazine.statusCounts,
        'falcon': falcon.statusCounts,
      },
    );
  }

  final List<GameCard> cracked;
  final List<GameCard> pd;
  final List<GameCard> utils;
  final List<GameCard> magazine;
  final List<GameCard> falcon;
  final CatalogFacets crackedFacets;
  final CatalogFacets pdFacets;
  final CatalogFacets utilsFacets;
  final CatalogFacets magazineFacets;
  final CatalogFacets falconFacets;
  final Map<String, Map<String, int>> _countsBySection;

  /// Aggregated `displayStatus` counts over cracked cards (status bar games
  /// column). `pending` is overridden by [pendingAnyVariantCount] there so
  /// the segment matches the app's pending filter rule. Shorthand for
  /// [statusCountsFor]`('cracked')`.
  Map<String, int> get statusCounts => statusCountsFor('cracked');

  /// Aggregated `displayStatus` counts over the cards of [section].
  Map<String, int> statusCountsFor(String section) =>
      _countsBySection[section] ?? const {};

  /// Every card of every section (the `★ Favorites` filter lists all
  /// sections at once).
  List<GameCard> get allCards =>
      [...cracked, ...pd, ...utils, ...magazine, ...falcon];

  List<GameCard> cardsFor(String section) => switch (section) {
        'pd' => pd,
        'utils' => utils,
        'magazine' => magazine,
        'falcon' => falcon,
        // The crew section is built by the controller from `crews.json`
        // (not from a screenshot index), so the universe has no cards here.
        'crew' => const <GameCard>[],
        _ => cracked,
      };

  CatalogFacets facetsFor(String section) => switch (section) {
        'pd' => pdFacets,
        'utils' => utilsFacets,
        'magazine' => magazineFacets,
        'falcon' => falconFacets,
        'crew' => const CatalogFacets(),
        _ => crackedFacets,
      };

  /// Number of cracked cards with at least one preview (status bar
  /// `3211 with screenshot`, next to the `3287 folders` segment).
  int get crackedWithScreenshot => withScreenshotFor('cracked');

  /// Cards of [section] with at least one preview.
  int withScreenshotFor(String section) =>
      cardsFor(section).where((c) => c.screenshots).length;

  /// Cracked cards with at least one `pending` ZIP — the app-specific
  /// pending filter rule (`matchesCard`), used by the status bar pending
  /// segment so it matches the dropdown result count.
  int get pendingAnyVariantCount => pendingAnyVariantCountFor('cracked');

  /// Cards of [section] with at least one ZIP variant in [status].
  int anyVariantCountFor(String section, String status) => cardsFor(section)
      .where((c) => c.variants.any((v) => v.status == status))
      .length;

  /// ZIPs of [section] whose status is [status] (across all cards).
  int anyVariantZipCountFor(String section, String status) => cardsFor(section)
      .fold(0, (sum, c) => sum + c.variants.where((v) => v.status == status).length);

  /// ZIPs in cards whose aggregated [displayStatus] is [status].
  int onlyVariantZipCountFor(String section, String status) =>
      cardsFor(section)
          .where((c) => c.displayStatus == status)
          .fold(0, (sum, c) => sum + c.variants.where((v) => v.status == status).length);

  /// Cards of [section] with at least one `pending` ZIP variant.
  int pendingAnyVariantCountFor(String section) =>
      anyVariantCountFor(section, 'pending');

  /// Cracked cards without gameinfo (gallery `sections.cracked.no_info`).
  int get crackedNoInfo => noInfoFor('cracked');

  /// Cards of [section] without gameinfo.
  int noInfoFor(String section) =>
      cardsFor(section).where((c) => c.info == null).length;

  int get crackedVariants => variantsFor('cracked');

  /// Number of ZIP variants of all cards of [section].
  int variantsFor(String section) =>
      cardsFor(section).fold(0, (sum, c) => sum + c.variants.length);
}

/// One section's index groups → cards (+ per-card status histogram).
typedef _SectionBuild = ({List<GameCard> cards, Map<String, int> statusCounts});

/// Groups [index] entries by (letter, folder), joins gameinfo and builds the
/// section's cards. With [unionGameinfo] the gameinfo-only folders without an
/// index entry are appended as metadata-only cards (pd/utils); cracked is
/// index-only like before.
_SectionBuild _buildIndexedSection({
  required String kind,
  required ScreenshotIndex index,
  required GameInfoIndex info,
  required String? Function(String rel, String? baseName) fullPng,
  required bool unionGameinfo,
  AtariLegendIndex? atariLegend,
  void Function(String)? onProgress,
}) {
  final groups = <String, List<(String, ScreenshotEntry)>>{};
  final groupKeys = <(String, String, String, String)>[];
  index.entries.forEach((rel, e) {
    final parts = rel.split('/');
    final letter = parts.length > 2 ? parts[2] : '';
    String folder;
    String display;
    String year;
    if (kind == 'magazine') {
      final stem = _stem(parts.length > 3 ? parts[3] : parts.last);
      final g = magazineGroup(letter, stem);
      folder = g.folder;
      display = g.display;
      year = g.year;
    } else {
      folder = parts.length > 3 ? parts[3] : _stem(parts.last);
      display = folder;
      year = '';
    }
    final key = '${letter.toLowerCase()}|${folder.toLowerCase()}';
    final bucket = groups[key];
    if (bucket == null) {
      groupKeys.add((letter, folder, display, year));
      groups[key] = [(rel, e)];
    } else {
      bucket.add((rel, e));
    }
  });

  final cards = <GameCard>[];
  final statusCounts = <String, int>{};
  final seen = <String>{};
  final total = groupKeys.length;
  for (var gi = 0; gi < groupKeys.length; gi++) {
    if (onProgress != null && gi % 500 == 0) {
      onProgress('Building catalog — $kind ${gi + 1}/$total…');
    }
    final (letter, folder, display, year) = groupKeys[gi];
    final items = groups['${letter.toLowerCase()}|${folder.toLowerCase()}']!;
    final game = info.lookupKind(kind, letter, folder);
    final card = buildIndexedCard(
      kind: kind,
      letter: letter,
      folder: folder,
      items: items,
      game: game,
      fullPng: fullPng,
      atariLegend: atariLegend?.matchFolder(folder),
      displayName: display,
      yearOverride: year,
    );
    cards.add(card);
    seen.add('${letter.toLowerCase()}|${folder.toLowerCase()}');
    if (card.displayStatus.isNotEmpty) {
      statusCounts[card.displayStatus] =
          (statusCounts[card.displayStatus] ?? 0) + 1;
    }
  }

  if (unionGameinfo) {
    for (final g in info.byKind(kind)) {
      final key = '${g.letter.toLowerCase()}|${g.folder.toLowerCase()}';
      if (seen.contains(key)) continue;
      cards.add(buildSimpleCard(
        game: g,
        kind: kind,
        atariLegend: atariLegend?.matchFolder(g.folder),
      ));
    }
  }

  return (cards: cards, statusCounts: statusCounts);
}

/// Gallery `_full_png`: OUT-relative `dirname(rel)/name`, resolved against
/// [screenshotDir] to an absolute path. Returns null for empty names.
String? Function(String rel, String? baseName) _fullPngFn(String screenshotDir) {
  return (String rel, String? baseName) {
    if (baseName == null || baseName.isEmpty) return null;
    final idx = rel.lastIndexOf('/');
    final relDir = idx == -1 ? '' : rel.substring(0, idx);
    return relDir.isEmpty
        ? '$screenshotDir/$baseName'
        : '$screenshotDir/$relDir/$baseName';
  };
}

String _stem(String name) {
  final idx = name.lastIndexOf('.');
  return idx <= 0 ? name : name.substring(0, idx);
}

/// Facets over all cards of a section (gallery `_facets`), incl. the
/// `0-9`-first letter ordering.
CatalogFacets _facets(List<GameCard> cards, String kind) {
  final pubs = <String>{}, crews = <String>{}, crackers = <String>{},
      langs = <String>{}, years = <String>{}, letters = <String>{},
      genres = <String>{}, developers = <String>{};
  final withCrew = kindFields(kind).contains('crew');
  final withCracker = kindFields(kind).contains('cracked_by');
  for (final c in cards) {
    if (c.letter.isNotEmpty) letters.add(c.letter);
    if (c.year.isNotEmpty && c.year != 'unknown') years.add(c.year);
    final al = c.atariLegend;
    if (al != null) {
      if (al.publisher.trim().isNotEmpty) pubs.add(al.publisher.trim());
      for (final g in al.genres) {
        if (g.trim().isNotEmpty) genres.add(g.trim());
      }
      for (final d in al.developers) {
        if (d.trim().isNotEmpty) developers.add(d.trim());
      }
    }
    for (final v in c.info?.variants ?? const <Map<String, dynamic>>[]) {
      String val(String key) => ((v[key] ?? '') as String).trim();
      if (val('publisher').isNotEmpty) pubs.add(val('publisher'));
      if (val('language').isNotEmpty) langs.add(val('language'));
      if (withCrew && val('crew').isNotEmpty) crews.add(val('crew'));
      if (withCracker && val('cracked_by').isNotEmpty) {
        crackers.add(val('cracked_by'));
      }
      final y = extractYear(v['release'] as String?);
      if (y.isNotEmpty) years.add(y);
    }
  }
  List<String> lowerSort(Iterable<String> s) =>
      (s.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())));
  return CatalogFacets(
    publishers: lowerSort(pubs),
    crews: lowerSort(crews),
    crackers: lowerSort(crackers),
    languages: lowerSort(langs),
    years: (years.toList()..sort()),
    genres: lowerSort(genres),
    developers: lowerSort(developers),
    letters: (letters.toList()
      ..sort((a, b) {
        final fa = a != '0-9', fb = b != '0-9';
        if (fa != fb) return fa ? 1 : -1;
        return a.compareTo(b);
      })),
  );
}

/// Metadata fields per section (gallery `kind_fields`).
Set<String> kindFields(String kind) => switch (kind) {
      'pd' => {'publisher', 'language', 'release', 'tos_bad'},
      'magazine' => const {},
      'falcon' => const {},
      'crew' => const {},
      'utils' => {
          'publisher',
          'crew',
          'cracked_by',
          'language',
          'release',
          'raw_dump',
          'tos_bad',
        },
      _ => {
          'publisher',
          'crew',
          'cracked_by',
          'language',
          'release',
          'raw_dump',
          'pasti_dump',
          'boxscan',
          'tos_bad',
        },
    };

/// One isolate-loadable bundle of all read-only data (indices, gameinfo,
/// universe). Loaded once at startup via [load] (a background isolate).
class CatalogBundle {
  CatalogBundle({
    required this.index,
    required this.fullIndex,
    required this.info,
    required this.crews,
    required this.crewImages,
    required this.atariLegend,
    required this.universe,
    required this.warnings,
  });

  /// Loads the whole bundle in a **background isolate**, reporting coarse
  /// progress through [onProgress] (called on the caller's isolate; e.g.
  /// `Loading screenshot index…`, `Building catalog — cracked 1200/8000…`,
  /// `Finalizing…`). Keeps the UI responsive while the large JSON files are
  /// parsed and the catalog is built.
  static Future<CatalogBundle> load({
    required String screenshotDir,
    required String gameinfoDir,
    String atariLegendDir = '',
    void Function(String message)? onProgress,
  }) {
    final receive = ReceivePort();
    final errors = ReceivePort();
    final completer = Completer<CatalogBundle>();
    Isolate? isolate;

    void cleanup() {
      receive.close();
      errors.close();
      isolate?.kill(priority: Isolate.immediate);
    }

    receive.listen((message) {
      if (message is CatalogBundle) {
        if (!completer.isCompleted) completer.complete(message);
        cleanup();
      } else if (message is String) {
        onProgress?.call(message);
      }
    });
    errors.listen((message) {
      if (completer.isCompleted) return;
      final text = message is List && message.isNotEmpty
          ? '${message.first}'
          : '$message';
      final trace = message is List && message.length > 1
          ? StackTrace.fromString('${message[1]}')
          : StackTrace.current;
      completer.completeError(Exception(text), trace);
      cleanup();
    });

    () async {
      try {
        isolate = await Isolate.spawn(
          _loadEntry,
          _LoadRequest(
              receive.sendPort, screenshotDir, gameinfoDir, atariLegendDir),
          onError: errors.sendPort,
        );
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
        cleanup();
      }
    }();

    return completer.future;
  }

  /// Loads everything synchronously (call inside an isolate). [onProgress]
  /// reports coarse phase messages (sources + catalog build progress).
  static CatalogBundle loadSync({
    required String screenshotDir,
    required String gameinfoDir,
    String atariLegendDir = '',
    void Function(String message)? onProgress,
  }) {
    final warnings = <String>[];

    onProgress?.call('Loading screenshot index…');
    final screenshots = ScreenshotIndices.load(screenshotDir);
    warnings.addAll(screenshots.warnings);

    onProgress?.call('Loading full index…');
    final fullIndex = FullIndex.load(gameinfoDir, warnings: warnings);
    final index = ScreenshotIndices.merge(
      screenshots: screenshots,
      full: fullIndex,
    );

    onProgress?.call('Loading game metadata…');
    GameInfoIndex info;
    if (gameinfoDir.isEmpty) {
      info = GameInfoIndex.load('');
      warnings.add('Game metadata: GameinfoDirectory not configured');
    } else {
      info = GameInfoIndex.load(gameinfoDir);
      warnings.addAll(info.warnings);
      if (info.length == 0) {
        warnings.add('Game metadata: no games found in $gameinfoDir');
      }
    }

    onProgress?.call('Loading crew data…');
    final crews = CrewIndex.load(gameinfoDir);
    final crewImages = CrewImageIndex.load(gameinfoDir);

    onProgress?.call('Loading AtariLegend data…');
    final atariLegend =
        AtariLegendIndex.load(atariLegendDir, warnings: warnings);

    final universe = CatalogUniverse.build(
      indices: index,
      info: info,
      screenshotDir: screenshotDir,
      atariLegend: atariLegend,
      onProgress: onProgress,
    );
    onProgress?.call('Finalizing…');
    return CatalogBundle(
      index: index,
      fullIndex: fullIndex,
      info: info,
      crews: crews,
      crewImages: crewImages,
      atariLegend: atariLegend,
      universe: universe,
      warnings: warnings,
    );
  }

  final ScreenshotIndices index;
  final FullIndex fullIndex;
  final GameInfoIndex info;
  final CrewIndex crews;
  final CrewImageIndex crewImages;
  final AtariLegendIndex atariLegend;
  final CatalogUniverse universe;
  final List<String> warnings;
}

/// Request passed to the loader isolate ([CatalogBundle.load]).
class _LoadRequest {
  const _LoadRequest(
      this.port, this.screenshotDir, this.gameinfoDir, this.atariLegendDir);

  final SendPort port;
  final String screenshotDir;
  final String gameinfoDir;
  final String atariLegendDir;
}

/// Isolate entry point: loads the bundle, streams progress messages through
/// the request port and exits with the finished bundle.
void _loadEntry(_LoadRequest request) {
  final bundle = CatalogBundle.loadSync(
    screenshotDir: request.screenshotDir,
    gameinfoDir: request.gameinfoDir,
    atariLegendDir: request.atariLegendDir,
    onProgress: request.port.send,
  );
  Isolate.exit(request.port, bundle);
}
