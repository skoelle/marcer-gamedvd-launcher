// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

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
  screenshot,
  gameinfo,
  hatariExec,
  hatariCfg,
  ftpHost,
  ftpUser,
  ftpPass,
  ftpBase,
}

class _PathField {
  _PathField(this.field, this.label, this.kind,
      {this.required = false, this.optionalHint, this.obscure = false});

  final _Field field;
  final String label;
  final _PickerKind kind;
  final bool required;
  final String? optionalHint;
  final bool obscure;
  final TextEditingController controller = TextEditingController();
}

/// Reusable editor for the path fields of `desktop.config.json`, shared by
/// the in-app settings dialog (gear button) and the first-run [SetupPage].
///
/// Every field is validated live as the user types / browses: existing
/// directories (or files for the Hatari fields) show a green check, invalid
/// entries a red cross, empty optional fields no icon. [onChanged] reports
/// the assembled [DesktopConfig] plus whether it is saveable (no invalid
/// field) so the owning widget can gate its Save button.
class SettingsForm extends StatefulWidget {
  const SettingsForm({super.key, required this.initial, this.onChanged});

  /// Values the fields start with (a default/empty config for first-run).
  final DesktopConfig initial;

  /// Called on every edit with the current config and its validity.
  final void Function(DesktopConfig config, bool allValid)? onChanged;

  @override
  State<SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<SettingsForm> {
  late final List<_PathField> _fields;

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
      _PathField(_Field.screenshot, 'ScreenshotDirectory', _PickerKind.directory,
          optionalHint: 'screenshots + index.json')
        ..controller.text = c.screenshotDirectory,
      _PathField(_Field.gameinfo, 'GameinfoDirectory', _PickerKind.directory,
          optionalHint: 'empty → <Patch>/../Data')
        ..controller.text = c.gameinfoDirectory,
      _PathField(_Field.hatariExec, 'Hatari executable', _PickerKind.executable)
        ..controller.text = c.hatariExecutable,
      _PathField(_Field.hatariCfg, 'Hatari config file', _PickerKind.configFile,
          optionalHint: 'empty → bundled MarcerGameDvd-Hatari.cfg')
        ..controller.text = c.hatariConfigFile,
      _PathField(_Field.ftpHost, 'FTP host', _PickerKind.text,
          optionalHint: 'host or host:port — for "Download missing"')
        ..controller.text = c.ftpHost,
      _PathField(_Field.ftpUser, 'FTP user', _PickerKind.text)
        ..controller.text = c.ftpUser,
      _PathField(_Field.ftpPass, 'FTP password', _PickerKind.text,
          obscure: true)
        ..controller.text = c.ftpPassword,
      _PathField(_Field.ftpBase, 'FTP remote base dir', _PickerKind.text,
          optionalHint: 'empty → FTP login root')
        ..controller.text = c.ftpRemoteBase,
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

  /// The config assembled from the current field values (untouched fields
  /// keep their initial value via [DesktopConfig.copyWith]).
  DesktopConfig get currentConfig {
    String textOf(_Field f) =>
        _fields.firstWhere((e) => e.field == f).controller.text.trim();
    return widget.initial.copyWith(
      rootDirectory: textOf(_Field.root),
      patchDirectory: textOf(_Field.patch),
      screenshotDirectory: textOf(_Field.screenshot),
      gameinfoDirectory: textOf(_Field.gameinfo),
      hatariExecutable: textOf(_Field.hatariExec),
      hatariConfigFile: textOf(_Field.hatariCfg),
      ftpHost: textOf(_Field.ftpHost),
      ftpUser: textOf(_Field.ftpUser),
      ftpPassword: textOf(_Field.ftpPass),
      ftpRemoteBase: textOf(_Field.ftpBase),
    );
  }

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
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('${field.label}: picker failed — $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in _fields) ...[
          if (field.field == _Field.ftpHost) _sectionHeader(
              'FTP — download missing game folders (optional)'),
          _fieldRow(field),
          const SizedBox(height: 10),
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

  Widget _fieldRow(_PathField field) {
    final isText = field.kind == _PickerKind.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(field.label,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
            if (field.required)
              const Text(' *',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12)),
            if (field.optionalHint != null) ...[
              const SizedBox(width: 6),
              Expanded(
                child: Text('(${field.optionalHint})',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
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
          ],
        ),
      ],
    );
  }

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
