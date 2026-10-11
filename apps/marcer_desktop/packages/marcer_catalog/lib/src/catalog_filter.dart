// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'card.dart';

/// API filter names applicable to a section (gallery `kind_filters`).
Set<String> kindFilters(String kind) => switch (kind) {
      'pd' => {'publisher', 'language', 'year', 'tos'},
      'utils' =>
        {'publisher', 'crew', 'language', 'year', 'raw', 'tos'},
      _ => {
          'publisher',
          'crew',
          'language',
          'year',
          'raw',
          'pasti',
          'boxscan',
          'tos',
        },
    };

/// Filter state of the global catalog view — field values and defaults are
/// identical to the gallery UI (`app.js` state / `gallery.py _matches`).
class CatalogFilter {
  CatalogFilter({
    this.section = 'cracked',
    this.status = 'with_screenshot',
    this.q = '',
    this.letter = 'any',
    this.publisher = 'any',
    this.crew = 'any',
    this.language = 'any',
    this.year = 'any',
    this.raw = 'any',
    this.pasti = 'any',
    this.boxscan = 'any',
    this.tos = 'any',
    this.sort = 'name',
    this.order = 'asc',
  });

  String section;
  String status;
  String q;
  String letter;
  String publisher;
  String crew;
  String language;
  String year;
  String raw;
  String pasti;
  String boxscan;
  String tos;
  String sort;
  String order;

  /// True when anything deviates from the factory state — the app is in
  /// catalog (global) mode while active.
  bool get isActive =>
      status != 'with_screenshot' ||
      q.trim().isNotEmpty ||
      letter != 'any' ||
      publisher != 'any' ||
      crew != 'any' ||
      language != 'any' ||
      year != 'any' ||
      raw != 'any' ||
      pasti != 'any' ||
      boxscan != 'any' ||
      tos != 'any' ||
      sort != 'name' ||
      order != 'asc';

  /// Gallery `clear`: resets status/search/facets/flags/sort — the section
  /// tab is intentionally kept.
  void reset() {
    status = 'with_screenshot';
    q = '';
    letter = 'any';
    publisher = 'any';
    crew = 'any';
    language = 'any';
    year = 'any';
    raw = 'any';
    pasti = 'any';
    boxscan = 'any';
    tos = 'any';
    sort = 'name';
    order = 'asc';
  }

  CatalogFilter copy() => CatalogFilter(
        section: section,
        status: status,
        q: q,
        letter: letter,
        publisher: publisher,
        crew: crew,
        language: language,
        year: year,
        raw: raw,
        pasti: pasti,
        boxscan: boxscan,
        tos: tos,
        sort: sort,
        order: order,
      );
}

/// Port of `gallery.py _matches`.
bool matchesCard(GameCard c, CatalogFilter f) {
  final fields = kindFilters(f.section);
  final crewActive =
      f.crew != 'any' && fields.contains('crew');
  if (f.section == 'cracked') {
    if (f.status == 'with_screenshot') {
      if (!crewActive && !c.screenshots) return false;
    } else if (f.status != 'any' && c.displayStatus != f.status) {
      return false;
    }
  }
  if (f.letter != 'any' && c.letter != f.letter) return false;
  final q = f.q.trim().toLowerCase();
  if (q.isNotEmpty && !c.searchText.contains(q)) return false;

  if (f.publisher != 'any') {
    if (!fields.contains('publisher') || !c.publishers.contains(f.publisher)) {
      return false;
    }
  }
  if (f.crew != 'any') {
    if (!fields.contains('crew') || !c.crews.contains(f.crew)) return false;
  }
  if (f.language != 'any') {
    if (!fields.contains('language') || !c.languages.contains(f.language)) {
      return false;
    }
  }
  if (f.year != 'any' && c.year != f.year) return false;

  for (final (flag, value) in [
    ('raw', f.raw),
    ('pasti', f.pasti),
    ('boxscan', f.boxscan),
  ]) {
    if (value == 'any') continue;
    final tri = switch (flag) {
      'raw' => c.raw,
      'pasti' => c.pasti,
      _ => c.boxscan,
    };
    if (!fields.contains(flag) || tri == null) return false;
    if (value == 'yes' && !tri) return false;
    if (value == 'no' && tri) return false;
  }
  if (f.tos == 'has' && !c.tos) return false;
  return true;
}

/// Port of `gallery.py _sort_cards` (deterministic comparators; Dart's
/// `List.sort` is unstable, so tie-breaks are explicit).
void sortCards(List<GameCard> cards, String sort, String order) {
  if (!kSortKeys.contains(sort)) sort = 'name';
  final desc = order == 'desc';
  if (sort == 'name') {
    cards.sort((a, b) {
      final cmp = a.tieCompare(b);
      return desc ? -cmp : cmp;
    });
    return;
  }

  String primStr(GameCard c) => switch (sort) {
        'publisher' => c.publisherSort,
        'cracker' => c.crackerSort,
        'crew' => c.crewSort,
        _ => '',
      };

  bool isUnknown(GameCard c) => sort == 'year' ? c.yearNum == 0 : primStr(c).isEmpty;

  final known = cards.where((c) => !isUnknown(c)).toList();
  final unknown = cards.where(isUnknown).toList();
  unknown.sort((a, b) => a.tieCompare(b));

  if (sort == 'year') {
    known.sort((a, b) {
      final cmp = desc
          ? b.yearNum.compareTo(a.yearNum)
          : a.yearNum.compareTo(b.yearNum);
      return cmp != 0 ? cmp : a.tieCompare(b);
    });
  } else {
    known.sort((a, b) {
      final cmp = primStr(a)
          .toLowerCase()
          .compareTo(primStr(b).toLowerCase());
      final ordered = desc ? -cmp : cmp;
      return ordered != 0 ? ordered : a.tieCompare(b);
    });
  }
  cards
    ..clear()
    ..addAll(known)
    ..addAll(unknown);
}

/// Filter + sort (gallery request pipeline without pagination — the desktop
/// grid virtualizes instead).
List<GameCard> queryCards(List<GameCard> cards, CatalogFilter f) {
  final out = cards.where((c) => matchesCard(c, f)).toList();
  sortCards(out, f.sort, f.order);
  return out;
}
