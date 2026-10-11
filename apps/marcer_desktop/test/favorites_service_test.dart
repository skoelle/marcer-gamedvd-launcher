// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/favorites_service.dart';

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
}
