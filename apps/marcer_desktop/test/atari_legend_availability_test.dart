// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';

/// The Genre/Developers filter dropdowns are only shown when the AtariLegend
/// cache is present (`CatalogController.hasAtariLegend`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String alDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('al_availability_test');
    Directory('${tmp.path}/root').createSync();
    Directory('${tmp.path}/out').createSync();
    Directory('${tmp.path}/data').createSync();
    alDir = '${tmp.path}/atarilegend';
    Directory(alDir).createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  CatalogController controller() => CatalogController(DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        screenshotDirectory: '${tmp.path}/out',
        gameinfoDirectory: '${tmp.path}/data',
        atariLegendDirectory: alDir,
      ));

  test('hasAtariLegend is false without the cache', () async {
    final c = controller();
    await c.init();
    expect(c.ready, isTrue);
    expect(c.hasAtariLegend, isFalse);
  });

  test('hasAtariLegend is true when the cache is loaded', () async {
    File('$alDir/atarilegend.json').writeAsStringSync(jsonEncode({
      'schema_version': kAtariLegendSchemaVersion,
      'generated_at': 'now',
      'games': [
        {'id': 22, 'name': 'Buggy Boy', 'slug': 'buggy-boy'},
      ],
    }));

    final c = controller();
    await c.init();
    expect(c.ready, isTrue);
    expect(c.hasAtariLegend, isTrue);
  });

  test('falcon cards resolve their AtariLegend match too', () async {
    File('$alDir/atarilegend.json').writeAsStringSync(jsonEncode({
      'schema_version': kAtariLegendSchemaVersion,
      'generated_at': 'now',
      'games': [
        {'id': 7, 'name': 'Another World', 'slug': 'another-world'},
      ],
    }));
    const rel = 'Falcon 030/Title Sorted/A/Another World/Another World.zip';
    Directory('${tmp.path}/root/Falcon 030/Title Sorted/A/Another World')
        .createSync(recursive: true);
    File('${tmp.path}/out/index-falcon.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        rel: {
          'rel': rel,
          'name': 'Another World.zip',
          'status': 'done',
          'kind': 'game',
          'layer': 'ROOT',
          'preview': null,
          'candidates': <String>[],
        },
      },
    }));

    final c = controller();
    await c.init();
    final card = c.universe.falcon.single;
    expect(card.folder, 'Another World');
    expect(card.atariLegend?.id, 7);
    expect(c.atariLegendForCard(card)?.id, 7);
    c.dispose();
  });

  test('curation keeps the AtariLegend match on the rebuilt cards', () async {
    File('$alDir/atarilegend.json').writeAsStringSync(jsonEncode({
      'schema_version': kAtariLegendSchemaVersion,
      'generated_at': 'now',
      'games': [
        {'id': 22, 'name': 'Alpha', 'slug': 'alpha'},
      ],
    }));
    const rel = 'Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.zip';
    File('${tmp.path}/out/$rel').parent.createSync(recursive: true);
    File('${tmp.path}/out/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        rel: {
          'rel': rel,
          'name': 'a.zip',
          'status': 'desktop',
          'kind': 'textscreen',
          'layer': 'ROOT',
          'preview': null,
          'candidates': <String>[],
        },
      },
    }));

    final c = controller();
    await c.init();
    final before = c.universe.cracked.firstWhere((x) => x.folder == 'Alpha');
    expect(before.atariLegend, isNotNull);
    // A crew/cracker focus filter copies the card (`applyFocus`); the
    // AtariLegend match must be carried over to the copy.
    expect(applyFocus(before, 'Some Crew', 'crew').atariLegend, isNotNull);

    // Manual curation rebuilds the universe in memory; the AtariLegend match
    // must survive (regression: `_rebuildUniverse` dropped it).
    c.applyStatusChange(rel, 'done', 'game');

    final after = c.universe.cracked.firstWhere((x) => x.folder == 'Alpha');
    expect(after.atariLegend, isNotNull);
    expect(c.hasAtariLegend, isTrue);
    c.dispose();
  });
}
