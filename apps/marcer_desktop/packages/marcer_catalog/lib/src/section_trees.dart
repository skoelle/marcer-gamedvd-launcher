// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'entry.dart';
import 'overlay.dart';

/// Section tree name prefixes (gallery directory names on the GameDVD):
/// `Cracked…`, `PD…`, `Util…`.
String? sectionOfTreeName(String name) {
  if (name.startsWith('Cracked')) return 'cracked';
  if (name.startsWith('PD')) return 'pd';
  if (name.startsWith('Util')) return 'utils';
  return null;
}

/// Discovers the section tree directories (relative to the overlay root) by
/// scanning the root itself and its direct children for the tree name
/// prefixes of [sectionOfTreeName] — e.g. `Title Sorted/Cracked Games - Title
/// Sorted` for a full-DVD root, or `Cracked Games - Title Sorted` when the
/// root already points at the tree's parent.
///
/// The result feeds the per-section favorites files (one `favorites.txt`
/// per section tree, console-launcher layout) and the pd/utils ZIP
/// resolution.
Map<String, String> discoverSectionTrees(OverlayBrowser browser) {
  final out = <String, String>{};

  void consider(String rel) {
    final name = rel.split('/').last;
    final section = sectionOfTreeName(name);
    if (section != null && !out.containsKey(section)) out[section] = rel;
  }

  for (final e in browser.list('')) {
    if (e.kind != EntryKind.directory) continue;
    consider(e.name);
    // Trees may sit one level deeper (e.g. under `Title Sorted`); do not
    // descend into an already matched tree (its children are letters).
    final matched = sectionOfTreeName(e.name) != null;
    if (matched) continue;
    for (final c in browser.list(e.name)) {
      if (c.kind == EntryKind.directory) consider('${e.name}/${c.name}');
    }
  }
  return out;
}

/// Section key (`cracked`/`pd`/`utils`) of a root-relative path, or `null`
/// when the path is outside every section tree.
String? sectionOfRel(Map<String, String> trees, String rel) {
  if (rel.isEmpty) return null;
  for (final entry in trees.entries) {
    final tree = entry.value;
    if (rel == tree || rel.startsWith('$tree/')) return entry.key;
  }
  return null;
}
