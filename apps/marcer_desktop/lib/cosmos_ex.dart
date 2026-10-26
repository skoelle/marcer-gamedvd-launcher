// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

/// Classic ce-atari floppy slot used by "Send to CosmosEx" (user decision
/// 2026-10-26: always slot 0, always activate).
const int kCosmosExSlot = 0;

/// Default cosmo2ex web-interface port (`WEBSERVER_PORT` in its `.env`).
const int kCosmosExWebPort = 8080;

/// Fired with a short human-readable progress message.
typedef CosmosExProgress = void Function(String message);

/// A user-facing "Send to CosmosEx" failure.
class CosmosExException implements Exception {
  const CosmosExException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of a successful send.
class CosmosExSendResult {
  const CosmosExSendResult({required this.mode, required this.message});

  /// `legacy` or `cosmo2ex`.
  final String mode;

  final String message;
}

/// Pluggable sender (the production implementation is [HttpCosmosExUploader];
/// the controller accepts a fake in unit tests).
abstract class CosmosExUploader {
  Future<CosmosExSendResult> send({
    required DesktopConfig config,
    required String zipPath,
    CosmosExProgress? onProgress,
  });
}

/// HTTP implementation for both CosmosEx generations.
///
/// - **legacy** (`ce-atari`): uploads the complete ZIP as multipart field
///   `file` to `POST /api/v1/floppy/0`, then activates slot 0 with
///   `PUT /api/v1/floppy/0`. The device extracts the first `.st/.msa`.
/// - **cosmo2ex**: logs in to its HTTPS web UI, resolves the MAC, extracts the
///   first `.st/.msa` from the ZIP into the configured local/mounted
///   `FLOPPY_IMAGES_DIR` share, reads the device-side directory from
///   `GET /fdd/{mac}/image` and inserts the remote path with
///   `PUT /fdd/{mac}/image`.
class HttpCosmosExUploader implements CosmosExUploader {
  const HttpCosmosExUploader();

  @override
  Future<CosmosExSendResult> send({
    required DesktopConfig config,
    required String zipPath,
    CosmosExProgress? onProgress,
  }) async {
    if (!config.cosmosExConfigured) {
      throw const CosmosExException(
        'CosmosEx host is not configured (Settings → CosmosEx).',
      );
    }
    final file = File(zipPath);
    if (!file.existsSync()) {
      throw CosmosExException('ZIP file not found: $zipPath');
    }
    try {
      switch (config.cosmosExModeNormalized) {
        case 'legacy':
          return await _sendLegacy(config, file, onProgress);
        case 'cosmo2ex':
          return await _sendWeb(config, file, onProgress);
        default:
          if (await _legacyAvailable(config)) {
            return await _sendLegacy(config, file, onProgress);
          }
          if (await _webAvailable(config)) {
            return await _sendWeb(config, file, onProgress);
          }
          throw CosmosExException(
            'No CosmosEx web interface found at ${config.cosmosExHost}. '
            'Check the host/port or select the mode explicitly.',
          );
      }
    } on CosmosExException {
      rethrow;
    } catch (e) {
      throw CosmosExException('CosmosEx request failed: $e');
    }
  }

  // ---------------------------------------------------------------- legacy

  Future<CosmosExSendResult> _sendLegacy(
    DesktopConfig config,
    File zip,
    CosmosExProgress? onProgress,
  ) async {
    final base = _legacyBase(config);
    final uploadUri = _withPath(base, '/api/v1/floppy/$kCosmosExSlot');
    final activateUri = uploadUri;
    final boundary =
        '----MarcerCosmosEx${DateTime.now().microsecondsSinceEpoch}';
    final filename = _safeFileName(p.basename(zip.path));
    final bytes = await zip.readAsBytes();
    final head = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; '
      'filename="$filename"\r\n'
      'Content-Type: application/zip\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final body = <int>[...head, ...bytes, ...tail];

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      onProgress?.call('Uploading ${p.basename(zip.path)} to CosmosEx…');
      final request = await client.postUrl(uploadUri);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'multipart/form-data; boundary=$boundary',
      );
      request.headers.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(
        const Duration(seconds: 120),
      );
      final text = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        throw CosmosExException(
          _httpError('CosmosEx upload', response.statusCode, text),
        );
      }

