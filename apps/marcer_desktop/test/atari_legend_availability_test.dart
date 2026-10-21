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
}
