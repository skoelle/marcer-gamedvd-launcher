// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

/// Bundled Hatari config shipped next to the executable (SPEC.md §12.1):
/// used automatically when `Hatari.ConfigFile` is empty.
const String kBundledHatariConfig = 'MarcerGameDvd-Hatari.cfg';

/// Configuration model for `desktop.config.json` (see PLAN.md §3).
class DesktopConfig {
  DesktopConfig({
    required this.rootDirectory,
    this.patchDirectory = '',
    this.screenshotDirectory = '',
    this.gameinfoDirectory = '',
    this.hatariExecutable = '',
    this.hatariConfigFile = '',
    this.hatariArgsTemplate = r'-c "{cfg}" --disk-a "{zip}"',
    this.showCandidates = true,
    this.defaultStatus = 'with_screenshot',
    this.appDir = '',
    this.searchDirs = const [],
    this.windowWidth = 1280,
    this.windowHeight = 800,
    this.windowMaximized = true,
  });

  final String rootDirectory;
  final String patchDirectory;
  final String screenshotDirectory;
  final String gameinfoDirectory;
  final String hatariExecutable;
  final String hatariConfigFile;
  final String hatariArgsTemplate;

  /// Application directory (the executable's directory): base for resolving
  /// relative Hatari paths and the bundled config (SPEC.md R10).
  final String appDir;

  /// Directories searched for the bundled Hatari config (in order) when
  /// `Hatari.ConfigFile` is empty; typically CWD → exe dir → macOS `.app`
  /// parent, same as `desktop.config.json` (PLAN.md §3).
  final List<String> searchDirs;

  /// Gallery `show_candidates` config: candidate thumb strip on grid cards.
  final bool showCandidates;

  /// Gallery `default_status` config: initial status preset of the status
  /// filter (used for the factory state, `clear` and section switches).
  final String defaultStatus;

  /// Initial window size (`Window.width`/`Window.height`) — used as the
  /// startup size and as the restore size under [windowMaximized].
  final int windowWidth;
  final int windowHeight;

  /// `Window.maximized` (default true): start the window maximized;
  /// `false` starts it at [windowWidth]×[windowHeight], centered.
  final bool windowMaximized;

  /// Loads and parses `desktop.config.json` from [configPath].
  ///
  /// [appDir] is the application (executable) directory used to resolve
  /// relative Hatari paths and the bundled config; defaults to the config
  /// file's directory.
  ///
  /// Throws [FormatException] / [FileSystemException] on unreadable or invalid
  /// files; callers decide how to surface the error (PLAN.md: clear message).
  static DesktopConfig load(String configPath,
      {String appDir = '', List<String> searchDirs = const []}) {
    final raw = File(configPath).readAsStringSync();
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final hatari = (map['Hatari'] as Map<String, dynamic>?) ?? const {};
    final window = (map['Window'] as Map<String, dynamic>?) ?? const {};
    final resolvedAppDir = appDir.isNotEmpty
        ? appDir
        : File(configPath).parent.path;
    return DesktopConfig(
      rootDirectory: (map['RootDirectory'] ?? '') as String,
      patchDirectory: (map['PatchDirectory'] ?? '') as String,
      screenshotDirectory: (map['ScreenshotDirectory'] ?? '') as String,
      gameinfoDirectory: (map['GameinfoDirectory'] ?? '') as String,
      hatariExecutable: (hatari['Executable'] ?? '') as String,
      hatariConfigFile: (hatari['ConfigFile'] ?? '') as String,
      hatariArgsTemplate:
          (hatari['ArgsTemplate'] ?? r'-c "{cfg}" --disk-a "{zip}"') as String,
      showCandidates: (map['ShowCandidates'] ?? true) as bool,
      defaultStatus: (map['DefaultStatus'] ?? 'with_screenshot') as String,
      appDir: resolvedAppDir,
      searchDirs: searchDirs,
      windowWidth: (window['width'] as int?) ?? 1280,
      windowHeight: (window['height'] as int?) ?? 800,
      windowMaximized: (window['maximized'] as bool?) ?? true,
    );
  }

