// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Kind of a document found in a game's `Manual/` folder.
enum LocalManualKind {
  /// A PDF (scan or text-layer variant) — opened with the OS default app.
  pdf,

  /// Image pages (JPG/PNG/GIF) inside a ZIP, or a loose image — shown in the
  /// in-app image viewer.
  imagePages,

  /// `.doc`/`.txt` — opened with the OS default app.
  document,

  /// `.msa` floppy disk image — not a document; shown as an info-only row.
  diskImage,
}

/// One image found in a `Boxscan/` folder or archive.
class LocalImageRef {
  const LocalImageRef({
    required this.name,
    required this.edition,
    this.loosePath,
    this.zipPath,
    this.entryName,
  });

  /// Display name (file or ZIP entry basename).
  final String name;

  /// Edition label used to group the gallery (ZIP stem, edition folder or
  /// `Boxscan`).
  final String edition;

  /// Absolute path of a loose image.
  final String? loosePath;

  /// Absolute path of the ZIP containing the image, plus its [entryName].
  final String? zipPath;
  final String? entryName;

  bool get isZip => zipPath != null && entryName != null;

  /// Stable identity used for the materialization cache.
  String get cacheKey => isZip ? '$zipPath#$entryName' : (loosePath ?? name);
}

/// One box-scan edition (a ZIP or an edition subfolder) with its images.
class LocalBoxscanEdition {
  const LocalBoxscanEdition(this.label, this.images);

  final String label;
  final List<LocalImageRef> images;
}

/// One manual document/asset.
class LocalManualDoc {
  const LocalManualDoc({
    required this.stem,
    required this.label,
    required this.kind,
    required this.textVariant,
    this.loosePath,
    this.zipPath,
    this.entryName,
    this.images = const [],
    this.sizeBytes = 0,
  });

  /// Grouping stem (`<stem>` pairs `<stem>_text`), lowercased comparison done
  /// by the UI.
  final String stem;

  /// Display name (ZIP entry or file basename, or the ZIP name for image
  /// pages).
  final String label;

  final LocalManualKind kind;

  /// True for the `_text` variant of a scan/text manual pair.
  final bool textVariant;

  final String? loosePath;
  final String? zipPath;
  final String? entryName;

  /// Image pages for [LocalManualKind.imagePages].
  final List<LocalImageRef> images;

  final int sizeBytes;

  bool get isZip => zipPath != null && entryName != null;

  /// Stable identity used for the materialization cache.
  String get cacheKey => isZip ? '$zipPath#$entryName' : (loosePath ?? label);
}

/// Everything found for one game folder (lazily discovered, never indexed).
class LocalGameAssets {
  const LocalGameAssets({
    this.boxscans = const [],
    this.manuals = const [],
  });

  static const LocalGameAssets empty = LocalGameAssets();

  final List<LocalBoxscanEdition> boxscans;
  final List<LocalManualDoc> manuals;

  bool get isEmpty => boxscans.isEmpty && manuals.isEmpty;

  int get boxscanImageCount =>
      boxscans.fold(0, (n, e) => n + e.images.length);
}

/// Lazily discovers and materializes the `Boxscan/` and `Manual/` assets of a
/// game folder (see `docs/ANALYSIS-boxscan-manual-structure.md`).
///
/// Discovery runs in a background isolate and only lists paths / ZIP central
/// directories; media is extracted to a session temp directory on demand.
class LocalAssetsService {
  Directory? _cacheDir;
  final Map<String, Future<String?>> _materialized = {};
  Future<void> _zipQueue = Future<void>.value();

  /// Discovers the assets of `<root|patch>/<gameRel>` (both layers merged,
  /// patch wins for the same relative path).
  Future<LocalGameAssets> discover({
    required String rootDirectory,
    required String patchDirectory,
    required String gameRel,
  }) async {
    if (gameRel.trim().isEmpty) return LocalGameAssets.empty;
    try {
      return await Isolate.run(
          () => discoverSync(rootDirectory, patchDirectory, gameRel));
    } catch (_) {
      return LocalGameAssets.empty;
    }
  }

