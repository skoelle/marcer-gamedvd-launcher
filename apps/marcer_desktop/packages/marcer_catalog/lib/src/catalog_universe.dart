// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'card.dart';
import 'gameinfo.dart';
import 'screenshot_index.dart';

/// Section identifiers matching the gallery tabs.
const List<String> kSections = ['cracked', 'pd', 'utils'];

/// Facet option lists of one section (gallery `/api/meta` `facets[section]`).
class CatalogFacets {
  const CatalogFacets({
    this.publishers = const [],
    this.crews = const [],
    this.crackers = const [],
    this.languages = const [],
    this.years = const [],
    this.letters = const [],
  });

  final List<String> publishers;
  final List<String> crews;
  final List<String> crackers;
  final List<String> languages;
  final List<String> years;
  final List<String> letters;
}

/// All catalog cards grouped per section plus their facets — the global
/// "universe" of the desktop app, derived from `index.json` + gameinfo
/// without any filesystem scan (user decision 2026-10-11).
class CatalogUniverse {
  CatalogUniverse._({
    required this.cracked,
    required this.pd,
    required this.utils,
    required this.crackedFacets,
    required this.pdFacets,
    required this.utilsFacets,
    required this.statusCounts,
  });

  factory CatalogUniverse.build({
    required ScreenshotIndex index,
    required GameInfoIndex info,
    required String outDir,
  }) {
    final fullPng = _fullPngFn(outDir);

    // Cracked: group index entries by (letter, folder), join games-cracked.
    final groups = <String, List<(String, ScreenshotEntry)>>{};
    final groupKeys = <(String, String)>[];
    index.entries.forEach((rel, e) {
      final parts = rel.split('/');
      final letter = parts.length > 2 ? parts[2] : '';
      final folder = parts.length > 3 ? parts[3] : _stem(parts.last);
      final key = (letter, folder);
      final bucket = groups['${letter.toLowerCase()}|${folder.toLowerCase()}'];
      if (bucket == null) {
        groupKeys.add(key);
        groups['${letter.toLowerCase()}|${folder.toLowerCase()}'] = [(rel, e)];
      } else {
        bucket.add((rel, e));
      }
    });

    final cracked = <GameCard>[];
    final statusCounts = <String, int>{};
    for (final (letter, folder) in groupKeys) {
      final items =
          groups['${letter.toLowerCase()}|${folder.toLowerCase()}']!;
      final game = info.lookupKind('cracked', letter, folder);
      final card = buildCrackedCard(
        letter: letter,
        folder: folder,
        items: items,
        game: game,
        fullPng: fullPng,
      );
      cracked.add(card);
      statusCounts[card.displayStatus] =
          (statusCounts[card.displayStatus] ?? 0) + 1;
    }

    final pd = [
      for (final g in info.byKind('pd')) buildSimpleCard(game: g, kind: 'pd'),
    ];
    final utils = [
      for (final g in info.byKind('utils'))
        buildSimpleCard(game: g, kind: 'utils'),
    ];

    return CatalogUniverse._(
      cracked: cracked,
      pd: pd,
      utils: utils,
      crackedFacets: _facets(cracked, 'cracked'),
      pdFacets: _facets(pd, 'pd'),
      utilsFacets: _facets(utils, 'utils'),
      statusCounts: statusCounts,
    );
  }

  final List<GameCard> cracked;
  final List<GameCard> pd;
  final List<GameCard> utils;
  final CatalogFacets crackedFacets;
  final CatalogFacets pdFacets;
  final CatalogFacets utilsFacets;

  /// Aggregated `displayStatus` counts over cracked cards (status bar).
  final Map<String, int> statusCounts;

  List<GameCard> cardsFor(String section) => switch (section) {
        'pd' => pd,
        'utils' => utils,
        _ => cracked,
      };

  CatalogFacets facetsFor(String section) => switch (section) {
        'pd' => pdFacets,
        'utils' => utilsFacets,
        _ => crackedFacets,
      };

  /// Number of cracked cards with at least one preview (status bar
  /// `4414 / 22938 with screenshot`).
  int get crackedWithScreenshot => cracked.where((c) => c.screenshots).length;
  int get crackedVariants =>
      cracked.fold(0, (sum, c) => sum + c.variants.length);
}

/// Gallery `_full_png`: OUT-relative `dirname(rel)/name`, resolved against
/// [outDir] to an absolute path. Returns null for empty names.
String? Function(String rel, String? baseName) _fullPngFn(String outDir) {
  return (String rel, String? baseName) {
    if (baseName == null || baseName.isEmpty) return null;
    final idx = rel.lastIndexOf('/');
    final relDir = idx == -1 ? '' : rel.substring(0, idx);
    return relDir.isEmpty
        ? '$outDir/$baseName'
        : '$outDir/$relDir/$baseName';
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
      langs = <String>{}, years = <String>{}, letters = <String>{};
  final withCrew = kindFields(kind).contains('crew');
  final withCracker = kindFields(kind).contains('cracked_by');
  for (final c in cards) {
    if (c.letter.isNotEmpty) letters.add(c.letter);
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

/// One isolate-loadable bundle of all read-only data (index, gameinfo,
/// universe). Loaded once at startup via `Isolate.run`.
class CatalogBundle {
  CatalogBundle({
    required this.index,
    required this.info,
    required this.universe,
    required this.warnings,
  });

  /// Loads everything synchronously (call inside an isolate).
  static CatalogBundle loadSync({
    required String outDir,
    required String dataDir,
  }) {
    final warnings = <String>[];

    ScreenshotIndex index;
    if (outDir.isEmpty) {
      index = ScreenshotIndex.empty('OutDirectory not configured');
      warnings.add('Screenshots: OutDirectory not configured');
    } else {
      index = ScreenshotIndex.load(outDir);
      if (index.loadError != null) {
        warnings.add('Screenshots: ${index.loadError}');
      }
    }

    GameInfoIndex info;
    if (dataDir.isEmpty) {
      info = GameInfoIndex.load('');
      warnings.add('Game metadata: DataDirectory not configured');
    } else {
      info = GameInfoIndex.load(dataDir);
      if (info.length == 0) {
        warnings.add('Game metadata: no games found in $dataDir');
      }
    }

    final universe = CatalogUniverse.build(
      index: index,
      info: info,
      outDir: outDir,
    );
    return CatalogBundle(
      index: index,
      info: info,
      universe: universe,
      warnings: warnings,
    );
  }

  final ScreenshotIndex index;
  final GameInfoIndex info;
  final CatalogUniverse universe;
  final List<String> warnings;
}
