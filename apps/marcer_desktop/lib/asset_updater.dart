// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import 'catalog_assets.dart';
import 'ftp_downloader.dart';
import 'self_updater.dart';

/// Fixed tag of the GitHub prerelease holding the `latest.json` pointer asset
/// (published by `tools/asset-manifest`).
const String kCatalogAssetsTag = 'catalog-latest';

/// URL of the `latest.json` pointer (GitHub release asset, no auth needed).
String catalogLatestUrl() =>
    'https://github.com/$kSelfUpdateRepo/releases/download/'
    '$kCatalogAssetsTag/latest.json';

/// One remote asset entry from `latest.json`.
class RemoteAsset {
  const RemoteAsset({required this.archive, this.size, this.sha256});

  final String archive;
  final int? size;
  final String? sha256;
}

/// Parsed `latest.json` (the remote catalog-data stand).
class CatalogLatest {
  const CatalogLatest(this.assets);

  final Map<CatalogAsset, RemoteAsset> assets;
}

/// Parses the `latest.json` body; returns `null` on malformed input.
CatalogLatest? parseCatalogLatest(String body) {
  try {
    final map = jsonDecode(body) as Map<String, dynamic>;
    final assets = <CatalogAsset, RemoteAsset>{};
    for (final asset in CatalogAsset.values) {
      final raw = map[asset.archivePrefix];
      if (raw is! Map) continue;
      final archive = (raw['archive'] as String?)?.trim() ?? '';
      if (archive.isEmpty) continue;
      assets[asset] = RemoteAsset(
        archive: archive,
        size: (raw['size'] as num?)?.toInt(),
        sha256: (raw['sha256'] as String?)?.trim(),
      );
    }
    return CatalogLatest(assets);
  } catch (_) {
    return null;
  }
}

/// True when [remote] should be offered as an update: not skipped and not
/// already applied with its data present.
///
/// [dataPresent] is whether the extracted files for the asset are on disk; a
/// marker whose data is gone (emptied directory) still counts as an update.
/// A missing marker with data present (unknown version) also counts, so the
/// dialog can offer an overwrite.
bool assetNeedsUpdate({
  RemoteAsset? remote,
  String? local,
  String? skipped,
  bool dataPresent = true,
}) {
  if (remote == null) return false;
  if (remote.archive == skipped) return false;
  if (remote.archive == local && dataPresent) return false;
  return true;
}

/// Fetches the raw body of [url] (injectable for tests).
typedef LatestFetcher = Future<String> Function(Uri url);

Future<String> httpLatestFetcher(Uri url) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(url);
    req.headers.add(HttpHeaders.userAgentHeader, 'MarcerGameDVDLauncher');
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode}');
    }
    return await resp.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

/// Startup asset check + asset update state, mirroring [SelfUpdateController]:
/// silent, release-builds only.
class AssetUpdateController extends ChangeNotifier {
  AssetUpdateController({
    LatestFetcher? fetcher,
    CatalogAssetDownloader? downloader,
  })  : _fetch = fetcher ?? httpLatestFetcher,
        _downloader = downloader ?? const FtpCatalogAssets();

  static const bool enabled = bool.fromEnvironment('RELEASE_BUILD');

  final LatestFetcher _fetch;
  final CatalogAssetDownloader _downloader;

  /// Live config (target directories + FTP settings); set by the home page.
  DesktopConfig config = DesktopConfig(rootDirectory: '');

  /// The last successfully fetched remote stand (`null` before the first check).
  CatalogLatest? latest;

  /// Last update error (shown in the dialog).
  String? error;

  /// Currently updating asset + progress (`null` when idle).
  CatalogAsset? updatingAsset;
  String updateMessage = '';
  int updateDone = 0;
  int updateTotal = 0;

  bool get busy => updatingAsset != null;

  String _targetDirFor(CatalogAsset asset) =>
      asset == CatalogAsset.screenshots
          ? config.screenshotDirectory
          : config.resolveGameinfoDirectory();

  RemoteAsset? remoteFor(CatalogAsset asset) => latest?.assets[asset];

  String? localFor(CatalogAsset asset) {
    final dir = _targetDirFor(asset);
    return dir.isEmpty ? null : readAppliedAssetVersion(dir, asset);
  }

  String? skippedFor(CatalogAsset asset) {
    final dir = _targetDirFor(asset);
    return dir.isEmpty ? null : readSkippedAsset(dir, asset);
  }

  bool isPending(CatalogAsset asset) => assetNeedsUpdate(
        remote: remoteFor(asset),
        local: localFor(asset),
        skipped: skippedFor(asset),
        dataPresent: dataPresentFor(asset),
      );

  /// Whether the extracted files for [asset] are present in its target
  /// directory (used to distinguish "not installed" from "version unknown").
  bool dataPresentFor(CatalogAsset asset) {
    final dir = _targetDirFor(asset);
    return dir.isNotEmpty && assetDataPresent(dir, asset);
  }

  /// Pending assets in dialog order: gameinfo first, then screenshots.
  List<CatalogAsset> pendingAssets() => const [
        CatalogAsset.gameinfo,
        CatalogAsset.screenshots,
      ].where(isPending).toList();

  bool get hasPending => pendingAssets().isNotEmpty;

  /// Silent startup check (release builds only; [force] for tests/manual).
  Future<void> check({bool force = false}) async {
    if (!enabled && !force) return;
    try {
      final parsed =
          parseCatalogLatest(await _fetch(Uri.parse(catalogLatestUrl())));
      if (parsed != null) latest = parsed;
    } catch (_) {
      // offline / 404 / malformed — stay silent
    }
    notifyListeners();
  }

  /// Suppresses the current remote version for [asset] until a newer one
  /// appears.
  void skip(CatalogAsset asset) {
    final remote = remoteFor(asset);
    final dir = _targetDirFor(asset);
    if (remote == null || dir.isEmpty) return;
    writeSkippedAsset(dir, asset, remote.archive);
    notifyListeners();
  }

  /// Downloads + extracts the remote version of [asset] (forced), verifies the
  /// sha256 when the pointer provides one and clears the skip entry on success.
  Future<bool> update(CatalogAsset asset,
      {bool Function()? isCancelled}) async {
    final remote = remoteFor(asset);
    if (remote == null || busy) return false;
    final dir = _targetDirFor(asset);
    if (dir.isEmpty) {
      error = 'No target directory for ${asset.label}.';
      notifyListeners();
      return false;
    }
    if (!config.ftpConfigured) {
      error = 'FTP not configured — set Host/User/Password in Settings.';
      notifyListeners();
      return false;
    }

    updatingAsset = asset;
    updateMessage = 'Starting…';
    updateDone = 0;
    updateTotal = 0;
    error = null;
    notifyListeners();
    try {
      await _downloader.download(
        asset: asset,
        config: config,
        targetDir: dir,
        force: true,
        expectedSha256: remote.sha256,
        onProgress: (message, done, total) {
          updateMessage = message;
          updateDone = done;
          updateTotal = total;
          notifyListeners();
        },
        isCancelled: isCancelled,
      );
      clearSkippedAsset(dir, asset);
      updatingAsset = null;
      notifyListeners();
      return true;
    } on DownloadCancelledException {
      error = '${asset.label} update cancelled.';
    } catch (e) {
      error = '${asset.label} update failed: $e';
    }
    updatingAsset = null;
    notifyListeners();
    return false;
  }

  void clearError() {
    if (error == null) return;
    error = null;
    notifyListeners();
  }
}