  /// Materializes all images of [edition]. Loose images are returned directly;
  /// each ZIP is read once and the extractions are serialized across editions
  /// and manuals (never several concurrent full-file reads over the network
  /// mount). Entries that still fail after the retry are omitted, so the UI can
  /// show a retry tile.
  Future<Map<String, String>> materializeEdition(
      LocalBoxscanEdition edition) async {
    final out = <String, String>{};
    final missingByZip = <String, List<LocalImageRef>>{};
    for (final image in edition.images) {
      final loose = image.loosePath;
      if (loose != null && loose.isNotEmpty) {
        out[image.cacheKey] = loose;
        continue;
      }
      final zip = image.zipPath;
      if (zip == null || image.entryName == null) continue;
      final cached = _materialized[image.cacheKey];
      if (cached != null) {
        final path = await cached;
        if (path != null && File(path).existsSync()) {
          out[image.cacheKey] = path;
          continue;
        }
        _materialized.remove(image.cacheKey);
      }
      missingByZip.putIfAbsent(zip, () => []).add(image);
    }
    for (final entry in missingByZip.entries) {
      final zipPath = entry.key;
      final images = entry.value;
      Map<String, String> paths = const {};
      try {
        paths = await _serialize(
            () => _withRetry(() => _extractMany(zipPath, images)));
      } catch (e) {
        stderr.writeln('[local_assets] failed to read $zipPath: $e');
      }
      for (final image in images) {
        final path = paths[image.cacheKey];
        if (path != null) {
          out[image.cacheKey] = path;
          _materialized[image.cacheKey] = Future.value(path);
        } else {
          _materialized.remove(image.cacheKey);
        }
      }
    }
    return out;
  }

  /// Absolute path of a loose image, or the image extracted from its ZIP.
  Future<String?> materializeImage(LocalImageRef ref) {
    final loose = ref.loosePath;
    if (loose != null && loose.isNotEmpty) return Future.value(loose);
    final zip = ref.zipPath;
    final entry = ref.entryName;
    if (zip == null || entry == null) return Future.value(null);
    return _materializeOne(ref.cacheKey, zip, entry);
  }

  /// Absolute path of a manual file (PDF/DOC/TXT), extracted from its ZIP when
  /// needed. Image-pages docs have no single file (use their [images]).
  Future<String?> materializeDoc(LocalManualDoc doc) {
    final loose = doc.loosePath;
    if (loose != null && loose.isNotEmpty) return Future.value(loose);
    final zip = doc.zipPath;
    final entry = doc.entryName;
    if (zip == null || entry == null) return Future.value(null);
    return _materializeOne(doc.cacheKey, zip, entry);
  }

  Future<String?> _materializeOne(
      String key, String zipPath, String entryName) {
    final cached = _materialized[key];
    if (cached != null) return cached;
    final future = _serialize(() async {
      try {
        final path =
            await _withRetry(() => _extractSingle(zipPath, entryName));
        if (path == null) _materialized.remove(key);
        return path;
      } catch (e) {
        stderr.writeln(
            '[local_assets] failed to read $zipPath ($entryName): $e');
        _materialized.remove(key);
        return null;
      }
    });
    _materialized[key] = future;
    return future;
  }

  Future<String?> _extractSingle(String zipPath, String entryName) async {
    final out = _cacheFileFor('$zipPath#$entryName', zipPath, entryName);
    final result =
        await Isolate.run(() => _extractZipEntries(zipPath, [(entryName, out)]));
    return result[entryName];
  }

  Future<Map<String, String>> _extractMany(
      String zipPath, List<LocalImageRef> images) async {
    final items = <(String, String)>[
      for (final image in images)
        (
          image.entryName!,
          _cacheFileFor(image.cacheKey, zipPath, image.entryName!),
        ),
    ];
    final byEntry = await Isolate.run(() => _extractZipEntries(zipPath, items));
    return {
      for (final image in images)
        if (byEntry[image.entryName] != null)
          image.cacheKey: byEntry[image.entryName]!,
    };
  }

  /// Runs ZIP extraction tasks one after another.
  Future<T> _serialize<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _zipQueue = _zipQueue.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<T> _withRetry<T>(Future<T> Function() task) async {
    try {
      return await task();
    } catch (e) {
      stderr.writeln('[local_assets] read failed, retrying: $e');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return task();
    }
  }

