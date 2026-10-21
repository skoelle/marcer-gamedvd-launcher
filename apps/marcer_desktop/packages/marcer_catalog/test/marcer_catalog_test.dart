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

    test('malformed games file is skipped with a warning (no throw)', () {
      final data = '${tmp.path}/data-broken';
      Directory(data).createSync();
      // Truncated JSON must not abort the whole catalog load.
      File('$data/games-cracked.json').writeAsStringSync('{"games": [ {"folder"');
      File('$data/games-pd.json').writeAsStringSync('''
        {"games": [
          {"folder": "PacMan", "letter": "P", "layers": ["ROOT"],
           "matched_via": "folder", "matched_title": "Pac-Man",
           "variants": []}
        ]}''');
      final idx = GameInfoIndex.load(data);
      expect(idx.byKind('cracked'), isEmpty);
      expect(idx.byKind('pd'), hasLength(1));
      expect(idx.warnings.any((w) => w.contains('games-cracked.json')), isTrue);
    });

    test('a single broken game entry is skipped, the rest is kept', () {
      final data = '${tmp.path}/data-partial';
      Directory(data).createSync();
      File('$data/games-cracked.json').writeAsStringSync('''
        {"games": [
          {"folder": "Broken", "letter": 42},
          {"folder": "Good", "letter": "G", "layers": ["ROOT"],
           "matched_via": "folder", "matched_title": "Good", "variants": []}
        ]}''');
      final idx = GameInfoIndex.load(data);
      expect(idx.byKind('cracked'), hasLength(1));
      expect(idx.byKind('cracked').single.folder, 'Good');
    });
  });

  group('DesktopConfig', () {
    test('parses config file', () {
      final f = File('${tmp.path}/desktop.config.json')
        ..writeAsStringSync('''
        {"RootDirectory": "/r", "PatchDirectory": "/p",
         "ScreenshotDirectory": "/o", "GameinfoDirectory": "/d",
         "AtariLegendDirectory": "/al",
         "ShowCandidates": false, "DefaultStatus": "done",
         "Window": {"width": 1024, "height": 768, "maximized": false}}''');
      final c = DesktopConfig.load(f.path);
      expect(c.rootDirectory, '/r');
      expect(c.screenshotDirectory, '/o');
      expect(c.atariLegendDirectory, '/al');
      expect(c.windowWidth, 1024);
      expect(c.windowMaximized, isFalse);
      expect(c.hatariArgsTemplate, contains('{zip}'));
      expect(c.showCandidates, isFalse);
      expect(c.defaultStatus, 'done');
    });

    test('parses the Ftp section and marks it configured', () {
      final f = File('${tmp.path}/desktop.config.json')
        ..writeAsStringSync('''
        {"RootDirectory": "/r",
         "Ftp": {"Host": "ftp.example.com", "User": "u",
                 "Password": "p", "RemoteBase": "/dvd"}}''');
      final c = DesktopConfig.load(f.path);
      expect(c.ftpHost, 'ftp.example.com');
      expect(c.ftpUser, 'u');
      expect(c.ftpPassword, 'p');
      expect(c.ftpRemoteBase, '/dvd');
      expect(c.ftpConfigured, isTrue);
    });

    test('FTP is unconfigured by default; download target falls back to root',
        () {
      final f = File('${tmp.path}/desktop.config.json')
        ..writeAsStringSync('{"RootDirectory": "/r"}');
      final c = DesktopConfig.load(f.path);
      expect(c.ftpConfigured, isFalse);
      expect(c.ftpHost, '');
      expect(c.ftpUser, '');
      expect(c.ftpPassword, '');
      expect(c.ftpRemoteBase, '/GameDVD/',
          reason: 'default remote base directory');
      expect(c.ftpAssetsRemote, '/Uploads/MarcerGameDVDLauncher-assets/',
          reason: 'default catalog asset directory');
      expect(c.downloadTargetDirectory, '/r',
          reason: 'no PatchDirectory → root layer');
      expect(c.copyWith(patchDirectory: '/p').downloadTargetDirectory, '/p');
    });

    test('resolveGameinfoDirectory has no implicit fallback', () {
      final f = File('${tmp.path}/desktop.config.json')
        ..writeAsStringSync(
            '{"RootDirectory": "/r", "PatchDirectory": "/p"}');
      final c = DesktopConfig.load(f.path);
      expect(c.resolveGameinfoDirectory(), '',
          reason: 'no <Patch>/../Data fallback anymore');
      expect(c.copyWith(gameinfoDirectory: '/data').resolveGameinfoDirectory(),
          '/data');
    });

    test('resolveAtariLegendDirectory has no implicit fallback', () {
      final f = File('${tmp.path}/desktop.config.json')
        ..writeAsStringSync('{"RootDirectory": "/r"}');
      final c = DesktopConfig.load(f.path);
      expect(c.resolveAtariLegendDirectory(), '');
      expect(
          c.copyWith(atariLegendDirectory: '/al')
              .resolveAtariLegendDirectory(),
          '/al');
    });

    test('Ftp.Host parses an optional :port (default 21)', () {
      DesktopConfig host(String h) =>
          DesktopConfig(rootDirectory: '/r', ftpHost: h);
      expect(host('ftp.example.com').ftpHostName, 'ftp.example.com');
      expect(host('ftp.example.com').ftpPort, 21);
      expect(host('ftp.example.com:2121').ftpHostName, 'ftp.example.com');
      expect(host('ftp.example.com:2121').ftpPort, 2121);
      expect(host('ftp.example.com:').ftpHostName, 'ftp.example.com');
      expect(host('ftp.example.com:').ftpPort, 21);
      expect(host('host:abc').ftpHostName, 'host:abc',
          reason: 'a non-numeric suffix is kept as part of the host');
      expect(host('host:abc').ftpPort, 21);
      expect(host('[::1]').ftpHostName, '::1');
      expect(host('[::1]').ftpPort, 21);
      expect(host('[::1]:2121').ftpHostName, '::1');
      expect(host('[::1]:2121').ftpPort, 2121);
      expect(host(':2121').ftpConfigured, isFalse,
          reason: 'empty host part → not configured');
    });

    test('gallery config defaults when fields are absent', () {
      final f = File('${tmp.path}/desktop.config.json')
        ..writeAsStringSync('{"RootDirectory": "/r"}');
      final c = DesktopConfig.load(f.path);
      expect(c.showCandidates, isTrue);
      expect(c.defaultStatus, 'with_screenshot');
      expect(c.windowMaximized, isTrue, reason: 'start maximized by default');
      expect(c.windowWidth, 1280);
      expect(c.windowHeight, 800);
    });

    test('copyWith replaces only the given path fields', () {
      final c = DesktopConfig(
        rootDirectory: '/r',
        patchDirectory: '/p',
        screenshotDirectory: '/o',
        gameinfoDirectory: '/d',
        hatariExecutable: '/hatari',
        hatariConfigFile: '',
        showCandidates: false,
        defaultStatus: 'done',
        windowWidth: 1024,
        windowHeight: 768,
        windowMaximized: false,
      );
      final edited = c.copyWith(
        rootDirectory: '/new-root',
        hatariExecutable: '/new-hatari',
      );
      expect(edited.rootDirectory, '/new-root');
      expect(edited.hatariExecutable, '/new-hatari');
      expect(edited.patchDirectory, '/p');
      expect(edited.screenshotDirectory, '/o');
      expect(edited.gameinfoDirectory, '/d');
      expect(edited.showCandidates, isFalse);
      expect(edited.defaultStatus, 'done');
      expect(edited.windowWidth, 1024);
      expect(edited.windowMaximized, isFalse);
    });

    test('toJson/save round-trips every persisted field', () {
      final f = File('${tmp.path}/desktop.config.json')
        ..writeAsStringSync('{"RootDirectory": "/r"}');
      final original = DesktopConfig.load(f.path);
      final edited = original.copyWith(
        rootDirectory: '/root',
        patchDirectory: '/patch',
        screenshotDirectory: '/out',
        gameinfoDirectory: '/data',
        atariLegendDirectory: '/atari-legend',
        hatariExecutable: '/hatari/bin/hatari',
        hatariConfigFile: '/cfg/hatari.cfg',
        hatariArgsTemplate: '-c "{cfg}" --disk-a "{zip}"',
        ftpHost: 'ftp.example.com',
        ftpUser: 'anonymous',
        ftpPassword: 'secret',
        ftpRemoteBase: '/dvd',
        ftpAssetsRemote: '/upload/assets',
        showCandidates: false,
        defaultStatus: 'done',
        windowWidth: 1600,
        windowHeight: 900,
        windowMaximized: false,
      );
      edited.save(f.path);
      final reloaded = DesktopConfig.load(f.path);
      expect(reloaded.rootDirectory, '/root');
      expect(reloaded.patchDirectory, '/patch');
      expect(reloaded.screenshotDirectory, '/out');
      expect(reloaded.gameinfoDirectory, '/data');
      expect(reloaded.atariLegendDirectory, '/atari-legend');
      expect(reloaded.hatariExecutable, '/hatari/bin/hatari');
      expect(reloaded.hatariConfigFile, '/cfg/hatari.cfg');
      expect(reloaded.hatariArgsTemplate, '-c "{cfg}" --disk-a "{zip}"');
      expect(reloaded.ftpHost, 'ftp.example.com');
      expect(reloaded.ftpUser, 'anonymous');
      expect(reloaded.ftpPassword, 'secret');
      expect(reloaded.ftpRemoteBase, '/dvd');
      expect(reloaded.ftpAssetsRemote, '/upload/assets');
      expect(reloaded.showCandidates, isFalse);
      expect(reloaded.defaultStatus, 'done');
      expect(reloaded.windowWidth, 1600);
      expect(reloaded.windowHeight, 900);
      expect(reloaded.windowMaximized, isFalse);
    });

    test('save writes empty optional paths and a trailing newline', () {
      final f = File('${tmp.path}/desktop.config.json')
        ..writeAsStringSync('{"RootDirectory": "/r"}');
      final c = DesktopConfig.load(f.path).copyWith(rootDirectory: '/r');
      c.save(f.path);
      final text = f.readAsStringSync();
      expect(text.endsWith('\n'), isTrue);
      final reloaded = DesktopConfig.load(f.path);
      expect(reloaded.patchDirectory, '');
      expect(reloaded.screenshotDirectory, '');
      expect(reloaded.gameinfoDirectory, '');
      expect(reloaded.atariLegendDirectory, '');
      expect(reloaded.hatariConfigFile, '');
    });
  });
}
