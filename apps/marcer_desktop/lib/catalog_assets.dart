// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
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
/// progress when known (0/0 while unknown). During the download [done]/[total]
/// are bytes, during extraction they are file counts.
typedef AssetProgress = void Function(String message, int done, int total);

/// Outcome of a catalog asset download: the newest [archive] on the FTP server
/// and whether it was already applied locally ([upToDate], no download ran).
class AssetDownloadResult {
  const AssetDownloadResult({required this.archive, required this.upToDate});

  final String archive;
  final bool upToDate;
}

/// Name of the marker file written into the target directory after a
/// successful download, recording which archive was applied.
const String kAssetVersionFileName = '.marcer-assets.json';

/// Absolute path of the version marker inside [targetDir].
String assetVersionFilePath(String targetDir) =>
    p.join(targetDir, kAssetVersionFileName);

/// The archive name last applied for [asset] into [targetDir], or `null` when
/// there is no (readable) marker yet.
String? readAppliedAssetVersion(String targetDir, CatalogAsset asset) {
  final file = File(assetVersionFilePath(targetDir));
  if (!file.existsSync()) return null;
  try {
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return map[asset.archivePrefix] as String?;
  } catch (_) {
    return null;
  }
}

/// Records [archive] as the applied version for [asset] in [targetDir],
/// preserving the other asset's entry when both share a directory.
void writeAppliedAssetVersion(
    String targetDir, CatalogAsset asset, String archive) {
  Directory(targetDir).createSync(recursive: true);
  final file = File(assetVersionFilePath(targetDir));
  var map = <String, dynamic>{};
  if (file.existsSync()) {
    try {
      map = Map<String, dynamic>.from(
          jsonDecode(file.readAsStringSync()) as Map);
    } catch (_) {
      map = <String, dynamic>{};
    }
  }
  map[asset.archivePrefix] = archive;
  file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(map)}\n');
}

/// True when [targetDir] actually holds extracted data for [asset] (so a stale
/// marker on an emptied directory does not report "up to date").
bool assetDataPresent(String targetDir, CatalogAsset asset) {
  bool exists(String name) => File(p.join(targetDir, name)).existsSync();
  switch (asset) {
    case CatalogAsset.screenshots:
      return exists('index.json');
    case CatalogAsset.gameinfo:
      return exists('games-cracked.json') ||
          exists('games-pd.json') ||
          exists('games-utils.json') ||
          exists('manifest.json');
  }
}

/// True when [newestArchive] was already applied into [targetDir] and the data
/// is still present.
bool isAssetUpToDate(
        String targetDir, CatalogAsset asset, String newestArchive) =>
    readAppliedAssetVersion(targetDir, asset) == newestArchive &&
    assetDataPresent(targetDir, asset);

/// Reads the marker JSON of [targetDir] (empty map when missing/unreadable).
Map<String, dynamic> _readMarker(String targetDir) {
  final file = File(assetVersionFilePath(targetDir));
  if (!file.existsSync()) return <String, dynamic>{};
  try {
    return Map<String, dynamic>.from(
        jsonDecode(file.readAsStringSync()) as Map);
  } catch (_) {
    return <String, dynamic>{};
  }
}

void _writeMarker(String targetDir, Map<String, dynamic> map) {
  Directory(targetDir).createSync(recursive: true);
  File(assetVersionFilePath(targetDir)).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(map)}\n');
}

/// The archive name the user chose to skip for [asset] in [targetDir], or
/// `null`. Stored under a `skipped` key so the applied-version entries stay
/// unchanged (backward compatible).
String? readSkippedAsset(String targetDir, CatalogAsset asset) {
  final skipped = _readMarker(targetDir)['skipped'];
  if (skipped is Map) return skipped[asset.archivePrefix] as String?;
  return null;
}

/// Records [archive] as the skipped version for [asset] in [targetDir].
void writeSkippedAsset(
    String targetDir, CatalogAsset asset, String archive) {
  final map = _readMarker(targetDir);
  final skipped = (map['skipped'] is Map)
      ? Map<String, dynamic>.from(map['skipped'] as Map)
      : <String, dynamic>{};
  skipped[asset.archivePrefix] = archive;
  map['skipped'] = skipped;
  _writeMarker(targetDir, map);
}

/// Clears the skipped version for [asset] (e.g. after it was applied).
void clearSkippedAsset(String targetDir, CatalogAsset asset) {
  final map = _readMarker(targetDir);
  if (map['skipped'] is! Map) return;
  final skipped = Map<String, dynamic>.from(map['skipped'] as Map);
  skipped.remove(asset.archivePrefix);
  if (skipped.isEmpty) {
    map.remove('skipped');
  } else {
    map['skipped'] = skipped;
  }
  _writeMarker(targetDir, map);
}

