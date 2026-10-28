// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:path/path.dart' as p;

/// Default favorites file name (SPEC.md §11.1; same as the console
/// launcher's `FavoritesService.DefaultFileName`).
const String kFavoritesFileName = 'favorites.txt';

/// Section key for favorite paths that lie outside every discovered section
/// tree (legacy single-file layout, unknown roots, foreign entries).
const String kMiscFavoritesSection = 'misc';

/// Per-section favorites file name used when no PatchDirectory is configured
/// (SPEC.md §11.1 order: patch tree → application directory): one
/// `favorites-<section>.txt` next to the executable.
String favoritesSectionFileName(String section) => 'favorites-$section.txt';

/// Resolves the legacy/unknown-section `favorites.txt` location used for
/// paths outside every section tree (SPEC.md §11.1): the first existing file
/// in `[patchDir, appDir, cwd]` — so a `favorites.txt` written by an older
/// desktop build or picked up from the console launcher is still read. When
/// no file exists yet, the save target is `patchDir` (when configured) else
/// the application directory (never the CWD).
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

/// Favorites persistence per `SPEC.md` §11.1/§11.2 — one file per section
/// tree (console layout: `…/<section tree>/favorites.txt`) plus a
/// legacy/unknown-section file.
///
/// UTF-8 files, one root-relative path per line (POSIX separators), sorted
/// case-insensitively, keyed by the ZIP's effective path (R26). Absolute
/// legacy lines are accepted and normalized on the next save; paths outside
/// both roots stay absolute and are preserved. All files are read (their
/// union is the favorite set) and only the touched files are rewritten.
/// Save failures never crash (R25): the in-memory set stays updated, only the
/// disk write is lost ([lastSaveError]).
class FavoritesService {
  FavoritesService._(
      this._fileForSection,
      this._files,
      this._sectionOfPath,
      this._writableFiles,
      this._encodePath,
      this._dirtyFiles,
      this._originals);

  /// Loads every mapped section file (missing files yield empty sets) plus
  /// [extraFiles] — additional read-only sources such as a legacy
  /// `favorites.txt` next to the executable or in the CWD.
  ///
  /// [sectionOfPath] classifies a favorite path on toggle (see the
  /// controller's root-relative section lookup); new entries land in
  /// `fileForSection[section]`, falling back to
  /// `fileForSection[kMiscFavoritesSection]`.
  ///
  /// [decodePath] turns a stored line into the absolute effective path used
  /// in memory; [encodePath] turns it back into the stored representation.
  factory FavoritesService.load({
    required Map<String, String> fileForSection,
    List<String> extraFiles = const [],
    required String Function(String path) sectionOfPath,
    String Function(String storedPath)? decodePath,
    String Function(String absolutePath)? encodePath,
  }) {
    final decode = decodePath ?? (line) => p.normalize(line);
    final encode = encodePath ?? (path) => path;
    final writableFiles = fileForSection.values.toSet();
    final dirtyFiles = <String>{};
    final originals = <String, Map<String, String>>{};
    final files = <String, List<String>>{};
    for (final path in [...fileForSection.values, ...extraFiles]) {
      if (files.containsKey(path)) continue;
      final list = <String>[];
      final fileOriginals = <String, String>{};
      final file = File(path);
      String? raw;
      if (file.existsSync()) {
        try {
          raw = file.readAsStringSync();
        } catch (_) {
          // Unreadable file: skip its entries instead of aborting the whole
          // favorites load (the other section files may still be fine).
          raw = null;
        }
      }
      if (raw != null) {
        final hasBom = raw.startsWith('\uFEFF');
        final hasCrlf = raw.contains('\r');
        var dirty = hasBom || hasCrlf;
        for (final line in raw.split(RegExp(r'\r\n|\r|\n'))) {
          final original = line.replaceFirst('\uFEFF', '').trim();
          if (original.isEmpty) continue;
          final decoded = decode(original);
          if (decoded.trim().isEmpty) continue;
          list.add(decoded);
          fileOriginals[decoded.toLowerCase()] = original;
          final encoded = encode(decoded);
          if (!_isAbsoluteEncoded(encoded) && encoded != original) {
            dirty = true;
          }
        }
        if (dirty && writableFiles.contains(path)) dirtyFiles.add(path);
      }
      list.sort(_byLower);
      files[path] = list;
      originals[path] = fileOriginals;
    }
    return FavoritesService._(
        Map<String, String>.unmodifiable(fileForSection),
        files,
        sectionOfPath,
        writableFiles,
        encode,
        dirtyFiles,
        originals);
  }

  final Map<String, String> _fileForSection;
  final Map<String, List<String>> _files;
  final String Function(String path) _sectionOfPath;
  final Set<String> _writableFiles;
  final String Function(String absolutePath) _encodePath;
  final Set<String> _dirtyFiles;
  final Map<String, Map<String, String>> _originals;
  List<String>? _union;

  /// Error of the last save round (`null` when every write succeeded or no
  /// write happened since). Shown by the status bar (R25).
  String? lastSaveError;

