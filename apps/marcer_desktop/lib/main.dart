// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import 'catalog_controller.dart';
import 'config_locator.dart';
import 'theme.dart';
import 'widgets/card_grid.dart';
import 'widgets/detail_panel.dart';
import 'widgets/entry_list.dart';
import 'widgets/filter_bar.dart';
import 'widgets/folder_tree.dart';
import 'widgets/game_lightbox.dart';
import 'widgets/help_overlay.dart';

void main() {
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
      config = DesktopConfig.load(configPath);
    } catch (e) {
      configError = '$configPath: $e';
    }
  } else {
    configError = 'desktop.config.json not found. Searched:\n'
        '${searchDirs.map((d) => '  $d').join('\n')}\n\n'
        'Copy desktop.config.example.json there and rename it to '
        'desktop.config.json.';
  }
  runApp(MarcerDesktopApp(config: config, configError: configError));
}

class MarcerDesktopApp extends StatelessWidget {
  const MarcerDesktopApp({super.key, this.config, this.configError});

  final DesktopConfig? config;
  final String? configError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Marcer GameDVD',
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
  bool _showHelp = false;

  @override
  void initState() {
    super.initState();
    _controller = CatalogController(widget.config);
    _controller.init();
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _toggleHelp() {
    if (_showHelp) {
      setState(() => _showHelp = false);
    } else {
      HelpOverlay.show(context, () {
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        setState(() => _showHelp = false);
      });
      setState(() => _showHelp = true);
    }
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
              FilterBar(controller: c, searchFocus: _searchFocus),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 260, child: FolderTree(controller: c)),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: c.gridMode
                          ? CenterGrid(
                              controller: c,
                              onToggleHelp: _toggleHelp,
                              onOpenLightbox: _openLightbox,
                              onFocusSearch: () => _searchFocus.requestFocus(),
                            )
                          : EntryList(
                              controller: c,
                              onToggleHelp: _toggleHelp,
                              onOpenLightbox: _openLightbox,
                              onFocusSearch: () => _searchFocus.requestFocus(),
                            ),
                    ),
                    const VerticalDivider(width: 1),
                    SizedBox(width: 420, child: DetailPanel(controller: c)),
                  ],
                ),
              ),
              const Divider(height: 1),
              _StatusBar(controller: c),
            ],
          ),
        );
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller});

  final CatalogController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final messages = <String>[
      if (!c.catalogMode) c.displayPath,
      c.countText,
      if (c.statusSummary != null) c.statusSummary!,
    ];
    final notices = [...c.notices];
    final favErr = c.favorites?.lastSaveError;
    if (favErr != null) notices.add('favorites save failed: $favErr');
    return Container(
      color: const Color(0xFF1B1B1B),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
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
        ],
      ),
    );
  }
}
