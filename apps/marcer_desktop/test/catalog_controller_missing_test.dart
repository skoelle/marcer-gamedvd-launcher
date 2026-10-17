// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';

/// MISSING detection (app-only divergence): the catalog is built from the
/// screenshot index + gameinfo without any filesystem scan, so an index
/// entry can reference a ZIP the user has not synced yet. `variantMissing` /
/// `cardMissing` flag exactly that on demand (lazy + cached, cleared on init).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const crackedTree = 'Title Sorted/Cracked Games - Title Sorted';
  const relAlphaA = '$crackedTree/A/Alpha/a.zip';
  const relAlphaB = '$crackedTree/A/Alpha/a_v2.zip';
  const relBeta = '$crackedTree/B/Beta/beta.zip';
  const relGamma = '$crackedTree/C/Gamma/gamma.zip';

  Map<String, dynamic> entry(String rel, String status,
          {String layer = 'ROOT'}) =>
      {
        'rel': rel,
        'name': rel.split('/').last,
        'status': status,
        'kind': status == 'done' ? 'game' : null,
        'layer': layer,
        'preview': null,
        'candidates': <String>[],
      };

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('missing_test');
    // Alpha: a.zip present in root, a_v2.zip absent.
    File('${tmp.path}/root/$relAlphaA')
      ..parent.createSync(recursive: true)
      ..createSync();
    // Gamma: present in the patch layer only.
    File('${tmp.path}/patch/$relGamma')
      ..parent.createSync(recursive: true)
      ..createSync();
    // Beta: no file at all.
    Directory('${tmp.path}/data').createSync(recursive: true);
    Directory('${tmp.path}/out').createSync(recursive: true);
    File('${tmp.path}/out/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        relAlphaA: entry(relAlphaA, 'done'),
        relAlphaB: entry(relAlphaB, 'pending'),
        relBeta: entry(relBeta, 'done'),
        relGamma: entry(relGamma, 'done', layer: 'PATCH'),
      },
    }));
    // pd gameinfo-only folders: Ghosts exists on disk, PacMan does not.
    File('${tmp.path}/data/games-pd.json').writeAsStringSync(jsonEncode({
      'games': [
        {
          'letter': 'P',
          'folder': 'PacMan',
          'layers': ['ROOT'],
          'matched_via': 'folder',
          'matched_title': 'Pac-Man',
          'variants': <Map<String, dynamic>>[],
        },
        {
          'letter': 'G',
          'folder': 'Ghosts',
          'layers': ['ROOT'],
          'matched_via': 'folder',
          'matched_title': 'Ghosts',
          'variants': <Map<String, dynamic>>[],
        },
      ],
    }));
    File('${tmp.path}/root/Title Sorted/PD Games - Title Sorted/G/Ghosts/g.zip')
      ..parent.createSync(recursive: true)
      ..createSync();
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

  GameCard crackedCard(String letter, String folder) => c.universe.cracked
      .firstWhere((x) => x.letter == letter && x.folder == folder);

  test('cracked card is missing when none of its variants exists locally',
      () async {
    await c.init();

    final alpha = crackedCard('A', 'Alpha');
    expect(alpha.variants.length, 2);
    expect(
        c.variantMissing(
            alpha.variants.firstWhere((v) => v.rel == relAlphaB)),
        isTrue);
    expect(
        c.variantMissing(
            alpha.variants.firstWhere((v) => v.rel == relAlphaA)),
        isFalse);
    expect(c.cardMissing(alpha), isFalse,
        reason: 'a.zip is present in root');

    expect(c.cardMissing(crackedCard('B', 'Beta')), isTrue,
        reason: 'no beta.zip in either layer');
    expect(c.cardMissing(crackedCard('C', 'Gamma')), isFalse,
        reason: 'gamma.zip is present in the patch layer');
  });

  test('pd metadata-only cards reflect the folder presence', () async {
    await c.init();
    final ghosts = c.universe.pd.firstWhere((x) => x.folder == 'Ghosts');
    expect(c.cardMissing(ghosts), isFalse);
    final pacman = c.universe.pd.firstWhere((x) => x.folder == 'PacMan');
    expect(c.cardMissing(pacman), isTrue, reason: 'no ZIP/folder on disk');
  });

  test('a reload with a fresh controller sees newly synced files', () async {
    await c.init();
    expect(c.cardMissing(crackedCard('B', 'Beta')), isTrue);
    File('${tmp.path}/root/$relBeta')
      ..parent.createSync(recursive: true)
      ..createSync();
    // Settings reloads build a fresh controller (HomePage._applyConfig).
    c = CatalogController(DesktopConfig(
      rootDirectory: '${tmp.path}/root',
      patchDirectory: '${tmp.path}/patch',
      screenshotDirectory: '${tmp.path}/out',
      gameinfoDirectory: '${tmp.path}/data',
    ));
    await c.init();
    expect(c.cardMissing(crackedCard('B', 'Beta')), isFalse);
  });
}
