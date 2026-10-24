// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

import 'ftp_downloader.dart';
import 'piratefinder_names.dart';

/// Fixed GitHub release/tag publishing the generic PirateFinder catalogue
/// JSON (`https://github.com/skoelle/piratefinder-catalog-json`).
const String kPirateFinderDataRepo = 'skoelle/piratefinder-catalog-json';
const String kPirateFinderDataTag = 'catalog-latest';

/// Original PirateFinder project (the catalogue's upstream source).
const String kPirateFinderProjectUrl =
    'https://github.com/peteclarke-del/PirateFinder';

/// Platform asset used by the desktop app (the Atari ST catalogue).
const String kPirateFinderPlatform = 'atari-st';

/// Marker file written after a successful download. It records which
/// catalogue build/asset was applied; the data itself is a PF-only JSON.
const String kPirateFinderMarkerFileName = '.piratefinder-catalog.json';

/// URL of the small pointer asset with the source tag, date and asset SHA-256.
String pirateFinderLatestUrl() =>
    'https://github.com/$kPirateFinderDataRepo/releases/download/'
    '$kPirateFinderDataTag/latest.json';

/// URL of one catalogue asset from the fixed release.
String pirateFinderAssetUrl(String file) =>
    'https://github.com/$kPirateFinderDataRepo/releases/download/'
    '$kPirateFinderDataTag/$file';

/// One remote asset from `latest.json`.
class PirateFinderRemoteAsset {
  const PirateFinderRemoteAsset({
    required this.file,
    this.size,
    this.sha256,
    this.counts = const {},
  });

  final String file;
  final int? size;
  final String? sha256;
  final Map<String, dynamic> counts;

  factory PirateFinderRemoteAsset.fromJson(Map<String, dynamic> json) {
    final counts = json['counts'];
    return PirateFinderRemoteAsset(
      file: (json['file'] as String?)?.trim() ?? '',
      size: (json['size'] as num?)?.toInt(),
      sha256: (json['sha256'] as String?)?.trim(),
      counts: counts is Map
          ? Map<String, dynamic>.from(counts)
          : const <String, dynamic>{},
    );
  }
}

/// Parsed PF `latest.json`.
class PirateFinderLatest {
  const PirateFinderLatest({
    required this.generatedAt,
    required this.sourceTag,
    required this.sourceCommit,
    required this.assets,
  });

  final String generatedAt;
  final String sourceTag;
  final String sourceCommit;
  final Map<String, PirateFinderRemoteAsset> assets;

  PirateFinderRemoteAsset? get atariSt => assets[kPirateFinderPlatform];
}

/// Parses `latest.json`; `null` on malformed input.
PirateFinderLatest? parsePirateFinderLatest(String body) {
  try {
    final map = jsonDecode(body) as Map<String, dynamic>;
    final source = map['source'];
    final assets = <String, PirateFinderRemoteAsset>{};
    final rawAssets = map['assets'];
    if (rawAssets is Map) {
      for (final entry in rawAssets.entries) {
        final value = entry.value;
        if (value is Map) {
          assets[entry.key.toString()] = PirateFinderRemoteAsset.fromJson(
            Map<String, dynamic>.from(value),
          );
        }
      }
    }
    return PirateFinderLatest(
      generatedAt: (map['generated_at'] as String?)?.trim() ?? '',
      sourceTag: source is Map ? (source['tag'] as String?)?.trim() ?? '' : '',
      sourceCommit: source is Map
          ? (source['commit'] as String?)?.trim() ?? ''
          : '',
      assets: assets,
    );
  } catch (_) {
    return null;
  }
}

/// The local marker of an applied PF data asset.
class PirateFinderLocalVersion {
  const PirateFinderLocalVersion({
    required this.sourceTag,
    required this.generatedAt,
    required this.asset,
    required this.sha256,
    required this.appliedAt,
  });

  final String sourceTag;
  final String generatedAt;
  final String asset;
  final String sha256;
  final String appliedAt;

  factory PirateFinderLocalVersion.fromJson(Map<String, dynamic> json) =>
      PirateFinderLocalVersion(
        sourceTag: (json['source_tag'] as String?)?.trim() ?? '',
        generatedAt: (json['generated_at'] as String?)?.trim() ?? '',
        asset: (json['asset'] as String?)?.trim() ?? '',
        sha256: (json['sha256'] as String?)?.trim() ?? '',
        appliedAt: (json['applied_at'] as String?)?.trim() ?? '',
      );

  Map<String, dynamic> toJson() => {
    'source_tag': sourceTag,
    'generated_at': generatedAt,
    'asset': asset,
    'sha256': sha256,
    'applied_at': appliedAt,
  };
}

/// PF catalogue directory under the shared data directory
/// (`<DataDir>/piratefinder`). Empty when no data directory is configured.
String pirateFinderDataDir(DesktopConfig config) =>
    config.resolvePirateFinderDirectory();

String pirateFinderMarkerPath(String dataDir) =>
    p.join(dataDir, kPirateFinderMarkerFileName);