  /// Returns a copy with the given fields replaced (used by the in-app
  /// settings editor to build an edited config while keeping the fields it
  /// does not expose, e.g. window size, `ShowCandidates`, `DefaultStatus`).
  DesktopConfig copyWith({
    String? rootDirectory,
    String? patchDirectory,
    String? screenshotDirectory,
    String? gameinfoDirectory,
    String? hatariExecutable,
    String? hatariConfigFile,
    String? hatariArgsTemplate,
    bool? showCandidates,
    String? defaultStatus,
    String? appDir,
    List<String>? searchDirs,
    int? windowWidth,
    int? windowHeight,
    bool? windowMaximized,
  }) {
    return DesktopConfig(
      rootDirectory: rootDirectory ?? this.rootDirectory,
      patchDirectory: patchDirectory ?? this.patchDirectory,
      screenshotDirectory: screenshotDirectory ?? this.screenshotDirectory,
      gameinfoDirectory: gameinfoDirectory ?? this.gameinfoDirectory,
      hatariExecutable: hatariExecutable ?? this.hatariExecutable,
      hatariConfigFile: hatariConfigFile ?? this.hatariConfigFile,
      hatariArgsTemplate: hatariArgsTemplate ?? this.hatariArgsTemplate,
      showCandidates: showCandidates ?? this.showCandidates,
      defaultStatus: defaultStatus ?? this.defaultStatus,
      appDir: appDir ?? this.appDir,
      searchDirs: searchDirs ?? this.searchDirs,
      windowWidth: windowWidth ?? this.windowWidth,
      windowHeight: windowHeight ?? this.windowHeight,
      windowMaximized: windowMaximized ?? this.windowMaximized,
    );
  }

  /// Serializes the persisted schema of `desktop.config.json` (PLAN.md §3).
  /// Runtime-only fields ([appDir], [searchDirs]) are not written.
  Map<String, dynamic> toJson() => {
        'RootDirectory': rootDirectory,
        'PatchDirectory': patchDirectory,
        'ScreenshotDirectory': screenshotDirectory,
        'GameinfoDirectory': gameinfoDirectory,
        'Hatari': {
          'Executable': hatariExecutable,
          'ConfigFile': hatariConfigFile,
          'ArgsTemplate': hatariArgsTemplate,
        },
        'ShowCandidates': showCandidates,
        'DefaultStatus': defaultStatus,
        'Window': {
          'width': windowWidth,
          'height': windowHeight,
          'maximized': windowMaximized,
        },
      };

  /// Writes this config as pretty-printed JSON (with a trailing newline) to
  /// [path]. Used by the in-app settings editor (see `settings_dialog.dart`).
  void save(String path) {
    final text = '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';
    File(path).writeAsStringSync(text);
  }

  /// Default gameinfo directory convention `<PatchDirectory>/../Data`
  /// (ANALYSIS-game-data.md §5.5) when [gameinfoDirectory] is empty.
  String resolveGameinfoDirectory() {
    if (gameinfoDirectory.isNotEmpty) return gameinfoDirectory;
    if (patchDirectory.isEmpty) return '';
    final dir = Directory('$patchDirectory/../Data');
    try {
      return dir.resolveSymbolicLinksSync();
    } catch (_) {
      return dir.path;
    }
  }

  /// Absolute Hatari executable (`Hatari.Executable`), resolved against
  /// [appDir] when relative (SPEC.md R10); empty when not configured.
  String resolveHatariExecutable() =>
      _resolveAgainstAppDir(hatariExecutable);

  /// Absolute Hatari config file: `Hatari.ConfigFile` when set, otherwise the
  /// bundled [kBundledHatariConfig] found in [searchDirs] (falling back to
  /// next to the executable; SPEC.md §12.1).
  String resolveHatariConfigFile() {
    if (hatariConfigFile.trim().isNotEmpty) {
      return _resolveAgainstAppDir(hatariConfigFile);
    }
    for (final dir in searchDirs) {
      final candidate = '$dir/$kBundledHatariConfig';
      if (File(candidate).existsSync()) return candidate;
    }
    if (appDir.isEmpty) return kBundledHatariConfig;
    return '$appDir/$kBundledHatariConfig';
  }

  String _resolveAgainstAppDir(String path) {
    if (path.trim().isEmpty) return '';
    final p = path.trim();
    if (p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p)) return p;
    return appDir.isEmpty ? p : '$appDir/$p';
  }
}
