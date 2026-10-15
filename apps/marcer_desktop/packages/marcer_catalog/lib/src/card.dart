// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'gameinfo.dart';
import 'screenshot_index.dart';

/// Status aggregation order of `SPEC-gallery-webapp.md` §4.4 (first match
/// wins), identical to `gallery.py STATUS_ORDER`.
const List<String> kStatusOrder = [
  'done',
  'desktop',
  'no_usable_shots',
  'interrupted',
  'pending',
  'skipped_disk_n',
];

/// Filter/status labels as shown in the desktop app (the two manual
/// curation filters `desktop_text`/`desktop_black` are app-only; the
/// gallery keeps its own `STATUS_LABELS`).
const Map<String, String> kStatusLabels = {
  'done': 'done',
  'desktop': 'desktop',
  'desktop_text': 'desktop text',
  'desktop_black': 'desktop black',
  'no_usable_shots': 'no usable shots',
  'interrupted': 'interrupted',
  'pending': 'pending',
  'skipped_disk_n': 'skipped (disk 2+)',
  'any': 'any status',
  'with_screenshot': 'with screenshot',
};

/// Status dropdown keys of the desktop app: the aggregation order plus the
/// two kind-based filters (strictly `status: desktop` + kind).
const List<String> kStatusFilterKeys = [
  'done',
  'desktop',
  'desktop_text',
  'desktop_black',
  'no_usable_shots',
  'interrupted',
  'pending',
  'skipped_disk_n',
];

const List<String> kSortKeys = ['name', 'year', 'publisher', 'cracker', 'crew'];

final RegExp _yearRe = RegExp(r'\d{4}');

/// First 4-digit year in a release string (gallery `extract_year`).
String extractYear(String? release) {
  if (release == null || release.isEmpty) return '';
  return _yearRe.firstMatch(release)?.group(0) ?? '';
}

/// One ZIP variant of a card (`gallery.py _build_cracked_cards`).
class CardVariant {
  const CardVariant({
    required this.rel,
    required this.name,
    required this.status,
    required this.layer,
    this.kind,
    this.previewPath,
    this.candidatePaths = const [],
    this.size,
  });

  final String rel;
  final String name;
  final String status;
  final String layer;

  /// Preview classification of the variant's main image (`game`/`desktop`/
  /// `textscreen`/`darkscreen`), null when the index has none — feeds the
  /// `desktop text`/`desktop black` filters and the "This ZIP" info row.
  final String? kind;

  /// Absolute PNG path (gallery `_full_png`: `dirname(rel)/basename`),
  /// no existence check — the widget errorBuilder shows a placeholder.
  final String? previewPath;
  final List<String> candidatePaths;
  final int? size;
}

/// Flattened first-XLS-variant info for display (gallery
/// `_variant_info_summary`); `variants` keeps the raw gameinfo variants.
class InfoSummary {
  const InfoSummary({
    required this.title,
    required this.publisher,
    required this.crackedBy,
    required this.crew,
    required this.introCode,
    required this.language,
    required this.disks,
    required this.rawDump,
    required this.pastiDump,
    required this.boxscan,
    required this.release,
    required this.tosBad,
    required this.specialFlag,
    required this.specialNote,
    required this.version,
    required this.company,
    required this.licence,
    required this.addInfo,
    required this.cracktro,
    required this.screenFormat,
    required this.variants,
  });

  factory InfoSummary.fromGame(GameInfo g) {
    final v0 = g.variants.isEmpty ? const <String, dynamic>{} : g.variants.first;
    String s(String key) => (v0[key] ?? '') as String;
    return InfoSummary(
      title: s('title').isNotEmpty ? s('title') : g.matchedTitle,
      publisher: s('publisher'),
      crackedBy: s('cracked_by'),
      crew: s('crew'),
      introCode: s('intro_code'),
      language: s('language'),
      disks: v0['disks'],
      rawDump: v0['raw_dump'] == true,
      pastiDump: v0['pasti_dump'] == true,
      boxscan: v0['boxscan'] == true,
      release: s('release'),
      tosBad: s('tos_bad'),
      specialFlag: s('special_flag'),
      specialNote: s('special_note'),
      version: s('version'),
      company: s('company'),
      licence: s('licence'),
      addInfo: s('add_info'),
      cracktro: s('cracktro'),
      screenFormat: s('screen_format'),
      variants: g.variants,
    );
  }

