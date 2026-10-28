// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'entry.dart';

/// Overlay merge per `SPEC-launcher.md` §7 (R11–R17).
///
/// Read-only: never writes into [rootDir] or [patchDir].
class OverlayBrowser {
  OverlayBrowser({required this.rootDir, this.patchDir});

  final String rootDir;
  final String? patchDir;

  /// Whether a patch layer is active (non-empty configured path that exists).
  bool get hasPatchLayer =>
      patchDir != null && patchDir!.isNotEmpty && Directory(patchDir!).existsSync();

  /// Lists direct children of [relPath] (empty relative path = root).
  ///
  /// Union of directory names and `.zip` file names from both layers,
  /// case-insensitively deduplicated, directories first then ZIPs, each group
  /// sorted case-insensitively ascending. Hidden entries are excluded.
  /// Never leaves the configured roots (R16).
  List<Entry> list(String relPath) {
    final rel = _sanitize(relPath);
    final rootList = _scan(_join(rootDir, rel));
    final patchList = hasPatchLayer ? _scan(_join(patchDir!, rel)) : <_ScanEntry>[];

    final byKey = <String, Entry>{};
    for (final s in rootList) {
      byKey[s.key] = Entry(
        name: s.name,
        kind: s.kind,
        inRoot: true,
        inPatch: false,
        rootPath: s.fullPath,
      );
    }
    for (final s in patchList) {
      final existing = byKey[s.key];
      if (existing == null) {
        byKey[s.key] = Entry(
          name: s.name,
          kind: s.kind,
          inRoot: false,
          inPatch: true,
          patchPath: s.fullPath,
        );
      } else {
        byKey[s.key] = Entry(
          name: existing.name,
          kind: existing.kind,
          inRoot: true,
          inPatch: true,
          rootPath: existing.rootPath,
          patchPath: s.fullPath,
        );
      }
    }

    final entries = byKey.values.toList();
    int cmp(Entry a, Entry b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    entries.sort((a, b) {
      if (a.kind != b.kind) return a.kind == EntryKind.directory ? -1 : 1;
      return cmp(a, b);
    });
    return entries;
  }

  /// Returns the parent relative path; root stays root (R17).
  String parent(String relPath) {
    final rel = _sanitize(relPath);
    if (rel.isEmpty) return '';
    final idx = rel.lastIndexOf('/');
    return idx == -1 ? '' : rel.substring(0, idx);
  }

  static String _sanitize(String rel) {
    if (rel.startsWith('/') || rel.contains('..')) return '';
    return rel.replaceAll(RegExp(r'^/+|/+$'), '');
  }

  static String _join(String base, String rel) =>
      rel.isEmpty ? base : '$base/$rel';

  static List<_ScanEntry> _scan(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const [];
    final out = <_ScanEntry>[];
    for (final e in dir.listSync(followLinks: false)) {
      final name = e.uri.pathSegments.isEmpty
          ? e.path.split('/').last
          : e.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
      if (name.isEmpty || name.startsWith('.') || name == '@eaDir') continue;
      if (e is Directory) {
        out.add(_ScanEntry(name, EntryKind.directory, name.toLowerCase(), e.path));
      } else if (e is File && name.toLowerCase().endsWith('.zip')) {
        out.add(_ScanEntry(
            name, EntryKind.zip, name.toLowerCase().replaceAll('.zip', ''), e.path));
      }
    }
    return out;
  }
}

class _ScanEntry {
  _ScanEntry(this.name, this.kind, this.key, this.fullPath);
  final String name;
  final EntryKind kind;
  final String key;
  final String fullPath;
}
