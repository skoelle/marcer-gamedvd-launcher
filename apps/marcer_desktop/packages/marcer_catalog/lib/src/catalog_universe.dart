// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'card.dart';
import 'gameinfo.dart';
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
  });

  final List<String> publishers;
  final List<String> crews;
  final List<String> crackers;
  final List<String> languages;
  final List<String> years;
  final List<String> letters;
}

/// All catalog cards grouped per section plus their facets — the global
/// "universe" of the desktop app, derived from the per-section screenshot
/// indices (`index.json` / `index-pd.json` / `index-utils.json`) + gameinfo
/// without any filesystem scan (user decision 2026-10-11; per-section
/// indices + pd/utils union 2026-10-16).
///
/// - `cracked` cards come from its index entries grouped by (letter, folder)
///   joined with `games-cracked.json`.
/// - `pd`/`utils` cards are the union of index groups (with status counts /
///   screenshots / variants) and gameinfo-only folders without an index entry
///   (metadata-only cards, the pre-index behaviour).
class CatalogUniverse {
  CatalogUniverse._({
    required this.cracked,
    required this.pd,
    required this.utils,
    required this.crackedFacets,
    required this.pdFacets,
    required this.utilsFacets,
    required Map<String, Map<String, int>> statusCountsBySection,
  }) : _countsBySection = statusCountsBySection;

  factory CatalogUniverse.build({
    required ScreenshotIndices indices,
    required GameInfoIndex info,
    required String outDir,
  }) {
    final fullPng = _fullPngFn(outDir);

    final cracked = _buildIndexedSection(
      kind: 'cracked',
      index: indices.forSection('cracked'),
      info: info,
      fullPng: fullPng,
      unionGameinfo: false,
    );
    final pd = _buildIndexedSection(
      kind: 'pd',
      index: indices.forSection('pd'),
      info: info,
      fullPng: fullPng,
      unionGameinfo: true,
    );
    final utils = _buildIndexedSection(
      kind: 'utils',
      index: indices.forSection('utils'),
      info: info,
      fullPng: fullPng,
      unionGameinfo: true,
    );

    return CatalogUniverse._(
      cracked: cracked.cards,
      pd: pd.cards,
      utils: utils.cards,
      crackedFacets: _facets(cracked.cards, 'cracked'),
      pdFacets: _facets(pd.cards, 'pd'),
      utilsFacets: _facets(utils.cards, 'utils'),
      statusCountsBySection: {
        'cracked': cracked.statusCounts,
        'pd': pd.statusCounts,
        'utils': utils.statusCounts,
      },
    );
  }

  final List<GameCard> cracked;
  final List<GameCard> pd;
  final List<GameCard> utils;
  final CatalogFacets crackedFacets;
  final CatalogFacets pdFacets;
  final CatalogFacets utilsFacets;
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
  List<GameCard> get allCards => [...cracked, ...pd, ...utils];

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
  /// `3211 with screenshot`, next to the `3287 folders` segment).
  int get crackedWithScreenshot => withScreenshotFor('cracked');

  /// Cards of [section] with at least one preview.
  int withScreenshotFor(String section) =>
      cardsFor(section).where((c) => c.screenshots).length;

  /// Cracked cards with at least one `pending` ZIP — the app-specific
  /// pending filter rule (`matchesCard`), used by the status bar pending
  /// segment so it matches the dropdown result count.
  int get pendingAnyVariantCount => pendingAnyVariantCountFor('cracked');

  /// Cards of [section] with at least one `pending` ZIP variant.
  int pendingAnyVariantCountFor(String section) => cardsFor(section)
      .where((c) => c.variants.any((v) => v.status == 'pending'))
      .length;

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
}) {
  final groups = <String, List<(String, ScreenshotEntry)>>{};
  final groupKeys = <(String, String)>[];
  index.entries.forEach((rel, e) {
    final parts = rel.split('/');
    final letter = parts.length > 2 ? parts[2] : '';
    final folder = parts.length > 3 ? parts[3] : _stem(parts.last);
    final key = '${letter.toLowerCase()}|${folder.toLowerCase()}';
    final bucket = groups[key];
    if (bucket == null) {
      groupKeys.add((letter, folder));
      groups[key] = [(rel, e)];
    } else {
      bucket.add((rel, e));
    }
  });

  final cards = <GameCard>[];
  final statusCounts = <String, int>{};
  final seen = <String>{};
  for (final (letter, folder) in groupKeys) {
    final items = groups['${letter.toLowerCase()}|${folder.toLowerCase()}']!;
    final game = info.lookupKind(kind, letter, folder);
    final card = buildIndexedCard(
      kind: kind,
      letter: letter,
      folder: folder,
      items: items,
      game: game,
      fullPng: fullPng,
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
      cards.add(buildSimpleCard(game: g, kind: kind));
    }
  }

  return (cards: cards, statusCounts: statusCounts);
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

/// One isolate-loadable bundle of all read-only data (indices, gameinfo,
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

    final index = ScreenshotIndices.load(outDir);
    warnings.addAll(index.warnings);

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
      indices: index,
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

  final ScreenshotIndices index;
  final GameInfoIndex info;
  final CatalogUniverse universe;
  final List<String> warnings;
}