  final String title;
  final String publisher;
  final String crackedBy;
  final String crew;
  final String introCode;
  final String language;
  final dynamic disks;
  final bool rawDump;
  final bool pastiDump;
  final bool boxscan;
  final String release;
  final String tosBad;
  final String specialFlag;
  final String specialNote;
  final String version;
  final String company;
  final String licence;
  final String addInfo;
  final String cracktro;
  final String screenFormat;
  final List<Map<String, dynamic>> variants;
}

/// One catalog card (= game folder for cracked/pd/utils), equivalent to a
/// gallery card (`gallery.py _build_cracked_cards` / `_build_simple_cards`).
class GameCard {
  GameCard({
    required this.id,
    required this.name,
    required this.letter,
    required this.folder,
    required this.displayStatus,
    required this.screenshots,
    required this.statusCounts,
    required this.layer,
    required this.year,
    required this.previewPath,
    required this.variants,
    required this.info,
    required this.yearNum,
    required this.publishers,
    required this.crews,
    required this.crackers,
    required this.languages,
    required this.raw,
    required this.pasti,
    required this.boxscan,
    required this.tos,
    required this.publisherSort,
    required this.crewSort,
    required this.crackerSort,
    required this.languageSort,
    required this.searchText,
    this.focusVariant,
  });

  final String id;
  final String name;
  final String letter;
  final String folder;
  final String displayStatus;
  final bool screenshots;
  final Map<String, int> statusCounts;
  final String layer;
  final String year;
  final String? previewPath;
  final List<CardVariant> variants;
  final InfoSummary? info;

  final int yearNum;
  final List<String> publishers;
  final List<String> crews;
  final List<String> crackers;
  final List<String> languages;
  final bool? raw;
  final bool? pasti;
  final bool? boxscan;
  final bool tos;
  final String publisherSort;
  final String crewSort;
  final String crackerSort;
  final String languageSort;
  final String searchText;

  /// Index of the ZIP variant focused by an active crew/cracker filter
  /// (gallery `_apply_focus`): `null` when no focus filter applies, `-1`
  /// when the filter is active but no ZIP could be identified for it,
  /// otherwise the focused variant index.
  final int? focusVariant;

  /// True while a crew/cracker focus filter has been applied to the card
  /// (gallery `focus_variant != null`).
  bool get focusActive => focusVariant != null;

  /// Sort tie key (gallery `_tie`): `(name.lower, firstVariantRel)`.
  int tieCompare(GameCard other) {
    final byName = name.toLowerCase().compareTo(other.name.toLowerCase());
    if (byName != 0) return byName;
    final a = variants.isNotEmpty ? variants.first.rel : name;
    final b = other.variants.isNotEmpty ? other.variants.first.rel : other.name;
    return a.compareTo(b);
  }

  /// Cards without a year always sort last (both directions).
  bool get hasUnknownYear => yearNum == 0;
}

/// Sorts case-insensitively-unique values like the gallery's `sorted(set(..))`.
List<String> _sortedSet(Iterable<String> values) {
  final set = values.where((v) => v.trim().isNotEmpty).toSet();
  final list = set.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return list;
}

String _minLower(Iterable<String> values) {
  final list =
      values.where((v) => v.trim().isNotEmpty).toList();
  if (list.isEmpty) return '';
  list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return list.first;
}

