// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/piratefinder_data.dart';
import 'package:marcer_desktop/widgets/crew_detail_panel.dart';
import 'package:marcer_desktop/widgets/crew_lightbox.dart';

/// PF data controller with an injected index (no file/isolate needed).
class _FakePirateFinderData extends PirateFinderDataController {
  _FakePirateFinderData(this.value);
  PirateFinderIndex? value;
  @override
  PirateFinderIndex? get index => value;
}

PirateFinderIndex _alphaIndex() => PirateFinderIndex.fromJson({
  'generated_at': '2026-10-24T12:34:16Z',
  'source': {'tag': 'catalogue-2026-10-19'},
  'disks': [
    {
      'id': 1,
      'kind': 'single',
      'title': 'Alpha (1990)(Publisher A)[cr Alpha Crew]',
      'label': 'Alpha',
      'publisher': 'Publisher A',
      'cracker': 'Alpha Crew',
      'crew': 'Alpha Crew',
      'year': 1990,
    },
  ],
  'contents': [],
  'images': [],
});

/// Crews tab: `crews.json` loading, top-N cards, search and the release ->
/// cracked-card lookup used to open the existing game lightbox.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const tree = 'Title Sorted/Cracked Games - Title Sorted';
  const relA = '$tree/A/Alpha/a.zip';
  const relA2 = '$tree/A/Alpha/a_v2.zip';
  const relB = '$tree/B/Beta/b.zip';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('crew_view_test');
    for (final rel in [relA, relA2, relB]) {
      final file = File('${tmp.path}/root/$rel');
      file.parent.createSync(recursive: true);
      file.createSync();
    }
    Directory('${tmp.path}/data').createSync(recursive: true);
    Directory('${tmp.path}/out').createSync(recursive: true);

    File('${tmp.path}/out/index.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'entries': {
          relA: {
            'rel': relA,
            'name': 'a.zip',
            'status': 'done',
            'kind': 'game',
            'layer': 'ROOT',
            'preview': 'a.png',
            'candidates': <String>[],
          },
          relA2: {
            'rel': relA2,
            'name': 'a_v2.zip',
            'status': 'done',
            'kind': 'game',
            'layer': 'ROOT',
            'preview': null,
            'candidates': <String>[],
          },
          relB: {
            'rel': relB,
            'name': 'b.zip',
            'status': 'done',
            'kind': 'game',
            'layer': 'ROOT',
            'preview': null,
            'candidates': <String>[],
          },
        },
      }),
    );

    File('${tmp.path}/data/games-cracked.json').writeAsStringSync(
      jsonEncode({
        'games': [
          {
            'letter': 'A',
            'folder': 'Alpha',
            'layers': ['ROOT'],
            'variants': [
              {
                'title': 'Alpha',
                'publisher': 'Publisher A',
                'crew': 'Alpha Crew',
                'cracked_by': '',
                'release': '1990',
                'language': 'English',
                'disks': 1,
              },
            ],
          },
          {
            'letter': 'B',
            'folder': 'Beta',
            'layers': ['ROOT'],
            'variants': [
              {
                'title': 'Beta',
                'publisher': 'Publisher B',
                'crew': '',
                'cracked_by': 'Beta Crackers',
                'release': '1991',
              },
            ],
          },
        ],
      }),
    );

    final curated = File(
      '${tmp.path}/out/Title Sorted/Cracked Games - Title Sorted/A/Alpha/curated.png',
    );
    curated.parent.createSync(recursive: true);
    curated.createSync();
    File('${tmp.path}/data/crew-images.json').writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'images': {
          'Alpha Crew': {
            'rel': relA,
            'name': 'curated.png',
            'source': 'manual',
          },
        },
      }),
    );

    File('${tmp.path}/data/crews.json').writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'generated_at': '2026-10-24T00:00:00Z',
        'groups': [
          {
            'id': 'alpha-crew',
            'name': 'Alpha Crew',
            'kind': 'crew',
            'rank': 1,
            'zips': 2,
            'aliases': ['Alpha Crew', 'Alpha'],
            'image': null,
            'releases': [
              {
                'rel': relA,
                'letter': 'A',
                'folder': 'Alpha',
                'zip': 'a.zip',
                'title': 'Alpha',
                'year': '1990',
                'publisher': 'Publisher A',
                'crew': 'Alpha Crew',
                'source': 'exact',
                'disks': 1,
              },
              {
                'rel': relA2,
                'letter': 'A',
                'folder': 'Alpha',
                'zip': 'a_v2.zip',
                'title': 'Alpha v2',
                'year': '1991',
                'publisher': 'Publisher A',
                'crew': 'Alpha Crew',
                'source': 'exact',
                'disks': 1,
              },
            ],
          },
          {
            'id': 'beta-crackers',
            'name': 'Beta Crackers',
            'kind': 'cracker',
            'rank': 2,
            'zips': 1,
            'aliases': ['Beta Crackers'],
            'image': null,
            'releases': [
              {
                'rel': relB,
                'letter': 'B',
                'folder': 'Beta',
                'zip': 'b.zip',
                'title': 'Beta',
                'year': '1991',
                'publisher': 'Publisher B',
                'cracked_by': 'Beta Crackers',
                'source': 'gameinfo_cracker',
                'disks': 1,
              },
            ],
          },
        ],
      }),
    );

    c = CatalogController(
      DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        screenshotDirectory: '${tmp.path}/out',
        gameinfoDirectory: '${tmp.path}/data',
      ),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('crew images are optional', () {
    final index = CrewImageIndex.load('${tmp.path}/missing-data');
    expect(index.length, 0);
    expect(index.loadError, isNull);
  });

  test('crews tab builds top-N cards, searches and maps releases', () async {
    await c.init();
    expect(c.crews.length, 2);
    expect(c.crews.totalReleases, 3);

    c.setSection('crew');
    expect(c.catalogCards, hasLength(2));
    expect(c.selectedCard?.crew?.name, 'Alpha Crew');
    expect(c.selectedCard?.previewPath, endsWith('curated.png'));
    expect(
      c.displayPreviewPathForCard(c.selectedCard!),
      endsWith('curated.png'),
    );
    expect(c.countText, '2 crews');
    expect(c.statusLine, contains('3 releases'));

    c.setQuery('beta');
    expect(c.catalogCards, hasLength(1));
    expect(c.catalogCards.single.crew?.name, 'Beta Crackers');

    c.setQuery('');
    final hit = c.releaseCardFor(relA2);
    expect(hit, isNotNull);
    expect(hit!.card.folder, 'Alpha');
    expect(hit.card.variants[hit.index].rel, relA2);

    // Legacy section-relative rel (older crews.json) resolves through the
    // cracked tree prefix fallback.
    final legacy = c.releaseCardFor('A/Alpha/a.zip');
    expect(legacy, isNotNull);
    expect(legacy!.card.variants[legacy.index].rel, relA);

    // Back to a normal section: the synthetic crew cards must not leak.
    c.setSection('cracked');
    c.setStatus('any');
    expect(c.catalogCards, hasLength(2));
    expect(c.catalogCards.every((card) => card.crew == null), isTrue);
  });

  test('crews tab shows the top 128 groups after exclusions', () async {
    final groups = [
      for (var i = 1; i <= 130; i++)
        {
          'id': 'crew-$i',
          'name': 'Crew ${i.toString().padLeft(2, '0')}',
          'kind': 'crew',
          'rank': i,
          'zips': 131 - i,
          'aliases': ['Crew $i'],
          'image': null,
          'excluded': i == 10,
          'releases': <Map<String, dynamic>>[],
        },
    ];
    File('${tmp.path}/data/crews.json')
        .writeAsStringSync(jsonEncode({'schema': 1, 'groups': groups}));
    final c2 = CatalogController(
      DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        screenshotDirectory: '${tmp.path}/out',
        gameinfoDirectory: '${tmp.path}/data',
      ),
    );
    addTearDown(c2.dispose);
    await c2.init();
    c2.setSection('crew');
    expect(c2.crews.length, 129);
    expect(c2.catalogCards, hasLength(128));
    expect(c2.catalogCards.first.crew?.name, 'Crew 01');
    expect(c2.crews.groups.any((g) => g.name == 'Crew 10'), isFalse);
    expect(c2.statusLine, contains('top 128 of 129'));
  });

  testWidgets('crew lightbox lists releases and navigates with arrows', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await c.init();
    });
    final crew = c.crews.groups.firstWhere(
      (group) => group.name == 'Alpha Crew',
    );
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CrewLightbox(controller: c, crew: crew),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Alpha Crew'), findsWidgets);
    expect(find.text('Crew · 2 releases'), findsOneWidget);
    expect(find.text('Search  ( / )'), findsOneWidget);
    expect(find.text('Alpha v2'), findsOneWidget);
    expect(find.text('a_v2.zip'), findsNothing);
    final search = tester.getTopLeft(find.text('Search  ( / )'));
    final sort = tester.getTopLeft(find.text('name asc'));
    expect(search.dx, lessThan(sort.dx));

    final header = tester.getRect(
      find.byKey(const ValueKey('crew-lightbox-header')),
    );
    final headerName = tester.getRect(
      find.byKey(const ValueKey('crew-lightbox-header-name')),
    );
    final overview = tester.getRect(
      find.byKey(const ValueKey('crew-lightbox-overview')),
    );
    expect((headerName.center.dx - header.center.dx).abs(), lessThan(2));
    expect(overview.top, greaterThanOrEqualTo(header.bottom));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('a_v2.zip'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'v2');
    await tester.pump();
    expect(find.text('Alpha v2'), findsOneWidget);
    expect(find.text('a_v2.zip'), findsOneWidget);

    expect(find.text('name asc'), findsOneWidget);
    expect(find.text('1 / 2'), findsNothing);
  });

  testWidgets('crew lightbox starts on the first sorted release', (
    tester,
  ) async {
    File('${tmp.path}/data/crew-images.json').writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'images': {
          'Alpha Crew': {
            'rel': relA2,
            'name': 'curated.png',
            'source': 'manual',
          },
        },
      }),
    );
    await tester.runAsync(() async {
      await c.init();
    });
    final crew = c.crews.groups.firstWhere(
      (group) => group.name == 'Alpha Crew',
    );
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CrewLightbox(controller: c, crew: crew),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('a.zip'), findsOneWidget);
    expect(find.text('a_v2.zip'), findsNothing);
  });

  testWidgets('crew lightbox sorts by name (default) and year', (tester) async {
    await tester.runAsync(() async {
      await c.init();
    });
    final crew = c.crews.groups.firstWhere(
      (group) => group.name == 'Alpha Crew',
    );
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CrewLightbox(controller: c, crew: crew),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('name asc'), findsOneWidget);
    expect(find.text('a.zip'), findsOneWidget);
    final alphaV2Before = tester.getTopLeft(find.text('Alpha v2'));

    await tester.tap(find.text('name asc'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('year asc'), findsOneWidget);
    expect(find.text('year desc'), findsOneWidget);
    expect(find.text('name desc'), findsOneWidget);

    await tester.tap(find.text('year desc'));
    await tester.pumpAndSettle();
    expect(find.text('year desc'), findsOneWidget);

    final alphaV2After = tester.getTopLeft(find.text('Alpha v2'));
    expect(alphaV2After.dx, lessThan(alphaV2Before.dx));
  });

  testWidgets('crew lightbox hides skipped_disk_n status', (tester) async {
    final index = jsonDecode(
      File('${tmp.path}/out/index.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final entries = index['entries'] as Map<String, dynamic>;
    entries[relA]['status'] = 'skipped_disk_n';
    File('${tmp.path}/out/index.json').writeAsStringSync(jsonEncode(index));

    await tester.runAsync(() async {
      await c.init();
    });
    final crew = c.crews.groups.firstWhere(
      (group) => group.name == 'Alpha Crew',
    );
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CrewLightbox(controller: c, crew: crew),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('skipped_disk_n'), findsNothing);
    expect(find.text('done'), findsWidgets);
  });

  testWidgets('crew lightbox side panel shows the PirateFinder section', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await c.init();
    });
    final crew = c.crews.groups.firstWhere(
      (group) => group.name == 'Alpha Crew',
    );
    // Inject a PF index so the Alpha card has a title match.
    final fake = _FakePirateFinderData(_alphaIndex());
    c.pirateFinderData = fake;

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CrewLightbox(controller: c, crew: crew),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('PirateFinder Crew Releases (1)'), findsOneWidget);
    expect(find.text('Crews'), findsOneWidget);
  });

  testWidgets('crew detail lists releases and opens one on tap', (
    tester,
  ) async {
    const group = CrewGroup(
      id: 'alpha-crew',
      name: 'Alpha Crew',
      kind: 'crew',
      rank: 1,
      zips: 2,
      aliases: ['Alpha Crew', 'Alpha'],
      releases: [
        CrewRelease(
          rel: relA,
          letter: 'A',
          folder: 'Alpha',
          zip: 'a.zip',
          title: 'Alpha',
          year: '1990',
          publisher: 'Publisher A',
          crackedBy: 'Cracker',
          crew: 'Alpha Crew',
          language: 'English',
          source: 'exact',
          disks: 1,
          rawDump: true,
          pastiDump: false,
          boxscan: false,
          ambiguous: false,
          tosBad: '',
          specialFlag: '',
          specialNote: '',
        ),
        CrewRelease(
          rel: relA2,
          letter: 'A',
          folder: 'Alpha',
          zip: 'a_v2.zip',
          title: 'Alpha v2',
          year: '1991',
          publisher: 'Publisher A',
          crackedBy: '',
          crew: 'Alpha Crew',
          language: 'English',
          source: 'exact',
          disks: 1,
          rawDump: false,
          pastiDump: false,
          boxscan: false,
          ambiguous: false,
          tosBad: '',
          specialFlag: '',
          specialNote: '',
        ),
      ],
    );
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 700,
            child: CrewDetailPanel(
              crew: group,
              onOpenRelease: (rel) => opened = rel,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Alpha Crew'), findsOneWidget);
    expect(find.text('Releases (2)'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Alpha v2'), findsOneWidget);
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(opened, relA);
  });

  testWidgets('CrewDetailPanel shows PirateFinder crew info when present', (
    tester,
  ) async {
    final group = CrewGroup(
      id: 'alpha',
      name: 'Alpha Crew',
      kind: 'crew',
      rank: 1,
      zips: 2,
      aliases: const ['Alpha Crew'],
      releases: const [],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 700,
            child: CrewDetailPanel(
              crew: group,
              pirateFinderCrew: const PirateFinderCrew(
                id: 613,
                name: 'Alpha Crew',
                platform: 'atari-st',
                notes: 'An Alfa cracking crew from 1988.',
                members: 'Floyd, Pumpkin',
                founded: '',
                source: 'atari-legend, demozoo',
                url: 'https://demozoo.org/groups/1/',
                wikipedia: '',
                diskCount: 40,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('PirateFinder-Catalog'), findsOneWidget);
    expect(find.textContaining('Floyd, Pumpkin'), findsOneWidget);
    expect(find.textContaining('An Alfa cracking crew'), findsOneWidget);
    expect(find.textContaining('40 releases'), findsOneWidget);
    expect(find.textContaining('atari-legend, demozoo'), findsOneWidget);
    expect(find.textContaining('Founded'), findsNothing);
  });
}
