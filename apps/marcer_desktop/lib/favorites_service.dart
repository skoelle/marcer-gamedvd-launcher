// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:path/path.dart' as p;

/// Default favorites file name (SPEC.md §11.1; same as the console
/// launcher's `FavoritesService.DefaultFileName`).
const String kFavoritesFileName = 'favorites.txt';

/// Resolves the single `favorites.txt` location used for both loading and
/// saving (SPEC.md §11.1): the first existing file in
/// `[patchDir, appDir, cwd]` — so a `favorites.txt` written by the console
/// launcher next to its EXE or inside `PatchDirectory` is picked up. When no
/// file exists yet, the save target is `patchDir` (when configured) else the
/// application directory (never the CWD).
String resolveFavoritesPath({
  String? patchDir,
  required String appDir,
  required String cwd,
  required bool Function(String path) exists,
}) {
  final dirs = <String>[
    if (patchDir != null && patchDir.isNotEmpty) patchDir,
    appDir,
    cwd,
  ];
  final seen = <String>{};
  for (final dir in dirs) {
    if (!seen.add(dir)) continue;
    final candidate = p.join(dir, kFavoritesFileName);
    if (exists(candidate)) return candidate;
  }
  return p.join(
      (patchDir != null && patchDir.isNotEmpty) ? patchDir : appDir,
      kFavoritesFileName);
}

/// Favorites persistence per `SPEC.md` §11.1/§11.2.
///
/// UTF-8 file `favorites.txt`, one absolute path per line, sorted
/// case-insensitively, keyed by the ZIP's effective path (R26). Save failures
/// never crash (R25): the in-memory set stays updated, only the disk write is
/// lost ([lastSaveError]).
class FavoritesService {
  FavoritesService._(this.filePath, this._paths);

  /// Loads favorites from [filePath]; missing file yields an empty set.
  factory FavoritesService.load(String filePath) {
    final file = File(filePath);
    final paths = <String>[];
    if (file.existsSync()) {
      for (final line in file.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        paths.add(p.normalize(trimmed));
      }
    }
    paths.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return FavoritesService._(filePath, paths);
  }

  final String filePath;
  final List<String> _paths;
  String? lastSaveError;

  int get length => _paths.length;
  bool get isEmpty => _paths.isEmpty;
  List<String> get paths => List.unmodifiable(_paths);

  static bool _eq(String a, String b) =>
      a.toLowerCase() == b.toLowerCase();

  bool contains(String path) => _paths.any((e) => _eq(e, p.normalize(path)));

  /// Toggles [path]; returns `true` when the path is a favorite afterwards.
  bool toggle(String path) {
    final norm = p.normalize(path);
    if (contains(norm)) {
      _paths.removeWhere((e) => _eq(e, norm));
    } else {
      _paths.add(norm);
    }
    _sort();
    save();
    return contains(norm);
  }

  void _sort() {
    _paths.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Best-effort persist (R25: failure must not crash the UI).
  void save() {
    try {
      File(filePath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('${_paths.join('\n')}${_paths.isEmpty ? '' : '\n'}');
      lastSaveError = null;
    } catch (e) {
      lastSaveError = '$e';
    }
  }
}
