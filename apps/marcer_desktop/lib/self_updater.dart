// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// GitHub repo hosting both apps; desktop releases use the `desktop-v*`
/// tag prefix (see .github/workflows/desktop-release.yml).
const String kSelfUpdateRepo = 'skoelle/marcer-gamedvd-launcher';

/// Release asset suffix per platform, matching the workflow's
/// `MarcerDesktop-v{version}-{tag}.zip` naming.
String? platformAssetTag({String? os}) {
  switch (os ?? Platform.operatingSystem) {
    case 'windows':
      return 'win-x64';
    case 'linux':
      return 'linux-x64';
    case 'macos':
      return 'osx-arm64';
    default:
      return null;
  }
}

/// Numeric `x.y.z` comparison (missing parts count as 0); pre-release
/// suffixes are ignored.
int compareVersions(String a, String b) {
  final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final va = i < pa.length ? pa[i] : 0;
    final vb = i < pb.length ? pb[i] : 0;
    if (va != vb) return va < vb ? -1 : 1;
  }
  return 0;
}

/// A newer desktop release with a matching platform asset.
class UpdateInfo {
  const UpdateInfo(
      {required this.version, required this.assetName, required this.assetUrl});

  final String version;
  final String assetName;
  final String assetUrl;
}

/// Pure selection from the GitHub `/releases` JSON payload (newest first):
/// the newest non-draft/non-prerelease `desktop-v*` release that is newer
/// than [current] and carries a `MarcerDesktop-v{version}-{assetTag}.zip`
/// asset. Console `v*` releases are ignored by the tag prefix.
UpdateInfo? pickRelease(List<Map<String, dynamic>> releases,
    {required String current, required String assetTag}) {
  UpdateInfo? best;
  for (final r in releases) {
    if (r['draft'] == true || r['prerelease'] == true) continue;
    final tag = (r['tag_name'] as String?) ?? '';
    if (!tag.startsWith('desktop-v')) continue;
    final version = tag.substring('desktop-v'.length);
    final cmp = compareVersions(version, current);
    if (cmp <= 0) continue; // older or equal — keep scanning for info only
    final assets = (r['assets'] as List?) ?? const [];
    for (final a in assets) {
      final name = ((a as Map)['name'] as String?) ?? '';
      final url = (a['browser_download_url'] as String?) ?? '';
      if (name == 'MarcerDesktop-v$version-$assetTag.zip' && url.isNotEmpty) {
        final info = UpdateInfo(version: version, assetName: name, assetUrl: url);
        if (best == null || compareVersions(version, best.version) > 0) {
          best = info;
        }
      }
    }
  }
  return best;
}

/// Directory the update is installed into:
/// - Windows/Linux: the directory of the running executable
/// - macOS: the folder *containing* the `.app` bundle (zip root: the app
///   bundle plus the two shipped cfg files, see desktop-release.yml)
String installTargetDir(
    {required String resolvedExecutable, bool isMacOS = false}) {
  if (isMacOS) {
    const marker = '.app';
    final idx = resolvedExecutable.indexOf(marker);
    if (idx != -1) {
      return p.dirname(resolvedExecutable.substring(0, idx + marker.length));
    }
  }
  return p.dirname(resolvedExecutable);
}

FileSystemEntity? _entry(String path) {
  final t = FileSystemEntity.typeSync(path, followLinks: false);
  switch (t) {
    case FileSystemEntityType.file:
      return File(path);
    case FileSystemEntityType.directory:
      return Directory(path);
    default:
      return null;
  }
}

void _deletePathBestEffort(String path) {
  try {
    final e = _entry(path);
    if (e is File) {
      e.deleteSync();
    } else if (e is Directory) {
      e.deleteSync(recursive: true);
    }
  } catch (_) {
    // best effort — a stale .old is retried on the next start
  }
}

void _copyDir(Directory src, String destPath) {
  Directory(destPath).createSync(recursive: true);
  for (final e in src.listSync(followLinks: false)) {
    final name = p.basename(e.path);
    final dest = p.join(destPath, name);
    if (e is Directory) {
      _copyDir(e, dest);
    } else if (e is File) {
      e.copySync(dest);
    }
  }
}

/// Installs the extracted release [from] over [into]:
/// every top-level entry is renamed to `<name>.old` first (rename is safe
/// for running executables / mapped libraries on all three platforms) and
/// then replaced by the new version. User files not contained in the zip
/// (`desktop.config.json`, `favorites.txt`, `TOS.IMG`, …) are never touched.
/// The `.old` leftovers are removed by [cleanupOldFiles] on the next start.
void swapInstall({required Directory from, required Directory into}) {
  into.createSync(recursive: true);
  for (final entity in from.listSync(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name == '__MACOSX') continue;
    final target = p.join(into.path, name);
    final oldPath = '$target.old';
    _deletePathBestEffort(oldPath);
    final existing = _entry(target);
    if (existing != null) {
      if (existing is Directory) {
        existing.renameSync(oldPath);
      } else if (existing is File) {
        existing.renameSync(oldPath);
      }
    }
    if (entity is Directory) {
      _copyDir(entity, target);
    } else if (entity is File) {
      entity.copySync(target);
    }
  }
}

