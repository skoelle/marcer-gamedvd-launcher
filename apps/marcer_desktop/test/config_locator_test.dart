// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/config_locator.dart';
import 'package:path/path.dart' as p;

void main() {
  group('configSearchDirs', () {
    test('cwd first, then exe dir (Windows/Linux)', () {
      expect(
        configSearchDirs(cwd: '/a', exeDir: '/b'),
        ['/a', '/b'],
      );
    });

    test('deduplicates when cwd == exe dir', () {
      expect(configSearchDirs(cwd: '/x', exeDir: '/x'), ['/x']);
    });

    test('macOS adds the parent of the .app bundle', () {
      expect(
        configSearchDirs(
          cwd: '/cwd',
          exeDir: '/Apps/Foo.app/Contents/MacOS',
          isMacOS: true,
        ),
        ['/cwd', '/Apps/Foo.app/Contents/MacOS', '/Apps'],
      );
    });

    test('appends the extra fallback dir last', () {
      expect(
        configSearchDirs(
          cwd: '/cwd',
          exeDir: '/Apps/Foo.app/Contents/MacOS',
          isMacOS: true,
          extraDir: '/Users/x/Library/Application Support/App',
        ),
        [
          '/cwd',
          '/Apps/Foo.app/Contents/MacOS',
          '/Apps',
          '/Users/x/Library/Application Support/App',
        ],
      );
    });

    test('deduplicates the extra fallback dir', () {
      expect(
        configSearchDirs(cwd: '/x', exeDir: '/x', extraDir: '/x'),
        ['/x'],
      );
    });
  });

  group('resolveConfigPath', () {
    test('returns first existing candidate', () {
      final found = resolveConfigPath(
        dirs: ['/a', '/b'],
        exists: (path) => path == p.join('/b', kConfigFileName),
      );
      expect(found, p.join('/b', kConfigFileName));
    });

    test('prefers earlier directory', () {
      final found = resolveConfigPath(
        dirs: ['/a', '/b'],
        exists: (_) => true,
      );
      expect(found, p.join('/a', kConfigFileName));
    });

    test('returns null when nothing matches', () {
      expect(
        resolveConfigPath(dirs: ['/a', '/b'], exists: (_) => false),
        isNull,
      );
    });
  });

  group('configSaveDirs', () {
    test('exe dir first, then cwd (Windows/Linux)', () {
      expect(configSaveDirs(cwd: '/a', exeDir: '/b'), ['/b', '/a']);
    });

    test('deduplicates when cwd == exe dir', () {
      expect(configSaveDirs(cwd: '/x', exeDir: '/x'), ['/x']);
    });

    test('macOS uses the .app parent, then cwd', () {
      expect(
        configSaveDirs(
          cwd: '/cwd',
          exeDir: '/Apps/Foo.app/Contents/MacOS',
          isMacOS: true,
        ),
        ['/Apps', '/cwd'],
      );
    });

    test('appends the extra fallback dir last', () {
      expect(
        configSaveDirs(
          cwd: '/cwd',
          exeDir: '/Apps/Foo.app/Contents/MacOS',
          isMacOS: true,
          extraDir: '/Users/x/Library/Application Support/App',
        ),
        ['/Apps', '/cwd', '/Users/x/Library/Application Support/App'],
      );
    });

    test('empty extra dir is ignored', () {
      expect(configSaveDirs(cwd: '/a', exeDir: '/b', extraDir: ''),
          ['/b', '/a']);
    });
  });

  group('writeFirstWritable', () {
    test('writes to the first directory and returns the path', () {
      final tmp = Directory.systemTemp.createTempSync('locator_test');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final dir = Directory('${tmp.path}/d')..createSync();
      final path = writeFirstWritable(
        [dir.path],
        fileName: 'x.json',
        write: (path) => File(path).writeAsStringSync('hi'),
      );
      expect(path, p.join(dir.path, 'x.json'));
      expect(File(path!).readAsStringSync(), 'hi');
    });

    test('skips a failing candidate and falls back to the next', () {
      final tmp = Directory.systemTemp.createTempSync('locator_test');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final good = Directory('${tmp.path}/good')..createSync();
      final calls = <String>[];
      final path = writeFirstWritable(
        ['/definitely/missing/dir', good.path],
        fileName: 'x.json',
        write: (path) {
          calls.add(path);
          File(path).writeAsStringSync('ok');
        },
      );
      expect(path, p.join(good.path, 'x.json'));
      expect(calls.length, 2);
    });

    test('returns null when no candidate is writable', () {
      final path = writeFirstWritable(
        ['/definitely/missing/dir'],
        fileName: 'x.json',
        write: (path) => File(path).writeAsStringSync('x'),
      );
      expect(path, isNull);
    });

    test('falls back to the last (per-user) candidate', () {
      final tmp = Directory.systemTemp.createTempSync('locator_test');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final fallback = Directory('${tmp.path}/appsupport')..createSync();
      final path = writeFirstWritable(
        ['/definitely/missing/a', '/definitely/missing/b', fallback.path],
        fileName: 'desktop.config.json',
        write: (path) => File(path).writeAsStringSync('cfg'),
      );
      expect(path, p.join(fallback.path, 'desktop.config.json'));
      expect(File(path!).readAsStringSync(), 'cfg');
    });
  });
}
