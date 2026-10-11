// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String outDir;
  late String dataDir;

  const relA = 'Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.zip';
  const relA2 = 'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Alpha v2.zip';
  const relB = 'Title Sorted/Cracked Games - Title Sorted/B/Beta/beta.zip';
  const relB9 = 'Title Sorted/Cracked Games - Title Sorted/0-9/999/999.zip';

  String entryJson(String rel, String status, String layer,
          {String? preview, List<String> candidates = const [], int? size}) =>
      jsonEncode({
        'rel': rel,
        'name': rel.split('/').last,
        'status': status,
        'kind': status == 'done' ? 'game' : null,
        'layer': layer,
        'preview': preview,
        'candidates': candidates,
        'size': size ?? 1000,
      });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('universe_test');
    outDir = '${tmp.path}/out';
    dataDir = '${tmp.path}/data';
    Directory('$outDir/A/Alpha').createSync(recursive: true);
    Directory('$outDir/B/Beta').createSync(recursive: true);
    File('$outDir/A/Alpha/a.png').createSync();
    File('$outDir/B/Beta/beta.png').createSync();
    Directory(dataDir).createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  CatalogUniverse buildUniverse(Map<String, String> entries,
      {String crackedGames = '[]', String pdGames = '[]'}) {
    File('$outDir/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        for (final e in entries.entries) e.key: jsonDecode(e.value),
      },
    }));
    File('$dataDir/games-cracked.json').writeAsStringSync(
        jsonEncode({'schema_version': 1, 'kind': 'cracked', 'games': jsonDecode(crackedGames)}));
    File('$dataDir/games-pd.json').writeAsStringSync(
        jsonEncode({'schema_version': 1, 'kind': 'pd', 'games': jsonDecode(pdGames)}));
    File('$dataDir/games-utils.json')
        .writeAsStringSync(jsonEncode({'schema_version': 1, 'kind': 'utils', 'games': []}));
    final index = ScreenshotIndex.load(outDir);
    final info = GameInfoIndex.load(dataDir);
    return CatalogUniverse.build(index: index, info: info, outDir: outDir);
  }

  group('CatalogUniverse.build (cracked cards)', () {
    test('groups variants, aggregates display status, prefers done preview', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
        relA2: entryJson(relA2, 'pending', 'PATCH'),
      });
      expect(u.cracked.length, 1);
      final card = u.cracked.first;
      expect(card.letter, 'A');
      expect(card.folder, 'Alpha');
      expect(card.variants.length, 2);
      expect(card.displayStatus, 'done');
      expect(card.layer, 'BOTH');
      expect(card.screenshots, isTrue);
      expect(
          card.previewPath,
          '$outDir/Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.png');
      expect(card.statusCounts, {'done': 1, 'pending': 1});
    });

    test('display status priority: no_usable_shots beats pending', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'pending', 'ROOT'),
        relA2: entryJson(relA2, 'no_usable_shots', 'ROOT'),
      });
      expect(u.cracked.first.displayStatus, 'no_usable_shots');
      expect(u.cracked.first.screenshots, isFalse);
      expect(u.cracked.first.previewPath, isNull);
    });

    test('desktop preview fallback when no done preview', () {
      final u = buildUniverse({
        relB: entryJson(relB, 'desktop', 'ROOT', preview: 'beta.png'),
      });
      final card = u.cracked.first;
      expect(card.displayStatus, 'desktop');
      expect(card.screenshots, isTrue);
      expect(
          card.previewPath,
          '$outDir/Title Sorted/Cracked Games - Title Sorted/B/Beta/beta.png');
    });

    test('single layer stays, candidates resolve against rel dir', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'PATCH', preview: 'a.png',
            candidates: ['a_c01.png']),
      });
      expect(u.cracked.first.layer, 'PATCH');
      expect(
          u.cracked.first.variants.first.candidatePaths,
          [
            '$outDir/Title Sorted/Cracked Games - Title Sorted/A/Alpha/a_c01.png'
          ]);
    });
  });

  group('CatalogUniverse facets + simple cards', () {
    test('facets per section, letters 0-9 first, crew only cracked/utils', () {
      const cracked = '''
      [{"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Alpha",
        "variants": [{"title": "Alpha", "publisher": "Publisher A",
          "crew": "The Crew", "language": "English", "release": "1990"}]}]
      ''';
      const pd = '''
      [{"letter": "0-9", "folder": "999", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "999",
        "variants": [{"title": "999", "publisher": "Pub B",
          "language": "German", "release": "12-03-1991"}]}]
      ''';
      final u = buildUniverse(
        {
          relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
          relB9: entryJson(relB9, 'done', 'ROOT'),
        },
        crackedGames: cracked,
        pdGames: pd,
      );
      expect(u.crackedFacets.publishers, ['Publisher A']);
      expect(u.crackedFacets.crews, ['The Crew']);
      expect(u.crackedFacets.languages, ['English']);
      expect(u.crackedFacets.years, ['1990']);
      expect(u.crackedFacets.letters.first, '0-9');
      expect(u.pdFacets.crews, isEmpty);
      expect(u.pdFacets.years, ['1991']);
      expect(u.pd.length, 1);
      expect(u.pd.first.displayStatus, '');
      expect(u.pd.first.layer, 'ROOT');
      expect(u.crackedWithScreenshot, 1); // relB9 has no preview basename
      expect(u.crackedVariants, 2);
    });
  });

  group('CatalogFilter.matchesCard', () {
    late CatalogUniverse u;
    late GameCard alpha;
    late GameCard noShot;

    setUp(() {
      const cracked = '''
      [{"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Alpha Game",
        "variants": [{"title": "Alpha Game", "publisher": "Publisher A",
          "crew": "The Crew", "cracked_by": "Crackerman",
          "language": "English", "release": "1990",
          "raw_dump": true, "tos_bad": "needs TOS 1.4"}]}]
      ''';
      u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
        relB: entryJson(relB, 'pending', 'ROOT'),
      }, crackedGames: cracked);
      alpha = u.cracked.firstWhere((c) => c.folder == 'Alpha');
      noShot = u.cracked.firstWhere((c) => c.folder == 'Beta');
    });

    test('default status with_screenshot keeps only screenshot cards', () {
      final f = CatalogFilter();
      expect(matchesCard(alpha, f), isTrue);
      expect(matchesCard(noShot, f), isFalse);
      f.status = 'any';
      expect(matchesCard(noShot, f), isTrue);
      f.status = 'pending';
      expect(matchesCard(noShot, f), isTrue);
      expect(matchesCard(alpha, f), isFalse);
    });

    test('letter and search query', () {
      var f = CatalogFilter()..letter = 'A';
      expect(matchesCard(alpha, f), isTrue);
      expect(matchesCard(noShot, f), isFalse);
      f = CatalogFilter()..q = 'alpha game';
      expect(matchesCard(alpha, f), isTrue);
      expect(matchesCard(noShot, f), isFalse);
      f = CatalogFilter()..q = 'crackerman'; // gameinfo variant text
      expect(matchesCard(alpha, f), isTrue);
      f = CatalogFilter()..q = 'nothing-here';
      expect(matchesCard(alpha, f), isFalse);
    });

    test('facets: publisher, year, tri-state raw and tos', () {
      var f = CatalogFilter()..publisher = 'Publisher A';
      expect(matchesCard(alpha, f), isTrue);
      f = CatalogFilter()..year = '1990';
      expect(matchesCard(alpha, f), isTrue);
      f = CatalogFilter()..year = '1991';
      expect(matchesCard(alpha, f), isFalse);
      f = CatalogFilter()..raw = 'yes';
      expect(matchesCard(alpha, f), isTrue);
      expect(matchesCard(noShot, f), isFalse); // None never matches
      f = CatalogFilter()..raw = 'no';
      expect(matchesCard(alpha, f), isFalse);
      f = CatalogFilter()..tos = 'has';
      expect(matchesCard(alpha, f), isTrue);
      f = CatalogFilter()..tos = 'any';
      expect(matchesCard(alpha, f), isTrue);
    });

    test('crew filter bypasses with_screenshot requirement', () {
      final f = CatalogFilter()..crew = 'The Crew';
      expect(matchesCard(alpha, f), isTrue);
      expect(matchesCard(noShot, f), isFalse); // no crew
      // crew on a non-screenshot card: build one with crew but pending
      const cracked = '''
      [{"letter": "B", "folder": "Beta", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Beta",
        "variants": [{"title": "Beta", "crew": "The Crew",
          "release": "1991"}]}]
      ''';
      final u2 = buildUniverse(
          {relB: entryJson(relB, 'pending', 'ROOT')},
          crackedGames: cracked);
      final b = u2.cracked.first;
      expect(b.screenshots, isFalse);
      expect(matchesCard(b, f), isTrue); // bypass
    });

    test('section-scoped filters reject when not applicable', () {
      // gallery _matches: flag set but not in section fields → False.
      final f = CatalogFilter()
        ..section = 'pd'
        ..raw = 'yes';
      expect(matchesCard(alpha, f), isFalse);
      final f2 = CatalogFilter()
        ..section = 'pd'
        ..publisher = 'No One';
      expect(matchesCard(alpha, f2), isFalse);
      final f3 = CatalogFilter()..section = 'pd';
      expect(matchesCard(alpha, f3), isTrue);
    });
  });

  group('sortCards', () {
    late List<GameCard> cards;

    setUp(() {
      const cracked = '''
      [
        {"letter": "A", "folder": "Zeta", "layers": ["ROOT"],
         "matched_via": "none", "matched_title": "",
         "variants": [{"title": "Zeta", "publisher": "Bovver", "release": "1991"}]},
        {"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
         "matched_via": "none", "matched_title": "",
         "variants": [{"title": "Alpha", "publisher": "Acme", "release": "1988"}]},
        {"letter": "C", "folder": "Mid", "layers": ["ROOT"],
         "matched_via": "none", "matched_title": "",
         "variants": [{"title": "Mid", "publisher": "Acme"}]}
      ]
      ''';
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT'), // groups into letter A / folder Alpha? no: A/Alpha
        relB: entryJson(relB, 'done', 'ROOT'), // B/Beta
      }, crackedGames: cracked);
      // cards: cracked index cards A/Alpha, B/Beta (no info) + info-only
      // folders are NOT cards (cards come from index) → build index entries
      // for every folder used above:
      final u2 = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT'),
        relB: entryJson(relB, 'done', 'ROOT'),
        'Title Sorted/Cracked Games - Title Sorted/A/Zeta/zeta.zip':
            entryJson('Title Sorted/Cracked Games - Title Sorted/A/Zeta/zeta.zip',
                'done', 'ROOT'),
        'Title Sorted/Cracked Games - Title Sorted/C/Mid/mid.zip':
            entryJson(
                'Title Sorted/Cracked Games - Title Sorted/C/Mid/mid.zip',
                'done', 'ROOT'),
      }, crackedGames: cracked);
      cards = u2.cracked;
      expect(u.cracked.length, 2); // sanity: index drives card creation
    });

    test('name asc/desc with full reverse', () {
      final list = [...cards];
      sortCards(list, 'name', 'asc');
      expect(list.map((c) => c.name).toList(), ['Alpha', 'Beta', 'Mid', 'Zeta']);
      sortCards(list, 'name', 'desc');
      expect(list.map((c) => c.name).toList(), ['Zeta', 'Mid', 'Beta', 'Alpha']);
    });

    test('year: unknown always last in both directions', () {
      final list = [...cards];
      sortCards(list, 'year', 'asc');
      expect(list.last.hasUnknownYear, isTrue);
      expect(list.map((c) => c.name).toList().first, 'Alpha');
      sortCards(list, 'year', 'desc');
      expect(list.last.hasUnknownYear, isTrue);
      expect(list.first.name, 'Zeta');
    });

    test('publisher: unknown last, ties keep name-asc even when desc', () {
      final list = [...cards];
      sortCards(list, 'publisher', 'desc');
      expect(list.last.publisherSort, isEmpty); // Mid has no publisher
      // Acme (Alpha) then Acme (Mid→unknown?) Mid has no publisher → unknown.
      // Known desc: Bovver(Zeta), Acme(Alpha) — desc by primary:
      expect(list.first.name, 'Zeta');
      expect(list[1].name, 'Alpha');
    });
  });

  group('CatalogFilter.reset / isActive', () {
    test('reset restores factory state but keeps section', () {
      final f = CatalogFilter()
        ..section = 'pd'
        ..q = 'foo'
        ..raw = 'yes'
        ..sort = 'year'
        ..order = 'desc';
      expect(f.isActive, isTrue);
      f.reset();
      expect(f.isActive, isFalse);
      expect(f.section, 'pd');
    });

    test('factoryStatus (gallery default_status config) drives isActive', () {
      final f = CatalogFilter()..factoryStatus = 'done';
      f.status = 'done';
      expect(f.isActive, isFalse); // configured default is not "active"
      f.status = 'with_screenshot';
      expect(f.isActive, isTrue);
      f.reset();
      expect(f.status, 'done');
    });
  });

  group('crew focus (gallery _apply_crew_focus)', () {
    test('focuses the ZIP whose name contains the crew', () {
      // rels sorted case-sensitively: 'Alpha the crew.zip' (0) < 'a.zip' (1).
      const cracked = '''
      [{"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Alpha Game",
        "variants": [{"title": "Alpha Game", "crew": "The Crew",
          "cracked_by": "Crackerman", "release": "1990"}]}]
      ''';
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
        'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Alpha the crew.zip':
            entryJson(
                'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Alpha the crew.zip',
                'pending',
                'ROOT'),
      }, crackedGames: cracked);
      final card = u.cracked.first;
      expect(card.variants.length, 2);

      final focused = applyCrewFocus(card, 'The Crew');
      expect(focused.focusVariant, 0);
      expect(focused.previewPath, isNull); // pending variant, no shot
      expect(focused.screenshots, isFalse);
      expect(focused.displayStatus, 'pending');
      expect(focused.name, card.name); // shallow copy keeps identity

      // default status would hide the pending card — crew bypass + focus
      final f = CatalogFilter()..crew = 'The Crew';
      final out = queryCards(u.cracked, f);
      expect(out.length, 1);
      expect(out.first.focusVariant, 0);
      expect(out.first.previewPath, isNull);
    });

    test('fallback: gameinfo crew variant matches cracker in ZIP name', () {
      // rels sorted: 'Crackerman - x.zip' (0) < 'a.zip' (1).
      const cracked = '''
      [{"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Alpha Game",
        "variants": [{"title": "Alpha Game", "crew": "The Crew",
          "cracked_by": "Crackerman", "release": "1990"}]}]
      ''';
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
        'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Crackerman - x.zip':
            entryJson(
                'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Crackerman - x.zip',
                'done',
                'ROOT',
                preview: 'a2.png'),
      }, crackedGames: cracked);
      final card = u.cracked.first;
      final focused = applyCrewFocus(card, 'The Crew');
      expect(focused.focusVariant, 0);
      expect(focused.previewPath, endsWith('/A/Alpha/a2.png'));
      expect(focused.screenshots, isTrue);
      expect(focused.displayStatus, 'done');
    });

    test('crew known but no ZIP identified → empty card, focus -1', () {
      const cracked = '''
      [{"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Alpha Game",
        "variants": [{"title": "Alpha Game", "crew": "The Crew",
          "release": "1990"}]}]
      ''';
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
      }, crackedGames: cracked);
      final card = u.cracked.first;
      final focused = applyCrewFocus(card, 'The Crew');
      expect(focused.focusVariant, -1);
      expect(focused.previewPath, isNull);
      expect(focused.screenshots, isFalse);
      // display status is untouched in the focus=-1 case (gallery: dict copy)
      expect(focused.displayStatus, card.displayStatus);

      final out = queryCards(u.cracked, CatalogFilter()..crew = 'The Crew');
      expect(out.single.focusVariant, -1);
      expect(out.single.previewPath, isNull);
    });

    test('no crew filter → cards pass through unchanged', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
      });
      final out = queryCards(u.cracked, CatalogFilter());
      expect(out.single.focusVariant, -1);
      expect(out.single.screenshots, isTrue);
      expect(out.single.previewPath, endsWith('/A/Alpha/a.png'));
    });
  });
}
