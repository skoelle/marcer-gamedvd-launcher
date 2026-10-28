// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

/// Entry model mirroring `SPEC-launcher.md` section 6.1.
library;

/// Kind of a catalog entry.
enum EntryKind { directory, zip }

/// Layer status derived from [Entry.inRoot] / [Entry.inPatch] (`SPEC-launcher.md` §6.2).
enum LayerStatus { both, root, patch }

/// A single overlay entry (directory or ZIP) as produced by the merge.
class Entry {
  Entry({
    required this.name,
    required this.kind,
    required this.inRoot,
    required this.inPatch,
    this.rootPath,
    this.patchPath,
    this.isVirtual = false,
  });

  final String name;
  final EntryKind kind;
  final bool inRoot;
  final bool inPatch;
  final String? rootPath;
  final String? patchPath;
  final bool isVirtual;

  /// Effective path: patch wins when present (`SPEC-launcher.md` R14).
  String? get effectivePath => inPatch ? (patchPath ?? rootPath) : rootPath;

  /// Derived layer status (`SPEC-launcher.md` §6.2).
  LayerStatus get layerStatus {
    if (inRoot && inPatch) return LayerStatus.both;
    if (inPatch) return LayerStatus.patch;
    return LayerStatus.root;
  }
}
