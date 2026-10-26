// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../atarilegend_fetcher.dart';
import '../catalog_assets.dart';
import '../ftp_downloader.dart';
import '../hatari_installer.dart';
import '../piratefinder_data.dart';
import '../piratefinder_names.dart';
import '../tos_rom.dart';
import 'hatari_install_dialog.dart';
import 'piratefinder_link.dart';
import 'tos_rom_dialog.dart';

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

/// Settings tabs (user decision 2026-10-26): CosmosEx is its own tab after
/// Hatari, so the shared form no longer renders everything at once.
enum _SettingsTab { library, hatari, cosmosEx }

enum _Field {
  root,
  patch,
  ftpHost,
  ftpUser,
  ftpPass,
  ftpBase,
  ftpAssets,
  cosmosHost,
  cosmosPass,
  cosmosMac,
  cosmosShare,
  screenshot,
  gameinfo,
  hatariExec,
  hatariCfg,
}

class _PathField {
  _PathField(
    this.field,
    this.label,
    this.kind, {
    this.required = false,
    this.optionalHint,
    this.obscure = false,
    this.sectionHeader,
    this.download,
  });

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
    this.onBusyChanged,
    this.assetDownloader = const FtpCatalogAssets(),
    this.tosDownloader = const HttpTosRomDownloader(),
    this.hatariDownloader = const HttpHatariDownloader(),
    this.atariLegendFetcher = const HttpAtariLegendFetcher(),
    this.pirateFinderData,
    this.hatariBuild,
  });

  /// Values the fields start with (a default/empty config for first-run).
  final DesktopConfig initial;

  /// Called on every edit with the current config and its validity.
  final void Function(DesktopConfig config, bool allValid)? onChanged;

  /// Called after a catalog asset (screenshots / gameinfo) was downloaded and
  /// extracted, so the owner can reload the catalog.
  final void Function(CatalogAsset asset)? onAssetDownloaded;

  /// Called with `true` while a download/extraction is running and `false`
  /// when it finishes, so the owner can disable Save/Cancel and block
  /// dismissal (the running transfer must not be interrupted).
  final ValueChanged<bool>? onBusyChanged;

  /// Downloads the catalog asset archives (injectable for tests).
  final CatalogAssetDownloader assetDownloader;

  /// Downloads the TOS ROM image (injectable for tests).
  final TosRomDownloader tosDownloader;

  /// Downloads and unpacks the prebuilt Hatari (injectable for tests).
  final HatariDownloader hatariDownloader;

  /// Fetches the AtariLegend dump and builds the compact cache (injectable
  /// for tests).
  final AtariLegendFetcher atariLegendFetcher;

  /// Shared PF catalogue download/update state. When omitted (first-run
  /// setup, tests) the form owns a private controller.
  final PirateFinderDataController? pirateFinderData;

  /// Overrides the platform build lookup for the Hatari install row (tests);
  /// `null` uses [hatariBuildFor] for the current platform.
  final HatariBuild? hatariBuild;

  @override
  State<SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<SettingsForm> {
  late final List<_PathField> _fields;

  _SettingsTab _tab = _SettingsTab.library;

  late String _cosmosExMode;

  CatalogAsset? _downloading;
  String _downloadMessage = '';
  int _downloadDone = 0;
  int _downloadTotal = 0;
  bool _cancelRequested = false;

  bool _fetchingAtariLegend = false;
  AtariLegendCacheInfo? _atariLegendInfoCache;
  String? _atariLegendInfoPath;
  int? _atariLegendInfoStamp;
  late final PirateFinderDataController _pirateFinder;
  late final bool _ownsPirateFinder;
  bool _pirateFinderCancel = false;
  String _atariLegendMessage = '';
  int _atariLegendDone = 0;
  int _atariLegendTotal = 0;
  bool _atariLegendCancel = false;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _cosmosExMode = c.cosmosExModeNormalized;
    _fields = [
      _PathField(
        _Field.root,
        'RootDirectory',
        _PickerKind.directory,
        required: true,
        sectionHeader: 'Paths',
      )..controller.text = c.rootDirectory,
      _PathField(
        _Field.patch,
        'PatchDirectory',
        _PickerKind.directory,
        optionalHint: 'leave empty for no patch layer',
      )..controller.text = c.patchDirectory,
      _PathField(
        _Field.ftpHost,
        'FTP host',
        _PickerKind.text,
        sectionHeader:
            'FTP — downloads from the server'
            ' (game folders + catalog data)',
        optionalHint: 'host or host:port',
      )..controller.text = c.ftpHost,
      _PathField(_Field.ftpUser, 'FTP user', _PickerKind.text)
        ..controller.text = c.ftpUser,
      _PathField(
        _Field.ftpPass,
        'FTP password',
        _PickerKind.text,
        obscure: true,
      )..controller.text = c.ftpPassword,
      _PathField(
        _Field.ftpBase,
        'FTP remote base dir (game folders)',
        _PickerKind.text,
        optionalHint: 'empty → FTP login root',
      )..controller.text = c.ftpRemoteBase,
      _PathField(
        _Field.ftpAssets,
        'FTP asset dir (screenshots + gameinfo)',
        _PickerKind.text,
        optionalHint: kDefaultFtpAssetsRemote,
      )..controller.text = c.ftpAssetsRemote,
      _PathField(
        _Field.cosmosHost,
        'CosmosEx host',
        _PickerKind.text,
        optionalHint: 'host, host:port or http(s)://host:port',
      )..controller.text = c.cosmosExHost,
      _PathField(
        _Field.cosmosPass,
        'CosmosEx web password',
        _PickerKind.text,
        obscure: true,
        optionalHint: 'cosmo2ex only (legacy: empty)',
      )..controller.text = c.cosmosExPassword,
      _PathField(
        _Field.cosmosMac,
        'CosmosEx device MAC',
        _PickerKind.text,
        optionalHint: 'cosmo2ex only · empty → single device',
      )..controller.text = c.cosmosExMac,
      _PathField(
        _Field.cosmosShare,
        'CosmosEx share directory',
        _PickerKind.directory,
        optionalHint:
            'cosmo2ex only · mounted FLOPPY_IMAGES_DIR (SMB/NFS/local)',
      )..controller.text = c.cosmosExShareDirectory,
      _PathField(
        _Field.screenshot,
        'ScreenshotDirectory',
        _PickerKind.directory,
        sectionHeader: 'Catalog data',
        optionalHint: 'screenshots + index.json',
        download: CatalogAsset.screenshots,
      )..controller.text = c.screenshotDirectory,
      _PathField(
        _Field.gameinfo,
        'Data directory (GameinfoDirectory)',
        _PickerKind.directory,
        optionalHint: 'gameinfo/, atarilegend/, piratefinder/',
        download: CatalogAsset.gameinfo,
      )..controller.text = c.gameinfoDirectory,
      _PathField(_Field.hatariExec, 'Hatari executable', _PickerKind.executable)
        ..controller.text = c.hatariExecutable,
      _PathField(
        _Field.hatariCfg,
        'Hatari config file',
        _PickerKind.configFile,
        optionalHint: 'empty → bundled MarcerGameDvd-Hatari.cfg',
      )..controller.text = c.hatariConfigFile,
    ];
    _ownsPirateFinder = widget.pirateFinderData == null;
    _pirateFinder = widget.pirateFinderData ?? PirateFinderDataController();
    _pirateFinder.config = widget.initial;
    _pirateFinder.addListener(_onPirateFinderChanged);
    _pirateFinder.refreshLocal();
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
    _pirateFinder.removeListener(_onPirateFinderChanged);
    if (_ownsPirateFinder) _pirateFinder.dispose();
    super.dispose();
  }

  void _revalidate() {
    _pirateFinder.config = currentConfig;
    _pirateFinder.refreshLocal();
    setState(() {});
    _emit();
  }

  void _onPirateFinderChanged() {
    if (mounted) setState(() {});
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
    cosmosExMode: _cosmosExMode,
    cosmosExHost: _textOf(_Field.cosmosHost),
    cosmosExPassword: _textOf(_Field.cosmosPass),
    cosmosExMac: _textOf(_Field.cosmosMac),
    cosmosExShareDirectory: _textOf(_Field.cosmosShare),
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
    if (ok) return FieldStatus.valid;
    return FieldStatus.invalid;
  }

  /// Target directory of the downloadable [asset] field.
  String _targetFor(CatalogAsset asset) => asset == CatalogAsset.screenshots
      ? _textOf(_Field.screenshot)
      : currentConfig.resolveGameinfoDirectory();

  Future<void> _downloadAsset(CatalogAsset asset, {bool force = false}) async {
    if (_downloading != null || _fetchingAtariLegend || _pirateFinder.busy) {
      return;
    }
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
    widget.onBusyChanged?.call(true);
    AssetDownloadResult? result;
    try {
      result = await widget.assetDownloader.download(
        asset: asset,
        config: currentConfig,
        targetDir: target,
        force: force,
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
      widget.onBusyChanged?.call(false);
    }

    if (!mounted || result == null) return;
    if (result.upToDate) {
      final proceed = await _confirmRedownload(asset, result.archive);
      if (proceed && mounted) await _downloadAsset(asset, force: true);
      return;
    }
    _snack('${asset.label} updated from ${result.archive}.');
    widget.onAssetDownloaded?.call(asset);
    _revalidate();
  }

  /// Downloads the newest AtariLegend dump and writes the compact metadata
  /// cache into the configured directory (created when it does not exist).
  Future<void> _downloadAtariLegend() async {
    if (_downloading != null || _fetchingAtariLegend || _pirateFinder.busy) {
      return;
    }
    final target = currentConfig.resolveAtariLegendDirectory();
    if (target.isEmpty) {
      _snack('Set a data directory first.');
      return;
    }

    setState(() {
      _fetchingAtariLegend = true;
      _atariLegendMessage = 'Starting…';
      _atariLegendDone = 0;
      _atariLegendTotal = 0;
      _atariLegendCancel = false;
    });
    widget.onBusyChanged?.call(true);
    try {
      final result = await widget.atariLegendFetcher.fetch(
        targetDir: target,
        onProgress: (message, done, total) {
          if (!mounted) return;
          setState(() {
            _atariLegendMessage = message;
            _atariLegendDone = done;
            _atariLegendTotal = total;
          });
        },
        isCancelled: () => _atariLegendCancel,
      );
      if (mounted) {
        _snack(
          'AtariLegend data: ${result.games} games '
          '(${result.dumpFile}).',
        );
      }
    } on AtariLegendFetchCancelled {
      if (mounted) _snack('AtariLegend download cancelled.');
    } catch (e) {
      if (mounted) _snack('AtariLegend download failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _fetchingAtariLegend = false;
          _atariLegendMessage = '';
        });
      }
      widget.onBusyChanged?.call(false);
      _revalidate();
    }
  }

  /// Downloads the newest PF catalogue JSON from GitHub (offered only; never
  /// applied automatically). The data stays in the app-managed PF directory.
  Future<void> _downloadPirateFinder() async {
    if (_pirateFinder.busy || _downloading != null || _fetchingAtariLegend) {
      return;
    }
    _pirateFinder.config = currentConfig;
    _pirateFinderCancel = false;
    widget.onBusyChanged?.call(true);
    try {
      final ok = await _pirateFinder.downloadLatest(
        isCancelled: () => _pirateFinderCancel,
      );
      if (!mounted) return;
      if (ok) {
        _snack('$kPirateFinderCatalogShortName updated.');
      } else if (_pirateFinder.error != null) {
        _snack(_pirateFinder.error!);
      }
    } finally {
      widget.onBusyChanged?.call(false);
    }
  }

  /// Asks whether the already-applied (up-to-date) archive should be
  /// downloaded again anyway.
  Future<bool> _confirmRedownload(CatalogAsset asset, String archive) async {
    final again = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Already up to date'),
        content: Text(
          'You already have the newest ${asset.label} ($archive). '
          'Download it again anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Download anyway'),
          ),
        ],
      ),
    );
    return again ?? false;
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
            allowedExtensions: field.kind == _PickerKind.configFile
                ? const ['cfg']
                : null,
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
      children: [_tabBar(), const SizedBox(height: 14), ..._tabContent()],
    );
  }

  List<Widget> _tabContent() {
    switch (_tab) {
      case _SettingsTab.library:
        return [
          for (final field in _fields)
            if (_tabOf(field.field) == _SettingsTab.library) ...[
              if (field.sectionHeader != null)
                _sectionHeader(field.sectionHeader!),
              _fieldRow(field),
              if (field.field == _Field.gameinfo) ...[
                _atariLegendRow(),
                if (widget.pirateFinderData != null) _pirateFinderRow(),
              ],
              const SizedBox(height: 8),
            ],
        ];
      case _SettingsTab.hatari:
        return [
          for (final field in _fields)
            if (_tabOf(field.field) == _SettingsTab.hatari) ...[
              _fieldRow(field),
              const SizedBox(height: 8),
            ],
          _hatariRow(),
          _tosRow(),
        ];
      case _SettingsTab.cosmosEx:
        return [
          _tabIntro(
            'Send the shown ZIP to a real Atari: legacy ce-atari uploads the '
            'whole ZIP; cosmo2ex copies the first .st/.msa into the mounted '
            'FLOPPY_IMAGES_DIR share and inserts that path.',
          ),
          const SizedBox(height: 10),
          _cosmosExModeRow(),
          const SizedBox(height: 8),
          for (final field in _fields)
            if (_tabOf(field.field) == _SettingsTab.cosmosEx) ...[
              _fieldRow(field),
              const SizedBox(height: 8),
            ],
        ];
    }
  }

  _SettingsTab _tabOf(_Field field) {
    switch (field) {
      case _Field.hatariExec:
      case _Field.hatariCfg:
        return _SettingsTab.hatari;
      case _Field.cosmosHost:
      case _Field.cosmosPass:
      case _Field.cosmosMac:
      case _Field.cosmosShare:
        return _SettingsTab.cosmosEx;
      default:
        return _SettingsTab.library;
    }
  }

  Widget _tabBar() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF2A2A2A))),
      ),
      child: Row(
        children: [for (final tab in _SettingsTab.values) _tabButton(tab)],
      ),
    );
  }

  Widget _tabButton(_SettingsTab tab) {
    final selected = _tab == tab;
    final invalid = _tabInvalid(tab);
    return Expanded(
      child: InkWell(
        key: Key('settings-tab-${_tabKey(tab)}'),
        onTap: () => setState(() => _tab = tab),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _tabIcon(tab),
                size: 16,
                color: selected ? Colors.white : Colors.grey,
              ),
              const SizedBox(width: 6),
              Text(
                _tabLabel(tab),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? Colors.white : Colors.grey,
                ),
              ),
              if (invalid) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Contains invalid fields',
                  child: Container(
                    key: Key('settings-tab-error-${_tabKey(tab)}'),
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  bool _tabInvalid(_SettingsTab tab) => _fields.any(
    (field) =>
        _tabOf(field.field) == tab && _statusOf(field) == FieldStatus.invalid,
  );

  String _tabKey(_SettingsTab tab) {
    switch (tab) {
      case _SettingsTab.library:
        return 'library';
      case _SettingsTab.hatari:
        return 'hatari';
      case _SettingsTab.cosmosEx:
        return 'cosmosex';
    }
  }

  String _tabLabel(_SettingsTab tab) {
    switch (tab) {
      case _SettingsTab.library:
        return 'Library';
      case _SettingsTab.hatari:
        return 'Hatari';
      case _SettingsTab.cosmosEx:
        return 'CosmosEx';
    }
  }

  IconData _tabIcon(_SettingsTab tab) {
    switch (tab) {
      case _SettingsTab.library:
        return Icons.folder_open;
      case _SettingsTab.hatari:
        return Icons.videogame_asset;
      case _SettingsTab.cosmosEx:
        return Icons.send;
    }
  }

  Widget _tabIntro(String text) => Text(
    text,
    style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.35),
  );

  /// Reads the cache header, cached by path + mtime so typing in the form does
  /// not parse the ~4.4 MB JSON on every rebuild.
  AtariLegendCacheInfo? _atariLegendInfo(String dir) {
    if (dir.isEmpty) return null;
    final file = File('$dir/$kAtariLegendFileName');
    if (!file.existsSync()) return null;
    final stamp = file.lastModifiedSync().millisecondsSinceEpoch;
    if (_atariLegendInfoPath != dir || _atariLegendInfoStamp != stamp) {
      _atariLegendInfoPath = dir;
      _atariLegendInfoStamp = stamp;
      _atariLegendInfoCache = AtariLegendCacheInfo.load(dir);
    }
    return _atariLegendInfoCache;
  }

  /// AtariLegend cache row (no path field; target is `<DataDir>/atarilegend`).
  Widget _atariLegendRow() {
    final target = currentConfig.resolveAtariLegendDirectory();
    final installed = target.isNotEmpty &&
        File('$target/$kAtariLegendFileName').existsSync();
    final info = installed ? _atariLegendInfo(target) : null;
    final date = info?.assetDate ?? '';
    final status = !installed
        ? 'not installed'
        : date.isNotEmpty
        ? 'installed · dump $date'
        : 'installed · date unknown';
    final busy =
        _downloading != null || _fetchingAtariLegend || _pirateFinder.busy;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _labelWidth,
          child: const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              'AtariLegend data',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(status, style: const TextStyle(fontSize: 11)),
                          Text(
                            target.isEmpty
                                ? 'set a data directory first'
                                : target,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'CC BY-NC-SA 4.0 · not part of the Marcer catalog',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFF7A7A7A),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 40,
                    child: FilledButton.tonal(
                      onPressed: busy || target.isEmpty
                          ? null
                          : _downloadAtariLegend,
                      child: const Text('Download AtariLegend data'),
                    ),
                  ),
                ],
              ),
              if (_fetchingAtariLegend) ...[
                const SizedBox(height: 6),
                _atariLegendStatus(),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Optional PF catalogue data row (`<DataDir>/piratefinder`).
  Widget _pirateFinderRow() {
    final pf = _pirateFinder;
    final local = pf.local;
    final busy = pf.busy || _downloading != null || _fetchingAtariLegend;
    final hasDataDir = pf.dataDir.isNotEmpty;
    final localLabel = local == null
        ? 'not installed'
        : local.sourceTag.isEmpty
        ? 'installed'
        : 'installed · catalogue ${local.sourceTag}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _labelWidth,
          child: const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              kPirateFinderCatalogShortName,
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            localLabel,
                            style: const TextStyle(fontSize: 11),
                          ),
                          Text(
                            hasDataDir
                                ? pf.dataDir
                                : 'set a data directory first',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              PirateFinderGithubLink(),
                              Text(
                                ' · CC BY-NC-SA 4.0 · not part of the '
                                'Marcer catalog',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFF7A7A7A),
                                ),
                              ),
                            ],
                          ),
                          if (hasDataDir) ...[
                            const SizedBox(height: 2),
                            Text(
                              pf.indexError != null
                                  ? 'index: ${pf.indexError}'
                                  : pf.indexLoading
                                  ? 'index: loading…'
                                  : pf.hasIndex
                                  ? 'index: loaded'
                                  : 'index: not loaded',
                              style: TextStyle(
                                fontSize: 10,
                                color: pf.indexError != null
                                    ? Colors.redAccent
                                    : Colors.grey,
                              ),
                            ),
                          ],
                          if (pf.error != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              pf.error!,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.redAccent,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 40,
                    child: FilledButton.tonal(
                      onPressed: busy || !hasDataDir
                          ? null
                          : _downloadPirateFinder,
                      child: const Text(kPirateFinderCatalogShortName),
                    ),
                  ),
                ],
              ),
              if (pf.downloading) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: pf.total > 0
                          ? LinearProgressIndicator(
                              value: pf.done / pf.total,
                              minHeight: 6,
                            )
                          : const LinearProgressIndicator(minHeight: 6),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        pf.message,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: () =>
                          setState(() => _pirateFinderCancel = true),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  /// Width of the left label column.
  static const double _labelWidth = 260;

  /// CosmosEx protocol selector (`auto` / `legacy` / `cosmo2ex`).
  Widget _cosmosExModeRow() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: _labelWidth,
        child: const Padding(
          padding: EdgeInsets.only(top: 11, right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CosmosEx mode',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
              Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text(
                  'auto → legacy first, then cosmo2ex',
                  style: TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: InputDecorator(
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 2,
            ),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _cosmosExMode,
              isExpanded: true,
              isDense: true,
              dropdownColor: const Color(0xFF1B1B1B),
              style: const TextStyle(fontSize: 12, color: Colors.white),
              items: const [
                DropdownMenuItem(
                  value: 'auto',
                  child: Text('auto — detect the firmware'),
                ),
                DropdownMenuItem(
                  value: 'legacy',
                  child: Text('legacy — ce-atari ZIP upload'),
                ),
                DropdownMenuItem(
                  value: 'cosmo2ex',
                  child: Text('cosmo2ex — copy to share + insert path'),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _cosmosExMode = value);
                _emit();
              },
            ),
          ),
        ),
      ),
    ],
  );

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
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
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
                        onPressed:
                            _downloading == null &&
                                !_fetchingAtariLegend &&
                                !_pirateFinder.busy
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

  /// Downloads and installs the prebuilt Hatari for this platform (or replaces
  /// an existing install) and fills the executable field with the result.
  Future<void> _installHatari() async {
    final build = widget.hatariBuild ?? hatariBuildFor();
    if (build == null) return;
    final exe = await showHatariInstallDialog(
      context,
      config: currentConfig,
      downloader: widget.hatariDownloader,
      build: build,
    );
    if (exe == null || !mounted) return;
    final value = hatariConfigExecutable(
      appDir: currentConfig.appDir,
      exePath: exe,
    );
    _fields.firstWhere((f) => f.field == _Field.hatariExec).controller.text =
        value;
    setState(() {});
  }

  /// Hatari installation row: status of the configured executable plus an
  /// install/replace button (downloads the prebuilt release). On platforms
  /// without a prebuilt binary (Linux) it points to a manual install instead.
  Widget _hatariRow() {
    final build = widget.hatariBuild ?? hatariBuildFor();
    final installed = hatariInstalled(currentConfig);
    final supported = build != null;
    final ok = supported && installed;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _labelWidth,
          child: const Padding(
            padding: EdgeInsets.only(top: 11),
            child: Text(
              'Hatari installation',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Row(
            children: [
              Icon(
                ok ? Icons.check : Icons.error_outline,
                size: 18,
                color: ok ? const Color(0xFF4CAF50) : Colors.redAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  !supported
                      ? 'No automatic install on this platform — install '
                            'Hatari manually'
                      : installed
                      ? 'Hatari is installed'
                      : 'Hatari missing — download a prebuilt binary',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              if (supported)
                SizedBox(
                  height: 40,
                  child: OutlinedButton(
                    onPressed: _installHatari,
                    child: Text(
                      installed ? 'Reinstall Hatari…' : 'Install Hatari…',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Downloads a TOS ROM image (or replaces the existing one) and refreshes the
  /// section's status.
  Future<void> _downloadTos() async {
    final ok = await showTosRomDialog(
      context,
      config: currentConfig,
      downloader: widget.tosDownloader,
    );
    if (ok && mounted) setState(() {});
  }

  /// TOS ROM row: status of `<appDir>/TOS.IMG` plus a download/replace button.
  Widget _tosRow() {
    final installed = tosInstalled(widget.initial);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _labelWidth,
          child: const Padding(
            padding: EdgeInsets.only(top: 11),
            child: Text(
              'TOS ROM',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Row(
            children: [
              Icon(
                installed ? Icons.check : Icons.error_outline,
                size: 18,
                color: installed ? const Color(0xFF4CAF50) : Colors.redAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  installed
                      ? 'TOS.IMG installed next to the app'
                      : 'TOS.IMG missing — Hatari needs it to boot',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 40,
                child: OutlinedButton(
                  onPressed: _downloadTos,
                  child: Text(
                    installed ? 'Replace TOS ROM…' : 'Download TOS ROM…',
                  ),
                ),
              ),
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
                  style: TextStyle(color: Colors.redAccent),
                ),
            ],
          ),
        ),
        if (field.optionalHint != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              field.optionalHint!,
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
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

  Widget _atariLegendStatus() => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      children: [
        Expanded(
          child: _atariLegendTotal > 0
              ? LinearProgressIndicator(
                  value: _atariLegendDone / _atariLegendTotal,
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
            _atariLegendMessage,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ),
        const SizedBox(width: 4),
        TextButton(
          onPressed: () => setState(() => _atariLegendCancel = true),
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
        return const Icon(
          Icons.check_circle,
          size: 18,
          color: Color(0xFF4CAF50),
        );
      case FieldStatus.invalid:
        return const Icon(Icons.cancel, size: 18, color: Colors.redAccent);
    }
  }
}
