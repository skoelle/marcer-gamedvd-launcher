// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String root;
  late String patch;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('marcer_catalog_test');
    root = '${tmp.path}/root';
    patch = '${tmp.path}/patch';
    Directory('$root/Games').createSync(recursive: true);
    Directory('$root/Tools').createSync();
    File('$root/Games/alpha.zip').createSync();
    File('$root/beta.zip').createSync();
    File('$root/readme.txt').createSync();
    File('$root/.hidden.zip').createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('OverlayBrowser', () {
    test('lists dirs first, then zips, ignores non-zip and hidden', () {
      final b = OverlayBrowser(rootDir: root);
      final entries = b.list('');
      final names = entries.map((e) => e.name).toList();
      expect(names, ['Games', 'Tools', 'beta.zip']);
      expect(entries[0].kind, EntryKind.directory);
      expect(entries[2].kind, EntryKind.zip);
    });

    test('root-only entries report ROOT layer', () {
      final b = OverlayBrowser(rootDir: root);
      final entries = b.list('');
      expect(entries.first.layerStatus, LayerStatus.root);
    });

    test('patch entry wins and reports BOTH', () {
      Directory('$patch/Games').createSync(recursive: true);
      File('$patch/Games/alpha.zip').createSync();
      File('$patch/Games/beta.zip').createSync();
      final b = OverlayBrowser(rootDir: root, patchDir: patch);
      final entries = b.list('Games');
      final alpha = entries.firstWhere((e) => e.name == 'alpha.zip');
      final beta = entries.firstWhere((e) => e.name == 'beta.zip');
      expect(alpha.layerStatus, LayerStatus.both);
      expect(alpha.effectivePath, '$patch/Games/alpha.zip');
      expect(beta.layerStatus, LayerStatus.patch);
    });

    test('case-insensitive dedup keeps single entry', () {
      File('$root/Games/Alpha.zip').createSync();
      final b = OverlayBrowser(rootDir: root);
      final entries = b.list('Games');
      expect(entries.where((e) => e.name.toLowerCase() == 'alpha.zip').length, 1);
    });

    test('traversal rel path resets to root listing (R16)', () {
      final b = OverlayBrowser(rootDir: root);
      final names = b.list('../../etc').map((e) => e.name).toList();
      expect(names, ['Games', 'Tools', 'beta.zip']);
    });

    test('parent at root stays root (R17)', () {
      final b = OverlayBrowser(rootDir: root);
      expect(b.parent(''), '');
      expect(b.parent('Games'), '');
      expect(b.parent('Games/Sub'), 'Games');
    });

    test('missing patch dir disables patch layer (R13)', () {
      final b =
          OverlayBrowser(rootDir: root, patchDir: '${tmp.path}/does-not-exist');
      expect(b.hasPatchLayer, false);
      final entries = b.list('');
      expect(entries.every((e) => e.layerStatus == LayerStatus.root), true);
    });
  });

  group('ScreenshotIndex', () {
    test('missing index.json degrades to empty with loadError', () {
      final idx = ScreenshotIndex.load('${tmp.path}/no-such-dir');
      expect(idx.length, 0);
      expect(idx.loadError, isNotNull);
    });

    test('preview basename resolves against rel dirname', () {
      final out = '${tmp.path}/out';
      Directory('$out/Games').createSync(recursive: true);
      File('$out/Games/alpha.png').createSync();
      File('$out/index.json').writeAsStringSync('''
        {"version": 1, "entries": {
          "Games/alpha.zip": {"rel": "Games/alpha.zip", "name": "alpha",
            "status": "done", "kind": "game", "layer": "ROOT",
            "preview": "alpha.png", "candidates": []}
        }}''');
      final idx = ScreenshotIndex.load(out);
      expect(idx.length, 1);
      expect(idx.previewPathFor('Games/alpha.zip'), '$out/Games/alpha.png');
      expect(idx.previewPathFor('missing.zip'), isNull);
    });
  });

  group('GameInfoIndex', () {
    test('missing data dir degrades to empty', () {
      final idx = GameInfoIndex.load('${tmp.path}/no-data');
      expect(idx.length, 0);
    });

    test('joins by letter/folder from rel path', () {
      final data = '${tmp.path}/data';
      Directory(data).createSync();
      File('$data/games-cracked.json').writeAsStringSync('''
        {"schema_version": 1, "kind": "cracked", "games": [
          {"folder": "Alpha Game", "letter": "A", "layers": ["ROOT"],
           "matched_via": "exact", "matched_title": "Alpha Game",
           "variants": [{"title": "Alpha Game"}]}
        ]}''');
      final idx = GameInfoIndex.load(data);
      final info = idx.lookupByRel(
          'Title Sorted/Cracked Games - Title Sorted/A/Alpha Game/Alpha.zip');
      expect(info, isNotNull);
      expect(info!.folder, 'Alpha Game');
      expect(idx.lookupByRel('too/short.zip'), isNull);
    });
  });

  group('DesktopConfig', () {
    test('parses config file', () {
      final f = File('${tmp.path}/desktop.config.json')
        ..writeAsStringSync('''
        {"RootDirectory": "/r", "PatchDirectory": "/p",
         "OutDirectory": "/o", "DataDirectory": "/d",
         "Window": {"width": 1024, "height": 768}}''');
      final c = DesktopConfig.load(f.path);
      expect(c.rootDirectory, '/r');
      expect(c.outDirectory, '/o');
      expect(c.windowWidth, 1024);
      expect(c.hatariArgsTemplate, contains('{zip}'));
    });
  });
}
