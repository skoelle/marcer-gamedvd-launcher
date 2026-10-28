// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

class FavoritesPathCodec {
  FavoritesPathCodec({
    required this.rootDirectory,
    required this.patchDirectory,
    required this.sectionTrees,
  });

  final String rootDirectory;
  final String patchDirectory;
  final Map<String, String> sectionTrees;

  String decode(String stored) {
    final value = _clean(stored);
    if (value.isEmpty) return '';
    if (!_isAbsolute(value)) {
      final rel = _sanitizeRelative(value);
      if (rel == null) return value;
      return _resolveRelative(rel) ?? value;
    }
    final absolute = p.normalize(value);
    if (_relativeUnder(absolute) != null) return absolute;
    return _mapForeignAbsolute(absolute) ?? absolute;
  }

  String encode(String absolute) {
    final normalized = p.normalize(absolute);
    final rel = _relativeUnder(normalized);
    if (rel != null) return rel;
    return normalizeRelSeparators(normalized);
  }

  String _clean(String value) => normalizeRelSeparators(value)
      .replaceFirst('\uFEFF', '')
      .trim();

  bool _isAbsolute(String value) =>
      value.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(value);

  String? _sanitizeRelative(String value) {
    var rel = value;
    while (rel.startsWith('./')) {
      rel = rel.substring(2);
    }
    rel = p.posix.normalize(rel);
    if (rel.isEmpty ||
        rel == '.' ||
        rel == '..' ||
        rel.startsWith('../') ||
        rel.startsWith('/')) {
      return null;
    }
    return rel;
  }

  Iterable<String> get _bases sync* {
    if (patchDirectory.isNotEmpty) yield patchDirectory;
    if (rootDirectory.isNotEmpty) yield rootDirectory;
  }

  String? _relativeUnder(String absolute) {
    String? best;
    var bestLength = -1;
    for (final base in _bases) {
      final normBase = p.normalize(base);
      if (p.isWithin(normBase, absolute) || p.equals(normBase, absolute)) {
        if (normBase.length > bestLength) {
          bestLength = normBase.length;
          best = normalizeRelSeparators(p.relative(absolute, from: normBase));
        }
      }
    }
    return best;
  }

  String? _resolveRelative(String rel, {bool requireExists = false}) {
    final patch = patchDirectory.isEmpty ? null : p.join(patchDirectory, rel);
    final root = rootDirectory.isEmpty ? null : p.join(rootDirectory, rel);
    if (patch != null && File(patch).existsSync()) return patch;
    if (root != null && File(root).existsSync()) return root;
    if (requireExists) return null;
    return root ?? patch;
  }

  String? _mapForeignAbsolute(String absolute) {
    final value = normalizeRelSeparators(absolute);
    final lowerValue = value.toLowerCase();
    final markers = <String>{
      for (final tree in sectionTrees.values) tree,
      'Title Sorted',
      'Utilitys - Title Sorted',
    };
    for (final marker in markers) {
      final index = lowerValue.indexOf('${marker.toLowerCase()}/');
      if (index < 0) continue;
      final rel = _sanitizeRelative(value.substring(index));
      if (rel == null) continue;
      final exact = _resolveRelative(rel, requireExists: true);
      if (exact != null) return exact;
      final caseInsensitive = _resolveRelativeCaseInsensitive(rel);
      if (caseInsensitive != null) return caseInsensitive;
    }
    return null;
  }

  String? _resolveRelativeCaseInsensitive(String rel) {
    for (final base in _bases) {
      final resolved = _walkCaseInsensitive(base, rel);
      if (resolved != null) return resolved;
    }
    return null;
  }

  String? _walkCaseInsensitive(String base, String rel) {
    try {
      var current = base;
      for (final part in rel.split('/')) {
        if (part.isEmpty) continue;
        final direct = p.join(current, part);
        if (File(direct).existsSync()) {
          current = direct;
          continue;
        }
        final dir = Directory(current);
        if (!dir.existsSync()) return null;
        String? match;
        for (final entry in dir.listSync(followLinks: false)) {
          if (p.basename(entry.path).toLowerCase() == part.toLowerCase()) {
            match = entry.path;
            break;
          }
        }
        if (match == null) return null;
        current = match;
      }
      return File(current).existsSync() ? current : null;
    } catch (_) {
      // Permission / I/O error on one path segment: no match, but never fail
      // the whole favorites load.
      return null;
    }
  }
}
