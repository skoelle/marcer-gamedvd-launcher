// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('crew_clusters_test');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('missing file degrades to an empty index', () {
    final index = CrewClusterIndex.load(tmp.path);
    expect(index.length, 0);
    expect(index.hasData, isFalse);
    expect(index.loadError, contains('not found'));
  });

  test('parses clusters, trees, entities and the reverse crew map', () {
    File('${tmp.path}/crew-cluster.json').writeAsStringSync(
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
            'counts': {'groups': 2, 'top': 1, 'zips': 3},
            'groups': [
              {
                'name': 'Alpha Crew',
                'local_id': 'alpha-crew',
                'status': 'top',
                'zips': 2,
                'clusters': ['elite'],
              },
            ],
          },
        ],
        'edges': [
          {
            'from': 'Alpha Crew',
            'to': 'Elite',
            'type': 'subgroup_of',
            'clusters': ['elite'],
            'cross_cluster': false,
          },
        ],
        'trees': {
          'elite': {
            'name': 'Elite',
            'status': 'top',
            'children': [
              {
                'name': 'Alpha Crew',
                'local_id': 'alpha-crew',
                'status': 'top',
                'zips': 2,
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

    final index = CrewClusterIndex.load(tmp.path);
    expect(index.loadError, isNull);
    expect(index.length, 1);
    final cluster = index.clusterFor('elite')!;
    expect(cluster.name, 'Elite / Empire');
    expect(cluster.isIndependent, isFalse);
    expect(cluster.counts.zips, 3);
    expect(cluster.tree?.children.single.localId, 'alpha-crew');
    expect(cluster.edges.single.crossCluster, isFalse);
    expect(index.clustersForCrew('alpha-crew').single.id, 'elite');
    expect(index.clustersForCrew('beta-crew').single.id, 'elite');
    expect(index.entityFor('beta-crew')?.summary,
        'Memberships: Elite (current)');
  });

  test('invalid JSON yields a clean error', () {
    File('${tmp.path}/crew-cluster.json').writeAsStringSync('{not json');
    final index = CrewClusterIndex.load(tmp.path);
    expect(index.length, 0);
    expect(index.loadError, startsWith('parse error:'));
  });
}