  String _cacheFileFor(String key, String zipPath, String entryName) {
    final zip = File(zipPath);
    final stamp =
        '${zip.lastModifiedSync().millisecondsSinceEpoch}-${zip.lengthSync()}';
    final hash = sha1.convert(utf8.encode('$key#$stamp')).toString();
    final dir = _cacheDir ??= _createCacheDir();
    return p.join(dir.path, '$hash${p.extension(entryName)}');
  }

  Directory _createCacheDir() {
    final dir = Directory(
        p.join(Directory.systemTemp.path, 'marcer_local_assets_$pid'));
    dir.createSync(recursive: true);
    return dir;
  }
}

const Set<String> _boxImageExts = {'.png', '.jpg', '.jpeg'};
const Set<String> _manualImageExts = {'.png', '.jpg', '.jpeg', '.gif'};

class _OverlayEntries<T> {
  final Map<String, T> _values = {};
  final Map<String, Set<String>> _keysByLower = {};
  final Map<String, int> _layerOf = {};

  Iterable<T> get values => _values.values;

  void add(int layer, String key, T value) {
    final lower = key.toLowerCase();
    final keys = _keysByLower.putIfAbsent(lower, () => <String>{});
    keys.removeWhere((other) {
      final otherLayer = _layerOf[other];
      if (otherLayer == null) return true;
      if (otherLayer < layer) {
        _values.remove(other);
        _layerOf.remove(other);
        return true;
      }
      return false;
    });
    if (_layerOf.containsKey(key)) {
      _values[key] = value;
      return;
    }
    _values[key] = value;
    _layerOf[key] = layer;
    keys.add(key);
  }
}

const Set<String> _frontSideTokens = {'front', 'f', 'fro'};
const Set<String> _backSideTokens = {'back', 'b', 'ba'};

_BoxImageSide? _boxImageSide(String name) {
  final stem = p.basenameWithoutExtension(name).toLowerCase();
  final tokens = stem
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.isNotEmpty)
      .toList();
  for (var i = tokens.length - 1; i >= 0; i--) {
    final token = tokens[i];
    if (int.tryParse(token) != null) continue;
    if (_frontSideTokens.contains(token)) return _BoxImageSide.front;
    if (_backSideTokens.contains(token)) return _BoxImageSide.back;
    return null;
  }
  return null;
}

enum _BoxImageSide { front, back }

void _sortBoxImages(List<LocalImageRef> images) {
  final hasFront =
      images.any((image) => _boxImageSide(image.name) == _BoxImageSide.front);
  final hasBack =
      images.any((image) => _boxImageSide(image.name) == _BoxImageSide.back);

  int rank(LocalImageRef image) {
    if (!hasFront || !hasBack) return 0;
    return switch (_boxImageSide(image.name)) {
      _BoxImageSide.front => 0,
      _BoxImageSide.back => 2,
      null => 1,
    };
  }

  images.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) return byName;
    return a.name.compareTo(b.name);
  });
}

