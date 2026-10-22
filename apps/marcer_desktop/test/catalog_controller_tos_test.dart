// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';

/// Non-default TOS marker (screenshot generator's TOS-1.02 retry): a card
/// whose index variant carries `tos: "1.02"` gets a `TOS 1.02` marker and the
/// primary Play action preselects the matching launch variant, while the
/// default TOS leaves both empty (`SPEC-screenshot-generator.md` §7.5).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const tree = 'Title Sorted/Cracked Games - Title Sorted';
  const relOld = '$tree/B/Bellum/bellum.zip';
  const relOld100 = '$tree/O/Old/old.zip';
  const relNew = '$tree/S/Star/star.zip';

  Map<String, dynamic> entry(String rel, {String? tos}) => {
        'rel': rel,
        'name': rel.split('/').last,
        'status': 'done',
        'kind': 'game',
        'layer': 'ROOT',
        'preview': null,
        'candidates': <String>[],
        'tos': ?tos,
      };

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tos_marker_test');
    Directory('${tmp.path}/data').createSync(recursive: true);
    Directory('${tmp.path}/out').createSync(recursive: true);
    File('${tmp.path}/out/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        relOld: entry(relOld, tos: '1.02'),
        relOld100: entry(relOld100, tos: '1.00'),
        relNew: entry(relNew),
      },
    }));
    c = CatalogController(DesktopConfig(
      rootDirectory: '${tmp.path}/root',
      patchDirectory: '${tmp.path}/patch',
      screenshotDirectory: '${tmp.path}/out',
      gameinfoDirectory: '${tmp.path}/data',
    ));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('non-default TOS preselects the matching Play variant', () async {
    await c.init();
    final bellum = c.universe.cracked.firstWhere((x) => x.folder == 'Bellum');
    expect(bellum.tosVersion, '1.02');
    final variant = c.defaultVariantForCard(bellum);
    expect(variant, isNotNull);
    expect(variant!.tosVersions, contains('1.02'));

    final old = c.universe.cracked.firstWhere((x) => x.folder == 'Old');
    expect(old.tosVersion, '1.00');
    final variant100 = c.defaultVariantForCard(old);
    expect(variant100, isNotNull);
    expect(variant100!.tosVersions, contains('1.00'));

    final star = c.universe.cracked.firstWhere((x) => x.folder == 'Star');
    expect(star.tosVersion, isNull);
    expect(c.defaultVariantForCard(star), isNull);
  });
}
