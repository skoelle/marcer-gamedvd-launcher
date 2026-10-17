// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

import 'ftp_downloader.dart';

/// The two catalog asset archives fetched from the FTP server as
/// `<prefix>-<yyyyMMdd-HHmmss>.zip` (user decision 2026-10-17). New files can
/// only be uploaded, never overwritten, so the newest archive is discovered by
/// its name timestamp.
enum CatalogAsset { screenshots, gameinfo }

extension CatalogAssetInfo on CatalogAsset {
  /// File name prefix of this asset's archive (`screenshots` / `gameinfo`).
  String get archivePrefix => this == CatalogAsset.screenshots
      ? 'screenshots'
      : 'gameinfo';

  /// Human label used in progress messages and error hints.
  String get label =>
      this == CatalogAsset.screenshots ? 'screenshots' : 'gameinfo';
}

/// Progress callback for an asset download: a coarse phase [message] plus
/// byte progress when known (0/0 while unknown).
typedef AssetProgress = void Function(String message, int done, int total);

/// Pluggable catalog asset downloader. The production implementation is
/// [FtpCatalogAssets]; the settings form accepts a fake for unit tests.
abstract class CatalogAssetDownloader {
  /// Downloads the newest `<asset>-<timestamp>.zip` from
  /// `config.ftpAssetsRemote` on the configured FTP server and extracts it
  /// into [targetDir] (created when missing). Existing files are overwritten.
  /// Returns the archive file name that was applied.
  ///
  /// Throws [DownloadException] on any failure and
  /// [DownloadCancelledException] when [isCancelled] reports cancellation.
  Future<String> download({
    required CatalogAsset asset,
    required DesktopConfig config,
    required String targetDir,
    AssetProgress? onProgress,
    bool Function()? isCancelled,
  });
}

/// Plain-FTP implementation of [CatalogAssetDownloader], built on the
/// `ftpconnect` package (same connection settings as [FtpDownloader]).
class FtpCatalogAssets implements CatalogAssetDownloader {
  const FtpCatalogAssets();

  @override
  Future<String> download({
    required CatalogAsset asset,
    required DesktopConfig config,
    required String targetDir,
    AssetProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!config.ftpConfigured) {
      throw const DownloadException('FTP host not configured.');
    }
    if (targetDir.trim().isEmpty) {
      throw DownloadException('No target directory for ${asset.label}.');
    }

    final client = _client(config);
    var connected = false;
    File? temp;
    try {
      onProgress?.call('Connecting…', 0, 0);
      connected = await client.connect();
      if (!connected) throw const DownloadException('FTP login failed.');

      final loginDir = await client.currentDirectory();
      final assetsDir = absoluteRemoteDir(loginDir, config.ftpAssetsRemote);
      if (!await client.changeDirectory(assetsDir)) {
        throw DownloadException('Asset directory not found: '
            '${config.ftpAssetsRemote}');
      }

      final entries = await client.listDirectoryContent();
      final newest = _pickNewest(entries, asset);
      if (newest == null) {
        throw DownloadException(
            'No ${asset.archivePrefix}-*.zip found in ${config.ftpAssetsRemote}');
      }
      if (isCancelled?.call() ?? false) {
        throw const DownloadCancelledException();
      }

      final size = newest.size ?? 0;
      onProgress?.call('Downloading ${newest.name}…', 0, size);
      temp = File(p.join(Directory.systemTemp.path, newest.name));
      await client.downloadFile(newest.name, temp);
      if (isCancelled?.call() ?? false) {
        throw const DownloadCancelledException();
      }

      onProgress?.call('Extracting ${newest.name}…', 0, 0);
      Directory(targetDir).createSync(recursive: true);
      await extractFileToDisk(temp.path, targetDir);
      onProgress?.call('${asset.label} updated.', size, size);
      return newest.name;
    } on DownloadCancelledException {
      rethrow;
    } on DownloadException {
      rethrow;
    } catch (e) {
      throw DownloadException('$e');
    } finally {
      if (temp != null) {
        try {
          if (temp.existsSync()) temp.deleteSync();
        } catch (_) {
          // Best effort — never mask the original result.
        }
      }
      if (connected) {
        try {
          await client.disconnect();
        } catch (_) {
          // Best effort — never mask the original result.
        }
      }
    }
  }

  FTPConnect _client(DesktopConfig config) => FTPConnect(
        config.ftpHostName,
        port: config.ftpPort,
        user: config.ftpUser.trim().isEmpty ? 'anonymous' : config.ftpUser,
        pass: config.ftpPassword,
        timeout: 60,
      );

  /// Newest archive entry for [asset], or `null` when none matches.
  static FTPEntry? _pickNewest(List<FTPEntry> entries, CatalogAsset asset) {
    final files =
        entries.where((e) => e.type == FTPEntryType.file).toList(growable: false);
    final name = newestAssetArchiveName(files.map((e) => e.name), asset);
    if (name == null) return null;
    return files.firstWhere((e) => e.name == name);
  }
}

/// Matches `screenshots-20261017-080230.zip` / `gameinfo-…`, capturing the
/// timestamp so the newest archive can be picked lexicographically.
final RegExp _assetArchivePattern =
    RegExp(r'^(screenshots|gameinfo)-(\d{8}-\d{6})\.zip$', caseSensitive: false);

/// The newest archive name among [names] for [asset] (by the `yyyyMMdd-HHmmss`
/// name timestamp), or `null` when none matches. Uploads never overwrite, so
/// the newest upload is picked by name (user decision 2026-10-17).
String? newestAssetArchiveName(Iterable<String> names, CatalogAsset asset) {
  String? best;
  String? bestStamp;
  for (final name in names) {
    final m = _assetArchivePattern.firstMatch(name);
    if (m == null) continue;
    if (m.group(1)!.toLowerCase() != asset.archivePrefix) continue;
    final stamp = m.group(2)!;
    if (bestStamp == null || stamp.compareTo(bestStamp) > 0) {
      best = name;
      bestStamp = stamp;
    }
  }
  return best;
}
