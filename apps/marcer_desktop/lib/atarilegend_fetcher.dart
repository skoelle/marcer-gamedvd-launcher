// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

/// AtariLegend weekly database dumps directory.
const String kAtariLegendDumpsUrl =
    'https://www.atarilegend.com/data/database-dumps/';

/// Progress callback: a phase [message] plus progress (bytes during download,
/// 0/0 while unknown).
typedef AtariLegendProgress = void Function(String message, int done, int total);

/// Outcome of a successful AtariLegend data fetch.
class AtariLegendFetchResult {
  const AtariLegendFetchResult({
    required this.games,
    required this.dumpFile,
    required this.cachePath,
  });

  final int games;
  final String dumpFile;
  final String cachePath;
}

/// Thrown when the user cancels the download.
class AtariLegendFetchCancelled implements Exception {
  const AtariLegendFetchCancelled();
}

/// Thrown for any other fetch/parse failure.
class AtariLegendFetchException implements Exception {
  const AtariLegendFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Fetches the newest AtariLegend dump and writes the compact cache
/// (`atarilegend.json`) into the target directory. Injectable for tests.
abstract class AtariLegendFetcher {
  Future<AtariLegendFetchResult> fetch({
    required String targetDir,
    AtariLegendProgress? onProgress,
    bool Function()? isCancelled,
  });

  /// Resolves the newest remote dump file name (`YYYY-MM-DD.sql.gz`) without
  /// downloading it. Used by the **manual** Catalog-data check.
  Future<String?> latestDump();
}

/// HTTP implementation: directory listing → latest `.sql.gz` → download →
/// gunzip + parse in a background isolate → atomic cache write → delete dump.
class HttpAtariLegendFetcher implements AtariLegendFetcher {
  const HttpAtariLegendFetcher({this.dumpsUrl = kAtariLegendDumpsUrl});

  final String dumpsUrl;

  @override
  Future<String?> latestDump() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final listing = await _getText(client, Uri.parse(dumpsUrl), noCache: true);
      return newestDumpName(listing);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<AtariLegendFetchResult> fetch({
    required String targetDir,
    AtariLegendProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = Directory(targetDir);
    await dir.create(recursive: true);

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    // The dump is gzip; keep the raw bytes (the server may advertise it as
    // `Content-Encoding: gzip`, which would otherwise be decompressed
    // transparently and break gzip.decode plus the progress display).
    final dumpClient = HttpClient()..autoUncompress = false;
    dumpClient.connectionTimeout = const Duration(seconds: 20);
    File? tmpDump;
    try {
      onProgress?.call('Resolving latest dump…', 0, 0);
      final listing = await _getText(client, Uri.parse(dumpsUrl));
      final dumpFile = newestDumpName(listing);
      if (dumpFile == null) {
        throw const AtariLegendFetchException(
            'No YYYY-MM-DD.sql.gz found in the AtariLegend listing.');
      }

      final url = Uri.parse(dumpsUrl).resolve(dumpFile);
      onProgress?.call('Downloading $dumpFile…', 0, 0);
      tmpDump = File(p.join(targetDir, '$dumpFile.part'));
      final total = await _download(dumpClient, url, tmpDump,
          onProgress: onProgress, isCancelled: isCancelled);
      if (total == 0) {
        onProgress?.call('Downloaded $dumpFile', 0, 0);
      }

      final bytes = await tmpDump.readAsBytes();
      onProgress?.call('Extracting and parsing…', 0, 0);
      final dumpDate =
          dumpFile.endsWith('.sql.gz') ? dumpFile.substring(0, 10) : '';
      final parsed = await Isolate.run(() {
        final sql = decodeAtariLegendDump(bytes);
        final generatedAt = DateTime.now().toUtc().toIso8601String();
        final texts = parseAtariLegendTexts(
          sql,
          generatedAt: generatedAt,
          sourceFile: dumpFile,
          dumpDate: dumpDate,
        );
        final counts = {
          for (final e in texts.games.entries)
            e.key: (
              reviews: e.value.reviews.length,
              comments: e.value.comments.length,
              magazines: e.value.magazines.length,
            ),
        };
        final cache = parseAtariLegendCache(
          sql,
          generatedAt: generatedAt,
          sourceFile: dumpFile,
          dumpDate: dumpDate,
          textCounts: counts,
        );
        return (cache, texts);
      });
      final cache = parsed.$1;
      final texts = parsed.$2;

      onProgress?.call('Writing cache…', 0, 0);
      final cachePath = p.join(targetDir, kAtariLegendFileName);
      await _writeAtomic(cachePath, cache.toJsonString());
      await _writeAtomic(
          p.join(targetDir, kAtariLegendTextsFileName), texts.toJsonString());

      return AtariLegendFetchResult(
        games: cache.games.length,
        dumpFile: dumpFile,
        cachePath: cachePath,
      );
    } on AtariLegendFetchCancelled {
      rethrow;
    } on AtariLegendFetchException {
      rethrow;
    } catch (e) {
      throw AtariLegendFetchException('AtariLegend fetch failed: $e');
    } finally {
      client.close(force: true);
      dumpClient.close(force: true);
      if (tmpDump != null && await tmpDump.exists()) {
        try {
          await tmpDump.delete();
        } catch (_) {
          // best effort
        }
      }
    }
  }

  Future<void> _writeAtomic(String path, String content) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(content, flush: true);
    final target = File(path);
    if (await target.exists()) await target.delete();
    await tmp.rename(path);
  }

  Future<String> _getText(HttpClient client, Uri url,
      {bool noCache = false}) async {
    final req = await client.getUrl(url);
    req.headers.add(HttpHeaders.userAgentHeader, 'MarcerGameDVDLauncher');
    if (noCache) {
      req.headers.add(HttpHeaders.cacheControlHeader, 'no-cache');
    }
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw AtariLegendFetchException('HTTP ${resp.statusCode} for $url');
    }
    return resp.transform(utf8.decoder).join();
  }

  Future<int> _download(
    HttpClient client,
    Uri url,
    File target, {
    AtariLegendProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    final req = await client.getUrl(url);
    req.headers.add(HttpHeaders.userAgentHeader, 'MarcerGameDVDLauncher');
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw AtariLegendFetchException('HTTP ${resp.statusCode} for $url');
    }
    final total = resp.contentLength;
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in resp) {
        if (isCancelled?.call() ?? false) {
          throw const AtariLegendFetchCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call('Downloading…', received, total);
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return received;
  }
}
