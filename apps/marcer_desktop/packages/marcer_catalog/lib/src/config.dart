// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

/// Bundled Hatari config shipped next to the executable (SPEC.md §12.1):
/// used automatically when `Hatari.ConfigFile` is empty.
const String kBundledHatariConfig = 'MarcerGameDvd-Hatari.cfg';

/// Default remote directory holding the catalog asset archives
/// (`screenshots-<timestamp>.zip` / `gameinfo-<timestamp>.zip`) on the FTP
/// server (user decision 2026-10-17). Overridable via `Ftp.AssetsRemote`.
const String kDefaultFtpAssetsRemote = '/Uploads/MarcerGameDVDLauncher-assets/';

/// Configuration model for `desktop.config.json` (see PLAN.md §3).
class DesktopConfig {
  DesktopConfig({
    required this.rootDirectory,
    this.patchDirectory = '',
    this.screenshotDirectory = '',
    this.gameinfoDirectory = '',
    this.atariLegendDirectory = '',
    this.hatariExecutable = '',
    this.hatariConfigFile = '',
    this.hatariArgsTemplate = r'-c "{cfg}" --disk-a "{zip}"',
    this.falconTosFile = 'TOS404.IMG',
    this.falconMemsize = '14',
    this.falconMonitor = 'rgb',
    this.falconDsp = 'emu',
    this.falconCpuClock = '16',
    this.falconFpu = 'none',
    this.falconExtraArgs = '',
    this.ftpHost = '',
    this.ftpUser = '',
    this.ftpPassword = '',
    this.ftpRemoteBase = '/GameDVD/',
    this.ftpAssetsRemote = kDefaultFtpAssetsRemote,
    this.showCandidates = true,
    this.defaultStatus = 'with_screenshot',
    this.appDir = '',
    this.hatariWorkingDirectory = '',
    this.searchDirs = const [],
    this.windowWidth = 1280,
    this.windowHeight = 800,
    this.windowMaximized = true,
  });

  final String rootDirectory;
  final String patchDirectory;
  final String screenshotDirectory;
  final String gameinfoDirectory;

  /// Directory holding the compact AtariLegend runtime cache
  /// (`atarilegend.json`), built by the settings "Download AtariLegend data"
  /// button from the weekly `.sql.gz` dump. Optional; no implicit fallback.
  final String atariLegendDirectory;

  final String hatariExecutable;
  final String hatariConfigFile;
  final String hatariArgsTemplate;

  /// Falcon 030 launch settings (the `Falcon` config block). Falcon is a
  /// completely different machine: it never uses the ST `Hatari.ConfigFile`/
  /// [hatariArgsTemplate] but a dedicated command line (`--machine falcon`,
  /// its own TOS 4.04, GEMDOS HD autostart). Defaults match the code
  /// variants; the block is optional.
  final String falconTosFile;
  final String falconMemsize;
  final String falconMonitor;
  final String falconDsp;
  final String falconCpuClock;
  final String falconFpu;

  /// Extra raw command-line arguments appended to every Falcon launch
  /// (split like [hatariArgsTemplate]); empty by default.
  final String falconExtraArgs;

  /// FTP download of missing game folders (DetailPanel "Download missing").
  /// Plain FTP; [ftpHost] is `host` or `host:port` (the port defaults to 21,
  /// resolved by [ftpHostName]/[ftpPort]; user decision 2026-10-17). The
  /// feature is considered unconfigured while the host part is empty
  /// ([ftpConfigured]). [ftpRemoteBase] is the remote directory prefix
  /// (default `/GameDVD/`); empty = the FTP login directory is the catalog
  /// root. The password is stored in plaintext in the config file.
  final String ftpHost;
  final String ftpUser;
  final String ftpPassword;
  final String ftpRemoteBase;

  /// Remote directory holding the catalog asset archives
  /// (`screenshots-*.zip`, `gameinfo-*.zip`), default
  /// [kDefaultFtpAssetsRemote]. Downloaded by the setup/settings
  /// "Download from FTP" buttons into [screenshotDirectory] /
  /// [gameinfoDirectory].
  final String ftpAssetsRemote;

  /// Application directory (the executable's directory): base for resolving
  /// relative Hatari paths and the bundled config (SPEC.md R10).
  final String appDir;