/// Synchronous discovery (runs inside an isolate).
LocalGameAssets discoverSync(
    String rootDirectory, String patchDirectory, String gameRel) {
  final looseBox = _OverlayEntries<LocalImageRef>();
  final boxZips = _OverlayEntries<String>();
  final looseManuals = _OverlayEntries<LocalManualDoc>();
  final manualZips = _OverlayEntries<String>();

  final layers = [rootDirectory, patchDirectory];
  for (var layerIndex = 0; layerIndex < layers.length; layerIndex++) {
    final layer = layers[layerIndex];
    if (layer.trim().isEmpty) continue;
    final gameBase = p.join(layer, gameRel);
    final gameDir = Directory(gameBase);
    if (!gameDir.existsSync()) continue;

    List<FileSystemEntity> children;
    try {
      children = gameDir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final child in children) {
      if (child is! Directory) continue;
      final name = p.basename(child.path);
      final lower = name.toLowerCase();
      final isBox = lower == 'boxscan' || lower == 'box scan';
      final isManual = lower == 'manual' || lower == 'manuals';
      if (!isBox && !isManual) continue;

      _walk(child, (file, relDir) {
        final relKey = p.relative(file.path, from: gameBase);
        final ext = p.extension(file.path).toLowerCase();
        final base = p.basename(file.path);
        if (isBox) {
          if (_boxImageExts.contains(ext)) {
            looseBox.add(
              layerIndex,
              relKey,
              LocalImageRef(
                name: base,
                edition: relDir.isEmpty ? 'Boxscan' : relDir.split('/').first,
                loosePath: file.path,
              ),
            );
          } else if (ext == '.zip') {
            boxZips.add(layerIndex, relKey, file.path);
          }
          // PDFs etc. misplaced in Boxscan/ are ignored (analysis §3.3/6.2).
        } else if (ext == '.zip') {
          manualZips.add(layerIndex, relKey, file.path);
        } else {
          final doc = _looseManualDoc(file.path);
          if (doc != null) looseManuals.add(layerIndex, relKey, doc);
        }
      });
    }
  }

  final editions = <String, List<LocalImageRef>>{};
  for (final ref in looseBox.values) {
    editions.putIfAbsent(ref.edition, () => []).add(ref);
  }
  for (final zipPath in boxZips.values) {
    final stem = _stemOfZip(zipPath);
    for (final entry in _listZipFiles(zipPath)) {
      final ext = p.extension(entry.name).toLowerCase();
      if (!_boxImageExts.contains(ext)) continue;
      editions.putIfAbsent(stem, () => []).add(LocalImageRef(
            name: p.basename(entry.name),
            edition: stem,
            zipPath: zipPath,
            entryName: entry.name,
          ));
    }
  }

  final manuals = <LocalManualDoc>[...looseManuals.values];
  for (final zipPath in manualZips.values) {
    manuals.addAll(_manualsFromZip(zipPath));
  }

  final editionList = <LocalBoxscanEdition>[];
  for (final e in editions.entries) {
    // A loose edition subfolder and its same-named ZIP often carry the same
    // scans; drop exact name duplicates within one edition (the analysis only
    // forbids deduplicating by content/inferred side, not identical names).
    final seen = <String>{};
    final images = <LocalImageRef>[];
    for (final image in e.value) {
      if (!seen.add(image.name)) continue;
      images.add(image);
    }
    _sortBoxImages(images);
    editionList.add(LocalBoxscanEdition(e.key, images));
  }
  editionList
      .sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

  manuals.sort((a, b) {
    final byStem = a.stem.toLowerCase().compareTo(b.stem.toLowerCase());
    if (byStem != 0) return byStem;
    if (a.textVariant != b.textVariant) return a.textVariant ? 1 : -1;
    return a.label.toLowerCase().compareTo(b.label.toLowerCase());
  });

  return LocalGameAssets(boxscans: editionList, manuals: manuals);
}

/// Recursively walks [dir], skipping hidden entries and `@eaDir`; [onFile] gets
/// the path relative to the companion folder (used as the edition label).
void _walk(Directory dir, void Function(File file, String relDir) onFile,
    [String rel = '']) {
  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } catch (_) {
    return;
  }
  for (final e in entries) {
    final name = p.basename(e.path);
    if (name.isEmpty || name.startsWith('.') || name.toLowerCase() == '@eadir') {
      continue;
    }
    if (e is Directory) {
      _walk(e, onFile, rel.isEmpty ? name : '$rel/$name');
    } else if (e is File) {
      onFile(e, rel);
    }
  }
}

bool _isTextStem(String stem) => stem.toLowerCase().endsWith('_text');

String _stemWithoutText(String stem) =>
    _isTextStem(stem) ? stem.substring(0, stem.length - 5) : stem;

String _stemOfZip(String zipPath) =>
    _stemWithoutText(p.basenameWithoutExtension(zipPath));

int _fileSize(String path) {
  try {
    return File(path).lengthSync();
  } catch (_) {
    return 0;
  }
}

