// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';

/// Favorites behavior of [CatalogController] (user decisions 2026-10-15):
/// per-section files, section-scoped ★ filter/folders, any-variant favorite,
/// lazy pd ZIP resolution and foreign (other-OS) line pass-through.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const crackedTree = 'Title Sorted/Cracked Games - Title Sorted';
  const pdTree = 'Title Sorted/PD Games - Title Sorted';
  const utilsTree = 'Utilitys - Title Sorted';
  const relA = '$crackedTree/A/Alpha/a.zip';
  const relV2 = '$crackedTree/A/Alpha/a_v2.zip';
  const relPd = '$pdTree/P/PacMan/pacman.zip';

  String rootZip(String rel) => '${tmp.path}/root/$rel';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('favorites_ctrl_test');
    for (final rel in [
      relA,
      relV2,
      relPd,
      '$utilsTree/U/Uni/uni.zip',
    ]) {
      final file = File('${tmp.path}/root/$rel');
      file.parent.createSync(recursive: true);
      file.createSync();
    }
    Directory('${tmp.path}/patch/Title Sorted').createSync(recursive: true);
    Directory('${tmp.path}/data').createSync(recursive: true);
    Directory('${tmp.path}/out').createSync(recursive: true);
    // Screenshot index: a.zip (done + preview → launch variant), a_v2.zip
    // (desktop, no preview); both in the ROOT layer.
    File('${tmp.path}/out/index.json').writeAsStringSync(jsonEncode({
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
        relV2: {
          'rel': relV2,
          'name': 'a_v2.zip',
          'status': 'desktop',
          'layer': 'ROOT',
          'preview': null,
          'candidates': <String>[],
        },
      },
    }));
    File('${tmp.path}/data/games-pd.json').writeAsStringSync(jsonEncode({
      'games': [
        {
          'letter': 'P',
          'folder': 'PacMan',
          'layers': ['ROOT'],
          'matched_via': 'folder',
          'matched_title': 'Pac-Man',
          'variants': [
            {'title': 'Pac-Man'}
          ],
        },
      ],
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

  test(
      'favorites are stored per section file; foreign console lines pass '
      'through and the flat view keeps folder/section context', () async {
    final sectionFile = File('${tmp.path}/patch/$crackedTree/favorites.txt');
    sectionFile.parent.createSync(recursive: true);
    const foreign =
        r'Y:\Downloads\MarcersGameDVD\Title Sorted\Cracked Games - Title Sorted\D\Dal X.zip';
    sectionFile.writeAsStringSync('$foreign\n');

    await c.init();
    expect(c.sectionTrees, {
      'cracked': crackedTree,
      'pd': pdTree,
      'utils': utilsTree,
    });

    // Catalog `*` on the cracked card (launch variant a.zip).
    c.toggleFavoriteSelected();
    final written = sectionFile.readAsStringSync();
    expect(written, contains('Alpha/a.zip'));
    expect(written, contains(r'Y:\Downloads'), reason: 'console line kept');
    expect(File('${tmp.path}/patch/favorites.txt').existsSync(), isFalse,
        reason: 'must not fall back to the "too high" patch-root file');

    // Flat favorites view: our entry only, with extension, folder and section.
    c.setPath(favoritesRelFor('cracked'));
    final entries = c.visibleEntries;
    expect(entries, hasLength(1), reason: 'foreign line is not rendered');
    expect(entries.single.name, 'a.zip');
    expect(c.isFavorite(entries.single), isTrue);
    expect(c.folderRelOf(entries.single), '$crackedTree/A/Alpha');
    expect(CatalogController.shortFolder(c.folderRelOf(entries.single)),
        '…/A/Alpha');
    expect(c.sectionOf(entries.single), 'Cracked');
  });

  test('init migrates legacy misc favorites into the section file', () async {
    final misc = File('${tmp.path}/patch/favorites.txt')
      ..writeAsStringSync('${rootZip(relA)}\n/other/Legacy.zip\n');

    await c.init();

    final sectionFile = File('${tmp.path}/patch/$crackedTree/favorites.txt');
    expect(sectionFile.readAsStringSync(), contains('Alpha/a.zip'));
    expect(misc.readAsStringSync(), isNot(contains('Alpha/a.zip')));
    expect(misc.readAsStringSync(), contains('Legacy.zip'));
    expect(c.favorites!.pathsForSection('cracked'),
        contains(rootZip(relA)));
  });

  test('★ lists the active section and ignores status/facets', () async {
    await c.init();
    c.toggleFavoriteSelected(); // cracked card → cracked section file
    expect(
        File('${tmp.path}/patch/$crackedTree/favorites.txt').readAsStringSync(),
        contains('Alpha/a.zip'));

    c.setSection('pd');
    expect(c.catalogCards, hasLength(1));
    c.toggleFavoriteSelected(); // pd card → pd section file
    expect(File('${tmp.path}/patch/$pdTree/favorites.txt').readAsStringSync(),
        contains('pacman.zip'));

    c.setSection('cracked');
    c.setStatus('desktop'); // card displayStatus is `done` → filtered out
    expect(c.catalogCards, isEmpty);

    c.toggleFavoritesOnly();
    expect(c.catalogCards, hasLength(1));
    expect(c.catalogCards.single.kind, 'cracked');
    expect(c.countText, '1 favorites');

    // Switching section applies the ★ filter to that section.
    c.setSection('pd');
    expect(c.catalogCards, hasLength(1));
    expect(c.catalogCards.single.kind, 'pd');

    // The text search stays active inside the ★ filter.
    c.setQuery('zzz-nope');
    expect(c.catalogCards, isEmpty);
    c.setQuery('');
    expect(c.catalogCards, hasLength(1));

    c.resetFilters();
    expect(c.favoritesOnly, isFalse);
    c.setSection('cracked');
    expect(c.catalogCards, hasLength(1));
  });

  test('root shows one Favorites folder per section', () async {
    await c.init();
    c.toggleFavoriteSelected(); // cracked
    c.setSection('pd');
    c.toggleFavoriteSelected(); // pd

    c.toggleView(); // folder browser
    c.setPath('');
    final virtual = c.visibleEntries.where((e) => e.isVirtual).toList();
    expect(virtual.map((e) => e.name).toList(),
        ['Favorites (games)', 'Favorites (pd)']);

    final games = virtual.firstWhere((e) => e.name == 'Favorites (games)');
    c.setPath(c.favoritesRelForEntry(games)!);
    expect(c.visibleEntries, hasLength(1));
    expect(c.visibleEntries.single.name, 'a.zip');
    expect(c.favoritesViewSection, 'cracked');
    c.parent();
    expect(c.currentRel, '');

    final pd = virtual.firstWhere((e) => e.name == 'Favorites (pd)');
    c.setPath(c.favoritesRelForEntry(pd)!);
    expect(c.visibleEntries, hasLength(1));
    expect(c.visibleEntries.single.name, 'pacman.zip');
    expect(c.favoritesViewSection, 'pd');
  });

  test(
      'any favorited ZIP marks the card; `*` removes the single starred '
      'variant and only falls back to the launch variant otherwise', () async {
    await c.init();
    final card = c.catalogCards.first;
    expect(c.isFavoriteCard(card), isFalse);

    // Favorite the NON-launch variant directly → card must show in ★ anyway.
    c.toggleFavoritePath(rootZip(relV2));
    expect(c.isFavoriteCard(card), isTrue);
    expect(c.favoriteKeysOfCard(card), [rootZip(relV2)]);
    expect(c.favorites!.contains(rootZip(relA)), isFalse);

    // `*` un-favorites the single starred ZIP (what the star displays).
    c.toggleFavoriteSelected();
    expect(c.isFavoriteCard(card), isFalse);
    expect(c.favorites!.isEmpty, isTrue);

    // Two starred variants: `*` toggles the launch variant only.
    c.toggleFavoritePath(rootZip(relV2));
    c.toggleFavoritePath(rootZip(relA));
    expect(c.favoriteKeysOfCard(card), hasLength(2));
    c.toggleFavoriteSelected();
    expect(c.favorites!.contains(rootZip(relA)), isFalse);
    expect(c.isFavoriteCard(card), isTrue);
  });

  test('pd cards resolve their folder ZIPs lazily and cache the result',
      () async {
    await c.init();
    c.setSection('pd');
    final card = c.catalogCards.first;
    expect(card.variants, isEmpty,
        reason: 'the universe itself never scans the filesystem');

    final resolved = c.variantsOfCard(card);
    expect(resolved.single.rel, relPd);
    expect(identical(resolved, c.variantsOfCard(card)), isTrue,
        reason: 'second call hits the cache');
    expect(c.favoriteKeyOfCard(card), rootZip(relPd));
    expect(c.isFavoriteCard(card), isFalse);
  });

  test('paths outside every section tree land in the misc favorites file',
      () async {
    await c.init();
    final stray = '${tmp.path}/root/stray.zip';
    File(stray).createSync();

    c.toggleFavoritePath(stray);

    expect(File('${tmp.path}/patch/favorites.txt').readAsStringSync(),
        contains('stray.zip'));
    expect(c.favorites!.contains(stray), isTrue);
  });

  test('canonical section trees win over decoy prefix matches', () async {
    // Real-DVD decoys that sort *before* `Title Sorted` — first-prefix-wins
    // used to pick them, which emptied the ★ filter and mis-filed toggles
    // into the misc favorites file (bug 2026-10-15).
    for (final rel in [
      'Bonus/Cracked Demos/D/demo.zip',
      'Bonus/PD Games - Data Disks/P/p.zip',
      'Crew Sorted/Utilitys - Scene and Cracks - Crew Sorted/U/u.zip',
    ]) {
      final f = File('${tmp.path}/root/$rel');
      f.parent.createSync(recursive: true);
      f.createSync();
    }

    await c.init();
    expect(c.sectionTrees, {
      'cracked': crackedTree,
      'pd': pdTree,
      'utils': utilsTree,
    });

    c.toggleFavoriteSelected();
    expect(
        File('${tmp.path}/patch/$crackedTree/favorites.txt').readAsStringSync(),
        contains('Alpha/a.zip'));
    expect(File('${tmp.path}/patch/favorites.txt').existsSync(), isFalse,
        reason: 'must not fall back to the misc file');
    expect(c.isFavoriteCard(c.catalogCards.single), isTrue);
  });

  test('a favorite deeper than the card folder (Original/) marks the card',
      () async {
    const relOrig = '$crackedTree/0-9/Nested/Original/n.zip';
    final zip = File('${tmp.path}/root/$relOrig');
    zip.parent.createSync(recursive: true);
    zip.createSync();
    final indexFile = File('${tmp.path}/out/index.json');
    final idx = jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;
    (idx['entries'] as Map<String, dynamic>)[relOrig] = {
      'rel': relOrig,
      'name': 'n.zip',
      'status': 'done',
      'kind': 'game',
      'layer': 'ROOT',
      'preview': null,
      'candidates': <String>[],
    };
    indexFile.writeAsStringSync(jsonEncode(idx));

    await c.init();
    c.setStatus('any'); // the preview-less Nested card only shows then
    final card = c.catalogCards.firstWhere((card) => card.folder == 'Nested');
    expect(card.letter, '0-9');
    expect(c.cardFolderRel(card), '$crackedTree/0-9/Nested');

    c.toggleFavoritePath(rootZip(relOrig));
    expect(c.isFavoriteCard(card), isTrue,
        reason: 'favorite dir is nested below the card folder');

    c.toggleFavoritesOnly();
    expect(c.catalogCards.single.folder, 'Nested');
  });
}
