// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

/// `CatalogBundle.load` runs the (potentially slow) JSON parsing in a
/// background isolate and streams `Loading <file>…` messages back so the UI can
/// show per-file progress on the loading screen.
void main() {
  late Directory tmp;
  late String out;
  late String data;

  const relA = 'Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.zip';

  Map<String, dynamic> entry(String rel) => {
        'rel': rel,
        'name': rel.split('/').last,
        'status': 'done',
        'kind': 'game',
        'layer': 'ROOT',
        'preview': null,
        'candidates': <String>[],
      };

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bundle_load_test');
    out = '${tmp.path}/out';
    data = '${tmp.path}/data';
    Directory(out).createSync(recursive: true);
    Directory(data).createSync(recursive: true);
    File('$out/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {relA: entry(relA)},
    }));
    File('$out/index-pd.json')
        .writeAsStringSync(jsonEncode({'version': 1, 'entries': <String, dynamic>{}}));
    File('$out/index-utils.json')
        .writeAsStringSync(jsonEncode({'version': 1, 'entries': <String, dynamic>{}}));
    File('$data/manifest.json').writeAsStringSync(
        jsonEncode({'generated_at': '2026-10-17', 'sources': <dynamic>[]}));
    File('$data/games-cracked.json').writeAsStringSync(jsonEncode({
      'games': [
        {
          'letter': 'A',
          'folder': 'Alpha',
          'layers': ['ROOT'],
          'matched_via': 'folder',
          'matched_title': 'Alpha',
          'variants': <Map<String, dynamic>>[],
        },
      ],
    }));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('reports load progress and returns the same bundle as loadSync',
      () async {
    final messages = <String>[];
    final bundle = await CatalogBundle.load(
      screenshotDir: out,
      gameinfoDir: data,
      onProgress: messages.add,
    );

    expect(messages, contains('Loading screenshot index…'));
    expect(messages, contains('Loading game metadata…'));
    expect(messages, contains('Building catalog — cracked…'));
    expect(messages, contains('Building catalog — pd…'));
    expect(messages, contains('Building catalog — utils…'));
    expect(messages, contains('Finalizing…'));
    // Per-section card counts are reported while building.
    expect(messages.any((m) => m.startsWith('Building catalog — cracked ')),
        isTrue);

    // Parity with the synchronous loader.
    final sync = CatalogBundle.loadSync(screenshotDir: out, gameinfoDir: data);
    expect(bundle.universe.cracked.length, sync.universe.cracked.length);
    expect(bundle.universe.cracked.single.folder, 'Alpha');
    expect(bundle.universe.cracked.single.letter, 'A');
  });

  test('degrades to empty data without throwing when dirs are missing',
      () async {
    final bundle = await CatalogBundle.load(
      screenshotDir: '${tmp.path}/nope-out',
      gameinfoDir: '${tmp.path}/nope-data',
    );
    expect(bundle.universe.cracked, isEmpty);
    expect(bundle.warnings, isNotEmpty);
    expect(bundle.atariLegend.length, 0);
  });

  test('loads the AtariLegend cache when configured', () async {
    final alDir = Directory('${tmp.path}/atarilegend')
      ..createSync(recursive: true);
    File('${alDir.path}/atarilegend.json').writeAsStringSync(jsonEncode({
      'schema_version': 1,
      'generated_at': 'now',
      'source': {'file': 'x.sql.gz', 'dump_date': '2026-10-18'},
      'games': [
        {'id': 22, 'name': 'Alpha', 'slug': 'alpha', 'year': 1990},
      ],
    }));

    final messages = <String>[];
    final bundle = await CatalogBundle.load(
      screenshotDir: out,
      gameinfoDir: data,
      atariLegendDir: alDir.path,
      onProgress: messages.add,
    );
    expect(messages, contains('Loading AtariLegend data…'));
    expect(bundle.atariLegend.length, 1);
    expect(bundle.atariLegend.matchFolder('Alpha')?.id, 22);
  });
}