LocalManualDoc? _looseManualDoc(String path) {
  final ext = p.extension(path).toLowerCase();
  final base = p.basename(path);
  final rawStem = p.basenameWithoutExtension(path);
  final text = _isTextStem(rawStem);
  final stem = _stemWithoutText(rawStem);
  final size = _fileSize(path);
  if (ext == '.pdf') {
    return LocalManualDoc(
      stem: stem,
      label: base,
      kind: LocalManualKind.pdf,
      textVariant: text,
      loosePath: path,
      sizeBytes: size,
    );
  }
  if (ext == '.doc' || ext == '.txt') {
    return LocalManualDoc(
      stem: stem,
      label: base,
      kind: LocalManualKind.document,
      textVariant: text,
      loosePath: path,
      sizeBytes: size,
    );
  }
  if (ext == '.msa') {
    return LocalManualDoc(
      stem: stem,
      label: base,
      kind: LocalManualKind.diskImage,
      textVariant: false,
      loosePath: path,
      sizeBytes: size,
    );
  }
  if (_manualImageExts.contains(ext)) {
    return LocalManualDoc(
      stem: stem,
      label: base,
      kind: LocalManualKind.imagePages,
      textVariant: false,
      images: [LocalImageRef(name: base, edition: stem, loosePath: path)],
      sizeBytes: size,
    );
  }
  // RAR and unknown formats are skipped (analysis §3.6/6.3).
  return null;
}

List<LocalManualDoc> _manualsFromZip(String zipPath) {
  final stem = _stemOfZip(zipPath);
  final text = _isTextStem(p.basenameWithoutExtension(zipPath));
  final out = <LocalManualDoc>[];
  final images = <LocalImageRef>[];
  for (final entry in _listZipFiles(zipPath)) {
    final ext = p.extension(entry.name).toLowerCase();
    final base = p.basename(entry.name);
    if (ext == '.pdf') {
      out.add(LocalManualDoc(
        stem: stem,
        label: base,
        kind: LocalManualKind.pdf,
        textVariant: text,
        zipPath: zipPath,
        entryName: entry.name,
        sizeBytes: entry.size,
      ));
    } else if (ext == '.doc' || ext == '.txt') {
      out.add(LocalManualDoc(
        stem: stem,
        label: base,
        kind: LocalManualKind.document,
        textVariant: text,
        zipPath: zipPath,
        entryName: entry.name,
        sizeBytes: entry.size,
      ));
    } else if (_manualImageExts.contains(ext)) {
      images.add(LocalImageRef(
        name: base,
        edition: stem,
        zipPath: zipPath,
        entryName: entry.name,
      ));
    } else if (ext == '.msa') {
      out.add(LocalManualDoc(
        stem: stem,
        label: base,
        kind: LocalManualKind.diskImage,
        textVariant: false,
        zipPath: zipPath,
        entryName: entry.name,
        sizeBytes: entry.size,
      ));
    }
  }
  if (images.isNotEmpty) {
    images.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    out.add(LocalManualDoc(
      stem: stem,
      label: p.basename(zipPath),
      kind: LocalManualKind.imagePages,
      textVariant: false,
      images: images,
    ));
  }
  return out;
}

class _ZipEntry {
  const _ZipEntry(this.name, this.size);

  final String name;
  final int size;
}

List<_ZipEntry> _listZipFiles(String zipPath) {
  try {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    return [
      for (final f in archive.files)
        if (f.isFile) _ZipEntry(f.name, f.size),
    ];
  } catch (_) {
    return const [];
  }
}

/// Extracts the requested ZIP entries (`(entryName, outPath)`) in one pass and
/// returns the successfully written ones. Verifies the uncompressed size.
Map<String, String> _extractZipEntries(
    String zipPath, List<(String, String)> items) {
  final out = <String, String>{};
  try {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final wanted = {for (final (entry, _) in items) entry};
    final byName = <String, ArchiveFile>{};
    for (final f in archive.files) {
      if (f.isFile && wanted.contains(f.name)) byName[f.name] = f;
    }
    for (final (entry, outPath) in items) {
      final f = byName[entry];
      if (f == null) continue;
      final content = f.content;
      if (content is! List<int>) continue;
      if (f.size > 0 && content.length != f.size) continue;
      try {
        File(outPath).parent.createSync(recursive: true);
        File(outPath).writeAsBytesSync(content);
        out[entry] = outPath;
      } catch (_) {
        // Skip this entry; the caller leaves it unresolved (retry in the UI).
      }
    }
  } catch (e) {
    stderr.writeln('[local_assets] ZIP decode failed ($zipPath): $e');
  }
  return out;
}
