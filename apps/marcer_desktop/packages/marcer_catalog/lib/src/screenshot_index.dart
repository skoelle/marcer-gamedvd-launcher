// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

/// Index file name per section (`index.json` stays the cracked index for
/// backward compatibility; `pd`/`utils` get their own files next to it —
/// see `SPEC-screenshot-generator.md`).
const Map<String, String> kSectionIndexNames = {
  'cracked': 'index.json',
  'pd': 'index-pd.json',
  'utils': 'index-utils.json',
};

/// Section keys in UI order (gallery tabs), matching [kSectionIndexNames].
const List<String> kSections = ['cracked', 'pd', 'utils'];

/// Screenshot index lookup (`SPEC-screenshot-generator.md`, `index.json`).
///
/// One instance represents **one** index file of one section. The
/// [ScreenshotIndices] aggregate holds the three section indices and provides
/// rel-path lookups across all of them.
///
/// Key gotcha (PLAN.md §2): on disk `preview` and `candidates` are *basenames*;
/// the real PNG is `<ScreenshotDirectory>/<dirname(rel)>/<preview>`.
class ScreenshotIndex {
  ScreenshotIndex._(this._entries, this.screenshotDirectory, this._loadError,
      this.mtime, this.indexName);

  /// Loads `<screenshotDirectory>/<indexName>`; missing/unreadable file yields an
  /// empty index ([loadError] set) instead of throwing (DECISION §7).
  factory ScreenshotIndex.load(String screenshotDirectory,
      [String indexName = 'index.json']) {
    final file = File('$screenshotDirectory/$indexName');
    if (!file.existsSync()) {
      return ScreenshotIndex._(
          const {}, screenshotDirectory, '$indexName not found', null, indexName);
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
      return ScreenshotIndex._(entries, screenshotDirectory, null, mtime, indexName);
    } catch (e) {
      return ScreenshotIndex._(
          const {}, screenshotDirectory, 'parse error: $e', null, indexName);
    }
  }

  /// Empty index for an unconfigured output directory.
  ScreenshotIndex.empty(String reason)
      : this._(const {}, '', reason, null, '');

  final Map<String, ScreenshotEntry> _entries;
  final String screenshotDirectory;
  final String? _loadError;

  /// File name this index was loaded from (`index.json`, `index-pd.json`, …).
  final String indexName;

  /// Index file modification time (gallery footer), or null when absent.
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
        dir.isEmpty ? '$screenshotDirectory/${entry.preview}' : '$screenshotDirectory/$dir/${entry.preview}';
    return File(path).existsSync() ? path : null;
  }

  /// Resolves candidate PNG absolute paths (existing files only).
  List<String> candidatePathsFor(String relPath) {
    final entry = _entries[relPath];
    if (entry == null) return const [];
    final dir = _dirname(relPath);
    return entry.candidates
        .map((c) => dir.isEmpty ? '$screenshotDirectory/$c' : '$screenshotDirectory/$dir/$c')
        .where((p) => File(p).existsSync())
        .toList();
  }

  static String _dirname(String relPath) {
    final idx = relPath.lastIndexOf('/');
    return idx == -1 ? '' : relPath.substring(0, idx);
  }
}

/// The three per-section screenshot indices of one output directory
/// (`index.json`, `index-pd.json`, `index-utils.json`). Missing files degrade
/// to empty indices (warning collected in [warnings]), so an older output
/// directory without the pd/utils indices still works (gameinfo-only pd/utils
/// cards, no status counts there).
class ScreenshotIndices {
  ScreenshotIndices._(this._bySection, this.warnings);

  factory ScreenshotIndices.load(String screenshotDirectory) {
    final warnings = <String>[];
    final bySection = <String, ScreenshotIndex>{};
    if (screenshotDirectory.isEmpty) {
      for (final section in kSections) {
        bySection[section] =
            ScreenshotIndex.empty('ScreenshotDirectory not configured');
      }
      warnings.add('Screenshots: ScreenshotDirectory not configured');
    } else {
      for (final entry in kSectionIndexNames.entries) {
        final idx = ScreenshotIndex.load(screenshotDirectory, entry.value);
        bySection[entry.key] = idx;
        // Only the cracked index is historically required; a missing
        // pd/utils index degrades silently to gameinfo-only cards.
        if (idx.loadError != null && entry.key == 'cracked') {
          warnings.add('Screenshots: ${idx.loadError}');
        }
      }
    }
    return ScreenshotIndices._(bySection, warnings);
  }

  final Map<String, ScreenshotIndex> _bySection;

  /// Load warnings (missing/unreadable files); also surfaced as app notices.
  final List<String> warnings;

  /// Index of one section (`cracked` | `pd` | `utils`); an empty index for
  /// unknown keys.
  ScreenshotIndex forSection(String section) =>
      _bySection[section] ?? ScreenshotIndex.empty('unknown section $section');

  Map<String, ScreenshotIndex> get bySection => _bySection;

  /// Status histogram of one section's index.
  Map<String, int> statusCountsFor(String section) =>
      forSection(section).statusCounts;

  /// Modification time of one section's index file.
  DateTime? mtimeFor(String section) => forSection(section).mtime;

  /// File name of one section's index (`index.json` / `index-pd.json` / …).
  String indexNameFor(String section) =>
      kSectionIndexNames[section] ?? forSection(section).indexName;

  /// Index entry by rel ZIP path, searched across all sections.
  ScreenshotEntry? operator [](String relPath) {
    for (final idx in _bySection.values) {
      final entry = idx[relPath];
      if (entry != null) return entry;
    }
    return null;
  }

  /// Preview PNG by rel ZIP path, searched across all sections.
  String? previewPathFor(String relPath) {
    for (final idx in _bySection.values) {
      if (idx[relPath] != null) return idx.previewPathFor(relPath);
    }
    return null;
  }

  /// Candidate PNGs by rel ZIP path, searched across all sections.
  List<String> candidatePathsFor(String relPath) {
    for (final idx in _bySection.values) {
      if (idx[relPath] != null) return idx.candidatePathsFor(relPath);
    }
    return const [];
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

  /// Pipeline status; mutable for the desktop app's manual curation
  /// (`C` + Save in the lightbox/detail view writes it back via the
  /// screenshot-gen lock, see `index_editor.dart`).
  String status;

  /// Preview classification (`game`/`desktop`/`textscreen`/`darkscreen`);
  /// mutable like [status] for manual curation.
  String? kind;

  final String layer;
  final String? preview;
  final List<String> candidates;
  final int? size;
  final List<String> zipContents;

  /// Manual curation: set a new status/kind pair in memory (the pending
  /// map in the controller keeps the original values for discard/save).
  void applyStatusKind(String newStatus, String? newKind) {
    status = newStatus;
    kind = newKind;
  }
}