PirateFinderLocalVersion? readPirateFinderLocal(String dataDir) {
  final file = File(pirateFinderMarkerPath(dataDir));
  if (!file.existsSync()) return null;
  try {
    final map = jsonDecode(file.readAsStringSync());
    if (map is! Map) return null;
    return PirateFinderLocalVersion.fromJson(Map<String, dynamic>.from(map));
  } catch (_) {
    return null;
  }
}

void writePirateFinderLocal(String dataDir, PirateFinderLocalVersion version) {
  Directory(dataDir).createSync(recursive: true);
  File(pirateFinderMarkerPath(dataDir)).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(version.toJson())}\n',
  );
}

/// True when the applied asset file is still present.
bool pirateFinderDataPresent(String dataDir, PirateFinderLocalVersion? local) =>
    local != null &&
    File(p.join(dataDir, p.basename(local.asset))).existsSync();

/// True when [latest] offers an asset different from the applied marker, or
/// when the local data is missing.
bool pirateFinderNeedsUpdate({
  PirateFinderLatest? latest,
  PirateFinderLocalVersion? local,
  required bool dataPresent,
}) {
  final remote = latest?.atariSt;
  if (remote == null || remote.file.isEmpty) return false;
  if (local == null) return true;
  final remoteSha = remote.sha256?.toLowerCase();
  if (remoteSha != null && remoteSha.isNotEmpty) {
    return remoteSha != local.sha256.toLowerCase() || !dataPresent;
  }
  return remote.file != local.asset ||
      (latest?.generatedAt.isNotEmpty == true &&
          latest!.generatedAt != local.generatedAt) ||
      !dataPresent;
}

/// Fetches the `latest.json` body (injectable for tests).
typedef PirateFinderLatestFetcher = Future<String> Function(Uri url);

