// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// Pinned Hatari release the installer offers (Stufe 1: prebuilt Windows and
/// macOS binaries taken from the official SourceForge project). Linux has no
/// official prebuilt binary, so [hatariBuildFor] returns `null` there and the
/// user has to install Hatari via the distribution / a system package.
///
/// Bump [kHatariVersion] (and the URLs below) when a new Hatari release with
/// prebuilt binaries is published.
const String kHatariVersion = '2.6.1';

/// Project page of Hatari (attribution in the install dialog; GPL-2.0).
const String kHatariSourceUrl = 'https://www.hatari-emu.org/';

/// Sub-directory of the application directory the prebuilt Hatari is unpacked
/// into (`<appDir>/hatari`). It sits next to `TOS.IMG` and is not part of the
/// release ZIP, so a self-update never touches it.
const String kHatariInstallSubdir = 'hatari';

/// One platform's prebuilt Hatari archive.
class HatariBuild {
  const HatariBuild({
    required this.os,
    required this.label,
    required this.url,
    this.sha256,
  });

  /// [Platform.operatingSystem] value (`windows`, `macos`).
  final String os;

  /// Human-readable label shown in the dialog.
  final String label;

  /// Direct download URL of the ZIP archive.
  final String url;

  /// Optional SHA-256 of the archive (SourceForge publishes none, so it stays
  /// `null` for now and the check is skipped).
  final String? sha256;

  @override
  String toString() => label;
}

/// The prebuilt releases offered (Stufe 1: Windows + macOS).
final List<HatariBuild> kHatariBuilds = [
  HatariBuild(
    os: 'windows',
    label: 'Windows (x64)',
    url:
        'https://sourceforge.net/projects/hatari/files/hatari/$kHatariVersion/hatari-${kHatariVersion}_windows64.zip/download',
  ),
  HatariBuild(
    os: 'macos',
    label: 'macOS (universal)',
    url:
        'https://sourceforge.net/projects/hatari/files/hatari/$kHatariVersion/hatari-${kHatariVersion}_macos.zip/download',
  ),
];

/// The prebuilt build for [os] (`Platform.operatingSystem` when omitted), or
/// `null` when none is offered (e.g. Linux).
HatariBuild? hatariBuildFor({String? os}) {
  final key = os ?? Platform.operatingSystem;
  for (final build in kHatariBuilds) {
    if (build.os == key) return build;
  }
  return null;
}

/// Base directory Hatari is installed relative to: the shared per-user data
/// directory ([downloadedDataDir]) — on macOS `~/Library/Application Support/…`
/// (never inside the `.app` bundle), elsewhere the app directory / CWD.
String hatariBaseDir(DesktopConfig config) => downloadedDataDir(config);

/// Absolute directory the prebuilt Hatari is unpacked into.
String hatariInstallDir(DesktopConfig config) =>
    p.join(hatariBaseDir(config), kHatariInstallSubdir);

/// True when the configured `Hatari.Executable` resolves to an existing file.
bool hatariInstalled(DesktopConfig config) {
  final exe = config.resolveHatariExecutable();
  return exe.isNotEmpty && File(exe).existsSync();
}

/// Value to store in `Hatari.Executable` for an installed [exePath]: relative
/// to the app directory when the executable lives inside it (portable
/// Windows/Linux layout, survives moving the folder), otherwise the absolute
/// path (macOS installs into the per-user data directory outside the bundle).
String hatariConfigExecutable(
    {required String appDir, required String exePath}) {
  if (appDir.isEmpty || !p.isWithin(appDir, exePath)) return exePath;
  return p.relative(exePath, from: appDir);
}

