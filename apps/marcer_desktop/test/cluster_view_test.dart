// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/widgets/cluster_detail_panel.dart';
import 'package:marcer_desktop/widgets/cluster_lightbox.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const tree = 'Title Sorted/Cracked Games - Title Sorted';
  const relA = '$tree/A/Alpha/a.zip';
  const relB = '$tree/B/Beta/b.zip';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cluster_view_test');
    for (final rel in [relA, relB]) {
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
          relB: {
            'rel': relB,
            'name': 'b.zip',
            'status': 'done',
            'kind': 'game',
            'layer': 'ROOT',
            'preview': 'b.png',
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
              {'title': 'Alpha', 'crew': 'Alpha Crew', 'release': '1990'},
            ],
          },
          {
            'letter': 'B',
            'folder': 'Beta',
            'layers': ['ROOT'],
            'variants': [
              {'title': 'Beta', 'crew': 'Beta Crew', 'release': '1991'},
            ],
          },
        ],
      }),
    );
    File('${tmp.path}/data/crews.json').writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'generated_at': '2026-10-31T00:00:00Z',
        'groups': [
          {
            'id': 'alpha-crew',
            'name': 'Alpha Crew',
            'kind': 'crew',
            'rank': 1,
            'zips': 1,
            'aliases': const <String>[],
            'releases': [
              {
                'rel': relA,
                'letter': 'A',
                'folder': 'Alpha',
                'zip': 'a.zip',
                'title': 'Alpha',
                'crew': 'Alpha Crew',
                'disks': 1,
              },
            ],
          },
          {
            'id': 'beta-crew',
            'name': 'Beta Crew',
            'kind': 'cracker',
            'rank': 2,
            'zips': 1,
            'aliases': const <String>[],
            'releases': [
              {
                'rel': relB,
                'letter': 'B',
                'folder': 'Beta',
                'zip': 'b.zip',
                'title': 'Beta',
                'cracked_by': 'Beta Crew',
                'disks': 1,
              },
            ],
          },
        ],
      }),
    );
    File('${tmp.path}/data/crew-cluster.json').writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'generated_at': '2026-10-31T00:00:00Z',
        'clusters': [
          {
            'id': 'elite',
            'name': 'Elite / Empire',
            'kind': 'umbrella',
            'roots': [
              {'name': 'Elite'},
            ],
            'counts': {
              'groups': 2,
              'top': 1,
              'excluded': 1,
              'ambiguous': 0,
              'external': 1,
              'members': 1,
              'group_zips': 2,
              'zips': 3,
              'member_zips': 1,
            },
            'groups': [
              {
                'name': 'Alpha Crew',
                'local_id': 'alpha-crew',
                'status': 'top',
                'zips': 1,
                'clusters': ['elite'],
              },
              {
                'name': 'Beta Crew',
                'local_id': 'beta-crew',
                'status': 'excluded',
                'zips': 1,
                'clusters': ['elite', 'other'],
              },
              {
                'name': 'External Group',
                'status': 'external',
                'zips': 0,
                'clusters': ['elite'],
              },
            ],
          },
          {
            'id': 'other',
            'name': 'Other Cluster',
            'kind': 'independent',
            'roots': [
              {'name': 'Other'},
            ],
            'counts': {'groups': 1, 'top': 0, 'excluded': 1},
            'groups': [
              {
                'name': 'Beta Crew',
                'local_id': 'beta-crew',
                'status': 'excluded',
                'zips': 1,
                'clusters': ['elite', 'other'],
              },
            ],
          },
        ],
        'edges': [
          {
            'from': 'Alpha Crew',
            'to': 'Elite',
            'type': 'subgroup_of',
            'current': false,
            'clusters': ['elite'],
            'cross_cluster': false,
          },
          {
            'from': 'Alpha Crew',
            'to': 'Other',
            'type': 'subgroup_of',
            'current': false,
            'clusters': ['elite', 'other'],
            'cross_cluster': true,
          },
        ],
        'trees': {
          'elite': {
            'name': 'Elite',
            'status': 'top',
            'local_id': null,
            'children': [
              {
                'name': 'Alpha Crew',
                'local_id': 'alpha-crew',
                'status': 'top',
                'zips': 1,
                'children': <Map<String, dynamic>>[],
              },
              {
                'name': 'External Group',
                'status': 'external',
                'children': <Map<String, dynamic>>[],
                'members': [
                  {
                    'name': 'Beta Crew',
                    'local_id': 'beta-crew',
                    'zips': 1,
                    'current': true,
                  },
                ],
              },
            ],
          },
          'other': {
            'name': 'Other',
            'status': 'external',
            'children': <Map<String, dynamic>>[],
          },
        },
        'entities': {
          'beta-crew': {
            'name': 'Beta Crew',
            'kind': 'person',
            'status': 'resolved',
            'memberships': [
              {'name': 'Elite', 'current': true},
            ],
          },
        },
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

  test('loads clusters, previews, reverse links and memberships', () async {
    await c.init();
    expect(c.clusters.length, 2);
    expect(c.clusters.hasData, isTrue);
    expect(c.clusters.clusterFor('elite')?.counts.zips, 3);
    expect(c.clusters.clustersForCrew('beta-crew'), hasLength(2));
    expect(c.entityForCrew(c.crews.groupForId('beta-crew')!)?.summary,
        contains('Memberships: Elite (current)'));

    c.setSection('cluster');
    expect(c.catalogCards, hasLength(2));
    final elite = c.catalogCards.firstWhere((card) => card.cluster?.id == 'elite');
    expect(elite.previewPath, endsWith('a.png'));
    expect(c.countText, '2 clusters');
    expect(c.statusLine, contains('2 clusters'));

    c.setQuery('other');
    expect(c.catalogCards.single.cluster?.name, 'Other Cluster');
    expect(c.displayPreviewPathForCard(c.catalogCards.single), endsWith('b.png'));

    c.setQuery('');
    c.setSection('cracked');
    expect(c.catalogCards.every((card) => card.cluster == null), isTrue);
  });

  test('missing cluster file degrades to an empty index', () {
    final index = CrewClusterIndex.load('${tmp.path}/missing-data');
    expect(index.length, 0);
    expect(index.hasData, isFalse);
    expect(index.loadError, isNotNull);
  });

  testWidgets('cluster browser prunes and reveals external branches', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await c.init();
    });
    final cluster = c.clusters.clusterFor('elite')!;
    CrewGroup? opened;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClusterLightbox(
            controller: c,
            cluster: cluster,
            onOpenCrew: (crew) => opened = crew,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Elite / Empire'), findsWidgets);
    expect(find.text('Alpha Crew'), findsOneWidget);
    expect(find.text('External Group'), findsNothing);
    expect(find.textContaining('1 external hidden'), findsOneWidget);

    await tester.tap(find.text('Show external'));
    await tester.pump();
    expect(find.text('External Group'), findsOneWidget);
    expect(find.text('Beta Crew'), findsOneWidget);

    await tester.tap(find.text('Alpha Crew'));
    await tester.pump();
    expect(opened?.id, 'alpha-crew');
  });

  testWidgets('cluster detail panel shows the counts and overlaps', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await c.init();
    });
    final cluster = c.clusters.clusterFor('elite')!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClusterDetailPanel(cluster: cluster),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Elite / Empire'), findsOneWidget);
    expect(find.text('umbrella'), findsOneWidget);
    expect(find.textContaining('3 ZIPs'), findsOneWidget);
    expect(find.text('Beta Crew · elite, other'), findsOneWidget);
    expect(find.text('Cross-cluster links'), findsWidgets);
  });
}
