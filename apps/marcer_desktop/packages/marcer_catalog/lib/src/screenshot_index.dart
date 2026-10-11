// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

/// Screenshot index lookup (`SPEC-screenshot-generator.md`, `index.json`).
///
/// Key gotcha (PLAN.md §2): on disk `preview` and `candidates` are *basenames*;
/// the real PNG is `<OutDirectory>/<dirname(rel)>/<preview>`.
class ScreenshotIndex {
  ScreenshotIndex._(
      this._entries, this.outDirectory, this._loadError, this.mtime);

  /// Loads `<outDirectory>/index.json`; missing/unreadable file yields an
  /// empty index ([loadError] set) instead of throwing (DECISION §7).
  factory ScreenshotIndex.load(String outDirectory) {
    final file = File('$outDirectory/index.json');
    if (!file.existsSync()) {
      return ScreenshotIndex._(
          const {}, outDirectory, 'index.json not found', null);
    }
    try {
      final mtime = file.statSync().modified;
      final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final entries = <String, ScreenshotEntry>{};
      final rawEntries = (map['entries'] as Map<String, dynamic>?) ?? const {};
      rawEntries.forEach((key, value) {
        entries[key] =
            ScreenshotEntry.fromJson(key, value as Map<String, dynamic>);
      });
      return ScreenshotIndex._(entries, outDirectory, null, mtime);
    } catch (e) {
      return ScreenshotIndex._(
          const {}, outDirectory, 'parse error: $e', null);
    }
  }

  /// Empty index for an unconfigured output directory.
  ScreenshotIndex.empty(String reason) : this._(const {}, '', reason, null);

  final Map<String, ScreenshotEntry> _entries;
  final String outDirectory;
  final String? _loadError;

  /// `index.json` modification time (gallery footer), or null when absent.
  final DateTime? mtime;

  String? get loadError => _loadError;
  int get length => _entries.length;
  Map<String, ScreenshotEntry> get entries => _entries;

  /// Status histogram over all index entries (gallery `status_counts`).
  Map<String, int> get statusCounts {
    final out = <String, int>{};
    for (final e in _entries.values) {
      final s = e.status.isEmpty ? 'unknown' : e.status;
      out[s] = (out[s] ?? 0) + 1;
    }
    return out;
  }

  ScreenshotEntry? operator [](String relPath) => _entries[relPath];

  /// Resolves the preview PNG absolute path, or null when absent.
  String? previewPathFor(String relPath) {
    final entry = _entries[relPath];
    if (entry == null || entry.preview == null) return null;
    final dir = _dirname(relPath);
    final path =
        dir.isEmpty ? '$outDirectory/${entry.preview}' : '$outDirectory/$dir/${entry.preview}';
    return File(path).existsSync() ? path : null;
  }

  /// Resolves candidate PNG absolute paths (existing files only).
  List<String> candidatePathsFor(String relPath) {
    final entry = _entries[relPath];
    if (entry == null) return const [];
    final dir = _dirname(relPath);
    return entry.candidates
        .map((c) => dir.isEmpty ? '$outDirectory/$c' : '$outDirectory/$dir/$c')
        .where((p) => File(p).existsSync())
        .toList();
  }

  static String _dirname(String relPath) {
    final idx = relPath.lastIndexOf('/');
    return idx == -1 ? '' : relPath.substring(0, idx);
  }
}

/// One `index.json` entry, keyed by rel zip path.
class ScreenshotEntry {
  ScreenshotEntry({
    required this.rel,
    required this.name,
    required this.status,
    required this.kind,
    required this.layer,
    required this.preview,
    required this.candidates,
    this.size,
    this.zipContents = const [],
  });

  factory ScreenshotEntry.fromJson(String key, Map<String, dynamic> json) {
    return ScreenshotEntry(
      rel: (json['rel'] ?? key) as String,
      name: (json['name'] ?? '') as String,
      status: (json['status'] ?? '') as String,
      kind: (json['kind'] ?? '') as String?,
      layer: (json['layer'] ?? '') as String,
      preview: (json['preview'] ?? '') as String?,
      candidates: ((json['candidates'] as List<dynamic>?) ?? const [])
          .map((e) => e as String)
          .toList(),
      size: (json['size'] as num?)?.toInt(),
      zipContents: ((json['zip_contents'] as List<dynamic>?) ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  final String rel;
  final String name;
  final String status;
  final String? kind;
  final String layer;
  final String? preview;
  final List<String> candidates;
  final int? size;
  final List<String> zipContents;
}
