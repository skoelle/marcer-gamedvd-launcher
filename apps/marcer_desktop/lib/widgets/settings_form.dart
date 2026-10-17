// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_assets.dart';
import '../ftp_downloader.dart';

/// Live validation state of a single path field, driving its trailing icon.
enum FieldStatus {
  /// Empty optional field: no icon, does not block saving.
  none,

  /// Existing directory / file behind the entered path.
  valid,

  /// Required-but-empty, or a path that does not exist.
  invalid,
}

enum _PickerKind { directory, executable, configFile, text }

enum _Field {
  root,
  patch,
  ftpHost,
  ftpUser,
  ftpPass,
  ftpBase,
  ftpAssets,
  screenshot,
  gameinfo,
  hatariExec,
  hatariCfg,
}

class _PathField {
  _PathField(this.field, this.label, this.kind,
      {this.required = false,
      this.optionalHint,
      this.obscure = false,
      this.sectionHeader,
      this.download});

  final _Field field;
  final String label;
  final _PickerKind kind;
  final bool required;
  final String? optionalHint;
  final bool obscure;

  /// Section header rendered above this field (only set on the first field of
  /// a group).
  final String? sectionHeader;

  /// When set, the field gets a "Download from FTP" button that fetches the
  /// newest archive of this asset into the field's directory.
  final CatalogAsset? download;

  final TextEditingController controller = TextEditingController();
}

/// Reusable editor for the path fields of `desktop.config.json`, shared by
/// the in-app settings dialog (gear button) and the first-run [SetupPage].
///
/// Field order: game roots, the FTP server (games **and** catalog assets),
/// the catalog data directories (with a "Download from FTP" button each) and
/// the Hatari launch settings.
///
/// Every field is validated live as the user types / browses: existing
/// directories (or files for the Hatari fields) show a green check, invalid
/// entries a red cross, empty optional fields no icon. [onChanged] reports
/// the assembled [DesktopConfig] plus whether it is saveable (no invalid
/// field) so the owning widget can gate its Save button.
class SettingsForm extends StatefulWidget {
  const SettingsForm({
    super.key,
    required this.initial,
    this.onChanged,
    this.onAssetDownloaded,
    this.assetDownloader = const FtpCatalogAssets(),
  });

  /// Values the fields start with (a default/empty config for first-run).
  final DesktopConfig initial;

  /// Called on every edit with the current config and its validity.
  final void Function(DesktopConfig config, bool allValid)? onChanged;

  /// Called after a catalog asset (screenshots / gameinfo) was downloaded and
  /// extracted, so the owner can reload the catalog.
  final void Function(CatalogAsset asset)? onAssetDownloaded;

  /// Downloads the catalog asset archives (injectable for tests).
  final CatalogAssetDownloader assetDownloader;

