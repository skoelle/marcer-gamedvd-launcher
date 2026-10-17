// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'catalog_controller.dart';
import 'config_locator.dart';
import 'self_updater.dart';
import 'theme.dart';
import 'widgets/card_grid.dart';
import 'widgets/detail_panel.dart';
import 'widgets/entry_list.dart';
import 'widgets/filter_bar.dart';
import 'widgets/folder_tree.dart';
import 'widgets/game_lightbox.dart';
import 'widgets/help_overlay.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/setup_page.dart';

Future<void> main() async {
  final cwd = Directory.current.path;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final searchDirs = configSearchDirs(
    cwd: cwd,
    exeDir: exeDir,
    isMacOS: Platform.isMacOS,
  );
  // Where a new config is written by the first-run setup (portable location
  // next to the executable / .app, CWD as writability fallback).
  final saveDirs = configSaveDirs(
    cwd: cwd,
    exeDir: exeDir,
    isMacOS: Platform.isMacOS,
  );
  final configPath = resolveConfigPath(
    dirs: searchDirs,
    exists: (path) => File(path).existsSync(),
  );
  DesktopConfig? config;
  String? configError;
  if (configPath != null) {
    try {
      // Hatari paths + the bundled config resolve against the executable dir;
      // the bundled config is searched in CWD → exe dir → (macOS) .app parent.
      config = DesktopConfig.load(configPath,
          appDir: exeDir, searchDirs: searchDirs);
    } catch (e) {
      configError = '$configPath: $e';
    }
  }
  // configPath == null && configError == null → no config found: the app
  // opens the first-run setup page instead of an error hint.
  // Remove *.old leftovers from the previous self-update (best effort;
  // runs in every build so a dev build can also clean a release install).
  unawaited(cleanupOldFiles(installTargetDir(
    resolvedExecutable: Platform.resolvedExecutable,
    isMacOS: Platform.isMacOS,
  )));
  // Drop a one-shot update task left behind by an aborted update.
  cleanupUpdateTask();
  // Window: start maximized (`Window.maximized`, default true — user
  // decision 2026-10-15); otherwise the configured size, centered. The
  // configured size is also the restore size under a maximized start.
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final maximized = config?.windowMaximized ?? true;
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: Size(
        (config?.windowWidth ?? 1280).toDouble(),
        (config?.windowHeight ?? 800).toDouble(),
      ),
      center: !maximized,
      title: 'MarcerGameDVDLauncher',
    ),
    () async {
      if (maximized) await windowManager.maximize();
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(MarcerDesktopApp(
    config: config,
    configError: configError,
    configPath: configPath,
    saveDirs: saveDirs,
  ));
  if (maximized) {
    // Windows safeguard: the runner reveals the window on the first frame
    // (win32_window.cpp Show() uses SW_SHOW since the SW_SHOWNORMAL fix) —
    // re-assert the maximize state once after that, just in case a late
    // size event still dropped it. No-op when already maximized (the
    // native Maximize checks the window state first).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      try {
        if (!await windowManager.isMaximized()) {
          await windowManager.maximize();
        }
      } catch (_) {
        // Best effort — never block startup on window state.
      }
    });
  }
}

class MarcerDesktopApp extends StatelessWidget {
  const MarcerDesktopApp({
    super.key,
    this.config,
    this.configError,
    this.configPath,
    this.saveDirs = const [],
  });

  final DesktopConfig? config;
  final String? configError;

  /// Resolved `desktop.config.json` path, used by the settings editor to
  /// save edits back to the same file.
  final String? configPath;

  /// Candidate directories for a first-run config file (see [configSaveDirs]).
  final List<String> saveDirs;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MarcerGameDVDLauncher',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: _AppRoot(
        config: config,
        configError: configError,
        configPath: configPath,
        saveDirs: saveDirs,
      ),
    );
  }
}

/// Owns the live config so the first-run setup can hand a freshly written
/// config to [HomePage] without restarting: no config → [SetupPage], an
/// unreadable config → [_ConfigErrorPage] with a setup shortcut, otherwise
/// straight to the catalog.
class _AppRoot extends StatefulWidget {
  const _AppRoot({
    required this.config,
    required this.configError,
    required this.configPath,
    required this.saveDirs,
  });