/// Builds a cracked card from grouped index entries (gallery
/// `_build_cracked_cards` + `_finalize_card`, kind `cracked`).
GameCard buildCrackedCard({
  required String letter,
  required String folder,
  required List<(String, ScreenshotEntry)> items,
  required GameInfo? game,
  required String? Function(String rel, String? baseName) fullPng,
}) {
  items.sort((a, b) => a.$1.compareTo(b.$1));
  final variants = <CardVariant>[];
  final scounts = <String, int>{};
  final layers = <String>{};
  for (final (rel, e) in items) {
    final st = e.status.isEmpty ? 'unknown' : e.status;
    scounts[st] = (scounts[st] ?? 0) + 1;
    if (e.layer.isNotEmpty) layers.add(e.layer);
    variants.add(CardVariant(
      rel: rel,
      name: e.name.isEmpty ? rel.split('/').last : e.name,
      status: st,
      layer: e.layer,
      kind: (e.kind == null || e.kind!.isEmpty) ? null : e.kind,
      previewPath: fullPng(rel, e.preview),
      candidatePaths:
          e.candidates.map((c) => fullPng(rel, c)).whereType<String>().toList(),
      size: e.size,
    ));
  }
  var displayStatus = 'pending';
  for (final s in kStatusOrder) {
    if ((scounts[s] ?? 0) > 0) {
      displayStatus = s;
      break;
    }
  }
  String? preview;
  for (final v in variants) {
    if (v.status == 'done' && v.previewPath != null) {
      preview = v.previewPath;
      break;
    }
  }
  preview ??= _firstDesktopPreview(variants);
  final layer = layers.length == 1
      ? layers.first
      : (layers.isEmpty ? '' : 'BOTH');
  final info = game == null ? null : InfoSummary.fromGame(game);
  return _finalizeCard(
    id: '$letter/$folder',
    name: folder,
    letter: letter,
    folder: folder,
    displayStatus: displayStatus,
    screenshots: preview != null,
    statusCounts: scounts,
    layer: layer,
    previewPath: preview,
    variants: variants,
    info: info,
    kind: 'cracked',
  );
}

String? _firstDesktopPreview(List<CardVariant> variants) {
  for (final v in variants) {
    if (v.status == 'desktop' && v.previewPath != null) return v.previewPath;
  }
  return null;
}

/// Builds a pd/utils card from a gameinfo record (gallery
/// `_build_simple_cards`).
GameCard buildSimpleCard({required GameInfo game, required String kind}) {
  final layers = game.layers;
  final layer =
      layers.length > 1 ? 'BOTH' : (layers.isEmpty ? '' : layers.first);
  final info = InfoSummary.fromGame(game);
  return _finalizeCard(
    id: '${game.letter}/${game.folder}',
    name: game.folder,
    letter: game.letter,
    folder: game.folder,
    displayStatus: '',
    screenshots: false,
    statusCounts: const {},
    layer: layer,
    previewPath: null,
    variants: const [],
    info: info,
    kind: kind,
  );
}