  /// File that stores favorites of [section] (`'cracked'`/`'pd'`/`'utils'`),
  /// the misc file for [kMiscFavoritesSection]; null when unmapped.
  String? fileForSection(String section) => _fileForSection[section];

  int migrateMisplacedFavorites(String? Function(String path) sectionOf) {
    final touched = <String>{};
    var moved = 0;
    for (final source in _writableFiles.toList()) {
      final list = _files[source];
      if (list == null) continue;
      final keep = <String>[];
      for (final path in list) {
        final section = sectionOf(path);
        final target = section == null ? null : _fileForSection[section];
        if (target == null || target == source) {
          keep.add(path);
          continue;
        }
        final targetList = _files.putIfAbsent(target, () => <String>[]);
        if (!targetList.any((entry) => _eq(entry, path))) {
          targetList.add(path);
          targetList.sort(_byLower);
        }
        final original = _originals[source]?[path.toLowerCase()];
        if (original != null) {
          _originals.putIfAbsent(target, () => {})[path.toLowerCase()] =
              original;
          _originals[source]?.remove(path.toLowerCase());
        }
        touched.add(target);
        moved++;
      }
      if (keep.length != list.length) {
        list
          ..clear()
          ..addAll(keep);
        touched.add(source);
      }
    }
    touched.addAll(_dirtyFiles);
    if (touched.isNotEmpty) {
      _union = null;
      _save(touched, backup: true);
      _dirtyFiles.clear();
    }
    return moved;
  }

  /// Every file path in use (mapped section files + extras actually loaded).
  Iterable<String> get files => _files.keys;

  /// Union of all favorites, sorted case-insensitively (memoized until a
  /// toggle changes a file).
  List<String> get paths {
    final cached = _union;
    if (cached != null) return cached;
    final set = <String>{};
    for (final list in _files.values) {
      set.addAll(list);
    }
    final sorted = set.toList()..sort(_byLower);
    return _union = List<String>.unmodifiable(sorted);
  }

  /// Favorites that belong to [section] (per its root-relative path tree).
  Iterable<String> pathsForSection(String section) =>
      paths.where((path) => _sectionOfPath(path) == section);

  int get length => paths.length;
  bool get isEmpty => paths.isEmpty;
  bool get isNotEmpty => paths.isNotEmpty;

  static int _byLower(String a, String b) =>
      a.toLowerCase().compareTo(b.toLowerCase());

  static bool _eq(String a, String b) => a.toLowerCase() == b.toLowerCase();

  static bool _isAbsoluteEncoded(String value) =>
      value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);

  /// True when [path] is a favorite (any file, case-insensitive, R26 key).
  bool contains(String path) {
    final norm = p.normalize(path);
    for (final list in _files.values) {
      for (final entry in list) {
        if (_eq(entry, norm)) return true;
      }
    }
    return false;
  }

  /// Toggles [path]: removes it from every file that holds it, otherwise
  /// adds it to its section's file (misplaced paths fall back to the misc
  /// file). Returns `true` when the path is a favorite afterwards.
  bool toggle(String path) {
    final norm = p.normalize(path);
    final touched = <String>{};
    for (final entry in _files.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((e) => _eq(e, norm));
      if (entry.value.length != before) touched.add(entry.key);
    }
    var added = touched.isEmpty;
    if (added) {
      final section = _sectionOfPath(norm);
      final file = _fileForSection[section] ??
          _fileForSection[kMiscFavoritesSection];
      if (file == null) {
        lastSaveError = 'no favorites file mapped for section "$section"';
        return false;
      }
      final list = _files.putIfAbsent(file, () => <String>[]);
      list.add(norm);
      list.sort(_byLower);
      touched.add(file);
    }
    _union = null;
    _save(touched);
    return added;
  }

  String _encodedFor(String file, String key) {
    final encoded = _encodePath(key);
    if (!_isAbsoluteEncoded(encoded)) return encoded;
    return _originals[file]?[key.toLowerCase()] ?? encoded;
  }

  /// Best-effort persist of [filesToWrite] (R25: failure must not crash the
  /// UI); [lastSaveError] holds the first error or `null` on success.
  void _save(Set<String> filesToWrite, {bool backup = false}) {
    String? error;
    for (final path in filesToWrite) {
      try {
        if (backup && File(path).existsSync()) _backup(path);
        final list = _files[path] ?? const <String>[];
        final encoded = [
          for (final key in list) _encodedFor(path, key),
        ]..sort(_byLower);
        final content = '${encoded.join('\n')}${encoded.isEmpty ? '' : '\n'}';
        // Write to a sibling temp file first so a crash mid-write cannot
        // truncate the existing favorites file.
        final target = File(path)..parent.createSync(recursive: true);
        final tmp = File('$path.tmp');
        tmp.writeAsStringSync(content, flush: true);
        try {
          tmp.renameSync(path);
        } on FileSystemException {
          // Windows cannot rename over an existing file.
          try {
            target.deleteSync();
          } catch (_) {}
          tmp.renameSync(path);
        }
      } catch (e) {
        error ??= '$e';
      }
    }
    lastSaveError = error;
  }

  void _backup(String path) {
    final stamp =
        DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    File(path).copySync('$path.bak-$stamp');
  }
}
