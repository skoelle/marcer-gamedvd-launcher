// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/favorites_paths.dart';
import 'package:marcer_desktop/favorites_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late String miscFile;
  late String crackedFile;
  late String pdFile;

  /// Loads a service with a `cracked` + `pd` section map (no `utils` entry —
  /// exercises the misc fallback) and classifies paths by their folder name.
  FavoritesService loadService({
    List<String> extraFiles = const [],
    String Function(String storedPath)? decodePath,
    String Function(String absolutePath)? encodePath,
  }) =>
      FavoritesService.load(
        fileForSection: {
          'cracked': crackedFile,
          'pd': pdFile,
          kMiscFavoritesSection: miscFile,
        },
        extraFiles: extraFiles,
        decodePath: decodePath,
        encodePath: encodePath,
        sectionOfPath: (path) {
          if (path.contains('Cracked')) return 'cracked';
          if (path.contains('PD')) return 'pd';
          if (path.contains('Util')) return 'utils'; // unmapped → misc
          return kMiscFavoritesSection;
        },
      );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('favorites_test');
    miscFile = p.join(tmp.path, 'favorites.txt');
    crackedFile = p.join(tmp.path, 'Cracked Games - Title Sorted', 'favorites.txt');
    pdFile = p.join(tmp.path, 'PD Games - Title Sorted', 'favorites.txt');
  });

  void write(String path, String content) {
    File(path).parent.createSync(recursive: true);
    File(path).writeAsStringSync(content);
  }

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('missing files yield empty set', () {
    final f = loadService();
    expect(f.isEmpty, isTrue);
    expect(f.lastSaveError, isNull);
  });

  test('toggle adds, persists, and removes case-insensitively (misc file)', () {
    final f = loadService();
    expect(f.toggle('/games/Alpha.zip'), isTrue);
    expect(f.contains('/games/ALPHA.ZIP'), isTrue);
    expect(File(miscFile).readAsStringSync(), contains('Alpha.zip'));
    expect(f.toggle('/games/alpha.zip'), isFalse);
    expect(f.isEmpty, isTrue);
  });

  test('loaded paths are sorted case-insensitively', () {
    write(miscFile, '/z/Beta.zip\n/a/alpha.zip\n');
    final f = loadService();
    expect(f.paths, ['/a/alpha.zip', '/z/Beta.zip']);
  });

  test('pathsForSection filters the union by section tree', () {
    write(crackedFile, '/games/Cracked Games - Title Sorted/a.zip\n');
    write(pdFile, '/games/PD Games - Title Sorted/p.zip\n');
    final f = loadService();
    expect(f.pathsForSection('cracked'),
        ['/games/Cracked Games - Title Sorted/a.zip']);
    expect(f.pathsForSection('pd'),
        ['/games/PD Games - Title Sorted/p.zip']);
    expect(f.pathsForSection('utils'), isEmpty);
  });

  test('new entries land in the section file of their tree', () {
    final f = loadService();
    expect(f.toggle('/games/Cracked Games - Title Sorted/A/Alpha/alpha.zip'),
        isTrue);
    expect(File(crackedFile).readAsStringSync(),
        contains('Cracked Games - Title Sorted/A/Alpha/alpha.zip'));
    expect(File(miscFile).existsSync(), isFalse);
    expect(f.fileForSection('cracked'), crackedFile);
  });

  test('migration moves section entries out of the misc file', () {
    write(
        miscFile,
        '/games/Cracked Games - Title Sorted/A/Alpha/alpha.zip\n'
        '/other/Legacy.zip\n');
    final f = loadService();
    expect(
        f.migrateMisplacedFavorites((path) {
          if (path.contains('Cracked')) return 'cracked';
          if (path.contains('PD')) return 'pd';
          return null;
        }),
        1);
    expect(File(crackedFile).readAsStringSync(), contains('alpha.zip'));
    expect(File(miscFile).readAsStringSync(), contains('Legacy.zip'));
    expect(File(miscFile).readAsStringSync(), isNot(contains('alpha.zip')));
    expect(f.pathsForSection('cracked'), contains(endsWith('alpha.zip')));
    expect(
        f.migrateMisplacedFavorites(
            (path) => path.contains('Cracked') ? 'cracked' : null),
        0);
  });

  test('codec rewrites legacy absolute lines to relative paths', () {
    final root = p.join(tmp.path, 'root');
    final legacyRel = 'Cracked Games - Title Sorted/A/Alpha/alpha.zip';
    final legacyAbs = p.join(root, legacyRel);
    File(legacyAbs).parent.createSync(recursive: true);
    File(legacyAbs).createSync();
    write(
        crackedFile,
        '\uFEFF'
        r'Y:\Downloads\MarcersGameDVD\Cracked Games - Title Sorted\A\Alpha\alpha.zip'
        '\r\n');
    final codec = FavoritesPathCodec(
      rootDirectory: root,
      patchDirectory: p.join(tmp.path, 'patch'),
      sectionTrees: const {'cracked': 'Cracked Games - Title Sorted'},
    );
    final f = loadService(
      decodePath: codec.decode,
      encodePath: codec.encode,
    );
    expect(f.paths, contains(legacyAbs));
    expect(
        f.migrateMisplacedFavorites(
            (path) => path.contains('Cracked') ? 'cracked' : null),
        0);
    expect(File(crackedFile).readAsStringSync(), '$legacyRel\n');
    expect(
        Directory(tmp.path)
            .listSync(recursive: true)
            .where((e) => p.basename(e.path).contains('.bak-')),
        isNotEmpty);
  });

  test('codec keeps unmapped foreign lines verbatim on save', () {
    const foreign = r'Y:\Other\missing.zip';
    write(miscFile, '$foreign\n');
    final codec = FavoritesPathCodec(
      rootDirectory: p.join(tmp.path, 'root'),
      patchDirectory: p.join(tmp.path, 'patch'),
      sectionTrees: const {'cracked': 'Cracked Games - Title Sorted'},
    );
    final f = loadService(
      decodePath: codec.decode,
      encodePath: codec.encode,
    );
    f.toggle('/games/Cracked Games - Title Sorted/A/Alpha/alpha.zip');
    expect(File(miscFile).readAsStringSync(), '$foreign\n');
  });

  test('migration does not rewrite extra files', () {
    final legacy = p.join(tmp.path, 'app', 'favorites.txt');
    write(
        legacy,
        '/games/Cracked Games - Title Sorted/A/Alpha/alpha.zip\n');
    final f = loadService(extraFiles: [legacy]);
    expect(
        f.migrateMisplacedFavorites(
            (path) => path.contains('Cracked') ? 'cracked' : null),
        0);
    expect(
        File(legacy).readAsStringSync(),
        '/games/Cracked Games - Title Sorted/A/Alpha/alpha.zip\n');
    expect(File(crackedFile).existsSync(), isFalse);
  });

  test('section without a mapped file falls back to the misc file', () {
    final f = loadService();
    expect(f.toggle('/games/Util Games - Title Sorted/U/Utils/utils.zip'), isTrue);
    expect(File(miscFile).readAsStringSync(), contains('utils.zip'));
  });

  test('union spans all files; removal strips the entry everywhere', () {
    write(pdFile, '/games/PD Games - Title Sorted/P/Pac/pac.zip\n');
    write(miscFile, '/other/Legacy.zip\n');
    final f = loadService();
    expect(f.length, 2);
    expect(f.contains('/games/PD Games - Title Sorted/P/Pac/pac.zip'), isTrue);
    expect(f.contains('/other/legacy.ZIP'), isTrue);
    expect(f.toggle('/games/PD Games - Title Sorted/P/Pac/pac.zip'), isFalse);
    expect(f.length, 1);
    expect(File(pdFile).readAsStringSync(), isEmpty);
    expect(File(miscFile).readAsStringSync(), contains('Legacy.zip'));
  });

  test('foreign lines of a touched file are preserved (console interop)',
      () {
    // A favorites.txt shared with the Windows console launcher: its Y:\
    // entries must survive every save of that file.
    const foreign = 'Y:\\Games\\Cracked Games - Title Sorted\\D\\Darius\\Darius.zip';
    write(crackedFile, '$foreign\n');
    final f = loadService();
    expect(f.paths, [foreign]);
    f.toggle('/games/Cracked Games - Title Sorted/A/Alpha/alpha.zip');
    final written = File(crackedFile).readAsStringSync();
    expect(written, contains(foreign));
    expect(written, contains('alpha.zip'));
    // …and are never dropped by a removal of one of our own entries.
    f.toggle('/games/Cracked Games - Title Sorted/A/Alpha/alpha.zip');
    expect(File(crackedFile).readAsStringSync(), contains(foreign));
  });

  test('extraFiles are read but never receive new entries', () {
    final legacy = p.join(tmp.path, 'app', 'favorites.txt');
    write(legacy, '/legacy/Old.zip\n');
    final f = loadService(extraFiles: [legacy]);
    expect(f.contains('/legacy/Old.zip'), isTrue);
    f.toggle('/games/Cracked Games - Title Sorted/A/Alpha/alpha.zip');
    expect(File(legacy).readAsStringSync(), equals('/legacy/Old.zip\n'));
    expect(File(crackedFile).readAsStringSync(), contains('alpha.zip'));
  });

  test('save failure does not crash (R25)', () async {
    // Force failure: parent path component of the misc file is a file.
    File('${tmp.path}/blocked').createSync();
    final f = FavoritesService.load(
      fileForSection: {kMiscFavoritesSection: '${tmp.path}/blocked/x/favorites.txt'},
      sectionOfPath: (_) => kMiscFavoritesSection,
    );
    final dir = Directory('${tmp.path}/blocked/x/favorites.txt');
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
