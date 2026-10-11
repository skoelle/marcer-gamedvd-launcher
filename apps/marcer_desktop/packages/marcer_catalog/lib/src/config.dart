// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

/// Configuration model for `desktop.config.json` (see PLAN.md §3).
class DesktopConfig {
  DesktopConfig({
    required this.rootDirectory,
    this.patchDirectory = '',
    this.outDirectory = '',
    this.dataDirectory = '',
    this.hatariExecutable = '',
    this.hatariConfigFile = '',
    this.hatariArgsTemplate = r'-c "{cfg}" --disk-a "{zip}"',
    this.showCandidates = true,
    this.defaultStatus = 'with_screenshot',
    this.windowWidth = 1280,
    this.windowHeight = 800,
  });

  final String rootDirectory;
  final String patchDirectory;
  final String outDirectory;
  final String dataDirectory;
  final String hatariExecutable;
  final String hatariConfigFile;
  final String hatariArgsTemplate;

  /// Gallery `show_candidates` config: candidate thumb strip on grid cards.
  final bool showCandidates;

  /// Gallery `default_status` config: initial status preset of the status
  /// filter (used for the factory state, `clear` and section switches).
  final String defaultStatus;

  final int windowWidth;
  final int windowHeight;

  /// Loads and parses `desktop.config.json` from [configPath].
  ///
  /// Throws [FormatException] / [FileSystemException] on unreadable or invalid
  /// files; callers decide how to surface the error (PLAN.md: clear message).
  static DesktopConfig load(String configPath) {
    final raw = File(configPath).readAsStringSync();
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final hatari = (map['Hatari'] as Map<String, dynamic>?) ?? const {};
    final window = (map['Window'] as Map<String, dynamic>?) ?? const {};
    return DesktopConfig(
      rootDirectory: (map['RootDirectory'] ?? '') as String,
      patchDirectory: (map['PatchDirectory'] ?? '') as String,
      outDirectory: (map['OutDirectory'] ?? '') as String,
      dataDirectory: (map['DataDirectory'] ?? '') as String,
      hatariExecutable: (hatari['Executable'] ?? '') as String,
      hatariConfigFile: (hatari['ConfigFile'] ?? '') as String,
      hatariArgsTemplate:
          (hatari['ArgsTemplate'] ?? r'-c "{cfg}" --disk-a "{zip}"') as String,
      showCandidates: (map['ShowCandidates'] ?? true) as bool,
      defaultStatus: (map['DefaultStatus'] ?? 'with_screenshot') as String,
      windowWidth: (window['width'] as int?) ?? 1280,
      windowHeight: (window['height'] as int?) ?? 800,
    );
  }

  /// Default gameinfo directory convention `<PatchDirectory>/../Data`
  /// (ANALYSIS-game-data.md §5.5) when [dataDirectory] is empty.
  String resolveDataDirectory() {
    if (dataDirectory.isNotEmpty) return dataDirectory;
    if (patchDirectory.isEmpty) return '';
    final dir = Directory('$patchDirectory/../Data');
    try {
      return dir.resolveSymbolicLinksSync();
    } catch (_) {
      return dir.path;
    }
  }
}
