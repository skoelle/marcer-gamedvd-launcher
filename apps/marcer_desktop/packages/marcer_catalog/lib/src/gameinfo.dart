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
  GameInfoIndex._(this._byLetterFolder);

  /// Loads all `games-<kind>.json` files found in [dataDir] (may be empty).
  factory GameInfoIndex.load(String dataDir) {
    final byLetterFolder = <String, GameInfo>{};
    final dir = Directory(dataDir);
    if (!dir.existsSync()) return GameInfoIndex._(byLetterFolder);
    for (final kind in ['cracked', 'pd', 'utils']) {
      final file = File('$dataDir/games-$kind.json');
      if (!file.existsSync()) continue;
      final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final games = (map['games'] as List<dynamic>?) ?? const [];
      for (final g in games) {
        final game = GameInfo.fromJson(g as Map<String, dynamic>, kind);
        final key = '${game.letter.toLowerCase()}|${game.folder.toLowerCase()}';
        byLetterFolder[key] ??= game;
      }
    }
    return GameInfoIndex._(byLetterFolder);
  }

  final Map<String, GameInfo> _byLetterFolder;

  int get length => _byLetterFolder.length;

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