/// Pluggable catalog asset downloader. The production implementation is
/// [FtpCatalogAssets]; the settings form accepts a fake for unit tests.
abstract class CatalogAssetDownloader {
  /// Downloads the newest `<asset>-<timestamp>.zip` from
  /// `config.ftpAssetsRemote` on the configured FTP server and extracts it
  /// into [targetDir] (created when missing). Existing files are overwritten.
  /// Returns the [AssetDownloadResult] (`upToDate` when the newest archive was
  /// already applied and [force] is false — no download runs then).
  ///
  /// Throws [DownloadException] on any failure and
  /// [DownloadCancelledException] when [isCancelled] reports cancellation.
  Future<AssetDownloadResult> download({
    required CatalogAsset asset,
    required DesktopConfig config,
    required String targetDir,
    bool force = false,
    String? expectedSha256,
    AssetProgress? onProgress,
    bool Function()? isCancelled,
  });
}

/// Plain-FTP implementation of [CatalogAssetDownloader], built on the
/// `ftpconnect` package (same connection settings as [FtpDownloader]).
class FtpCatalogAssets implements CatalogAssetDownloader {
  const FtpCatalogAssets();

  @override
  Future<AssetDownloadResult> download({
    required CatalogAsset asset,
    required DesktopConfig config,
    required String targetDir,
    bool force = false,
    String? expectedSha256,
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
      // Binary transfer is mandatory for the ZIP archives: `connect()` resets
      // the transfer type to ASCII, and RETR in ASCII mode corrupts binary data.
      await client.setTransferType(TransferType.binary);

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

      // Already have the newest version (and the data is still present): do not
      // download unless explicitly forced.
      if (!force && isAssetUpToDate(targetDir, asset, newest.name)) {
        return AssetDownloadResult(archive: newest.name, upToDate: true);
      }

      temp = File(p.join(Directory.systemTemp.path, newest.name));
      onProgress?.call('Downloading ${newest.name}…', 0, newest.size ?? 0);
      await client.downloadFile(
        newest.name,
        temp,
        onProgress: (percent, done, total) =>
            onProgress?.call('Downloading ${newest.name}…', done, total),
      );
      if (isCancelled?.call() ?? false) {
        throw const DownloadCancelledException();
      }
      final sizeError = downloadSizeError(temp.lengthSync(), newest.size ?? 0);
      if (sizeError != null) throw DownloadException(sizeError);

      onProgress?.call('Extracting ${newest.name}…', 0, 0);
      // Extraction runs in a background isolate (thousands of files) with
      // per-file progress so the UI stays responsive. The message carries the
      // file counter (numbers only for the extraction phase).
      await extractZipWithProgress(
        archivePath: temp.path,
        targetDir: targetDir,
        expectedSha256: expectedSha256,
        onProgress: (done, total) => onProgress?.call(
            'Extracting $done/$total files…', done, total),
        isCancelled: isCancelled,
      );
      onProgress?.call('${asset.label} updated.', 1, 1);
      writeAppliedAssetVersion(targetDir, asset, newest.name);
      return AssetDownloadResult(archive: newest.name, upToDate: false);
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

/// Returns an error message when a downloaded file's [actual] byte count does
/// not match the FTP-reported [expected] size (0 = unknown, not checked), or
/// `null` when it matches. Catches truncated/corrupted transfers before the
/// archive is extracted.
String? downloadSizeError(int actual, int expected) {
  if (expected <= 0 || actual == expected) return null;
  return 'Download incomplete or corrupted '
      '(got $actual of $expected bytes). Please retry.';
}

/// Extracts the ZIP at [archivePath] into [targetDir] in a **background
/// isolate** (the archive holds thousands of PNGs), reporting per-file progress
/// through [onProgress] (`done` out of `total` file entries). The UI isolate
/// stays responsive; [isCancelled] is polled and aborts the extraction.
///
/// Throws [DownloadException] on I/O/archive errors and
/// [DownloadCancelledException] when [isCancelled] reports cancellation.
Future<void> extractZipWithProgress({
  required String archivePath,
  required String targetDir,
  String? expectedSha256,
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  if (isCancelled?.call() ?? false) {
    throw const DownloadCancelledException();
  }

  final receive = ReceivePort();
  final errors = ReceivePort();
  final exited = ReceivePort();
  final completer = Completer<void>();
  Isolate? isolate;
  var cleanedUp = false;
  Timer? cancelTimer;

  void cleanup() {
    if (cleanedUp) return;
    cleanedUp = true;
    cancelTimer?.cancel();
    receive.close();
    errors.close();
    exited.close();
    isolate?.kill(priority: Isolate.immediate);
  }

  receive.listen((message) {
    if (completer.isCompleted) return;
    if (message is List && message.length == 2) {
      onProgress?.call(message[0] as int, message[1] as int);
    } else if (message == 'done') {
      completer.complete();
      cleanup();
    } else if (message is String && message.startsWith('error:')) {
      completer.completeError(DownloadException(message.substring(6)));
      cleanup();
    }
  });
  errors.listen((message) {
    if (completer.isCompleted) return;
    final text = message is List && message.isNotEmpty
        ? '${message.first}'
        : '$message';
    completer.completeError(DownloadException(text));
    cleanup();
  });
  // Safety net: if the isolate dies without sending `done`/`error`, fail
  // instead of waiting forever. The delay lets a pending `done`/`error`
  // message arrive first (ports are not ordered relative to each other).
  exited.listen((_) {
    Future<void>.delayed(const Duration(milliseconds: 100), () {
      if (completer.isCompleted) return;
      completer.completeError(const DownloadException(
          'Extraction stopped unexpectedly (the extractor crashed).'));
      cleanup();
    });
  });

  if (isCancelled != null) {
    cancelTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (completer.isCompleted) return;
      if (isCancelled()) {
        completer.completeError(const DownloadCancelledException());
        cleanup();
      }
    });
  }

  try {
    isolate = await Isolate.spawn(
      _extractZipEntry,
      _ExtractRequest(receive.sendPort, archivePath, targetDir, expectedSha256),
      onError: errors.sendPort,
      onExit: exited.sendPort,
    );
    await completer.future;
  } finally {
    cleanup();
  }
}

/// Message sent to the extraction isolate.
class _ExtractRequest {
  const _ExtractRequest(
      this.port, this.archivePath, this.targetDir, this.expectedSha256);

  final SendPort port;
  final String archivePath;
  final String targetDir;
  final String? expectedSha256;
}

/// Isolate entry point: optionally verifies the archive's sha256, then extracts
/// the ZIP, streaming one file at a time so memory stays bounded, and sends
/// `[done, total]` progress, then `done`, or `error:<message>` on failure.
Future<void> _extractZipEntry(_ExtractRequest request) async {
  final send = request.port;
  InputFileStream? input;
  try {
    final expected = request.expectedSha256;
    if (expected != null && expected.isNotEmpty) {
      final digest =
          await sha256.bind(File(request.archivePath).openRead()).first;
      if (digest.toString().toLowerCase() != expected.toLowerCase()) {
        send.send('error:Checksum mismatch — the downloaded archive is corrupt '
            '(expected ${expected.toLowerCase()}, got $digest).');
        return;
      }
    }

    final root = p.normalize(Directory(request.targetDir).absolute.path);
    Directory(root).createSync(recursive: true);

    input = InputFileStream(request.archivePath);
    final archive = ZipDecoder().decodeBuffer(input);

    // Create the explicit directory entries first (empty dirs in the archive).
    for (final entry in archive.files) {
      if (entry.isFile || entry.name.isEmpty) continue;
      final dir = _safeOutputPath(root, entry.name);
      if (dir != null) Directory(dir).createSync(recursive: true);
    }

    final files = archive.files.where((f) => f.isFile).toList(growable: false);
    final total = files.length;
    send.send(<int>[0, total]);

    // Throttle progress messages (thousands of small files would otherwise
    // flood the UI isolate with one setState per file); the last update is
    // always sent.
    var done = 0;
    var lastSent = 0;
    void report() {
      if (done == total || done - lastSent >= 25) {
        lastSent = done;
        send.send(<int>[done, total]);
      }
    }

    for (final entry in files) {
      final path = _safeOutputPath(root, entry.name);
      if (path == null) {
        done++;
        report();
        continue;
      }
      final output = File(path);
      output.parent.createSync(recursive: true);
      final out = OutputFileStream(path);
      try {
        entry.writeContent(out);
      } finally {
        out.closeSync();
      }
      done++;
      report();
    }
    send.send('done');
  } catch (e) {
    send.send('error:$e');
  } finally {
    input?.closeSync();
  }
}

/// Absolute output path for an archive entry, or `null` when the entry would
/// escape [root] (zip-slip protection).
String? _safeOutputPath(String root, String name) {
  final full = p.normalize(p.join(root, name));
  return p.isWithin(root, full) ? full : null;
}
