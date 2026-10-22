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

/// Canonical gallery tree directory names (the three trees under
/// `Title Sorted/` on a full GameDVD). Other prefix matches such as
/// `Bonus/Cracked Demos` or `Crew Sorted/Utilitys - Scene and Cracks -
/// Crew Sorted` are decoys and must never win when the canonical tree
/// exists (bug 2026-10-15: first-prefix-wins picked the decoys, which
/// emptied the ★ Favorites filter and mis-filed new favorites).
const Map<String, String> kCanonicalTreeNames = {
  'cracked': 'Cracked Games - Title Sorted',
  'pd': 'PD Games - Title Sorted',
  'utils': 'Utilitys - Title Sorted',
};

/// Discovers the section tree directories (relative to the overlay root) by
/// scanning the root itself and its direct children for the tree name
/// prefixes of [sectionOfTreeName] — e.g. `Title Sorted/Cracked Games -
/// Sorted` for a full-DVD root, or `Cracked Games - Title Sorted` when the
/// root already points at the tree's parent.
///
/// Multiple directories may match one section (decoy trees like
/// `Bonus/Cracked Demos` exist on real DVDs). Per section the winner is:
/// 1. the candidate whose name equals [kCanonicalTreeNames], else
/// 2. the first candidate (previous behaviour — deterministic scan order).
///
/// The result feeds the per-section favorites files (one `favorites.txt`
/// per section tree, console-launcher layout) and the pd/utils ZIP
/// resolution.
Map<String, String> discoverSectionTrees(OverlayBrowser browser) {
  final candidates = <String, List<String>>{};

  void consider(String rel) {
    final name = rel.split('/').last;
    final section = sectionOfTreeName(name);
    if (section == null) return;
    final list = candidates.putIfAbsent(section, () => []);
    if (!list.contains(rel)) list.add(rel);
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

  final out = <String, String>{};
  candidates.forEach((section, rels) {
    String? winner;
    for (final rel in rels) {
      if (rel.split('/').last == kCanonicalTreeNames[section]) {
        winner = rel;
        break;
      }
    }
    out[section] = winner ?? rels.first;
  });
  return out;
}

String normalizeRelSeparators(String rel) => rel.replaceAll('\\', '/');

/// Section key (`cracked`/`pd`/`utils`) of a root-relative path, or `null`
/// when the path is outside every section tree.
String? sectionOfRel(Map<String, String> trees, String rel) {
  final relPath = normalizeRelSeparators(rel);
  if (relPath.isEmpty) return null;
  for (final entry in trees.entries) {
    final tree = entry.value;
    if (relPath == tree || relPath.startsWith('$tree/')) return entry.key;
  }
  return null;
}
