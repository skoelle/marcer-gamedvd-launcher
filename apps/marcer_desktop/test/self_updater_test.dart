// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/self_updater.dart';
import 'package:path/path.dart' as p;

Map<String, dynamic> _release(String tag,
    {List<Map<String, dynamic>> assets = const [],
    bool draft = false,
    bool prerelease = false}) {
  return {
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'assets': [
      for (final a in assets)
        {'name': a['name'], 'browser_download_url': a['url']}
    ],
  };
}

Map<String, dynamic> _desktopAsset(String version, String tag) => {
      'name': 'MarcerDesktop-v$version-$tag.zip',
      'url': 'https://example.com/$version/$tag.zip',
    };

void main() {
  group('compareVersions', () {
    test('orders numerically, not lexicographically', () {
      expect(compareVersions('0.1.0', '0.2.0'), -1);
      expect(compareVersions('0.10.0', '0.9.0'), 1);
      expect(compareVersions('1.0.0', '0.9.9'), 1);
      expect(compareVersions('1.2.3', '1.2.3'), 0);
    });

    test('missing parts count as zero', () {
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('1.0.1', '1.0'), 1);
    });
  });

  group('pickRelease', () {
    test('picks newest desktop release with matching asset', () {
      final releases = [
        _release('v2.5.0'), // console tag — ignored
        _release('desktop-v0.2.0', assets: [_desktopAsset('0.2.0', 'linux-x64')]),
        _release('desktop-v0.1.0', assets: [_desktopAsset('0.1.0', 'linux-x64')]),
      ];
      final info = pickRelease(releases, current: '0.1.0', assetTag: 'linux-x64');
      expect(info, isNotNull);
      expect(info!.version, '0.2.0');
      expect(info.assetName, 'MarcerDesktop-v0.2.0-linux-x64.zip');
      expect(info.assetUrl, 'https://example.com/0.2.0/linux-x64.zip');
    });

    test('up to date yields null', () {
      final releases = [
        _release('desktop-v0.1.0', assets: [_desktopAsset('0.1.0', 'win-x64')]),
      ];
      expect(pickRelease(releases, current: '0.1.0', assetTag: 'win-x64'),
          isNull);
      expect(pickRelease(releases, current: '0.2.0', assetTag: 'win-x64'),
          isNull);
    });

    test('drafts and prereleases are skipped', () {
      final releases = [
        _release('desktop-v0.3.0',
            assets: [_desktopAsset('0.3.0', 'osx-arm64')], draft: true),
        _release('desktop-v0.2.0',
            assets: [_desktopAsset('0.2.0', 'osx-arm64')], prerelease: true),
        _release('desktop-v0.1.0', assets: [_desktopAsset('0.1.0', 'osx-arm64')]),
      ];
      final info = pickRelease(releases, current: '0.0.9', assetTag: 'osx-arm64');
      expect(info!.version, '0.1.0');
    });

    test('missing platform asset yields null', () {
      final releases = [
        _release('desktop-v0.2.0', assets: [_desktopAsset('0.2.0', 'win-x64')]),
      ];
      expect(pickRelease(releases, current: '0.1.0', assetTag: 'linux-x64'),
          isNull);
    });
  });

  group('installTargetDir', () {
    test('Windows/Linux: directory of the executable', () {
      // POSIX paths stand in for both platforms — `dirname` semantics are
      // identical; Windows-style paths are only meaningful on a Windows
      // host and are covered by the real install flow.
      expect(
          installTargetDir(resolvedExecutable: '/opt/app/MarcerGameDVDLauncher'),
          '/opt/app');
      expect(
          installTargetDir(
              resolvedExecutable: '/opt/app/MarcerGameDVDLauncher.exe'),
          '/opt/app');
    });

    test('macOS: folder containing the .app bundle', () {
      expect(
          installTargetDir(
              resolvedExecutable:
                  '/Applications/Marcer.app/Contents/MacOS/MarcerGameDVDLauncher',
              isMacOS: true),
          '/Applications');
    });
  });

  group('swapInstall / cleanupOldFiles', () {
    late Directory sandbox;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('selfupdate_test_');
    });

    tearDown(() {
      try {
        sandbox.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('replaces shipped files, keeps user files, renames old to .old',
        () {
      final appDir = Directory(p.join(sandbox.path, 'app'))..createSync();
      final extract = Directory(p.join(sandbox.path, 'extract'))..createSync();

      // Current install: binary + user config + favorites + shipped cfg.
      File(p.join(appDir.path, 'launcher')).writeAsStringSync('old-binary');
      File(p.join(appDir.path, 'desktop.config.json'))
          .writeAsStringSync('{"user": true}');
      File(p.join(appDir.path, 'favorites.txt')).writeAsStringSync('/game/a.zip');
      File(p.join(appDir.path, 'MarcerGameDvd-Hatari.cfg')).writeAsStringSync('old-cfg');
      Directory(p.join(appDir.path, 'data')).createSync();
      File(p.join(appDir.path, 'data', 'blob.bin')).writeAsStringSync('old-data');

      // New release zip contents.
      File(p.join(extract.path, 'launcher')).writeAsStringSync('new-binary');
      File(p.join(extract.path, 'MarcerGameDvd-Hatari.cfg')).writeAsStringSync('new-cfg');
      Directory(p.join(extract.path, 'data')).createSync();
      File(p.join(extract.path, 'data', 'blob.bin')).writeAsStringSync('new-data');

      swapInstall(from: extract, into: appDir);

      expect(File(p.join(appDir.path, 'launcher')).readAsStringSync(),
          'new-binary');
      expect(File(p.join(appDir.path, 'launcher.old')).readAsStringSync(),
          'old-binary');
      expect(File(p.join(appDir.path, 'MarcerGameDvd-Hatari.cfg'))
          .readAsStringSync(), 'new-cfg');
      expect(
          File(p.join(appDir.path, 'data', 'blob.bin')).readAsStringSync(),
          'new-data');
      // User files untouched.
      expect(File(p.join(appDir.path, 'desktop.config.json')).readAsStringSync(),
          '{"user": true}');
      expect(File(p.join(appDir.path, 'favorites.txt')).readAsStringSync(),
          '/game/a.zip');
      // Directory replaced as a whole.
      expect(Directory(p.join(appDir.path, 'data.old')).existsSync(), isTrue);
    });

    test('cleanupOldFiles removes .old files and dirs, keeps the rest',
        () async {
      final appDir = Directory(p.join(sandbox.path, 'app2'))..createSync();
      File(p.join(appDir.path, 'launcher')).writeAsStringSync('new');
      File(p.join(appDir.path, 'launcher.old')).writeAsStringSync('old');
      Directory(p.join(appDir.path, 'MarcerGameDVDLauncher.app.old'))
          .createSync();
      File(p.join(appDir.path, 'desktop.config.json')).writeAsStringSync('{}');

      await cleanupOldFiles(appDir.path);

      expect(File(p.join(appDir.path, 'launcher.old')).existsSync(), isFalse);
      expect(
          Directory(p.join(appDir.path, 'MarcerGameDVDLauncher.app.old'))
              .existsSync(),
          isFalse);
      expect(File(p.join(appDir.path, 'launcher')).existsSync(), isTrue);
      expect(File(p.join(appDir.path, 'desktop.config.json')).existsSync(),
          isTrue);
    });
  });

  group('extractZipToDir', () {
    late Directory sandbox;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('selfupdate_extract_');
    });

    tearDown(() {
      try {
        sandbox.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('extracts entries, skips __MACOSX and AppleDouble files', () async {
      final archive = Archive();
      void addFile(String name, String content) {
        archive.addFile(ArchiveFile(name, content.length, content.codeUnits));
      }

      addFile('MarcerGameDVDLauncher', 'bin');
      addFile('data/blob.bin', 'data');
      addFile('__MACOSX/MarcerGameDVDLauncher._bin', 'junk');
      addFile('data/._blob.bin', 'junk');

      final zipBytes = ZipEncoder().encode(archive)!;
      final zipFile = File(p.join(sandbox.path, 'update.zip'))
        ..writeAsBytesSync(zipBytes);
      final out = Directory(p.join(sandbox.path, 'out'))..createSync();

      await extractZipToDir(zipFile, out);

      expect(File(p.join(out.path, 'MarcerGameDVDLauncher')).readAsStringSync(),
          'bin');
      expect(File(p.join(out.path, 'data', 'blob.bin')).readAsStringSync(),
          'data');
      expect(
          Directory(p.join(out.path, '__MACOSX')).existsSync(), isFalse);
      expect(File(p.join(out.path, 'data', '._blob.bin')).existsSync(),
          isFalse);
    });
  });
}