/// A Hatari download/installation failed (network, HTTP status, bad archive or
/// no executable inside).
class HatariInstallException implements Exception {
  const HatariInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The user cancelled the installation.
class HatariInstallCancelledException implements Exception {
  const HatariInstallCancelledException();
}

/// Progress callback: a coarse [message] plus byte progress when known
/// ([total] is 0 when unknown).
typedef HatariInstallProgress = void Function(
    String message, int done, int total);

/// Locates the Hatari executable inside an extracted archive [root].
///
/// Preference order (shallowest wins on ties):
/// 1. a `hatari.exe` (Windows),
/// 2. a file directly inside a macOS `*.app/Contents/MacOS/` bundle,
/// 3. a plain `hatari` binary.
///
/// Returns the absolute path, or `null` when nothing matches.
String? findHatariExecutable(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return null;
  final files = _listFilesSafe(dir);
  File? best;
  var bestRank = 1 << 30;
  var bestDepth = 1 << 30;
  for (final f in files) {
    // Never pick an empty placeholder or a directory stub.
    if (f.lengthSync() == 0) continue;
    final segs = p.split(p.normalize(f.path));
    final lower = p.basename(f.path).toLowerCase();
    int? rank;
    if (lower == 'hatari.exe') {
      rank = 0;
    } else if (_insideMacAppBundle(segs)) {
      rank = 1;
    } else if (lower == 'hatari') {
      rank = 2;
    }
    if (rank == null) continue;
    if (best == null ||
        rank < bestRank ||
        (rank == bestRank && segs.length < bestDepth)) {
      best = f;
      bestRank = rank;
      bestDepth = segs.length;
    }
  }
  return best?.path;
}

bool _insideMacAppBundle(List<String> segs) {
  for (var i = 0; i + 1 < segs.length; i++) {
    if (segs[i] == 'Contents' && segs[i + 1] == 'MacOS') return true;
  }
  return false;
}

/// Recursively lists the files under [dir], skipping unreadable
/// sub-directories (best effort).
List<File> _listFilesSafe(Directory dir) {
  final out = <File>[];
  void walk(Directory d) {
    List<FileSystemEntity> entries;
    try {
      entries = d.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final e in entries) {
      final type = FileSystemEntity.typeSync(e.path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        out.add(File(e.path));
      } else if (type == FileSystemEntityType.directory) {
        walk(Directory(e.path));
      }
    }
  }

  walk(dir);
  return out;
}

/// Extracts Hatari from [zipBytes] into [targetDir] (created when missing) and
/// returns the absolute path of the executable. Verifies [expectedSha256] when
/// provided. Throws [HatariInstallException] on a bad archive / checksum or
/// when no executable is found.
String installHatariFromZip(List<int> zipBytes, String targetDir,
    {String? expectedSha256}) {
  if (expectedSha256 != null && expectedSha256.isNotEmpty) {
    final actual = sha256.convert(zipBytes).toString();
    if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
      throw HatariInstallException(
          'Checksum mismatch (expected $expectedSha256, got $actual).');
    }
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipBytes);
  } catch (e) {
    throw HatariInstallException(
        'Downloaded file is not a valid ZIP archive: $e');
  }
  Directory(targetDir).createSync(recursive: true);
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final name = entry.name;
    if (name.isEmpty) continue;
    final norm = p.normalize(name);
    if (p.isAbsolute(norm) || norm == '..' || norm.startsWith('..')) continue;
    final parts = p.split(norm);
    if (parts.first == '__MACOSX') continue;
    if (p.basename(norm).startsWith('._')) continue;
    final out = File(p.join(targetDir, norm));
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(entry.content as List<int>);
  }
  final exe = findHatariExecutable(targetDir);
  if (exe == null) {
    throw const HatariInstallException(
        'No Hatari executable found in the downloaded archive.');
  }
  if (Platform.isMacOS || Platform.isLinux) {
    try {
      Process.runSync('chmod', ['+x', exe]);
    } catch (_) {
      // best effort
    }
  }
  return exe;
}

/// Pluggable Hatari downloader (the production implementation is
/// [HttpHatariDownloader]; the dialog accepts a fake for unit tests).
abstract class HatariDownloader {
  /// Downloads [build] and unpacks it into [installDir] (created when
  /// missing). Returns the absolute path of the installed executable. Throws
  /// [HatariInstallException] on failure and [HatariInstallCancelledException]
  /// when [isCancelled] reports cancellation.
  Future<String> download(
    HatariBuild build,
    String installDir, {
    HatariInstallProgress? onProgress,
    bool Function()? isCancelled,
  });
}

/// `dart:io` HTTP implementation (follows the SourceForge mirror redirects).
class HttpHatariDownloader implements HatariDownloader {
  const HttpHatariDownloader();

  @override
  Future<String> download(
    HatariBuild build,
    String installDir, {
    HatariInstallProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    Directory? tmp;
    try {
      onProgress?.call('Connecting…', 0, 0);
      tmp = Directory.systemTemp.createTempSync('marcer_hatari_');
      final zipFile = File(p.join(tmp.path, 'hatari.zip'));

      final request = await client.getUrl(Uri.parse(build.url));
      request.headers.add(HttpHeaders.userAgentHeader, 'MarcerGameDVDLauncher');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HatariInstallException(
            'Download failed (HTTP ${response.statusCode}).');
      }
      final total = response.contentLength;
      final sink = zipFile.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          if (isCancelled?.call() ?? false) {
            throw const HatariInstallCancelledException();
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(
              'Downloading Hatari $kHatariVersion (${build.label})…',
              received,
              total < 0 ? 0 : total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (isCancelled?.call() ?? false) {
        throw const HatariInstallCancelledException();
      }

      onProgress?.call('Extracting…', 0, 0);
      final bytes = await zipFile.readAsBytes();
      final exe = installHatariFromZip(bytes, installDir,
          expectedSha256: build.sha256);
      if (Platform.isMacOS) {
        // Strip the download quarantine so Gatekeeper does not block the
        // freshly unpacked binary (best effort).
        try {
          Process.runSync(
              'xattr', ['-dr', 'com.apple.quarantine', installDir]);
        } catch (_) {
          // best effort
        }
      }
      onProgress?.call('Hatari installed.', 0, 0);
      return exe;
    } on HatariInstallException {
      rethrow;
    } on HatariInstallCancelledException {
      rethrow;
    } catch (e) {
      throw HatariInstallException('$e');
    } finally {
      client.close(force: true);
      if (tmp != null) {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {
          // best effort
        }
      }
    }
  }
}
