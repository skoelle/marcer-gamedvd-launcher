// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

/// Gameinfo join per `ANALYSIS-game-data.md` §4.2.
///
/// Loads the generated `games-*.json` files and joins them against screenshot
/// index entries by `letter = parts[2]` / `folder = parts[3]` of the rel path
/// (e.g. `Title Sorted/<tree>/<Letter>/<Folder>/...zip`).
///
/// Degrades gracefully (DECISION §7): missing files yield empty results.
class GameInfoIndex {
  GameInfoIndex._(
      this._byLetterFolder, this._byKind, this._byKindKey, this.manifest);

  /// Loads all `games-<kind>.json` files found in [gameinfoDir] (may be empty).
  factory GameInfoIndex.load(String gameinfoDir) {
    final byLetterFolder = <String, GameInfo>{};
    final byKind = <String, List<GameInfo>>{};
    final byKindKey = <String, Map<String, GameInfo>>{};
    var manifest = <String, dynamic>{};
    final dir = Directory(gameinfoDir);
    if (!dir.existsSync()) {
      return GameInfoIndex._(byLetterFolder, byKind, byKindKey, manifest);
    }
    final manifestFile = File('$gameinfoDir/manifest.json');
    if (manifestFile.existsSync()) {
      try {
        manifest =
            jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {
        manifest = <String, dynamic>{};
      }
    }
    for (final kind in ['cracked', 'pd', 'utils']) {
      final file = File('$gameinfoDir/games-$kind.json');
      if (!file.existsSync()) continue;
      final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final games = (map['games'] as List<dynamic>?) ?? const [];
      final list = <GameInfo>[];
      final keyed = <String, GameInfo>{};
      for (final g in games) {
        final game = GameInfo.fromJson(g as Map<String, dynamic>, kind);
        list.add(game);
        final key = '${game.letter.toLowerCase()}|${game.folder.toLowerCase()}';
        byLetterFolder[key] ??= game;
        keyed[key] ??= game;
      }
      byKind[kind] = list;
      byKindKey[kind] = keyed;
    }
    return GameInfoIndex._(byLetterFolder, byKind, byKindKey, manifest);
  }

  final Map<String, GameInfo> _byLetterFolder;
  final Map<String, List<GameInfo>> _byKind;
  final Map<String, Map<String, GameInfo>> _byKindKey;

  /// Raw `manifest.json` content (gallery footer/status), possibly empty.
  final Map<String, dynamic> manifest;

  int get length => _byLetterFolder.length;

  /// `generated_at` timestamp from the manifest, or empty (gallery footer).
  String get generatedAt => (manifest['generated_at'] ?? '') as String;

  /// Cracked matched-folder coverage from the manifest (gallery `coverage`).
  int? get matchedFolders {
    for (final src in (manifest['sources'] as List<dynamic>?) ?? const []) {
      final m = src as Map<String, dynamic>;
      if (m['kind'] == 'cracked') {
        return (m['matched_folders'] as num?)?.toInt();
      }
    }
    return null;
  }

  /// All games of one section (`cracked` | `pd` | `utils`).
  List<GameInfo> byKind(String kind) => _byKind[kind] ?? const [];

  /// Section-scoped join by letter/folder (case-insensitive) — the cracked
  /// card join must only see `games-cracked.json`, like the gallery.
  GameInfo? lookupKind(String kind, String letter, String folder) =>
      _byKindKey[kind]?['${letter.toLowerCase()}|${folder.toLowerCase()}'];

  /// Extracts letter/folder from a screenshot-index rel zip path and joins.
  GameInfo? lookupByRel(String relPath) {
    final parts = relPath.split('/');
    if (parts.length < 4) return null;
    final letter = parts[2];
    final folder = parts[3];
    return _byLetterFolder['${letter.toLowerCase()}|${folder.toLowerCase()}'];
  }
}

/// One matched game folder from `games-*.json`.
class GameInfo {
  GameInfo({
    required this.folder,
    required this.letter,
    required this.layers,
    required this.matchedVia,
    required this.matchedTitle,
    required this.variants,
    required this.kind,
  });

  factory GameInfo.fromJson(Map<String, dynamic> json, String kind) {
    return GameInfo(
      folder: (json['folder'] ?? '') as String,
      letter: (json['letter'] ?? '') as String,
      layers: ((json['layers'] as List<dynamic>?) ?? const [])
          .map((e) => e as String)
          .toList(),
      matchedVia: (json['matched_via'] ?? 'none') as String,
      matchedTitle: (json['matched_title'] ?? '') as String,
      variants: ((json['variants'] as List<dynamic>?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      kind: kind,
    );
  }

  final String folder;
  final String letter;
  final List<String> layers;
  final String matchedVia;
  final String matchedTitle;
  final List<Map<String, dynamic>> variants;
  final String kind;
}
