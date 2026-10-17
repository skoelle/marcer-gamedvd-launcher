// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';

/// Robustness around a missing/partial catalog: a malformed gameinfo file or a
/// missing screenshot index must degrade to a notice/banner, never leave the
/// app stuck on the loading screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('notice_test');
    Directory('${tmp.path}/root').createSync();
    Directory('${tmp.path}/out').createSync();
    Directory('${tmp.path}/data').createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  CatalogController controller() => CatalogController(DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        screenshotDirectory: '${tmp.path}/out',
        gameinfoDirectory: '${tmp.path}/data',
      ));

  test('malformed gameinfo + missing index do not throw and raise a notice',
      () async {
    File('${tmp.path}/data/games-cracked.json')
        .writeAsStringSync('{"games": [ {"folder"');

    final c = controller();
    await c.init();

    expect(c.initError, isNull);
    expect(c.ready, isTrue);
    expect(c.catalogDataNotice, isNotNull);
    expect(c.catalogDataNotice, contains('Download from FTP'));
  });

  test('a populated catalog has no data notice', () async {
    const rel = 'Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.zip';
    File('${tmp.path}/out/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        rel: {
          'rel': rel,
          'name': 'a.zip',
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

    expect(c.ready, isTrue);
    expect(c.catalogDataNotice, isNull);
  });
}
