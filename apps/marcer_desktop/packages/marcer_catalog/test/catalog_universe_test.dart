// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String screenshotDir;
  late String gameinfoDir;

  const relA = 'Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.zip';
  const relA2 = 'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Alpha v2.zip';
  const relB = 'Title Sorted/Cracked Games - Title Sorted/B/Beta/beta.zip';
  const relB2 = 'Title Sorted/Cracked Games - Title Sorted/B/Beta/beta2.zip';
  const relB9 = 'Title Sorted/Cracked Games - Title Sorted/0-9/999/999.zip';

  String entryJson(String rel, String status, String layer,
          {String? preview,
          List<String> candidates = const [],
          int? size,
          String? kindOverride,
          String? tos}) =>
      jsonEncode({
        'rel': rel,
        'name': rel.split('/').last,
        'status': status,
        'kind': kindOverride ?? (status == 'done' ? 'game' : null),
        'layer': layer,
        'preview': preview,
        'candidates': candidates,
        'size': size ?? 1000,
        'tos': ?tos,
      });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('universe_test');
    screenshotDir = '${tmp.path}/out';
    gameinfoDir = '${tmp.path}/data';
    Directory('$screenshotDir/A/Alpha').createSync(recursive: true);
    Directory('$screenshotDir/B/Beta').createSync(recursive: true);
    File('$screenshotDir/A/Alpha/a.png').createSync();
    File('$screenshotDir/B/Beta/beta.png').createSync();
    Directory(gameinfoDir).createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  CatalogUniverse buildUniverse(Map<String, String> entries,
      {String crackedGames = '[]',
      String pdGames = '[]',
      Map<String, String> pdEntries = const {},
      Map<String, String> utilsEntries = const {},
      Map<String, String> magazineEntries = const {},
      Map<String, String> falconEntries = const {},
      AtariLegendIndex? atariLegend}) {
    File('$screenshotDir/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        for (final e in entries.entries) e.key: jsonDecode(e.value),
      },
    }));
    File('$screenshotDir/index-pd.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        for (final e in pdEntries.entries) e.key: jsonDecode(e.value),
      },
    }));
    File('$screenshotDir/index-utils.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        for (final e in utilsEntries.entries) e.key: jsonDecode(e.value),
      },
    }));
    File('$screenshotDir/index-magazine.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        for (final e in magazineEntries.entries) e.key: jsonDecode(e.value),
      },
    }));
    File('$screenshotDir/index-falcon.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        for (final e in falconEntries.entries) e.key: jsonDecode(e.value),
      },
    }));
    File('$gameinfoDir/games-cracked.json').writeAsStringSync(
        jsonEncode({'schema_version': 1, 'kind': 'cracked', 'games': jsonDecode(crackedGames)}));
    File('$gameinfoDir/games-pd.json').writeAsStringSync(
        jsonEncode({'schema_version': 1, 'kind': 'pd', 'games': jsonDecode(pdGames)}));
    File('$gameinfoDir/games-utils.json')
        .writeAsStringSync(jsonEncode({'schema_version': 1, 'kind': 'utils', 'games': []}));
    final index = ScreenshotIndices.load(screenshotDir);
    final info = GameInfoIndex.load(gameinfoDir);
    return CatalogUniverse.build(
      indices: index,
      info: info,
      screenshotDir: screenshotDir,
      atariLegend: atariLegend,
    );
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
          '$screenshotDir/Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.png');
      expect(card.statusCounts, {'done': 1, 'pending': 1});
    });

    test('done preview prefers kind game over earlier textscreen', () {
      final u = buildUniverse({
        // 'Alpha v2.zip' sorts before 'a.zip' (ASCII) and must NOT win.
        relA2: entryJson(relA2, 'done', 'ROOT', preview: 'a2.png',
            kindOverride: 'textscreen'),
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
      });
      expect(
          u.cracked.first.previewPath,
          '$screenshotDir/Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.png');
    });

    test('thumb indices: kind game wins inside a status tier (2×2 order)',
        () {
      const relA3 =
          'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Alpha v3.zip';
      const relA4 =
          'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Alpha v4.zip';
      const relA5 =
          'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Alpha v5.zip';
      final u = buildUniverse({
        // Sorted variants: v2(0,ts) v3(1,ts) v4(2,ts) v5(3,game) a.zip(4,game).
        // Without the kind tier the first four are three textscreens plus
        // one game — the game at index 4 would be dropped from the tile.
        relA2: entryJson(relA2, 'done', 'ROOT', preview: 'a2.png',
            kindOverride: 'textscreen'),
        relA3: entryJson(relA3, 'done', 'ROOT', preview: 'a3.png',
            kindOverride: 'textscreen'),
        relA4: entryJson(relA4, 'done', 'ROOT', preview: 'a4.png',
            kindOverride: 'textscreen'),
        relA5: entryJson(relA5, 'done', 'ROOT', preview: 'a5.png'),
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
      });
      final card = u.cracked.single;
      expect(card.thumbIndices(), [3, 4, 0, 1]);
    });

    test('thumb indices: status tier dominates kind (desktop game last)',
        () {
      const relB2 =
          'Title Sorted/Cracked Games - Title Sorted/B/Beta/Beta v2.zip';
      final u = buildUniverse({
        relB2: entryJson(relB2, 'done', 'ROOT', preview: 'b2.png',
            kindOverride: 'textscreen'),
        relB: entryJson(relB, 'desktop', 'ROOT', preview: 'beta.png',
            kindOverride: 'game'),
      });
      expect(u.cracked.single.thumbIndices(), [0, 1]);
    });

    test('non-default TOS marker flows to variant and card (tosVersion)', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png', tos: '1.02'),
      });
      final card = u.cracked.single;
      expect(card.variants.single.tos, '1.02');
      expect(card.tosVersion, '1.02');
    });

    test('default TOS (no index field) leaves tosVersion null', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
      });
      expect(u.cracked.single.variants.single.tos, isNull);
      expect(u.cracked.single.tosVersion, isNull);
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
          '$screenshotDir/Title Sorted/Cracked Games - Title Sorted/B/Beta/beta.png');
    });

    test('no_usable_shots keeps its preview as card fallback', () {
      final u = buildUniverse({
        relB: entryJson(relB, 'no_usable_shots', 'ROOT', preview: 'beta.png'),
      });
      final card = u.cracked.first;
      expect(card.displayStatus, 'no_usable_shots');
      expect(card.screenshots, isTrue);
      expect(
          card.previewPath,
          '$screenshotDir/Title Sorted/Cracked Games - Title Sorted/B/Beta/beta.png');
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
            '$screenshotDir/Title Sorted/Cracked Games - Title Sorted/A/Alpha/a_c01.png'
          ]);
    });

    test('CardVariant.kind comes from the index entry', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'desktop', 'ROOT', preview: 'a.png',
            kindOverride: 'textscreen'),
        relB: entryJson(relB, 'done', 'ROOT', preview: 'beta.png'),
      });
      final alpha = u.cracked.firstWhere((c) => c.folder == 'Alpha');
      final beta = u.cracked.firstWhere((c) => c.folder == 'Beta');
      expect(alpha.variants.single.kind, 'textscreen');
      expect(beta.variants.single.kind, 'game');
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

  group('AtariLegend integration', () {
    test('attaches the match, merges publisher, exposes genre/developer', () {
      const cracked = '''
      [{"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Alpha",
        "variants": [{"title": "Alpha", "publisher": "Pub A"}]}]
      ''';
      final al = AtariLegendIndex.fromGames([
        const AtariLegendGame(
          id: 1,
          name: 'Alpha',
          slug: 'alpha',
          publisher: 'AL Pub',
          genres: ['Simulation'],
          developers: ['Taito'],
        ),
      ]);
      final u = buildUniverse(
        {relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png')},
        crackedGames: cracked,
        atariLegend: al,
      );
      final card = u.cracked.first;
      expect(card.atariLegend?.id, 1);
      expect(card.publishers, containsAll(['Pub A', 'AL Pub']));
      expect(u.crackedFacets.genres, ['Simulation']);
      expect(u.crackedFacets.developers, ['Taito']);
      expect(u.crackedFacets.publishers, containsAll(['Pub A', 'AL Pub']));
      expect(matchesCard(card, CatalogFilter()..genre = 'Simulation'), isTrue);
      expect(matchesCard(card, CatalogFilter()..developer = 'Taito'), isTrue);
      expect(matchesCard(card, CatalogFilter()..publisher = 'AL Pub'), isTrue);
      expect(matchesCard(card, CatalogFilter()..genre = 'Action'), isFalse);
    });
  });

  group('CatalogUniverse.build (pd/utils from their own indices)', () {
    const pdRel = 'Title Sorted/PD Games - Title Sorted/P/PacMan/pacman.zip';
    const pdRel2 = 'Title Sorted/PD Games - Title Sorted/P/PacMan/pacman2.zip';

    test('pd cards unite index groups (status/screenshots) and gameinfo', () {
      const pd = '''
      [{"letter": "P", "folder": "PacMan", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Pac-Man",
        "variants": [{"title": "Pac-Man", "publisher": "Atari"}]},
       {"letter": "M", "folder": "MetaOnly", "layers": ["ROOT"],
        "matched_via": "none", "matched_title": "",
        "variants": []}]
      ''';
      final u = buildUniverse(
        {},
        pdGames: pd,
        pdEntries: {
          pdRel: entryJson(pdRel, 'done', 'ROOT', preview: 'pacman.png'),
          pdRel2: entryJson(pdRel2, 'pending', 'ROOT'),
        },
      );
      // PacMan from the pd index (status + variants), MetaOnly from gameinfo.
      expect(u.pd.length, 2);
      final pac = u.pd.firstWhere((c) => c.folder == 'PacMan');
      expect(pac.kind, 'pd');
      expect(pac.displayStatus, 'done');
      expect(pac.variants.length, 2);
      expect(pac.statusCounts, {'done': 1, 'pending': 1});
      expect(pac.screenshots, isTrue);
      final meta = u.pd.firstWhere((c) => c.folder == 'MetaOnly');
      expect(meta.displayStatus, '');
      expect(meta.variants, isEmpty);
      expect(meta.screenshots, isFalse);
      // Per-section counts: cracked stays empty, pd counts only index cards.
      expect(u.statusCountsFor('pd'), {'done': 1});
      expect(u.statusCountsFor('cracked'), isEmpty);
      expect(u.statusCounts, isEmpty);
    });

    test('utils index groups feed the utils section independently', () {
      const utilsRel =
          'Title Sorted/Utilitys - Title Sorted/U/Util/util.zip';
      final u = buildUniverse({}, utilsEntries: {
        utilsRel: entryJson(utilsRel, 'desktop', 'ROOT', preview: 'util.png'),
      });
      expect(u.utils.length, 1);
      expect(u.utils.single.kind, 'utils');
      expect(u.utils.single.displayStatus, 'desktop');
      expect(u.utils.single.screenshots, isTrue);
      expect(u.withScreenshotFor('utils'), 1);
      expect(u.statusCountsFor('utils'), {'desktop': 1});
    });
  });

  group('CatalogUniverse status counts (status bar)', () {
    test('statusCounts aggregates displayStatus over cracked cards', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
        relA2: entryJson(relA2, 'pending', 'ROOT'), // Alpha: done+pending
        relB: entryJson(relB, 'desktop', 'ROOT', preview: 'beta.png'),
        relB9: entryJson(relB9, 'pending', 'ROOT'),
      });
      expect(u.statusCounts, {'done': 1, 'desktop': 1, 'pending': 1});
    });

    test('pendingAnyVariantCount follows the app filter rule, not the '
        'aggregate', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
        relA2: entryJson(relA2, 'pending', 'ROOT'), // aggregate hides it
        relB: entryJson(relB, 'error', 'ROOT'), // fallback aggregate pending
        relB9: entryJson(relB9, 'pending', 'ROOT'),
      });
      // Alpha (pending ZIP inside a done folder) + 999; the error-only card
      // aggregates to `pending` but has no pending ZIP.
      expect(u.pendingAnyVariantCount, 2);
      expect(u.statusCounts['pending'], 2);
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

    test('pending matches any pending ZIP, not the card aggregate', () {
      // App-only semantics (user decision 2026-10-15): a pending ZIP inside
      // a mostly-done folder must stay reachable; error-only cards are not
      // pending (their aggregate falls back to `pending` in the gallery).
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
        relA2: entryJson(relA2, 'pending', 'ROOT'),
        relB: entryJson(relB, 'error', 'ROOT'),
      });
      final mixed = u.cracked.firstWhere((c) => c.folder == 'Alpha');
      final errorOnly = u.cracked.firstWhere((c) => c.folder == 'Beta');
      expect(mixed.displayStatus, 'done',
          reason: 'aggregate hides the pending variant');
      expect(matchesCard(mixed, CatalogFilter()..status = 'pending'), isTrue);
      expect(matchesCard(errorOnly, CatalogFilter()..status = 'pending'),
          isFalse);
      expect(matchesCard(mixed, CatalogFilter()..status = 'done'), isTrue);
    });

    test('desktop and no-usable have only and any variants', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
        relA2: entryJson(relA2, 'desktop', 'ROOT', preview: 'a2.png'),
        relB: entryJson(relB, 'done', 'ROOT', preview: 'beta.png'),
        relB2: entryJson(relB2, 'no_usable_shots', 'ROOT',
            preview: 'beta2.png'),
      });
      final mixedDesktop = u.cracked.firstWhere((c) => c.folder == 'Alpha');
      final mixedNoUsable = u.cracked.firstWhere((c) => c.folder == 'Beta');
      expect(mixedDesktop.displayStatus, 'done');
      expect(mixedNoUsable.displayStatus, 'done');
      expect(
          matchesCard(
              mixedDesktop, CatalogFilter()..status = 'desktop'),
          isFalse);
      expect(
          matchesCard(
              mixedDesktop, CatalogFilter()..status = 'desktop_any'),
          isTrue);
      expect(
          matchesCard(
              mixedNoUsable, CatalogFilter()..status = 'no_usable_shots'),
          isFalse);
      expect(
          matchesCard(
              mixedNoUsable, CatalogFilter()..status = 'no_usable_shots_any'),
          isTrue);
      expect(u.anyVariantCountFor('cracked', 'desktop'), 1);
      expect(u.anyVariantZipCountFor('cracked', 'desktop'), 1);
      expect(u.onlyVariantZipCountFor('cracked', 'desktop'), 0);
      expect(u.anyVariantCountFor('cracked', 'no_usable_shots'), 1);
      expect(u.anyVariantZipCountFor('cracked', 'no_usable_shots'), 1);
      expect(u.onlyVariantZipCountFor('cracked', 'no_usable_shots'), 0);
      expect(mixedDesktop.previewVariantFor(status: 'desktop')?.status,
          'desktop');
      expect(
          mixedDesktop.thumbIndices(preferredStatus: 'desktop').first,
          mixedDesktop.variants
              .indexWhere((v) => v.status == 'desktop'));
      expect(mixedNoUsable.previewVariantFor(status: 'no_usable_shots')?.status,
          'no_usable_shots');
      expect(
          mixedNoUsable.thumbIndices(preferredStatus: 'no_usable_shots').first,
          mixedNoUsable.variants
              .indexWhere((v) => v.status == 'no_usable_shots'));
    });

    test('interrupted and skipped filters match any ZIP', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
        relA2: entryJson(relA2, 'interrupted', 'ROOT', preview: 'a2.png'),
        relB: entryJson(relB, 'done', 'ROOT', preview: 'beta.png'),
        relB2: entryJson(relB2, 'skipped_disk_n', 'ROOT', preview: 'beta2.png'),
      });
      final interrupted = u.cracked.firstWhere((c) => c.folder == 'Alpha');
      final skipped = u.cracked.firstWhere((c) => c.folder == 'Beta');
      expect(interrupted.displayStatus, 'done');
      expect(skipped.displayStatus, 'done');
      expect(matchesCard(interrupted, CatalogFilter()..status = 'interrupted'),
          isTrue);
      expect(matchesCard(skipped, CatalogFilter()..status = 'skipped_disk_n'),
          isTrue);
      expect(u.anyVariantCountFor('cracked', 'interrupted'), 1);
      expect(u.anyVariantZipCountFor('cracked', 'interrupted'), 1);
      expect(u.onlyVariantZipCountFor('cracked', 'interrupted'), 0);
      expect(u.anyVariantCountFor('cracked', 'skipped_disk_n'), 1);
      expect(u.anyVariantZipCountFor('cracked', 'skipped_disk_n'), 1);
      expect(u.onlyVariantZipCountFor('cracked', 'skipped_disk_n'), 0);
    });

    test('desktop umbrella keeps all kinds; text/black are strict', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'desktop', 'ROOT', preview: 'a.png',
            kindOverride: 'textscreen'),
        relB: entryJson(relB, 'desktop', 'ROOT', preview: 'beta.png',
            kindOverride: 'darkscreen'),
      });
      final text = u.cracked.firstWhere((c) => c.folder == 'Alpha');
      final black = u.cracked.firstWhere((c) => c.folder == 'Beta');
      // desktop = any kind (umbrella)
      expect(matchesCard(text, CatalogFilter()..status = 'desktop'), isTrue);
      expect(matchesCard(black, CatalogFilter()..status = 'desktop'), isTrue);
      // strict kind filters
      expect(
          matchesCard(text, CatalogFilter()..status = 'desktop_text'), isTrue);
      expect(
          matchesCard(black, CatalogFilter()..status = 'desktop_text'),
          isFalse);
      expect(
          matchesCard(text, CatalogFilter()..status = 'desktop_black'),
          isFalse);
      expect(
          matchesCard(black, CatalogFilter()..status = 'desktop_black'),
          isTrue);
    });

    test('desktop_text stays strict for manually done textscreen entries',
        () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png',
            kindOverride: 'textscreen'),
      });
      final card = u.cracked.first;
      expect(card.displayStatus, 'done');
      expect(
          matchesCard(card, CatalogFilter()..status = 'desktop_text'), isFalse);
      expect(matchesCard(card, CatalogFilter()..status = 'done'), isTrue);
      expect(
          matchesCard(card, CatalogFilter()..status = 'desktop'), isFalse);
    });

    test('kStatusFilterKeys and kStatusLabels cover the kind filters', () {
      expect(
          kStatusFilterKeys,
          containsAllInOrder([
            'done',
            'desktop',
            'desktop_any',
            'desktop_text',
            'desktop_black',
            'no_usable_shots',
            'no_usable_shots_any',
          ]));
      expect(kStatusLabels['done'], 'done');
      expect(kStatusLabels['desktop'], 'desktop (only)');
      expect(kStatusLabels['desktop_any'], 'desktop (any ZIP)');
      expect(kStatusLabels['desktop_text'], 'desktop text');
      expect(kStatusLabels['desktop_black'], 'desktop black');
      expect(kStatusLabels['no_usable_shots'], 'no usable shots (only)');
      expect(kStatusLabels['no_usable_shots_any'],
          'no usable shots (any ZIP)');
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

  group('crew focus (gallery _apply_focus)', () {
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

      final focused = applyFocus(card, 'The Crew', 'crew');
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
      final focused = applyFocus(card, 'The Crew', 'crew');
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
      final focused = applyFocus(card, 'The Crew', 'crew');
      expect(focused.focusVariant, -1);
      expect(focused.focusActive, isTrue);
      expect(focused.previewPath, isNull);
      expect(focused.screenshots, isFalse);
      // display status is untouched in the focus=-1 case (gallery: dict copy)
      expect(focused.displayStatus, card.displayStatus);

      final out = queryCards(u.cracked, CatalogFilter()..crew = 'The Crew');
      expect(out.single.focusVariant, -1);
      expect(out.single.previewPath, isNull);
    });

    test('no crew filter → cards pass through unchanged (focusVariant null)', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
      });
      final out = queryCards(u.cracked, CatalogFilter());
      expect(out.single.focusVariant, isNull);
      expect(out.single.focusActive, isFalse);
      expect(out.single.screenshots, isTrue);
      expect(out.single.previewPath, endsWith('/A/Alpha/a.png'));
    });
  });

  group('fuzzy group matching (gallery _norm_crew/_crew_tokens)', () {
    test('normCrew expands & / + to "and" and collapses whitespace', () {
      expect(normCrew('Equinox  &  MDK'), 'equinox and mdk');
      expect(normCrew('Hotline+MCA'), 'hotline and mca');
      expect(normCrew(null), '');
    });

    test('crewTokens drops stopwords and 1-char tokens', () {
      expect(crewTokens('The Hotline & MCA Crew'), ['hotline', 'mca']);
    });

    test('&/and equivalence matches the ZIP name (tier 1)', () {
      const cracked = '''
      [{"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Alpha Game",
        "variants": [{"title": "Alpha Game", "crew": "Equinox & MDK",
          "release": "1990"}]}]
      ''';
      final u = buildUniverse({
        'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Equinox and MDK - g.zip':
            entryJson(
                'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Equinox and MDK - g.zip',
                'done',
                'ROOT',
                preview: 'a.png'),
      }, crackedGames: cracked);
      final card = u.cracked.first;
      expect(focusVariant(card, 'Equinox & MDK', 'crew'), 0);
    });

    test('token subset tolerates missing connective (tier 3)', () {
      const cracked = '''
      [{"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Alpha Game",
        "variants": [{"title": "Alpha Game", "crew": "Hotline & MCA",
          "release": "1990"}]}]
      ''';
      final u = buildUniverse({
        'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Hotline MCA g.zip':
            entryJson(
                'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Hotline MCA g.zip',
                'done',
                'ROOT',
                preview: 'a.png'),
      }, crackedGames: cracked);
      final card = u.cracked.first;
      expect(focusVariant(card, 'Hotline & MCA', 'crew'), 0);
    });

    test('first-with-preview wins among multiple matches', () {
      const cracked = '''
      [{"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
        "matched_via": "exact", "matched_title": "Alpha Game",
        "variants": [{"title": "Alpha Game", "crew": "Hotline & MCA",
          "release": "1990"}]}]
      ''';
      final u = buildUniverse({
        'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Hotline MCA a.zip':
            entryJson(
                'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Hotline MCA a.zip',
                'pending',
                'ROOT'),
        'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Hotline MCA b.zip':
            entryJson(
                'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Hotline MCA b.zip',
                'done',
                'ROOT',
                preview: 'b.png'),
      }, crackedGames: cracked);
      final card = u.cracked.first;
      expect(card.variants.length, 2);
      // variant 0 has no preview, variant 1 does → focus lands on 1
      expect(focusVariant(card, 'Hotline & MCA', 'crew'), 1);
    });
  });

  group('cracker focus + facet (gallery crew dropdown)', () {
    const cracked = '''
    [{"letter": "A", "folder": "Alpha", "layers": ["ROOT"],
      "matched_via": "exact", "matched_title": "Alpha Game",
      "variants": [{"title": "Alpha Game", "crew": "The Crew",
        "cracked_by": "Crackerman", "release": "1990"}]}]
    ''';

    test('cracker focus matches cracked_by in ZIP name (no tier 2)', () {
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
      expect(focusVariant(card, 'Crackerman', 'cracker'), 0);
      final out =
          queryCards(u.cracked, CatalogFilter()..cracker = 'Crackerman');
      expect(out.single.focusVariant, 0);
    });

    test('cracker takes precedence over crew in queryCards', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
        'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Crackerman - x.zip':
            entryJson(
                'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Crackerman - x.zip',
                'done',
                'ROOT',
                preview: 'a2.png'),
      }, crackedGames: cracked);
      final out = queryCards(
          u.cracked, CatalogFilter()..crew = 'The Crew'..cracker = 'Crackerman');
      expect(out.single.focusVariant, 0);
      expect(out.single.previewPath, endsWith('/A/Alpha/a2.png'));
    });

    test('cracker is a facet for cracked + utils, not pd', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
      }, crackedGames: cracked);
      expect(u.crackedFacets.crackers, ['Crackerman']);
      expect(kindFilters('cracked'), contains('cracker'));
      expect(kindFilters('utils'), contains('cracker'));
      expect(kindFilters('pd'), isNot(contains('cracker')));
    });

    test('cracker filter matches by card crackers list', () {
      final u = buildUniverse({
        relA: entryJson(relA, 'done', 'ROOT', preview: 'a.png'),
      }, crackedGames: cracked);
      final card = u.cracked.first;
      expect(matchesCard(card, CatalogFilter()..cracker = 'Crackerman'), isTrue);
      expect(matchesCard(card, CatalogFilter()..cracker = 'Nobody'), isFalse);
    });
  });

  group('CatalogUniverse.build (magazine cards)', () {
    const magA = 'Bonus/Magazine Cover Disks/Zero - Complete/'
        'Zero Issue 01 - Nov 89 - Recoil.zip';
    const magA2 = 'Bonus/Magazine Cover Disks/Zero - Complete/'
        'Zero Issue 01 - Nov 89 - Recoil (2).zip';
    const magB = 'Bonus/Magazine Cover Disks/ST Computer/1995_02.zip';
    const magC = 'Bonus/Magazine Cover Disks/ST Computer/1995_02 (2).zip';

    test('groups issue variants, derives display name and year', () {
      final u = buildUniverse({}, magazineEntries: {
        magA: entryJson(magA, 'done', 'PATCH', preview: 'a.png'),
        magA2: entryJson(magA2, 'pending', 'PATCH'),
        magB: entryJson(magB, 'done', 'PATCH', preview: 'b.png'),
        magC: entryJson(magC, 'done', 'PATCH', preview: 'c.png'),
      });
      expect(u.magazine.length, 2);
      final zero = u.magazine.firstWhere((c) => c.letter == 'Zero - Complete');
      expect(zero.name, 'Zero Issue 01');
      expect(zero.folder, '01');
      expect(zero.variants.length, 2);
      expect(zero.displayStatus, 'done');
      final st = u.magazine.firstWhere((c) => c.letter == 'ST Computer');
      expect(st.name, 'ST Computer 1995-02');
      expect(st.year, '1995');
      expect(st.yearNum, 1995);
      expect(st.variants.length, 2);
    });

    test('letter facet lists magazines, year facet comes from file names', () {
      final u = buildUniverse({}, magazineEntries: {
        magA: entryJson(magA, 'done', 'PATCH', preview: 'a.png'),
        magB: entryJson(magB, 'done', 'PATCH', preview: 'b.png'),
      });
      expect(u.magazineFacets.letters,
          ['ST Computer', 'Zero - Complete']);
      expect(u.magazineFacets.years, ['1995']);
      expect(u.magazineFacets.publishers, isEmpty);
    });

    test('cardsFor/facetsFor resolve the magazine section', () {
      final u = buildUniverse({}, magazineEntries: {
        magA: entryJson(magA, 'done', 'PATCH', preview: 'a.png'),
      });
      expect(u.cardsFor('magazine'), u.magazine);
      expect(u.facetsFor('magazine'), u.magazineFacets);
      expect(u.allCards, contains(u.magazine.first));
    });

    test('kind filters: year only, no cracker/crew', () {
      expect(kindFilters('magazine'), {'year'});
      expect(kindFields('magazine'), isEmpty);
    });
  });

  group('CatalogUniverse.build (falcon cards)', () {
    const falconA =
        'Falcon 030/Title Sorted/A/Another World/Another World - F030.zip';
    const falconA2 =
        'Falcon 030/Title Sorted/A/Another World/Another World - Original.zip';
    const falconB = 'Falcon 030/Title Sorted/B/Bad Mood/Bad Mood v3.07a.zip';

    test('groups by (letter, folder) like the cracked section', () {
      final u = buildUniverse({}, falconEntries: {
        falconA: entryJson(falconA, 'done', 'ROOT', preview: 'a.png'),
        falconA2: entryJson(falconA2, 'pending', 'ROOT'),
        falconB: entryJson(falconB, 'done', 'PATCH', preview: 'b.png'),
      });
      expect(u.falcon.length, 2);
      final aw = u.falcon.firstWhere((c) => c.folder == 'Another World');
      expect(aw.letter, 'A');
      expect(aw.kind, 'falcon');
      expect(aw.variants.length, 2);
      expect(aw.displayStatus, 'done');
      final bm = u.falcon.firstWhere((c) => c.folder == 'Bad Mood');
      expect(bm.displayStatus, 'done');
      expect(bm.layer, 'PATCH');
    });

    test('previewVariant follows the displayed done/game preview', () {
      const original =
          'Falcon 030/Title Sorted/0-9/4WD Road Riot/Original/road_riot.zip';
      const elite =
          'Falcon 030/Title Sorted/0-9/4WD Road Riot/Road Riot 4WD - Elite.zip';
      final u = buildUniverse({}, falconEntries: {
        original: entryJson(original, 'desktop', 'ROOT',
            preview: 'original.png',
            candidates: const ['original_c01.png'],
            kindOverride: 'darkscreen'),
        elite: entryJson(elite, 'done', 'ROOT',
            preview: 'elite.png',
            candidates: const [
              'elite_c01.png',
              'elite_c02.png',
              'elite_c03.png',
            ]),
      });
      final card = u.falcon.single;
      expect(card.variants.first.name, 'road_riot.zip');
      expect(card.previewVariant?.name, 'Road Riot 4WD - Elite.zip');
      expect(card.previewVariant?.candidatePaths, [
        '$screenshotDir/Falcon 030/Title Sorted/0-9/4WD Road Riot/elite_c01.png',
        '$screenshotDir/Falcon 030/Title Sorted/0-9/4WD Road Riot/elite_c02.png',
        '$screenshotDir/Falcon 030/Title Sorted/0-9/4WD Road Riot/elite_c03.png',
      ]);
    });

    test('index-only: no gameinfo join, no AtariLegend', () {
      final u = buildUniverse({}, falconEntries: {
        falconA: entryJson(falconA, 'done', 'ROOT', preview: 'a.png'),
      });
      final card = u.falcon.single;
      expect(card.info, isNull);
      expect(card.atariLegend, isNull);
      expect(u.falconFacets.letters, ['A']);
      expect(kindFilters('falcon'), isEmpty);
      expect(kindFields('falcon'), isEmpty);
    });

    test('cardsFor/facetsFor/allCards resolve the falcon section', () {
      final u = buildUniverse({}, falconEntries: {
        falconA: entryJson(falconA, 'done', 'ROOT', preview: 'a.png'),
      });
      expect(u.cardsFor('falcon'), u.falcon);
      expect(u.facetsFor('falcon'), u.falconFacets);
      expect(u.allCards, contains(u.falcon.first));
    });
  });
}
