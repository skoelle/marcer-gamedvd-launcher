// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../config_locator.dart';
import 'settings_form.dart';

/// First-run setup shown when no `desktop.config.json` was found: the user
/// fills in the paths (validated live by [SettingsForm]) and saves, which
/// creates the file and hands the config + path back via [onConfigured] so
/// the app can continue straight into the catalog UI.
///
/// When [configPath] is set (recovering from an unreadable/broken config) that
/// exact file is overwritten; otherwise the config is written to the first
/// writable directory of [saveDirs].
class SetupPage extends StatefulWidget {
  const SetupPage({
    super.key,
    required this.onConfigured,
    required this.saveDirs,
    this.searchDirs = const [],
    this.initial,
    this.configPath,
  });

  final void Function(DesktopConfig config, String path) onConfigured;

  /// Directories tried (in order) for the new config file.
  final List<String> saveDirs;

  /// Directories searched for an existing `desktop.config.json` (shown so the
  /// user can also drop the file there by hand).
  final List<String> searchDirs;

  /// Prefilled values; defaults to an empty config.
  final DesktopConfig? initial;

  /// Known target file to overwrite, or `null` to create a new file under
  /// [saveDirs].
  final String? configPath;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  DesktopConfig? _latest;
  bool _valid = false;
  String? _error;

  /// True while a download/extraction runs in the form (blocks Save/Exit so
  /// the running transfer is not interrupted).
  bool _busy = false;

  void _save() {
    final cfg = _latest;
    if (cfg == null || !_valid || _busy) return;

    final known = widget.configPath;
    if (known != null) {
      try {
        cfg.save(known);
      } catch (e) {
        setState(() => _error = 'Could not write $known: $e');
        return;
      }
      widget.onConfigured(cfg, known);
      return;
    }

    final path = writeFirstWritable(
      widget.saveDirs,
      fileName: kConfigFileName,
      write: cfg.save,
    );
    if (path == null) {
      setState(() => _error =
          'Could not write $kConfigFileName to any of:\n'
          '${widget.saveDirs.map((d) => '  $d').join('\n')}');
      return;
    }
    widget.onConfigured(cfg, path);
  }

  @override
  Widget build(BuildContext context) {
    final knownTarget = widget.configPath;
    final saveCandidates = widget.saveDirs
        .map((d) => '$d${Platform.pathSeparator}$kConfigFileName')
        .join('  ·  ');
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Welcome',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'No desktop.config.json was found — set up your paths below '
                  'and save to get started.',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  knownTarget != null
                      ? 'Saves to: $knownTarget'
                      : 'Saves to the first writable of: $saveCandidates',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                if (widget.searchDirs.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Searched in: ${widget.searchDirs.join('  ·  ')}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 20),
                SettingsForm(
                  initial: widget.initial ?? DesktopConfig(rootDirectory: ''),
                  onChanged: (config, valid) {
                    _latest = config;
                    _valid = valid;
                    if (_error != null) _error = null;
                    setState(() {});
                  },
                  onBusyChanged: (busy) {
                    if (mounted) setState(() => _busy = busy);
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 4),
                  Text(_error!,
                      style: const TextStyle(
                          color: Colors.redAccent, fontSize: 12)),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : () => exit(0),
                      child: const Text('Exit'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: (_valid && !_busy) ? _save : null,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
