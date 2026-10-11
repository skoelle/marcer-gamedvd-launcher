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

/// Filter/status labels exactly as in the gallery UI (`gallery.py`
/// `STATUS_LABELS`).
const Map<String, String> kStatusLabels = {
  'done': 'done (game)',
  'desktop': 'desktop',
  'no_usable_shots': 'no usable shots',
  'interrupted': 'interrupted',
  'pending': 'pending',
  'skipped_disk_n': 'skipped (disk 2+)',
  'any': 'any status',
  'with_screenshot': 'with screenshot',
};

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
    this.previewPath,
    this.candidatePaths = const [],
    this.size,
  });

  final String rel;
  final String name;
  final String status;
  final String layer;

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
  required String Function(String rel, String? baseName) fullPng,
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
