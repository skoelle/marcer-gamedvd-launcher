// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

const crackedRel =
    'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Alpha - Crew.zip';
const crackedPatch =
    'Title Sorted/Cracked Games - Title Sorted/B/Beta/Beta - Crew.zip';
const pdRel = 'Title Sorted/PD Games - Title Sorted/A/Alpha/Alpha.zip';

Map<String, dynamic> member(String name, String sha1) => {
  'name': name,
  'format': 'st',
  'crc32': 'b2aa7578',
  'size': 512,
  'raw': {'sha1': sha1, 'sha512': 'aa$sha1', 'crc32': 'b2aa7578', 'size': 512},
};

Map<String, dynamic> entry(
  String rel,
  String section, {
  String sha1 = 'sha',
  String layer = 'ROOT',
  String fingerprint = 'b2aa7578:512',
}) => {
  'section': section,
  'name': rel.split('/').last,
  'size': 624,
  'mtime': 1700000000,
  'layer': layer,
  'fingerprint': fingerprint,
  'members': [member('game.st', sha1)],
};

void writeFullIndex(Directory dir, Map<String, dynamic> entries) {
  final payload = {
    'schema': 1,
    'tool': 'tools/full-index-gen',
    'counts': {'zips': entries.length, 'members': entries.length, 'errors': 0},
    'errors': const [],
    'entries': entries,
  };
  File('${dir.path}/full-index.json.gz')
      .writeAsBytesSync(gzip.encode(utf8.encode(jsonEncode(payload))));
}

void main() {
  late Directory tmp;
  late Directory gameinfo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('full_index_test');
    gameinfo = Directory('${tmp.path}/data/gameinfo')
      ..createSync(recursive: true);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('loads entries, hashes and the fingerprint index', () {
    writeFullIndex(gameinfo, {
      crackedRel: entry(crackedRel, 'cracked', sha1: 'aaa'),
      pdRel: entry(pdRel, 'pd', sha1: 'bbb', fingerprint: 'deadbeef:512'),
    });
    final full = FullIndex.load(gameinfo.path);
    expect(full.isEmpty, isFalse);
    expect(full.entries.length, 2);
    expect(full.bySection['cracked']!.length, 1);
    expect(full.bySection['pd']!.length, 1);
    expect(full.hashesForRel(crackedRel).single['sha1'], 'aaa');
    expect(full.hashesForFingerprint('deadbeef:512').single['sha1'], 'bbb');
    expect(full[crackedRel]!.layer, 'ROOT');
  });

  test('missing index degrades to empty without throwing', () {
    final full = FullIndex.load(gameinfo.path, warnings: []);
    expect(full.isEmpty, isTrue);
    expect(full.hashesForRel(crackedRel), isEmpty);
  });

  test('merge keeps screenshot state and adds new ZIPs as pending', () {
    writeFullIndex(gameinfo, {
      crackedRel: entry(crackedRel, 'cracked'),
      crackedPatch: entry(crackedPatch, 'cracked', sha1: 'ccc'),
    });
    final screenshotsDir = Directory('${tmp.path}/shots')..createSync();
    File('${screenshotsDir.path}/index.json').writeAsStringSync(
      jsonEncode({
        'entries': {
          crackedRel: {
            'rel': crackedRel,
            'name': 'Alpha - Crew.zip',
            'status': 'done',
            'kind': 'game',
            'layer': 'ROOT',
            'preview': 'alpha.png',
            'candidates': ['alpha_c01.png'],
            'size': 624,
          },
          'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Legacy.zip': {
            'rel':
                'Title Sorted/Cracked Games - Title Sorted/A/Alpha/Legacy.zip',
            'name': 'Legacy.zip',
            'status': 'done',
            'layer': 'ROOT',
            'preview': 'legacy.png',
            'candidates': <String>[],
          },
        },
      }),
    );

    final shots = ScreenshotIndices.load(screenshotsDir.path);
    final merged = ScreenshotIndices.merge(
      screenshots: shots,
      full: FullIndex.load(gameinfo.path),
    );
    final cracked = merged.forSection('cracked');

    final overlaid = cracked[crackedRel]!;
    expect(overlaid.status, 'done');
    expect(overlaid.preview, 'alpha.png');
    expect(overlaid.candidates, ['alpha_c01.png']);

    final newZip = cracked[crackedPatch]!;
    expect(newZip.status, 'pending');
    expect(newZip.preview, isNull);
    expect(newZip.size, 624);

    final legacy =
        cracked['Title Sorted/Cracked Games - Title Sorted/A/Alpha/Legacy.zip'];
    expect(legacy?.status, 'done');
    expect(legacy?.preview, 'legacy.png');
  });

  test('CatalogBundle builds the catalog from the full index alone', () {
    writeFullIndex(gameinfo, {
      crackedRel: entry(crackedRel, 'cracked', sha1: 'aaa'),
    });
    final bundle = CatalogBundle.loadSync(
      screenshotDir: '${tmp.path}/missing-shots',
      gameinfoDir: gameinfo.path,
    );
    expect(bundle.fullIndex.entries.length, 1);
    final alpha = bundle.universe.cracked.firstWhere(
      (card) => card.folder == 'Alpha',
    );
    expect(alpha.variants.length, 1);
    expect(alpha.variants.single.status, 'pending');
    expect(alpha.screenshots, isFalse);
    expect(bundle.index[crackedRel]!.status, 'pending');
  });
}