  final DesktopConfig? config;
  final String? configError;
  final String? configPath;
  final List<String> saveDirs;

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  DesktopConfig? _config;
  String? _configPath;

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _configPath = widget.configPath;
  }

  void _onConfigured(DesktopConfig config, String path) {
    setState(() {
      _config = config;
      _configPath = path;
    });
  }

  /// Error-page shortcut: modal settings editor for the broken config file.
  Future<void> _openSetupForError() async {
    final edited = await showSettingsDialog(
      context,
      config: DesktopConfig(rootDirectory: ''),
      title: 'Setup',
      subtitle:
          '${_configPath ?? kConfigFileName} — edit and save to fix it',
    );
    if (edited == null || !mounted) return;

    final known = _configPath;
    final path = known ??
        writeFirstWritable(
          widget.saveDirs,
          fileName: kConfigFileName,
          write: edited.save,
        );
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not write desktop.config.json')));
      return;
    }
    try {
      if (known != null) edited.save(known);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not write $known: $e'),
          duration: const Duration(seconds: 5)));
      return;
    }
    _onConfigured(edited, path);
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    if (config != null) {
      return HomePage(config: config, configPath: _configPath ?? '');
    }
    if (widget.configError != null) {
      return _ConfigErrorPage(
        message: widget.configError!,
        onOpenSetup: _openSetupForError,
      );
    }
    return SetupPage(
      saveDirs: widget.saveDirs,
      onConfigured: _onConfigured,
    );
  }
}

class _ConfigErrorPage extends StatelessWidget {
  const _ConfigErrorPage({required this.message, this.onOpenSetup});

  final String message;

