// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/favorites_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String file;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('favorites_test');
    file = '${tmp.path}/favorites.txt';
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('missing file yields empty set', () {
    final f = FavoritesService.load(file);
    expect(f.isEmpty, isTrue);
    expect(f.lastSaveError, isNull);
  });

  test('toggle adds, persists, and removes case-insensitively', () {
    final f = FavoritesService.load(file);
    expect(f.toggle('/games/Alpha.zip'), isTrue);
    expect(f.contains('/games/ALPHA.ZIP'), isTrue);
    expect(File(file).readAsStringSync(), contains('Alpha.zip'));
    expect(f.toggle('/games/alpha.zip'), isFalse);
    expect(f.isEmpty, isTrue);
  });

  test('loaded paths are sorted case-insensitively', () {
    File(file).writeAsStringSync('/z/Beta.zip\n/a/alpha.zip\n');
    final f = FavoritesService.load(file);
    expect(f.paths, ['/a/alpha.zip', '/z/Beta.zip']);
  });

  test('save failure does not crash (R25)', () async {
    final f = FavoritesService.load('${tmp.path}/no-dir-allowed/x/favorites.txt');
    final dir = Directory('${tmp.path}/no-dir-allowed/x/favorites.txt');
    // Force failure: parent path component is a file.
    File('${tmp.path}/no-dir-allowed').createSync();
    expect(() => f.toggle('/g/Game.zip'), returnsNormally);
    expect(f.contains('/g/Game.zip'), isTrue);
    expect(f.lastSaveError, isNotNull);
    expect(await dir.exists(), isFalse);
  });

  group('resolveFavoritesPath', () {
    bool Function(String) existsIn(Set<String> existing) =>
        (path) => existing.contains(path);

    test('prefers an existing PatchDirectory file (console interop)', () {
      final file = p.join('/patch', 'favorites.txt');
      final path = resolveFavoritesPath(
        patchDir: '/patch',
        appDir: '/app',
        cwd: '/cwd',
        exists: existsIn({file, p.join('/app', 'favorites.txt')}),
      );
      expect(path, file);
    });

    test('falls back to an existing application-directory file', () {
      final file = p.join('/app', 'favorites.txt');
      final path = resolveFavoritesPath(
        patchDir: '/patch',
        appDir: '/app',
        cwd: '/cwd',
        exists: existsIn({file}),
      );
      expect(path, file);
    });

    test('falls back to an existing CWD file', () {
      final file = p.join('/cwd', 'favorites.txt');
      final path = resolveFavoritesPath(
        patchDir: '/patch',
        appDir: '/app',
        cwd: '/cwd',
        exists: existsIn({file}),
      );
      expect(path, file);
    });

    test('no file anywhere → save target is PatchDirectory when set', () {
      final path = resolveFavoritesPath(
        patchDir: '/patch',
        appDir: '/app',
        cwd: '/cwd',
        exists: existsIn(const {}),
      );
      expect(path, p.join('/patch', 'favorites.txt'));
    });

    test('no file anywhere, no PatchDirectory → app dir (never CWD)', () {
      final path = resolveFavoritesPath(
        patchDir: null,
        appDir: '/app',
        cwd: '/cwd',
        exists: existsIn(const {}),
      );
      expect(path, p.join('/app', 'favorites.txt'));
    });
  });
}