GameCard _finalizeCard({
  required String id,
  required String name,
  required String letter,
  required String folder,
  required String displayStatus,
  required bool screenshots,
  required Map<String, int> statusCounts,
  required String layer,
  required String? previewPath,
  required List<CardVariant> variants,
  required InfoSummary? info,
  required String kind,
}) {
  final years = <int>[];
  final pubs = <String>[], crews = <String>[], crackers = <String>[],
      langs = <String>[];
  final raws = <bool>[], pastis = <bool>[], boxes = <bool>[],
      tosNotes = <bool>[];
  if (info != null) {
    for (final v in info.variants) {
      final y = extractYear(v['release'] as String?);
      if (y.isNotEmpty) years.add(int.parse(y));
      void bucket(List<String> target, String key) {
        final val = (v[key] ?? '') as String;
        if (val.trim().isNotEmpty) target.add(val);
      }

      bucket(pubs, 'publisher');
      bucket(crews, 'crew');
      bucket(crackers, 'cracked_by');
      bucket(langs, 'language');
      if (kind == 'cracked') {
        raws.add(v['raw_dump'] == true);
        pastis.add(v['pasti_dump'] == true);
        boxes.add(v['boxscan'] == true);
      } else if (kind == 'utils') {
        raws.add(v['raw_dump'] == true);
      }
      final tos = (v['tos_bad'] ?? '') as String;
      if (tos.trim().isNotEmpty) tosNotes.add(true);
    }
  }
  final yearNum = years.isEmpty ? 0 : years.reduce((a, b) => a < b ? a : b);

  final searchParts = <String>[
    name,
    letter,
    folder,
    for (final v in variants) v.name,
    for (final v in variants) v.rel,
    _infoSearchText(info),
  ];
  return GameCard(
    id: id,
    name: name,
    letter: letter,
    folder: folder,
    displayStatus: displayStatus,
    screenshots: screenshots,
    statusCounts: statusCounts,
    layer: layer,
    year: yearNum == 0 ? 'unknown' : '$yearNum',
    previewPath: previewPath,
    variants: variants,
    info: info,
    yearNum: yearNum,
    publishers: _sortedSet(pubs),
    crews: _sortedSet(crews),
    crackers: _sortedSet(crackers),
    languages: _sortedSet(langs),
    raw: raws.isEmpty ? null : raws.any((b) => b),
    pasti: pastis.isEmpty ? null : pastis.any((b) => b),
    boxscan: boxes.isEmpty ? null : boxes.any((b) => b),
    tos: tosNotes.any((b) => b),
    publisherSort: _minLower(pubs),
    crewSort: _minLower(crews),
    crackerSort: _minLower(crackers),
    languageSort: _minLower(langs),
    searchText: searchParts.where((p) => p.isNotEmpty).join(' ').toLowerCase(),
  );
}

/// Lowercased concat of folder, matched_title and every field of every XLS
/// variant (gallery `_info_search_text`). The summary has no folder /
/// matched_title keys — matching the gallery's effective behaviour.
String _infoSearchText(InfoSummary? info) {
  if (info == null) return '';
  final parts = <String>[];
  for (final v in info.variants) {
    for (final value in v.values) {
      parts.add('$value');
    }
  }
  return parts.join(' ').toLowerCase();
}