Future<String> httpPirateFinderLatestFetcher(Uri url) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(url);
    request.headers.add(HttpHeaders.userAgentHeader, 'MarcerGameDVDLauncher');
    request.headers.add(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

typedef PirateFinderProgress = void Function(
  String message,
  int done,
  int total,
);

/// Parses the catalogue in a background isolate.
///
/// Kept top-level so the isolate closure captures only [path]; a closure
/// created inside the controller would capture `this` (and its listener /
/// service graph), which is not sendable.
Future<PirateFinderIndex> _parsePirateFinderIndexInIsolate(String path) =>
    Isolate.run(() => PirateFinderIndex.fromGzipFile(path));

/// Downloads one PF catalogue asset (injectable for tests).
abstract class PirateFinderDownloader {
  Future<void> download({
    required PirateFinderRemoteAsset asset,
    required String targetDir,
    PirateFinderProgress? onProgress,
    bool Function()? isCancelled,
  });
}

/// Plain HTTPS download from the fixed GitHub release; verifies SHA-256.
class HttpPirateFinderDownloader implements PirateFinderDownloader {
  const HttpPirateFinderDownloader();

  @override
  Future<void> download({
    required PirateFinderRemoteAsset asset,
    required String targetDir,
    PirateFinderProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (asset.file.isEmpty) {
      throw ArgumentError(
        'The $kPirateFinderCatalogShortName asset has no file name.',
      );
    }
    final directory = Directory(targetDir)..createSync(recursive: true);
    final destination = File(p.join(directory.path, p.basename(asset.file)));
    final part = File('${destination.path}.part');
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(
        Uri.parse(pirateFinderAssetUrl(asset.file)),
      );
      request.headers.add(HttpHeaders.userAgentHeader, 'MarcerGameDVDLauncher');
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : (asset.size ?? 0);
      final sink = part.openWrite();
      var done = 0;
      try {
        await for (final chunk in response) {
          if (isCancelled?.call() == true) {
            throw const DownloadCancelledException();
          }
          sink.add(chunk);
          done += chunk.length;
          onProgress?.call(
            'Downloading $kPirateFinderCatalogShortName…',
            done,
            total,
          );
        }
      } finally {
        await sink.close();
      }
      final actual = (await sha256.bind(part.openRead()).first).toString();
      final expected = asset.sha256;
      if (expected != null &&
          expected.isNotEmpty &&
          actual.toLowerCase() != expected.toLowerCase()) {
        throw Exception('SHA-256 mismatch (got $actual, expected $expected).');
      }
      if (destination.existsSync()) destination.deleteSync();
      part.renameSync(destination.path);
    } finally {
      client.close(force: true);
      if (part.existsSync()) {
        try {
          part.deleteSync();
        } catch (_) {
          // Best effort cleanup of a partial download.
        }
      }
    }
  }
}

/// Download/update state for the optional PF catalogue JSON.
///
/// The data is app-managed and downloaded from the generic
/// `piratefinder-catalog-json` GitHub release. It is never written into the
/// Marcer catalog directories and is only offered (never applied silently).
class PirateFinderDataController extends ChangeNotifier {
  PirateFinderDataController({
    PirateFinderLatestFetcher? fetcher,
    PirateFinderDownloader? downloader,
  }) : _fetch = fetcher ?? httpPirateFinderLatestFetcher,
       _downloader = downloader ?? const HttpPirateFinderDownloader();

  /// The startup check runs in release builds only (manual checks always work).
  static const bool enabled = bool.fromEnvironment('RELEASE_BUILD');

  final PirateFinderLatestFetcher _fetch;
  final PirateFinderDownloader _downloader;

  DesktopConfig config = DesktopConfig(rootDirectory: '');

  PirateFinderLatest? latest;
  PirateFinderLocalVersion? local;
  String? error;
  bool checking = false;
  bool downloading = false;
  bool indexLoading = false;
  String? indexError;
  PirateFinderIndex? _index;
  Future<PirateFinderIndex?>? _indexFuture;
  String message = '';
  int done = 0;
  int total = 0;
  bool _disposed = false;

  String get dataDir => pirateFinderDataDir(config);
  PirateFinderRemoteAsset? get remote => latest?.atariSt;
  bool get busy => checking || downloading;

  bool get dataPresent => pirateFinderDataPresent(dataDir, local);

  bool get hasPending => pirateFinderNeedsUpdate(
    latest: latest,
    local: local,
    dataPresent: dataPresent,
  );

  void refreshLocal() {
    local = dataDir.isEmpty ? null : readPirateFinderLocal(dataDir);
  }

  /// Drops a parsed index (data update or config change).
  void invalidateIndex() {
    _index = null;
    _indexFuture = null;
    indexError = null;
  }

  bool get hasIndex => _index != null;

  /// Parsed catalog, once [ensureIndex] has completed.
  PirateFinderIndex? get index => _index;

  /// Parses the downloaded PF JSON on first use, in a background isolate.
  Future<PirateFinderIndex?> ensureIndex({bool force = false}) {
    if (_index != null && !force) return Future.value(_index);
    if (_indexFuture != null) return _indexFuture!;
    final current = local;
    if (current == null || downloading) return Future.value(null);
    final path = p.join(dataDir, p.basename(current.asset));
    if (!File(path).existsSync()) return Future.value(null);
    indexLoading = true;
    indexError = null;
    final future = () async {
      try {
        final value = await _parsePirateFinderIndexInIsolate(path);
        _index = value;
        return value;
      } catch (e) {
        indexError = 'Could not read $kPirateFinderCatalogShortName: $e';
        return null;
      } finally {
        indexLoading = false;
        _indexFuture = null;
        _notify();
      }
    }();
    _indexFuture = future;
    return future;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Fetches the remote pointer; silent on failure until [error] is read.
  /// [force] bypasses the release-build gate (tests / manual checks).
  Future<void> check({bool force = false}) async {
    if (!enabled && !force) return;
    if (checking || downloading) return;
    checking = true;
    error = null;
    refreshLocal();
    _notify();
    try {
      final body = await _fetch(Uri.parse(pirateFinderLatestUrl()));
      final parsed = parsePirateFinderLatest(body);
      if (parsed == null) {
        throw const FormatException('invalid latest.json');
      }
      latest = parsed;
    } catch (e) {
      error = 'Could not check $kPirateFinderCatalogShortName: $e';
    } finally {
      checking = false;
      refreshLocal();
      _notify();
    }
  }

  /// Downloads the configured platform asset and records the local marker.
  Future<bool> update({bool Function()? isCancelled}) async {
    final asset = remote;
    if (asset == null || downloading || checking) return false;
    if (dataDir.isEmpty) {
      error = 'Set a data directory first.';
      _notify();
      return false;
    }
    downloading = true;
    error = null;
    message = 'Starting…';
    done = 0;
    total = asset.size ?? 0;
    _notify();
    try {
      await _downloader.download(
        asset: asset,
        targetDir: dataDir,
        onProgress: (nextMessage, nextDone, nextTotal) {
          message = nextMessage;
          done = nextDone;
          total = nextTotal;
          _notify();
        },
        isCancelled: isCancelled ?? () => false,
      );
      final applied = PirateFinderLocalVersion(
        sourceTag: latest?.sourceTag ?? '',
        generatedAt: latest?.generatedAt ?? '',
        asset: p.basename(asset.file),
        sha256: asset.sha256 ?? '',
        appliedAt: DateTime.now().toUtc().toIso8601String(),
      );
      writePirateFinderLocal(dataDir, applied);
      local = applied;
      invalidateIndex();
      return true;
    } on DownloadCancelledException {
      error = '$kPirateFinderCatalogShortName download cancelled.';
      return false;
    } catch (e) {
      error = '$kPirateFinderCatalogShortName download failed: $e';
      return false;
    } finally {
      downloading = false;
      message = '';
      _notify();
    }
  }

  /// Refreshes the remote pointer and downloads the newest Atari ST asset.
  ///
  /// Used by the settings row's single "PirateFinder-Catalog" action:
  /// it always checks for the newest catalogue first, then overwrites the
  /// local data. Returns `false` (with [error] set) when the check or the
  /// download fails.
  Future<bool> downloadLatest({bool Function()? isCancelled}) async {
    if (busy) return false;
    await check(force: true);
    if (error != null) return false;
    if (remote == null) {
      error = 'No $kPirateFinderCatalogShortName Atari ST data available.';
      _notify();
      return false;
    }
    return update(isCancelled: isCancelled);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
