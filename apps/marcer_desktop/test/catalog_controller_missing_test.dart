// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:path/path.dart' as p;

/// MISSING detection + local layer (app-only divergence): the catalog is built
/// from the screenshot index + gameinfo without any filesystem scan, so an
/// index entry can reference a ZIP the user has not synced yet. `variantMissing`
/// / `cardMissing` flag exactly that on demand (lazy + cached, cleared on
/// init), and `zipLayer`/`variantLayer`/`cardLayer` resolve the layer
/// (`ROOT`/`PATCH`/`BOTH`) from the same local check instead of the published
/// index layer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const crackedTree = 'Title Sorted/Cracked Games - Title Sorted';
  const relAlphaA = '$crackedTree/A/Alpha/a.zip';
  const relAlphaB = '$crackedTree/A/Alpha/a_v2.zip';
  const relBeta = '$crackedTree/B/Beta/beta.zip';
  const relGamma = '$crackedTree/C/Gamma/gamma.zip';
  // Published as PATCH but physically present in ROOT (moved by the user).
  const relDelta = '$crackedTree/D/Delta/delta.zip';
  // One variant in root, one in patch → card layer BOTH.
  const relEpsA = '$crackedTree/E/Epsilon/e.zip';
  const relEpsB = '$crackedTree/E/Epsilon/e_v2.zip';

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
    // Delta: index says PATCH, but the file actually lives in root.
    File('${tmp.path}/root/$relDelta')
      ..parent.createSync(recursive: true)
      ..createSync();
    // Epsilon: one variant in root, one in patch.
    File('${tmp.path}/root/$relEpsA')
      ..parent.createSync(recursive: true)
      ..createSync();
    File('${tmp.path}/patch/$relEpsB')
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
        relDelta: entry(relDelta, 'done', layer: 'PATCH'),
        relEpsA: entry(relEpsA, 'done'),
        relEpsB: entry(relEpsB, 'done', layer: 'PATCH'),
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
    c.dispose();
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

  test('layer is resolved locally (not from the published index layer)',
      () async {
    await c.init();

    // Alpha: a.zip in root, a_v2.zip absent.
    final alpha = crackedCard('A', 'Alpha');
    expect(
        c.variantLayer(alpha.variants.firstWhere((v) => v.rel == relAlphaA)),
        'ROOT');
    expect(
        c.variantLayer(alpha.variants.firstWhere((v) => v.rel == relAlphaB)),
        '');
    expect(c.cardLayer(alpha), 'ROOT');

    // Gamma: patch-only.
    expect(c.cardLayer(crackedCard('C', 'Gamma')), 'PATCH');

    // Delta: published as PATCH but physically in root → local ROOT, not missing.
    final delta = crackedCard('D', 'Delta');
    expect(c.variantLayer(delta.variants.single), 'ROOT');
    expect(c.cardLayer(delta), 'ROOT');
    expect(c.cardMissing(delta), isFalse);

    // Epsilon: variants split across layers → BOTH.
    expect(c.cardLayer(crackedCard('E', 'Epsilon')), 'BOTH');

    // Beta: absent everywhere → no layer badge (MISSING instead).
    expect(c.cardLayer(crackedCard('B', 'Beta')), '');
  });

  test('cardFolderPath resolves the game folder per layer', () async {
    await c.init();
    final alpha = crackedCard('A', 'Alpha');
    const folder = '$crackedTree/A/Alpha';
    expect(c.cardFolderPath(alpha), p.join(tmp.path, 'root', folder));
    expect(c.cardFolderPath(alpha, patch: true),
        p.join(tmp.path, 'patch', folder));
    c.config = c.config.copyWith(patchDirectory: '');
    expect(c.cardFolderPath(alpha, patch: true), isNull);
  });

  test('cardFolderLayers reports only existing layer folders', () async {
    await c.init();
    expect(await c.cardFolderLayers(crackedCard('A', 'Alpha')), {'ROOT'});
    expect(await c.cardFolderLayers(crackedCard('C', 'Gamma')), {'PATCH'});
    expect(await c.cardFolderLayers(crackedCard('E', 'Epsilon')),
        {'ROOT', 'PATCH'});
    expect(await c.cardFolderLayers(crackedCard('B', 'Beta')), isEmpty);
  });

  test('zipLayer reports BOTH when a ZIP exists in both layers', () async {
    await c.init();
    expect(c.zipLayer(relAlphaA), 'ROOT');
    File('${tmp.path}/patch/$relAlphaA')
      ..parent.createSync(recursive: true)
      ..createSync();
    // Fresh controller: the caches are rebuilt on init.
    c = CatalogController(DesktopConfig(
      rootDirectory: '${tmp.path}/root',
      patchDirectory: '${tmp.path}/patch',
      screenshotDirectory: '${tmp.path}/out',
      gameinfoDirectory: '${tmp.path}/data',
    ));
    await c.init();
    expect(c.zipLayer(relAlphaA), 'BOTH');
    expect(c.cardLayer(crackedCard('A', 'Alpha')), 'BOTH');
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

  test('cached layer/missing are unknown until the async scan lands', () async {
    await c.init();
    final alpha = crackedCard('A', 'Alpha');
    // Before any scan: no synchronous filesystem access, unknown state.
    expect(c.cachedCardLayer(alpha), isNull);
    expect(c.cachedCardMissing(alpha), isNull);

    c.ensureCardScanned(alpha);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(c.cachedCardLayer(alpha), 'ROOT');
    expect(c.cachedCardMissing(alpha), isFalse);

    final beta = crackedCard('B', 'Beta');
    c.ensureCardScanned(beta);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.cachedCardLayer(beta), '');
    expect(c.cachedCardMissing(beta), isTrue);
  });

  test('metadata-only cards resolve their folder asynchronously', () async {
    await c.init();
    final ghosts = c.universe.pd.firstWhere((x) => x.folder == 'Ghosts');
    expect(c.cachedCardLayer(ghosts), isNull);
    expect(c.cachedVariantsOfCard(ghosts), isNull);

    c.ensureCardScanned(ghosts);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.cachedCardLayer(ghosts), 'ROOT');
    expect(c.cachedCardMissing(ghosts), isFalse);
    expect(c.cachedVariantsOfCard(ghosts)?.length, 1);

    final pacman = c.universe.pd.firstWhere((x) => x.folder == 'PacMan');
    c.ensureCardScanned(pacman);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.cachedCardLayer(pacman), '');
    expect(c.cachedCardMissing(pacman), isTrue);
  });

  test('statusLine is memoized per section', () async {
    await c.init();
    final first = c.statusLine;
    expect(identical(c.statusLine, first), isTrue);
  });
}