/// Normalize a group string (crew/cracker) for fuzzy matching
/// (gallery `_norm_crew`): lowercases, expands `&`/`+` to "and" and
/// collapses whitespace so e.g. "Equinox & MDK" matches "Equinox and MDK".
String normCrew(String? s) {
  var out = (s ?? '').trim().toLowerCase();
  out = out.replaceAll(RegExp(r'\s*[&+]\s*'), ' and ');
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

const Set<String> _crewStopwords = {
  'and', 'the', 'co', 'crew', 'inc', 'ltd', 'team', 'software'
};

final RegExp _alnumRe = RegExp(r'[a-z0-9]+');

/// Tokenize a group string: alphanumeric, no stopwords, length >= 2
/// (gallery `_crew_tokens`).
List<String> crewTokens(String? s) {
  final raw = _alnumRe.allMatches((s ?? '').toLowerCase());
  return [
    for (final m in raw)
      if (!_crewStopwords.contains(m.group(0)) &&
          m.group(0)!.length >= 2)
        m.group(0)!,
  ];
}

/// First matching index whose variant has a screenshot preview, otherwise
/// the first (gallery `_first_with_preview`).
int _firstWithPreview(List<CardVariant> variants, List<int> indices) {
  for (final i in indices) {
    if (variants[i].previewPath != null) return i;
  }
  return indices.first;
}

/// Index of the ZIP variant that belongs to [value], or -1
/// (gallery `_focus_variant`). [kind] is `'crew'` or `'cracker'`.
///
/// Matching is tried in increasing fuzziness:
///   1) normalized [value] is a substring of the normalized ZIP name;
///   2) (crew only) a gameinfo variant with this crew whose `cracked_by`
///      appears in a ZIP name;
///   3) token subset: all tokens (ignoring stopwords) appear in the ZIP
///      name, requiring at least one token with length >= 3.
/// Among multiple matches the first with a screenshot preview wins.
int focusVariant(GameCard card, String value, String kind) {
  final valueN = normCrew(value);
  if (valueN.isEmpty) return -1;
  final variants = card.variants;
  // 1) normalized substring match
  final subs = <int>[
    for (var i = 0; i < variants.length; i++)
      if (normCrew(variants[i].name).contains(valueN)) i,
  ];
  if (subs.isNotEmpty) return _firstWithPreview(variants, subs);
  // 2) (crew only) gameinfo variant with this crew → its cracker in names
  if (kind == 'crew') {
    for (final iv in card.info?.variants ?? const <Map<String, dynamic>>[]) {
      if (normCrew((iv['crew'] ?? '') as String) != valueN) continue;
      final cracker = ((iv['cracked_by'] ?? '') as String).trim().toLowerCase();
      if (cracker.isEmpty) continue;
      final hits = <int>[
        for (var i = 0; i < variants.length; i++)
          if (variants[i].name.toLowerCase().contains(cracker)) i,
      ];
      if (hits.isNotEmpty) return _firstWithPreview(variants, hits);
    }
  }
  // 3) token subset match (typo / missing connective tolerant)
  final tokens = crewTokens(value);
  if (tokens.isNotEmpty && tokens.any((t) => t.length >= 3)) {
    final hits = <int>[];
    for (var i = 0; i < variants.length; i++) {
      final nameTokens =
          _alnumRe.allMatches(variants[i].name.toLowerCase()).map((m) => m.group(0)!).toSet();
      if (tokens.every(nameTokens.contains)) hits.add(i);
    }
    if (hits.isNotEmpty) return _firstWithPreview(variants, hits);
  }
  return -1;
}

/// Shallow-adjusted copy of [card] focused on the group variant
/// (gallery `_apply_focus`): sets `focusVariant` and overrides
/// preview / display status / screenshots of the payload — even when the
/// focused variant has no screenshot (empty preview → placeholder).
/// Sets `focusVariant = -1` when the filter is active but no ZIP could be
/// identified.
GameCard applyFocus(GameCard card, String value, String kind) {
  final focus = focusVariant(card, value, kind);
  if (focus < 0) {
    return _copyCard(card, focusVariant: -1, previewPath: null, screenshots: false);
  }
  final v = card.variants[focus];
  return _copyCard(
    card,
    focusVariant: focus,
    previewPath: v.previewPath,
    displayStatus: v.status,
    screenshots: v.previewPath != null,
  );
}

GameCard _copyCard(
  GameCard card, {
  required int focusVariant,
  String? previewPath,
  String? displayStatus,
  bool? screenshots,
}) {
  return GameCard(
    id: card.id,
    name: card.name,
    letter: card.letter,
    folder: card.folder,
    displayStatus: displayStatus ?? card.displayStatus,
    screenshots: screenshots ?? card.screenshots,
    statusCounts: card.statusCounts,
    layer: card.layer,
    year: card.year,
    previewPath: previewPath,
    variants: card.variants,
    info: card.info,
    yearNum: card.yearNum,
    publishers: card.publishers,
    crews: card.crews,
    crackers: card.crackers,
    languages: card.languages,
    raw: card.raw,
    pasti: card.pasti,
    boxscan: card.boxscan,
    tos: card.tos,
    publisherSort: card.publisherSort,
    crewSort: card.crewSort,
    crackerSort: card.crackerSort,
    languageSort: card.languageSort,
    searchText: card.searchText,
    focusVariant: focusVariant,
  );
}