  @override
  State<SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<SettingsForm> {
  late final List<_PathField> _fields;

  CatalogAsset? _downloading;
  String _downloadMessage = '';
  int _downloadDone = 0;
  int _downloadTotal = 0;
  bool _cancelRequested = false;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _fields = [
      _PathField(_Field.root, 'RootDirectory', _PickerKind.directory,
          required: true)
        ..controller.text = c.rootDirectory,
      _PathField(_Field.patch, 'PatchDirectory', _PickerKind.directory,
          optionalHint: 'leave empty for no patch layer')
        ..controller.text = c.patchDirectory,
      _PathField(_Field.ftpHost, 'FTP host', _PickerKind.text,
          sectionHeader: 'FTP — downloads from the server'
              ' (game folders + catalog data)',
          optionalHint: 'host or host:port')
        ..controller.text = c.ftpHost,
      _PathField(_Field.ftpUser, 'FTP user', _PickerKind.text)
        ..controller.text = c.ftpUser,
      _PathField(_Field.ftpPass, 'FTP password', _PickerKind.text,
          obscure: true)
        ..controller.text = c.ftpPassword,
      _PathField(_Field.ftpBase, 'FTP remote base dir (game folders)',
          _PickerKind.text,
          optionalHint: 'empty → FTP login root')
        ..controller.text = c.ftpRemoteBase,
      _PathField(_Field.ftpAssets, 'FTP asset dir (screenshots + gameinfo)',
          _PickerKind.text,
          optionalHint: 'default $kDefaultFtpAssetsRemote')
        ..controller.text = c.ftpAssetsRemote,
      _PathField(_Field.screenshot, 'ScreenshotDirectory', _PickerKind.directory,
          sectionHeader: 'Catalog data (download missing from FTP)',
          optionalHint: 'screenshots + index.json',
          download: CatalogAsset.screenshots)
        ..controller.text = c.screenshotDirectory,
      _PathField(_Field.gameinfo, 'GameinfoDirectory', _PickerKind.directory,
          optionalHint: 'game metadata JSON',
          download: CatalogAsset.gameinfo)
        ..controller.text = c.gameinfoDirectory,
      _PathField(_Field.hatariExec, 'Hatari executable', _PickerKind.executable,
          sectionHeader: 'Hatari')
        ..controller.text = c.hatariExecutable,
      _PathField(_Field.hatariCfg, 'Hatari config file', _PickerKind.configFile,
          optionalHint: 'empty → bundled MarcerGameDvd-Hatari.cfg')
        ..controller.text = c.hatariConfigFile,
    ];
    for (final f in _fields) {
      f.controller.addListener(_revalidate);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  @override
  void dispose() {
    for (final f in _fields) {
      f.controller.removeListener(_revalidate);
      f.controller.dispose();
    }
    super.dispose();
  }

  void _revalidate() {
    setState(() {});
    _emit();
  }

  void _emit() {
    if (!mounted) return;
    widget.onChanged?.call(currentConfig, allValid);
  }

  String _textOf(_Field f) =>
      _fields.firstWhere((e) => e.field == f).controller.text.trim();

  /// The config assembled from the current field values (untouched fields
  /// keep their initial value via [DesktopConfig.copyWith]).
  DesktopConfig get currentConfig => widget.initial.copyWith(
        rootDirectory: _textOf(_Field.root),
        patchDirectory: _textOf(_Field.patch),
        screenshotDirectory: _textOf(_Field.screenshot),
        gameinfoDirectory: _textOf(_Field.gameinfo),
        hatariExecutable: _textOf(_Field.hatariExec),
        hatariConfigFile: _textOf(_Field.hatariCfg),
        ftpHost: _textOf(_Field.ftpHost),
        ftpUser: _textOf(_Field.ftpUser),
        ftpPassword: _textOf(_Field.ftpPass),
        ftpRemoteBase: _textOf(_Field.ftpBase),
        ftpAssetsRemote: _textOf(_Field.ftpAssets),
      );

  /// True when no field is invalid (required filled + valid, optional either
  /// empty or valid).
  bool get allValid =>
      _fields.every((f) => _statusOf(f) != FieldStatus.invalid);

  FieldStatus _statusOf(_PathField f) {
    // Free-text fields (FTP) are never validated: any value (or none) is fine.
    if (f.kind == _PickerKind.text) return FieldStatus.none;
    final v = f.controller.text.trim();
    if (v.isEmpty) return f.required ? FieldStatus.invalid : FieldStatus.none;
    final ok = f.kind == _PickerKind.directory
        ? Directory(v).existsSync()
        : File(v).existsSync();
    return ok ? FieldStatus.valid : FieldStatus.invalid;
  }

  /// Target directory of the downloadable [asset] field.
  String _targetFor(CatalogAsset asset) => asset == CatalogAsset.screenshots
      ? _textOf(_Field.screenshot)
      : _textOf(_Field.gameinfo);

  Future<void> _downloadAsset(CatalogAsset asset) async {
    if (_downloading != null) return;
    if (!currentConfig.ftpConfigured) {
      _snack('FTP host missing — enter the FTP server above first.');
      return;
    }
    final target = _targetFor(asset);
    if (target.isEmpty) {
      _snack('Choose a target directory for ${asset.label} first.');
      return;
    }

    setState(() {
      _downloading = asset;
      _downloadMessage = 'Starting…';
      _downloadDone = 0;
      _downloadTotal = 0;
      _cancelRequested = false;
    });
    try {
      final name = await widget.assetDownloader.download(
        asset: asset,
        config: currentConfig,
        targetDir: target,
        onProgress: (message, done, total) {
          if (!mounted) return;
          setState(() {
            _downloadMessage = message;
            _downloadDone = done;
            _downloadTotal = total;
          });
        },
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;
      _snack('${asset.label} updated from $name.');
      widget.onAssetDownloaded?.call(asset);
      _revalidate();
    } on DownloadCancelledException {
      if (mounted) _snack('${asset.label} download cancelled.');
    } catch (e) {
      if (mounted) _snack('${asset.label} download failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _downloading = null;
          _downloadMessage = '';
        });
      }
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _browse(_PathField field) async {
    try {
      final current = field.controller.text.trim();
      final initial = Directory(current).existsSync() ? current : null;
      switch (field.kind) {
        case _PickerKind.directory:
          final dir = await FilePicker.getDirectoryPath(
            dialogTitle: 'Select ${field.label}',
            initialDirectory: initial,
          );
          if (dir != null) field.controller.text = dir;
        case _PickerKind.executable:
        case _PickerKind.configFile:
          final result = await FilePicker.pickFiles(
            dialogTitle: 'Select ${field.label}',
            initialDirectory: initial,
            type: field.kind == _PickerKind.configFile
                ? FileType.custom
                : FileType.any,
            allowedExtensions:
                field.kind == _PickerKind.configFile ? const ['cfg'] : null,
          );
          final path = result?.files.single.path;
          if (path != null) field.controller.text = path;
        case _PickerKind.text:
          break;
      }
    } catch (e) {
      if (mounted) {
        _snack('${field.label}: picker failed — $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in _fields) ...[
          if (field.sectionHeader != null) _sectionHeader(field.sectionHeader!),
          _fieldRow(field),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.bold)),
      );

  /// Width of the left label column.
  static const double _labelWidth = 220;

  Widget _fieldRow(_PathField field) {
    final isText = field.kind == _PickerKind.text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: _labelWidth, child: _label(field)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: field.controller,
                      obscureText: field.obscure,
                      style: const TextStyle(fontSize: 12),
                      decoration: InputDecoration(
                        isDense: true,
                        suffixIcon: _statusIcon(_statusOf(field)),
                        suffixIconConstraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 10),
                      ),
                    ),
                  ),
                  if (!isText) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 40,
                      child: OutlinedButton(
                        onPressed: () => _browse(field),
                        child: const Text('Browse…'),
                      ),
                    ),
                  ],
                  if (field.download != null) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 40,
                      child: FilledButton.tonal(
                        onPressed: _downloading == null
                            ? () => _downloadAsset(field.download!)
                            : null,
                        child: const Text('Download from FTP'),
                      ),
                    ),
                  ],
                ],
              ),
              if (field.download != null && _downloading == field.download)
                _downloadStatus(),
            ],
          ),
        ),
      ],
    );
  }

  /// Left label column: the field label (with a required marker) and, below it,
  /// the optional hint in small grey text.
  Widget _label(_PathField field) => Padding(
        padding: const EdgeInsets.only(top: 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                text: field.label,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                children: [
                  if (field.required)
                    const TextSpan(
                        text: ' *',
                        style: TextStyle(color: Colors.redAccent)),
                ],
              ),
            ),
            if (field.optionalHint != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(field.optionalHint!,
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
              ),
          ],
        ),
      );

  Widget _downloadStatus() => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            Expanded(
              child: _downloadTotal > 0
                  ? LinearProgressIndicator(
                      value: _downloadDone / _downloadTotal,
                      minHeight: 6,
                      backgroundColor: const Color(0xFF2A2A2A),
                    )
                  : const LinearProgressIndicator(
                      minHeight: 6,
                      backgroundColor: Color(0xFF2A2A2A),
                    ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                _downloadMessage,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: () => setState(() => _cancelRequested = true),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

  Widget _statusIcon(FieldStatus status) {
    switch (status) {
      case FieldStatus.none:
        return const SizedBox.shrink();
      case FieldStatus.valid:
        return const Icon(Icons.check_circle,
            size: 18, color: Color(0xFF4CAF50));
      case FieldStatus.invalid:
        return const Icon(Icons.cancel, size: 18, color: Colors.redAccent);
    }
  }
}
