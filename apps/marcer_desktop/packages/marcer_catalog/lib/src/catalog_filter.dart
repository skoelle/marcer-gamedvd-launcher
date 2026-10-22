// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'card.dart';

/// API filter names applicable to a section (gallery `kind_filters`).
Set<String> kindFilters(String kind) => switch (kind) {
      'pd' => {
          'publisher',
          'genre',
          'developer',
          'language',
          'year',
          'tos',
        },
      'magazine' => {'year'},
      'falcon' => const {},
      'utils' => {
          'publisher',
          'genre',
          'developer',
          'crew',
          'cracker',
          'language',
          'year',
          'raw',
          'tos',
        },
      _ => {
          'publisher',
          'genre',
          'developer',
          'crew',
          'cracker',
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
    this.genre = 'any',
    this.developer = 'any',
    this.crew = 'any',
    this.cracker = 'any',
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
  String genre;
  String developer;
  String crew;
  String cracker;
  String language;
  String year;
  String raw;
  String pasti;
  String boxscan;
  String tos;
  String sort;
  String order;

  /// Status value considered "default" (gallery `default_status` config);
  /// [isActive] and [reset] use it instead of a hardcoded value.
  String factoryStatus = 'with_screenshot';

  /// True when anything deviates from the factory state — the app is in
  /// catalog (global) mode while active.
  bool get isActive =>
      status != factoryStatus ||
      q.trim().isNotEmpty ||
      letter != 'any' ||
      publisher != 'any' ||
      genre != 'any' ||
      developer != 'any' ||
      crew != 'any' ||
      cracker != 'any' ||
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
    status = factoryStatus;
    q = '';
    letter = 'any';
    publisher = 'any';
    genre = 'any';
    developer = 'any';
    crew = 'any';
    cracker = 'any';
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
        genre: genre,
        developer: developer,
        crew: crew,
        cracker: cracker,
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
  final crewActive = f.crew != 'any' && fields.contains('crew');
  final crackerActive = f.cracker != 'any' && fields.contains('cracker');
  final focusActive = crewActive || crackerActive;
  // Status/kind filters apply to every section; all sections use the
  // configured `DefaultStatus` on startup.
  if (f.status == 'with_screenshot') {
    // crew/cracker focus always shows the focused variant, even empty
    if (!focusActive && !c.screenshots) return false;
  } else if (f.status == 'desktop_text') {
    // strict: only a status-desktop variant whose kind is textscreen
    if (!c.variants
        .any((v) => v.status == 'desktop' && v.kind == 'textscreen')) {
      return false;
    }
  } else if (f.status == 'desktop_black') {
    if (!c.variants
        .any((v) => v.status == 'desktop' && v.kind == 'darkscreen')) {
      return false;
    }
  } else if (f.status == 'desktop_any') {
    if (!c.variants.any((v) => v.status == 'desktop')) return false;
  } else if (f.status == 'no_usable_shots_any') {
    if (!c.variants.any((v) => v.status == 'no_usable_shots')) return false;
  } else if (f.status == 'pending') {
    // App-only: a game counts as pending as soon as **any** of its ZIPs
    // is pending (the gallery's aggregated display_status would hide
    // pending ZIPs behind done folders — user decision 2026-10-15).
    if (!c.variants.any((v) => v.status == 'pending')) return false;
  } else if (f.status == 'interrupted' || f.status == 'skipped_disk_n') {
    // Same any-ZIP rule: these are ZIP-level failure/skip states, so a card
    // with a done ZIP must still be reachable from the filter.
    if (!c.variants.any((v) => v.status == f.status)) return false;
  } else if (f.status != 'any' && c.displayStatus != f.status) {
    return false;
  }
  if (f.letter != 'any' && c.letter != f.letter) return false;
  final q = f.q.trim().toLowerCase();
  if (q.isNotEmpty && !c.searchText.contains(q)) return false;

  if (f.publisher != 'any') {
    if (!fields.contains('publisher') || !c.publishers.contains(f.publisher)) {
      return false;
    }
  }
  // AtariLegend facets (available when the cache is present; unmatched cards
  // never match an active genre/developer filter).
  if (f.genre != 'any') {
    if (!(c.atariLegend?.genres.contains(f.genre) ?? false)) return false;
  }
  if (f.developer != 'any') {
    if (!(c.atariLegend?.developers.contains(f.developer) ?? false)) {
      return false;
    }
  }
  if (f.crew != 'any') {
    if (!fields.contains('crew') || !c.crews.contains(f.crew)) return false;
  }
  if (f.cracker != 'any') {
    if (!fields.contains('cracker') || !c.crackers.contains(f.cracker)) {
      return false;
    }
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
///
/// The comparators only read precomputed keys (`GameCard.sortName` and the
/// lowercased `*Sort` fields) — no `toLowerCase()`/allocation inside the sort.
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

  bool isUnknown(GameCard c) =>
      sort == 'year' ? c.yearNum == 0 : primStr(c).isEmpty;

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
      final cmp = primStr(a).compareTo(primStr(b));
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
/// grid virtualizes instead). When a crew/cracker filter is active the
/// returned cards are focus-adjusted copies (gallery `_apply_focus`):
/// preview / status / `focusVariant` reflect the group's ZIP variant.
/// Cracker takes precedence over crew (SPEC-gallery-webapp.md §5.3).
List<GameCard> queryCards(List<GameCard> cards, CatalogFilter f) {
  final out = cards.where((c) => matchesCard(c, f)).toList();
  sortCards(out, f.sort, f.order);
  final fields = kindFilters(f.section);
  if (f.cracker != 'any' && fields.contains('cracker')) {
    return [for (final c in out) applyFocus(c, f.cracker, 'cracker')];
  }
  if (f.crew != 'any' && fields.contains('crew')) {
    return [for (final c in out) applyFocus(c, f.crew, 'crew')];
  }
  return out;
}
