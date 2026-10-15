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

Future<void> main() async {
  final searchDirs = configSearchDirs(
    cwd: Directory.current.path,
    exeDir: File(Platform.resolvedExecutable).parent.path,
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
      final exeDir = searchDirs.length > 1 ? searchDirs[1] : searchDirs.first;
      config = DesktopConfig.load(configPath,
          appDir: exeDir, searchDirs: searchDirs);
    } catch (e) {
      configError = '$configPath: $e';
    }
  } else {
    configError = 'desktop.config.json not found. Searched:\n'
        '${searchDirs.map((d) => '  $d').join('\n')}\n\n'
        'Copy desktop.config.example.json there and rename it to '
        'desktop.config.json.';
  }
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
  runApp(MarcerDesktopApp(config: config, configError: configError));
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
  const MarcerDesktopApp({super.key, this.config, this.configError});

  final DesktopConfig? config;
  final String? configError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MarcerGameDVDLauncher',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: configError != null
          ? _ConfigErrorPage(message: configError!)
          : HomePage(config: config!),
    );
  }
}

class _ConfigErrorPage extends StatelessWidget {
  const _ConfigErrorPage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(
            'desktop.config.json error:\n\n$message',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.config});

  final DesktopConfig config;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final CatalogController _controller;
  final FocusNode _searchFocus = FocusNode(debugLabel: 'search');

  /// Shared by the grid/list so Escape in the search field can hand focus
  /// back to the center panel.
  final FocusNode _centerFocus = FocusNode(debugLabel: 'center');
  final SelfUpdateController _updater = SelfUpdateController();
  bool _showHelp = false;
  bool _showingLaunchError = false;
  bool _showingUpdateError = false;

  /// Running app version (release builds: stamped from the git tag via
  /// `--build-name`; dev builds: the pubspec version). Shown right-aligned
  /// in the status bar.
  String? _appVersion;

  @override
  void initState() {
    super.initState();
    _controller = CatalogController(widget.config);
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

  /// Surfaces launch errors (SPEC.md E3/E4/E7) as a modal, once per error.
  void _onControllerChanged() {
    final err = _controller.launchError;
    if (err == null || _showingLaunchError || !mounted) return;
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
