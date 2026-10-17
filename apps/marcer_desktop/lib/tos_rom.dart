// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

/// One downloadable TOS ROM image, offered when `TOS.IMG` (expected by the
/// bundled `MarcerGameDvd-Hatari.cfg`) is missing.
class TosRomOption {
  const TosRomOption(this.version, this.language, this.url);

  /// TOS version (`1.02`, `1.04`).
  final String version;

  /// Language label (`English (UK)`, `Deutsch`).
  final String language;

  /// Direct download URL of the ZIP archive containing the ROM image.
  final String url;

  /// Dropdown label (`English (UK) — TOS 1.04`).
  String get label => '$language — TOS $version';

  @override
  String toString() => label;
}

/// The offered TOS options (user decision 2026-10-17): language first, English
/// (UK) before Deutsch, newer version first. Only TOS 1.02 and 1.04, only the
/// English (UK) and German variants.
const List<TosRomOption> kTosRomOptions = [
  TosRomOption('1.04', 'English (UK)',
      'https://www.atariworld.org/files/images/tos104uk.zip'),
  TosRomOption('1.02', 'English (UK)',
      'https://www.atariworld.org/files/images/tos102uk.zip'),
  TosRomOption('1.04', 'Deutsch',
      'https://www.atariworld.org/files/images/tos104de.zip'),
  TosRomOption('1.02', 'Deutsch',
      'https://www.atariworld.org/files/images/tos102de.zip'),
];

/// Default selection of the TOS dropdown.
const TosRomOption kDefaultTosRomOption = TosRomOption(
    '1.04', 'English (UK)',
    'https://www.atariworld.org/files/images/tos104uk.zip');

/// Source page of the TOS ROM images (attribution in the download dialog).
const String kTosRomSourceUrl = 'https://www.atariworld.org/tos-rom/';

/// File name of the TOS image the bundled Hatari config expects
/// (`szTosImageFileName = TOS.IMG`, resolved relative to Hatari's working
/// directory = the executable directory).
const String kTosImageFileName = 'TOS.IMG';

/// Directory Hatari looks for the TOS image in: the executable directory
/// (`config.appDir`), falling back to the current working directory when unset
/// (e.g. a dev run).
String tosTargetDirectory(DesktopConfig config) =>
    config.appDir.isNotEmpty ? config.appDir : Directory.current.path;

/// Absolute path of the TOS image Hatari looks for: `<appDir>/TOS.IMG`.
String tosImagePath(DesktopConfig config) =>
    p.join(tosTargetDirectory(config), kTosImageFileName);

/// True when the TOS image exists next to the app.
bool tosInstalled(DesktopConfig config) => File(tosImagePath(config)).existsSync();

/// A TOS ROM download failed (network, HTTP status, or no ROM in the archive).
class TosRomException implements Exception {
  const TosRomException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The user cancelled the download.
class TosRomCancelledException implements Exception {
  const TosRomCancelledException();
}

/// Progress callback: a coarse [message] plus byte progress when known
/// ([total] is 0 when unknown).
typedef TosRomProgress = void Function(String message, int done, int total);

/// The ROM file entry of a decoded archive: prefers a `.img`/`.rom`/`.bin`
/// file, otherwise the largest file. Returns the entry name and its bytes, or
/// `null` when the archive has no file entries.
({String name, List<int> bytes})? pickTosRomEntry(Archive archive) {
  final files = archive.files.where((f) => f.isFile && f.size > 0).toList();
  if (files.isEmpty) return null;
  final romPattern = RegExp(r'\.(img|rom|bin|tos)$', caseSensitive: false);
  final roms = files.where((f) => romPattern.hasMatch(f.name)).toList();
  final pool = roms.isNotEmpty ? roms : files;
  pool.sort((a, b) => b.size.compareTo(a.size));
  final entry = pool.first;
  final content = entry.content;
  final bytes = content is List<int> ? content : const <int>[];
  return (name: entry.name, bytes: bytes);
}

/// Extracts the ROM from [zipBytes] and writes it as `<targetDir>/TOS.IMG`
/// (the target directory is created when missing). Returns the source entry
/// name. Throws [TosRomException] when the ZIP is invalid or has no ROM file.
String writeTosImageFromZip(List<int> zipBytes, String targetDir) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipBytes);
  } catch (e) {
    throw TosRomException('Downloaded file is not a valid ZIP archive: $e');
  }
  final entry = pickTosRomEntry(archive);
  if (entry == null) {
    throw const TosRomException('No ROM file found in the downloaded archive.');
  }
  Directory(targetDir).createSync(recursive: true);
  File(p.join(targetDir, kTosImageFileName)).writeAsBytesSync(entry.bytes);
  return entry.name;
}

/// Pluggable TOS ROM downloader (the production implementation is
/// [HttpTosRomDownloader]; the dialog accepts a fake for unit tests).
abstract class TosRomDownloader {
  /// Downloads [option] and writes it as `<targetDir>/TOS.IMG`. Throws
  /// [TosRomException] on failure and [TosRomCancelledException] when
  /// [isCancelled] reports cancellation.
  Future<void> download(
    TosRomOption option,
    String targetDir, {
    TosRomProgress? onProgress,
    bool Function()? isCancelled,
  });
}

/// `dart:io` HTTP implementation (follows redirects; the atariworld.org
/// `download.php` links redirect to the actual `*.zip`).
class HttpTosRomDownloader implements TosRomDownloader {
  const HttpTosRomDownloader();

  @override
  Future<void> download(
    TosRomOption option,
    String targetDir, {
    TosRomProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = HttpClient();
    try {
      onProgress?.call('Connecting…', 0, 0);
      final request = await client.getUrl(Uri.parse(option.url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw TosRomException(
            'Download failed (HTTP ${response.statusCode}).');
      }
      final total = response.contentLength;
      final bytes = <int>[];
      await for (final chunk in response) {
        if (isCancelled?.call() ?? false) {
          throw const TosRomCancelledException();
        }
        bytes.addAll(chunk);
        onProgress?.call('Downloading ${option.label}…', bytes.length,
            total < 0 ? 0 : total);
      }
      if (isCancelled?.call() ?? false) {
        throw const TosRomCancelledException();
      }
      onProgress?.call('Extracting…', 0, 0);
      writeTosImageFromZip(bytes, targetDir);
      onProgress?.call('TOS ROM installed.', 0, 0);
    } on TosRomException {
      rethrow;
    } on TosRomCancelledException {
      rethrow;
    } catch (e) {
      throw TosRomException('$e');
    } finally {
      client.close(force: true);
    }
  }
}
