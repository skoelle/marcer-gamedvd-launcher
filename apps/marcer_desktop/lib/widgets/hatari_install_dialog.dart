// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../hatari_installer.dart';

/// Shows the Hatari install dialog and returns the absolute path of the
/// installed executable when an install succeeded, or `null` on cancel/failure.
Future<String?> showHatariInstallDialog(
  BuildContext context, {
  required DesktopConfig config,
  HatariDownloader downloader = const HttpHatariDownloader(),
  HatariBuild? build,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) =>
        HatariInstallDialog(config: config, downloader: downloader, build: build),
  );
}

/// Offers the prebuilt Hatari release for the current platform, downloads and
/// unpacks it into `<appDir>/hatari`, then pops with the installed executable
/// path.
class HatariInstallDialog extends StatefulWidget {
  const HatariInstallDialog({
    super.key,
    required this.config,
    this.downloader = const HttpHatariDownloader(),
    this.build,
  });

  final DesktopConfig config;
  final HatariDownloader downloader;

  /// Overrides the platform build lookup (tests); `null` uses
  /// [hatariBuildFor] for the current platform.
  final HatariBuild? build;

  @override
  State<HatariInstallDialog> createState() => _HatariInstallDialogState();
}

class _HatariInstallDialogState extends State<HatariInstallDialog> {
  HatariBuild? get _build => widget.build ?? hatariBuildFor();

  bool _downloading = false;
  bool _cancelRequested = false;
  String _message = '';
  int _done = 0;
  int _total = 0;
  String? _error;

  Future<void> _install() async {
    final build = _build;
    if (build == null) return;
    setState(() {
      _downloading = true;
      _cancelRequested = false;
      _message = 'Starting…';
      _done = 0;
      _total = 0;
      _error = null;
    });
    try {
      final exe = await widget.downloader.download(
        build,
        hatariInstallDir(widget.config),
        onProgress: (message, done, total) {
          if (!mounted) return;
          setState(() {
            _message = message;
            _done = done;
            _total = total;
          });
        },
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;
      Navigator.of(context).pop(exe);
    } on HatariInstallCancelledException {
      if (mounted) setState(() => _error = 'Download cancelled.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Install failed: $e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final build = _build;
    return AlertDialog(
      title: const Text('Hatari not found'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (build == null)
              const Text(
                'No prebuilt Hatari binary is available for this platform. '
                'Install Hatari with your system package manager (e.g. '
                'apt/dnf/pacman) and set the "Hatari executable" path in the '
                'settings.',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              )
            else ...[
              Text(
                'The launcher can download and install prebuilt Hatari '
                '$kHatariVersion for ${build.label} into:',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 6),
              SelectableText(
                hatariInstallDir(widget.config),
                style: const TextStyle(fontSize: 12, color: Colors.lightBlue),
              ),
              if (_downloading) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _total > 0
                          ? LinearProgressIndicator(value: _done / _total)
                          : const LinearProgressIndicator(),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        _message,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(
                        fontSize: 12, color: Colors.redAccent)),
              ],
              const SizedBox(height: 14),
              const Text(
                'Hatari is free software (GPL-2.0). Source:',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              SelectableText(
                kHatariSourceUrl,
                style: const TextStyle(fontSize: 11, color: Colors.lightBlue),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading
              ? () => setState(() => _cancelRequested = true)
              : () => Navigator.of(context).pop(),
          child: Text(_downloading ? 'Cancel download' : 'Cancel'),
        ),
        if (build != null)
          FilledButton(
            onPressed: _downloading ? null : _install,
            child: Text(_error == null ? 'Install Hatari' : 'Retry'),
          ),
      ],
    );
  }
}
