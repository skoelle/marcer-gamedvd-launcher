// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

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
}
