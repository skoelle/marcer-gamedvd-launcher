// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../tos_rom.dart';

/// Shows the TOS ROM download dialog and returns `true` when a TOS image was
/// successfully installed as [fileName] (default `TOS.IMG`) next to the app.
Future<bool> showTosRomDialog(
  BuildContext context, {
  required DesktopConfig config,
  TosRomDownloader downloader = const HttpTosRomDownloader(),
  List<String>? versions,
  String fileName = kTosImageFileName,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => TosRomDialog(
      config: config,
      downloader: downloader,
      versions: versions,
      fileName: fileName,
    ),
  );
  return result ?? false;
}

/// Dialog offering the TOS 1.00/1.02/1.04 (and, when filtered, 1.62) English
/// (UK) and German ROM images for download. Pops `true` after the ROM was
/// written as [fileName] into the app directory.
class TosRomDialog extends StatefulWidget {
  const TosRomDialog({
    super.key,
    required this.config,
    this.downloader = const HttpTosRomDownloader(),
    this.versions,
    this.fileName = kTosImageFileName,
  });

  final DesktopConfig config;
  final TosRomDownloader downloader;

  /// TOS versions offered (e.g. `['1.62']`); `null` offers the default set
  /// ([kDefaultTosVersions]).
  final List<String>? versions;

  /// File the ROM is written to next to the app.
  final String fileName;

  @override
  State<TosRomDialog> createState() => _TosRomDialogState();
}

class _TosRomDialogState extends State<TosRomDialog> {
  late final List<TosRomOption> _options;
  late TosRomOption _selected;
  bool _downloading = false;
  bool _cancelRequested = false;
  String _message = '';
  int _done = 0;
  int _total = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    final wanted = widget.versions ?? kDefaultTosVersions;
    var options =
        kTosRomOptions.where((o) => wanted.contains(o.version)).toList();
    if (options.isEmpty) options = List<TosRomOption>.of(kTosRomOptions);
    _options = options;
    _selected = _options.firstWhere((o) => o == kDefaultTosRomOption,
        orElse: () => _options.first);
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _cancelRequested = false;
      _message = 'Starting…';
      _done = 0;
      _total = 0;
      _error = null;
    });
    try {
      await widget.downloader.download(
        _selected,
        tosTargetDirectory(widget.config),
        fileName: widget.fileName,
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
      Navigator.of(context).pop(true);
    } on TosRomCancelledException {
      if (mounted) setState(() => _error = 'Download cancelled.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Download failed: $e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('TOS ROM not found'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hatari needs a TOS ROM image (${widget.fileName}) next to the '
              'app. Choose a version and it will be downloaded and installed '
              'into ${tosTargetDirectory(widget.config)}.',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<TosRomOption>(
              initialValue: _selected,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'TOS version',
              ),
              items: [
                for (final option in _options)
                  DropdownMenuItem(
                    value: option,
                    child: Text(option.label),
                  ),
              ],
              onChanged: _downloading
                  ? null
                  : (value) {
                      if (value != null) setState(() => _selected = value);
                    },
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
                  style:
                      const TextStyle(fontSize: 12, color: Colors.redAccent)),
            ],
            const SizedBox(height: 14),
            const Text(
              'TOS ROM images are Atari copyrighted. Download only for '
              'non-commercial use. Source:',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            SelectableText(
              kTosRomSourceUrl,
              style: const TextStyle(fontSize: 11, color: Colors.lightBlue),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading
              ? () => setState(() => _cancelRequested = true)
              : () => Navigator.of(context).pop(false),
          child: Text(_downloading ? 'Cancel download' : 'Cancel'),
        ),
        FilledButton(
          onPressed: _downloading ? null : _download,
          child: const Text('Download'),
        ),
      ],
    );
  }
}