  /// Runtime-only working directory Hatari is started in (and where the
  /// bundled config's `TOS.IMG` is expected). Empty falls back to [appDir]
  /// (or the CWD). On macOS the app sets this to the per-user data directory,
  /// since downloaded artifacts live outside the `.app` bundle.
  final String hatariWorkingDirectory;

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
    final falcon = (map['Falcon'] as Map<String, dynamic>?) ?? const {};
    final window = (map['Window'] as Map<String, dynamic>?) ?? const {};
    final ftp = (map['Ftp'] as Map<String, dynamic>?) ?? const {};
    final resolvedAppDir = appDir.isNotEmpty
        ? appDir
        : File(configPath).parent.path;
    return DesktopConfig(
      rootDirectory: (map['RootDirectory'] ?? '') as String,
      patchDirectory: (map['PatchDirectory'] ?? '') as String,
      screenshotDirectory: (map['ScreenshotDirectory'] ?? '') as String,
      gameinfoDirectory: (map['GameinfoDirectory'] ?? '') as String,
      atariLegendDirectory: (map['AtariLegendDirectory'] ?? '') as String,
      hatariExecutable: (hatari['Executable'] ?? '') as String,
      hatariConfigFile: (hatari['ConfigFile'] ?? '') as String,
      hatariArgsTemplate:
          (hatari['ArgsTemplate'] ?? r'-c "{cfg}" --disk-a "{zip}"') as String,
      falconTosFile: (falcon['TosFile'] ?? 'TOS404.IMG') as String,
      falconMemsize: (falcon['Memsize'] ?? '14') as String,
      falconMonitor: (falcon['Monitor'] ?? 'rgb') as String,
      falconDsp: (falcon['Dsp'] ?? 'emu') as String,
      falconCpuClock: (falcon['CpuClock'] ?? '16') as String,
      falconFpu: (falcon['Fpu'] ?? 'none') as String,
      falconExtraArgs: (falcon['ExtraArgs'] ?? '') as String,
      ftpHost: (ftp['Host'] ?? '') as String,
      ftpUser: (ftp['User'] ?? '') as String,
      ftpPassword: (ftp['Password'] ?? '') as String,
      ftpRemoteBase: (ftp['RemoteBase'] ?? '/GameDVD/') as String,
      ftpAssetsRemote:
          (ftp['AssetsRemote'] ?? kDefaultFtpAssetsRemote) as String,
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
    String? atariLegendDirectory,
    String? hatariExecutable,
    String? hatariConfigFile,
    String? hatariArgsTemplate,
    String? falconTosFile,
    String? falconMemsize,
    String? falconMonitor,
    String? falconDsp,
    String? falconCpuClock,
    String? falconFpu,
    String? falconExtraArgs,
    String? ftpHost,
    String? ftpUser,
    String? ftpPassword,
    String? ftpRemoteBase,
    String? ftpAssetsRemote,
    bool? showCandidates,
    String? defaultStatus,
    String? appDir,
    String? hatariWorkingDirectory,
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
      atariLegendDirectory:
          atariLegendDirectory ?? this.atariLegendDirectory,
      hatariExecutable: hatariExecutable ?? this.hatariExecutable,
      hatariConfigFile: hatariConfigFile ?? this.hatariConfigFile,
      hatariArgsTemplate: hatariArgsTemplate ?? this.hatariArgsTemplate,
      falconTosFile: falconTosFile ?? this.falconTosFile,
      falconMemsize: falconMemsize ?? this.falconMemsize,
      falconMonitor: falconMonitor ?? this.falconMonitor,
      falconDsp: falconDsp ?? this.falconDsp,
      falconCpuClock: falconCpuClock ?? this.falconCpuClock,
      falconFpu: falconFpu ?? this.falconFpu,
      falconExtraArgs: falconExtraArgs ?? this.falconExtraArgs,
      ftpHost: ftpHost ?? this.ftpHost,
      ftpUser: ftpUser ?? this.ftpUser,
      ftpPassword: ftpPassword ?? this.ftpPassword,
      ftpRemoteBase: ftpRemoteBase ?? this.ftpRemoteBase,
      ftpAssetsRemote: ftpAssetsRemote ?? this.ftpAssetsRemote,
      showCandidates: showCandidates ?? this.showCandidates,
      defaultStatus: defaultStatus ?? this.defaultStatus,
      appDir: appDir ?? this.appDir,
      hatariWorkingDirectory:
          hatariWorkingDirectory ?? this.hatariWorkingDirectory,
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
        'AtariLegendDirectory': atariLegendDirectory,
        'Hatari': {
          'Executable': hatariExecutable,
          'ConfigFile': hatariConfigFile,
          'ArgsTemplate': hatariArgsTemplate,
        },
        'Falcon': {
          'TosFile': falconTosFile,
          'Memsize': falconMemsize,
          'Monitor': falconMonitor,
          'Dsp': falconDsp,
          'CpuClock': falconCpuClock,
          'Fpu': falconFpu,
          'ExtraArgs': falconExtraArgs,
        },
        'Ftp': {
          'Host': ftpHost,
          'User': ftpUser,
          'Password': ftpPassword,
          'RemoteBase': ftpRemoteBase,
          'AssetsRemote': ftpAssetsRemote,
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

  /// True when the FTP download of missing game folders is configured (only
  /// the host is required; user/password may be empty for anonymous-ish
  /// setups).
  bool get ftpConfigured => ftpHostName.isNotEmpty;

  /// FTP host without the optional `:port` suffix. Supports a bracketed IPv6
  /// literal (`[::1]` / `[::1]:2121`, brackets stripped for the socket) and a
  /// plain `host` / `host:port`; a trailing/invalid port part is ignored.
  String get ftpHostName {
    final raw = ftpHost.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('[')) {
      final end = raw.indexOf(']');
      if (end > 0) return raw.substring(1, end);
    }
    final colon = raw.lastIndexOf(':');
    if (colon <= 0) return colon == 0 ? '' : raw;
    final portPart = raw.substring(colon + 1);
    if (portPart.isEmpty) return raw.substring(0, colon);
    return int.tryParse(portPart) == null ? raw : raw.substring(0, colon);
  }

  /// FTP port parsed from the optional `host:port` form; defaults to the
  /// standard port 21 when absent or invalid.
  int get ftpPort {
    final raw = ftpHost.trim();
    if (raw.isEmpty) return 21;
    final colon = raw.lastIndexOf(':');
    if (colon < 0 || colon == raw.length - 1) return 21;
    // Skip the colons of a bracketed IPv6 literal (`[::1]`, `[::1]:21`).
    if (raw.startsWith('[') && colon < raw.indexOf(']')) return 21;
    return int.tryParse(raw.substring(colon + 1)) ?? 21;
  }

  /// Directory a "download missing" run writes into: the [patchDirectory] when
  /// set, otherwise the [rootDirectory] (user decision 2026-10-17).
  String get downloadTargetDirectory =>
      patchDirectory.trim().isNotEmpty ? patchDirectory : rootDirectory;

  /// The configured gameinfo directory (or empty when not set). There is no
  /// implicit fallback: gameinfo data must be fetched explicitly (user
  /// decision 2026-10-17, see "Download from FTP" in the setup/settings form).
  String resolveGameinfoDirectory() => gameinfoDirectory;

  /// The configured AtariLegend directory (or empty when not set). No implicit
  /// fallback: the cache is built explicitly via the settings download button.
  String resolveAtariLegendDirectory() => atariLegendDirectory;

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

  /// Absolute path of the Falcon TOS image (`Falcon.TosFile`, default
  /// `TOS404.IMG`) in the Hatari working directory (or [appDir]).
  String resolveFalconTosPath() {
    final base =
        hatariWorkingDirectory.isNotEmpty ? hatariWorkingDirectory : appDir;
    return base.isEmpty ? falconTosFile : '$base/$falconTosFile';
  }

  /// True when the Falcon TOS image exists (see [resolveFalconTosPath]).
  bool falconTosInstalled() => File(resolveFalconTosPath()).existsSync();

  String _resolveAgainstAppDir(String path) {
    if (path.trim().isEmpty) return '';
    final p = path.trim();
    if (p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p)) return p;
    return appDir.isEmpty ? p : '$appDir/$p';
  }
}