/// Best-effort removal of `<name>.old` leftovers next to the executable
/// (files and directories). Runs on every start; failures are ignored —
/// Windows may still hold a lock for a moment.
Future<void> cleanupOldFiles(String installDir) async {
  try {
    final dir = Directory(installDir);
    if (!dir.existsSync()) return;
    for (var attempt = 0; attempt < 3; attempt++) {
      var removedAny = false;
      for (final e in dir.listSync(followLinks: false)) {
        if (p.basename(e.path).endsWith('.old')) {
          _deletePathBestEffort(e.path);
          removedAny = true;
        }
      }
      final stillThere = dir
          .listSync(followLinks: false)
          .any((e) => p.basename(e.path).endsWith('.old'));
      if (!stillThere || !removedAny) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  } catch (_) {
    // best effort
  }
}

enum UpdatePhase { none, checking, downloading, installing, restarting, failed }

/// Owns the update state and drives check/download/install/relaunch.
/// Only active in release builds (workflow passes `--dart-define=
/// RELEASE_BUILD=true`); dev runs via `run.sh` never check.
class SelfUpdateController extends ChangeNotifier {
  static const bool enabled = bool.fromEnvironment('RELEASE_BUILD');

  String currentVersion = '0.0.0';
  UpdateInfo? available;
  UpdatePhase phase = UpdatePhase.none;
  double? progress; // 0..1 while downloading
  String? error;

  /// Silent startup check; network failures stay silent.
  Future<void> check() async {
    if (!enabled) return;
    if (phase == UpdatePhase.downloading ||
        phase == UpdatePhase.installing ||
        phase == UpdatePhase.restarting) {
      return;
    }
    phase = UpdatePhase.checking;
    error = null;
    notifyListeners();
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      try {
        final req = await client.getUrl(Uri.parse(
            'https://api.github.com/repos/$kSelfUpdateRepo/releases?per_page=30'));
        req.headers
          ..add(HttpHeaders.acceptHeader, 'application/vnd.github+json')
          ..add(HttpHeaders.userAgentHeader, 'MarcerGameDVDLauncher');
        final resp = await req.close();
        if (resp.statusCode != 200) {
          throw HttpException('HTTP ${resp.statusCode}');
        }
        final body = await resp.transform(utf8.decoder).join();
        final list = (jsonDecode(body) as List).cast<Map<String, dynamic>>();
        final tag = platformAssetTag();
        available =
            tag == null ? null : pickRelease(list, current: currentVersion, assetTag: tag);
      } finally {
        client.close(force: true);
      }
      phase = UpdatePhase.none;
    } catch (_) {
      // offline / rate-limited / API down — stay silent, keep old state
      available = null;
      phase = UpdatePhase.none;
    }
    notifyListeners();
  }

  /// Downloads the available release, installs it over the app directory
  /// and relaunches; errors surface via [error] and phase [failed].
  Future<void> install() async {
    final info = available;
    if (!enabled || info == null) return;
    Directory? tmp;
    try {
      phase = UpdatePhase.downloading;
      progress = 0;
      error = null;
      notifyListeners();

      tmp = Directory.systemTemp.createTempSync('marcer_update_');
      final zipFile = File(p.join(tmp.path, 'update.zip'));
      await _download(info.assetUrl, zipFile);

      phase = UpdatePhase.installing;
      notifyListeners();
      final extractDir = Directory(p.join(tmp.path, 'extract'));
      extractDir.createSync(recursive: true);
      await extractZipToDir(zipFile, extractDir);

      final installDir = installTargetDir(
          resolvedExecutable: Platform.resolvedExecutable,
          isMacOS: Platform.isMacOS);
      swapInstall(from: extractDir, into: Directory(installDir));

      phase = UpdatePhase.restarting;
      notifyListeners();
      relaunch(installDir);
      exit(0);
    } catch (e) {
      phase = UpdatePhase.failed;
      error = e.toString();
      notifyListeners();
      if (tmp != null) {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {
          // best effort
        }
      }
    }
  }

  void clearError() {
    if (phase == UpdatePhase.failed) {
      phase = UpdatePhase.none;
    }
    error = null;
    notifyListeners();
  }

  Future<void> _download(String url, File target) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.add(HttpHeaders.userAgentHeader, 'MarcerGameDVDLauncher');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode} for $url');
      }
      final total = resp.contentLength;
      final sink = target.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            progress = received / total;
            notifyListeners();
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }
}

/// Extracts a release zip into [into], skipping `__MACOSX` dirs and
/// AppleDouble `._*` files (macOS `ditto` zips) and any entry that would
/// escape [into] (zip-slip guard).
Future<void> extractZipToDir(File zipFile, Directory into) async {
  final bytes = await zipFile.readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final entry in archive) {
    final name = entry.name;
    if (name.isEmpty) continue;
    final norm = p.normalize(name);
    if (p.isAbsolute(norm) || norm == '..' || norm.startsWith('..')) {
      continue;
    }
    final parts = p.split(norm);
    if (parts.first == '__MACOSX') continue;
    if (p.basename(norm).startsWith('._')) continue;
    final outPath = p.join(into.path, norm);
    if (entry.isFile) {
      File(outPath).parent.createSync(recursive: true);
      File(outPath).writeAsBytesSync(entry.content as List<int>);
    } else {
      Directory(outPath).createSync(recursive: true);
    }
  }
}

/// Starts the freshly installed binary (same product name on all
/// platforms, `MarcerGameDVDLauncher[.exe]`; on macOS the binary inside
/// the replaced `.app` — the executable file name is unchanged, so
/// `basename(Platform.resolvedExecutable)` identifies it).
void relaunch(String installDir) {
  final exeName = p.basename(Platform.resolvedExecutable);
  final exe = Platform.isMacOS
      ? p.join(installDir, 'MarcerGameDVDLauncher.app', 'Contents',
          'MacOS', exeName)
      : p.join(installDir, exeName);
  if (Platform.isLinux || Platform.isMacOS) {
    try {
      Process.runSync('chmod', ['+x', exe]);
    } catch (_) {
      // best effort — extraction may already have preserved the bit
    }
  }
  Process.start(exe, []);
}
