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
  });
}