  /// When set, a button opens the setup to fix/replace the config file.
  final VoidCallback? onOpenSetup;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                'desktop.config.json error:\n\n$message',
                textAlign: TextAlign.center,
              ),
              if (onOpenSetup != null) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: onOpenSetup,
                  child: const Text('Setup…'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.config, this.configPath = ''});

  final DesktopConfig config;

  /// Resolved config file path the settings editor writes to.
  final String configPath;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late DesktopConfig _config;
  late CatalogController _controller;
  final FocusNode _searchFocus = FocusNode(debugLabel: 'search');

  /// Shared by the grid/list so Escape in the search field can hand focus
  /// back to the center panel.
  final FocusNode _centerFocus = FocusNode(debugLabel: 'center');
  final SelfUpdateController _updater = SelfUpdateController();
  bool _showHelp = false;
  bool _showingLaunchError = false;
  bool _showingDownloadError = false;
  bool _showingUpdateError = false;

  /// Running app version (release builds: stamped from the git tag via
  /// `--build-name`; dev builds: the pubspec version). Shown right-aligned
  /// in the status bar.
  String? _appVersion;

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _controller = CatalogController(_config);
    _controller.addListener(_onControllerChanged);
    _controller.init();
    _updater.addListener(_onUpdateChanged);
    _loadAppVersion();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initSelfUpdate());
  }

  /// Reads the version for the status bar (always — unlike the self-update
  /// check, which only runs in release builds).
  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
    } catch (_) {
      // No version shown — never block the UI on package info.
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _updater.removeListener(_onUpdateChanged);
    _searchFocus.dispose();
    _centerFocus.dispose();
    _updater.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Silent update check after startup (release builds only; the version
  /// is stamped from the git tag via `--build-name` in the workflow).
  Future<void> _initSelfUpdate() async {
    if (!SelfUpdateController.enabled) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _updater.currentVersion = info.version;
    } catch (_) {
      return;
    }
    await _updater.check();
  }

  /// Surfaces failed update installs as a modal, once per error.
  void _onUpdateChanged() {
    if (_updater.phase != UpdatePhase.failed ||
        _updater.error == null ||
        _showingUpdateError ||
        !mounted) {
      return;
    }
    _showingUpdateError = true;
    final err = _updater.error!;
    final logPath = _updater.logPath;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Update failed'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(err),
              const SizedBox(height: 12),
              SelectableText('Log: $logPath',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _updater.clearError();
                Navigator.of(context).pop();
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
      _showingUpdateError = false;
    });
  }

  /// Surfaces launch errors (SPEC.md E3/E4/E7) and download failures as a
  /// modal, once per error.
  void _onControllerChanged() {
    if (!mounted) return;
    final err = _controller.launchError;
    if (err != null && !_showingLaunchError) {
      _showingLaunchError = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Cannot launch'),
            content: Text(err),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        _controller.clearLaunchError();
        _showingLaunchError = false;
      });
    }
    final derr = _controller.downloadError;
    if (derr != null && !_showingDownloadError) {
      _showingDownloadError = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Download failed'),
            content: Text(derr),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        _controller.clearDownloadError();
        _showingDownloadError = false;
      });
    }
  }

  /// Opens the settings editor, persists the edited paths back to
  /// `desktop.config.json` and reloads the catalog in place so the new
  /// paths take effect without restarting the app.
  Future<void> _openSettings() async {
    final edited = await showSettingsDialog(context, config: _config);
    if (edited == null || !mounted) return;
    try {
      edited.save(widget.configPath);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Could not save desktop.config.json: $e'),
            duration: const Duration(seconds: 5)),
      );
      return;
    }
    _applyConfig(edited);
  }

  /// Rebuilds the catalog controller with [cfg] (overlay, screenshots,
  /// gameinfo and favorites are all re-read by `init`).
  void _applyConfig(DesktopConfig cfg) {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    setState(() {
      _config = cfg;
      _controller = CatalogController(cfg);
    });
    _controller.addListener(_onControllerChanged);
    _controller.init();
  }

  void _toggleHelp() {
    if (_showHelp) return; // modal; any key or a barrier tap closes it
    setState(() => _showHelp = true);
    HelpOverlay.show(context, () {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    }).whenComplete(() {
      // Resets on every dismissal path (key, barrier tap), so `?` works
      // again after either one.
      if (mounted) setState(() => _showHelp = false);
    });
  }

  void _openLightbox(int variant, int image) {
    final c = _controller;
    if (!c.catalogMode) {
      final e = c.selectedEntry;
      if (e == null || e.kind != EntryKind.zip) return;
    } else if (c.selectedCard == null) {
      return;
    }
    GameLightbox.show(context, c, variant: variant, image: image);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        if (!c.ready) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(c.progress, style: const TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          body: Column(
            children: [
              FilterBar(
                controller: c,
                searchFocus: _searchFocus,
                onExitSearch: () => _centerFocus.requestFocus(),
                onOpenSettings: _openSettings,
                updater: _updater,
              ),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!c.catalogMode) ...[
                      SizedBox(width: 260, child: FolderTree(controller: c)),
                      const VerticalDivider(width: 1),
                    ],
                    Expanded(
                      child: c.gridMode
                          ? CenterGrid(
                              controller: c,
                              onToggleHelp: _toggleHelp,
                              onOpenLightbox: _openLightbox,
                              onFocusSearch: () => _searchFocus.requestFocus(),
                              focusNode: _centerFocus,
                            )
                          : EntryList(
                              controller: c,
                              onToggleHelp: _toggleHelp,
                              onOpenLightbox: _openLightbox,
                              onFocusSearch: () => _searchFocus.requestFocus(),
                              focusNode: _centerFocus,
                            ),
                    ),
                    const VerticalDivider(width: 1),
                    SizedBox(
                        width: 420,
                        child: DetailPanel(
                          controller: c,
                          onOpenLightbox: _openLightbox,
                        )),
                  ],
                ),
              ),
              const Divider(height: 1),
              _StatusBar(controller: c, version: _appVersion),
            ],
          ),
        );
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller, this.version});

  final CatalogController controller;

  /// Running app version, right-aligned in the bar (`null` while the
  /// async `PackageInfo` read has not finished / failed).
  final String? version;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final messages = <String>[
      if (!c.catalogMode) c.displayPath,
      c.countText,
      ...c.statusLine,
    ];
    final notices = [...c.notices];
    final favErr = c.favorites?.lastSaveError;
    if (favErr != null) notices.add('favorites save failed: $favErr');
    return Container(
      color: const Color(0xFF1B1B1B),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          if (c.launching) ...[
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 6),
            const Text('Hatari is running…',
                style: TextStyle(fontSize: 11, color: Colors.lightGreen)),
            const SizedBox(width: 16),
          ],
          if (c.downloading) ...[
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 6),
            Text('Downloading… ${c.downloadProgress}',
                style: const TextStyle(
                    fontSize: 11, color: Colors.orangeAccent)),
            const SizedBox(width: 16),
          ],
          Text(messages.join('  ·  '),
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          if (notices.isNotEmpty) ...[
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                notices.join('  |  '),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.orange),
              ),
            ),
          ] else
            const Spacer(),
          if (version != null) ...[
            const SizedBox(width: 16),
            Text(
              'v$version',
              style: TextStyle(
                  fontSize: 11, color: Colors.grey.withValues(alpha: 0.7)),
            ),
          ],
        ],
      ),
    );
  }
}