      onProgress?.call('Activating CosmosEx slot ${kCosmosExSlot + 1}…');
      final activate = await client.putUrl(activateUri);
      activate.headers.contentLength = 0;
      final activated = await activate.close().timeout(
        const Duration(seconds: 20),
      );
      final activateText = await utf8
          .decodeStream(activated)
          .timeout(const Duration(seconds: 20));
      if (activated.statusCode != HttpStatus.ok) {
        throw CosmosExException(
          _httpError(
            'CosmosEx slot activation',
            activated.statusCode,
            activateText,
          ),
        );
      }

      return CosmosExSendResult(
        mode: 'legacy',
        message:
            'Sent ${p.basename(zip.path)} to CosmosEx '
            '(slot ${kCosmosExSlot + 1}).',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _legacyAvailable(DesktopConfig config) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(
        _withPath(_legacyBase(config), '/api/v1/floppy'),
      );
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      final text = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 3));
      return response.statusCode == HttpStatus.ok && text.contains('"slots"');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------- cosmo2ex

  Future<CosmosExSendResult> _sendWeb(
    DesktopConfig config,
    File zip,
    CosmosExProgress? onProgress,
  ) async {
    final password = config.cosmosExPassword.trim();
    if (password.isEmpty) {
      throw const CosmosExException(
        'Set the CosmosEx web-interface password (Settings → CosmosEx).',
      );
    }
    final shareDir = config.cosmosExShareDirectory.trim();
    if (shareDir.isEmpty) {
      throw const CosmosExException(
        'cosmo2ex has no upload API. Configure a local/mounted '
        'FLOPPY_IMAGES_DIR share (Settings → CosmosEx → Share directory).',
      );
    }
    final share = Directory(shareDir);
    if (!share.existsSync()) {
      throw CosmosExException('CosmosEx share directory not found: $shareDir');
    }

    final base = _webBase(config);
    final client = _webClient(base);
    try {
      onProgress?.call('Logging in to CosmosEx…');
      final login = await _jsonRequest(
        client,
        'POST',
        _withPath(base, '/auth/login'),
        body: {'password': password},
      );
      if (login.status == HttpStatus.unauthorized) {
        throw const CosmosExException(
          'CosmosEx login failed — check the web-interface password.',
        );
      }
      if (login.status != HttpStatus.ok) {
        throw CosmosExException(
          _httpError('CosmosEx login', login.status, login.text),
        );
      }
      if (login.json is Map && login.json['mustSetPassword'] == true) {
        throw const CosmosExException(
          'Set a password in the CosmosEx web UI first, then enter it in '
          'Settings → CosmosEx.',
        );
      }
      final token = login.json is Map
          ? (login.json['token'] as String? ?? '')
          : '';
      if (token.isEmpty) {
        throw const CosmosExException(
          'CosmosEx login returned no session token.',
        );
      }

      final mac = await _resolveMac(client, base, config, token);
      final fddPath = '/fdd/${Uri.encodeComponent(mac)}/image';
      onProgress?.call('Reading CosmosEx floppy directory…');
      final info = await _jsonRequest(
        client,
        'GET',
        _withPath(base, fddPath),
        token: token,
      );
      if (info.status == HttpStatus.found ||
          info.status == HttpStatus.unauthorized) {
        throw const CosmosExException(
          'CosmosEx rejected the session — check the web-interface password.',
        );
      }
      if (info.status != HttpStatus.ok) {
        throw CosmosExException(
          _httpError('CosmosEx floppy info', info.status, info.text),
        );
      }
      final defaultDir = info.json is Map
          ? (info.json['defaultDir'] as String? ?? '').trim()
          : '';
      if (defaultDir.isEmpty) {
        throw const CosmosExException(
          'cosmo2ex has no FLOPPY_IMAGES_DIR configured (defaultDir is empty).',
        );
      }

      final image = _firstFloppyImage(zip);
      final sharedName = _sharedImageName(zip.path, image);
      final localPath = p.join(shareDir, sharedName);
      _writeSharedImage(File(localPath), image.bytes);

      final remotePath = _joinRemote(defaultDir, sharedName);
      onProgress?.call('Inserting $sharedName into CosmosEx…');
      final inserted = await _jsonRequest(
        client,
        'PUT',
        _withPath(base, fddPath),
        body: {'image': remotePath},
        token: token,
      );
      if (inserted.status != HttpStatus.noContent &&
          inserted.status != HttpStatus.ok) {
        throw CosmosExException(
          _httpError('CosmosEx floppy insert', inserted.status, inserted.text),
        );
      }

      return CosmosExSendResult(
        mode: 'cosmo2ex',
        message: 'Sent $sharedName to CosmosEx and inserted it.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _resolveMac(
    HttpClient client,
    Uri base,
    DesktopConfig config,
    String token,
  ) async {
    final configured = config.cosmosExMacNormalized;
    if (configured.isNotEmpty) {
      if (configured.length != 12) {
        throw const CosmosExException(
          'CosmosEx MAC must be 12 hex characters (with or without colons).',
        );
      }
      return configured;
    }

    final response = await _jsonRequest(
      client,
      'GET',
      _withPath(base, '/devices'),
      token: token,
    );
    if (response.status == HttpStatus.found ||
        response.status == HttpStatus.unauthorized) {
      throw const CosmosExException(
        'CosmosEx rejected the session — check the web-interface password.',
      );
    }
    if (response.status != HttpStatus.ok) {
      throw CosmosExException(
        _httpError('CosmosEx device list', response.status, response.text),
      );
    }
    final list = response.json;
    final macs = <String>[];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final mac = item['mac'];
        if (mac is! String) continue;
        final normalized = mac
            .replaceAll(RegExp(r'[^0-9a-fA-F]'), '')
            .toLowerCase();
        if (normalized.length == 12) macs.add(normalized);
      }
    }
    if (macs.isEmpty) {
      throw const CosmosExException('No CosmosEx device found.');
    }
    if (macs.length > 1) {
      throw const CosmosExException(
        'Multiple CosmosEx devices found — set the MAC in '
        'Settings → CosmosEx.',
      );
    }
    return macs.first;
  }

  Future<bool> _webAvailable(DesktopConfig config) async {
    final Uri base;
    try {
      base = _webBase(config);
    } on CosmosExException {
      return false;
    }
    final client = _webClient(base);
    try {
      // `/ca.crt` is public in cosmo2ex and identifies the new web UI
      // (legacy ce-atari has no such endpoint).
      final request = await client.getUrl(_withPath(base, '/ca.crt'));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      await response.drain<void>().timeout(const Duration(seconds: 3));
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------- helpers

  Uri _legacyBase(DesktopConfig config) {
    var raw = config.cosmosExHost.trim();
    if (raw.isEmpty) {
      throw const CosmosExException('CosmosEx host is not configured.');
    }
    if (!raw.contains('://')) raw = 'http://$raw';
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      throw CosmosExException('Invalid CosmosEx host: ${config.cosmosExHost}');
    }
    return uri.replace(path: '', query: null, fragment: null);
  }

  Uri _webBase(DesktopConfig config) {
    var raw = config.cosmosExHost.trim();
    if (raw.isEmpty) {
      throw const CosmosExException('CosmosEx host is not configured.');
    }
    if (!raw.contains('://')) raw = 'https://$raw';
    var uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) {
      throw CosmosExException('Invalid CosmosEx host: ${config.cosmosExHost}');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw CosmosExException(
        'CosmosEx host must use http:// or https://: ${config.cosmosExHost}',
      );
    }
    if (uri.scheme == 'https' && !uri.hasPort) {
      uri = uri.replace(port: kCosmosExWebPort);
    }
    return uri.replace(path: '', query: null, fragment: null);
  }

  HttpClient _webClient(Uri base) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    // cosmo2ex uses a self-signed certificate; accept it only for the
    // configured host (never for arbitrary hosts).
    client.badCertificateCallback = (cert, host, port) => host == base.host;
    return client;
  }

  Uri _withPath(Uri base, String path) => base.replace(path: path);

  Future<_JsonResponse> _jsonRequest(
    HttpClient client,
    String method,
    Uri uri, {
    Object? body,
    String? token,
  }) async {
    final request = await client.openUrl(method, uri);
    // Surface the auth middleware's login redirect as a status instead of
    // silently following it to an HTML page.
    request.followRedirects = false;
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await utf8
        .decodeStream(response)
        .timeout(const Duration(seconds: 20));
    dynamic decoded;
    if (text.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = null;
      }
    }
    return _JsonResponse(response.statusCode, decoded, text);
  }

  String _httpError(String what, int status, String body) {
    final detail = body.trim();
    return '$what failed (HTTP $status)'
        '${detail.isEmpty ? '' : ': ${_shorten(detail)}'}';
  }

  String _shorten(String text) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 200 ? oneLine : '${oneLine.substring(0, 200)}…';
  }

  String _safeFileName(String name) {
    final safe = name.replaceAll(RegExp(r'[\r\n"\\/]'), '_').trim();
    return safe.isEmpty ? 'game.zip' : safe;
  }

  _SharedImage _firstFloppyImage(File zip) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    } catch (e) {
      throw CosmosExException('Cannot read ZIP ${zip.path}: $e');
    }
    final images = archive.files.where((f) {
      if (!f.isFile) return false;
      final ext = p.extension(f.name).toLowerCase();
      return ext == '.st' || ext == '.msa';
    }).toList();
    if (images.isEmpty) {
      throw const CosmosExException(
        'ZIP contains no .st/.msa floppy image for cosmo2ex.',
      );
    }
    images.sort((a, b) {
      final byDisk = _diskIndex(a.name).compareTo(_diskIndex(b.name));
      if (byDisk != 0) return byDisk;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    final entry = images.first;
    final content = entry.content;
    final bytes = content is List<int> ? content : const <int>[];
    if (bytes.isEmpty) {
      throw CosmosExException('Floppy image ${entry.name} is empty.');
    }
    return _SharedImage(entry.name, bytes);
  }

  int _diskIndex(String name) {
    final base = p
        .basenameWithoutExtension(name)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    final match = RegExp(r'(\d+)$').firstMatch(base);
    if (match != null) return int.parse(match.group(1)!);
    if (base.endsWith('a')) return 1;
    if (base.endsWith('b')) return 2;
    return 99;
  }

  String _sharedImageName(String zipPath, _SharedImage image) {
    final stem = p
        .basenameWithoutExtension(zipPath)
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final shortStem = stem.isEmpty
        ? 'game'
        : (stem.length <= 48 ? stem : stem.substring(0, 48));
    final ext = p.extension(image.name).toLowerCase();
    final hash = sha1.convert(image.bytes).toString().substring(0, 8);
    return 'marcer-$shortStem-$hash$ext';
  }

  void _writeSharedImage(File target, List<int> bytes) {
    final tmp = File('${target.path}.tmp-$pid');
    tmp.writeAsBytesSync(bytes, flush: true);
    try {
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(target.path);
    } catch (_) {
      // Some SMB mounts do not support rename-over; fall back to a direct
      // write so the image still reaches the share.
      target.writeAsBytesSync(bytes, flush: true);
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }

  String _joinRemote(String dir, String name) {
    final normalized = dir.replaceAll('\\', '/');
    return normalized.endsWith('/') ? '$normalized$name' : '$normalized/$name';
  }
}

class _JsonResponse {
  const _JsonResponse(this.status, this.json, this.text);

  final int status;
  final dynamic json;
  final String text;
}

class _SharedImage {
  const _SharedImage(this.name, this.bytes);

  final String name;
  final List<int> bytes;
}
