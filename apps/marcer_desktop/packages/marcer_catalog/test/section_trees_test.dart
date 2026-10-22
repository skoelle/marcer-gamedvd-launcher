// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('section_trees_test');
    root = '${tmp.path}/root';
    for (final rel in [
      'Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.zip',
      'Title Sorted/PD Games - Title Sorted/P/PacMan/pacman.zip',
      'Utilitys - Title Sorted/U/Uni/uni.zip',
      'Other Stuff/readme.txt',
    ]) {
      final file = File('$root/$rel');
      file.parent.createSync(recursive: true);
      file.createSync();
    }
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('sectionOfTreeName', () {
    test('matches the gallery directory prefixes', () {
      expect(sectionOfTreeName('Cracked Games - Title Sorted'), 'cracked');
      expect(sectionOfTreeName('PD Games - Title Sorted'), 'pd');
      expect(sectionOfTreeName('Utilitys - Title Sorted'), 'utils');
      expect(sectionOfTreeName('Magazine Cover Disks'), 'magazine');
      expect(sectionOfTreeName('Title Sorted'), isNull);
      expect(sectionOfTreeName('Bonus'), isNull);
    });
  });

  group('discoverSectionTrees', () {
    test('finds trees at depth 1 and below a shared parent (depth 2)', () {
      final browser = OverlayBrowser(rootDir: root);
      expect(discoverSectionTrees(browser), {
        'cracked': 'Title Sorted/Cracked Games - Title Sorted',
        'pd': 'Title Sorted/PD Games - Title Sorted',
        'utils': 'Utilitys - Title Sorted',
      });
    });

    test('trees directly below the root are found at depth 1', () {
      final shallow = '${tmp.path}/shallow';
      Directory('$shallow/Cracked Games - Title Sorted/A')
          .createSync(recursive: true);
      final browser = OverlayBrowser(rootDir: shallow);
      expect(discoverSectionTrees(browser),
          {'cracked': 'Cracked Games - Title Sorted'});
    });

    test('canonical tree wins over decoy prefix matches (real-DVD layout)',
        () {
      // Decoys sort before `Title Sorted` — first-prefix-wins used to pick
      // them (bug 2026-10-15).
      final decoy = '${tmp.path}/decoy';
      for (final rel in [
        'Bonus/Cracked Demos/A/demo.zip',
        'Bonus/PD Games - Data Disks/P/p.zip',
        'Crew Sorted/Utilitys - Scene and Cracks - Crew Sorted/U/u.zip',
        'Title Sorted/Cracked Games - Title Sorted/A/a.zip',
        'Title Sorted/PD Games - Title Sorted/P/p.zip',
        'Title Sorted/Utilitys - Title Sorted/U/u.zip',
      ]) {
        final file = File('$decoy/$rel');
        file.parent.createSync(recursive: true);
        file.createSync();
      }
      final browser = OverlayBrowser(rootDir: decoy);
      expect(discoverSectionTrees(browser), {
        'cracked': 'Title Sorted/Cracked Games - Title Sorted',
        'pd': 'Title Sorted/PD Games - Title Sorted',
        'utils': 'Title Sorted/Utilitys - Title Sorted',
      });
    });

    test('prefix fallback keeps the only candidate without a canonical name',
        () {
      final only = '${tmp.path}/only';
      Directory('$only/Bonus/Cracked Demos/A').createSync(recursive: true);
      final browser = OverlayBrowser(rootDir: only);
      expect(discoverSectionTrees(browser),
          {'cracked': 'Bonus/Cracked Demos'});
    });

    test('discovers the magazine cover disks tree under Bonus', () {
      final mag = '${tmp.path}/mag';
      Directory('$mag/Bonus/Magazine Cover Disks/Zero - Complete')
          .createSync(recursive: true);
      final browser = OverlayBrowser(rootDir: mag);
      expect(discoverSectionTrees(browser),
          {'magazine': 'Bonus/Magazine Cover Disks'});
    });
  });

  group('sectionOfRel', () {
    final trees = {
      'cracked': 'Title Sorted/Cracked Games - Title Sorted',
      'pd': 'Title Sorted/PD Games - Title Sorted',
    };

    test('classifies paths inside a tree, the tree itself and outsiders', () {
      expect(sectionOfRel(trees, 'Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.zip'),
          'cracked');
      expect(sectionOfRel(trees, 'Title Sorted/PD Games - Title Sorted'), 'pd');
      expect(sectionOfRel(trees, 'Title Sorted/Other/x.zip'), isNull);
      expect(sectionOfRel(trees, ''), isNull);
    });

    test('a prefix that is not a path boundary does not match', () {
      expect(
          sectionOfRel(trees, 'Title Sorted/Cracked Games - Title SortedXX/a.zip'),
          isNull);
    });

    test('classifies Windows-separated relative paths', () {
      expect(
          sectionOfRel(
              trees,
              r'Title Sorted\Cracked Games - Title Sorted\A\Alpha\a.zip'),
          'cracked');
      expect(
          sectionOfRel(
              trees, r'Title Sorted\PD Games - Title Sorted\P\PacMan\p.zip'),
          'pd');
      expect(sectionOfRel(trees, r'Title Sorted\Other\a.zip'), isNull);
    });
  });

  group('GameCard.kind', () {
    test('cards carry their section kind (per-section favorites mapping)', () {
      const rel = 'Title Sorted/Cracked Games - Title Sorted/A/Alpha/a.zip';
      final cracked = buildIndexedCard(
        kind: 'cracked',
        letter: 'A',
        folder: 'Alpha',
        items: [
          (
            rel,
            ScreenshotEntry(
              rel: rel,
              name: 'a.zip',
              status: 'done',
              kind: 'game',
              layer: 'ROOT',
              preview: 'a.png',
              candidates: const [],
            ),
          ),
        ],
        game: null,
        fullPng: (rel, base) => '$rel/$base',
      );
      expect(cracked.kind, 'cracked');

      final pd = buildSimpleCard(
        game: GameInfo(
          folder: 'PacMan',
          letter: 'P',
          layers: const ['ROOT'],
          matchedVia: 'folder',
          matchedTitle: 'Pac-Man',
          variants: const [],
          kind: 'pd',
        ),
        kind: 'pd',
      );
      expect(pd.kind, 'pd');
    });
  });
}
