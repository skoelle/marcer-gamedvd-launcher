// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'index_editor.dart';

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

/// Name of the tiny update log written next to the app by the Windows
/// helper (the only diagnostic channel — the helper runs without UI).
const String kUpdateLogName = 'MarcerUpdater.log';

/// App-side update log (parent process). The helper writes [kUpdateLogName]
/// next to the app; the parent appends to the same file so that a helper
/// which never starts still leaves a trace. Falls back to the temp dir when
/// the install dir is not writable.
class UpdateLog {
  UpdateLog(String? preferredPath)
      : path = preferredPath ?? p.join(Directory.systemTemp.path, kUpdateLogName);

  final String path;
  final List<String> _writeErrors = [];

  /// Paths the log could not be written to (surfaced in the error dialog).
  List<String> get writeErrors => List.unmodifiable(_writeErrors);

  void line(String message) {
    final stamp = DateTime.now().toIso8601String();
    final entry = '$stamp [app] $message\n';
    for (final candidate in _candidates()) {
      try {
        File(candidate).writeAsStringSync(entry, mode: FileMode.append);
        return;
      } catch (e) {
        final note = '$candidate: $e';
        if (!_writeErrors.contains(note)) _writeErrors.add(note);
      }
    }
  }

  /// Primary path first, then the system temp dir.
  Iterable<String> _candidates() sync* {
    yield path;
    final temp = p.join(Directory.systemTemp.path, kUpdateLogName);
    if (temp != path) yield temp;
  }
}

/// Whether the current process is assigned to a job object (Windows). A job
/// with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` kills detached children when the
/// parent exits; Dart's detached mode uses `DETACHED_PROCESS` but never
/// `CREATE_BREAKAWAY_FROM_JOB`, so the helper can die before its first line.
/// Null = unknown (non-Windows / lookup failure).
bool? currentProcessInJob() {
  if (!Platform.isWindows) return null;
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final getCurrent = k32.lookupFunction<_GetCurrentProcessC,
        _GetCurrentProcessD>('GetCurrentProcess');
    final inJob =
        k32.lookupFunction<_IsProcessInJobC, _IsProcessInJobD>('IsProcessInJob');
    final crt = _openCrt();
    final malloc = crt.lookupFunction<_MallocC, _MallocD>('malloc');
    final free = crt.lookupFunction<_FreeC, _FreeD>('free');
    final out = malloc(4).cast<Int32>();
    try {
      final ok = inJob(getCurrent(), 0, out);
      return ok != 0 ? out.value != 0 : null;
    } finally {
      free(out.cast<Uint8>());
    }
  } catch (_) {
    return null;
  }
}

typedef _GetCurrentProcessC = IntPtr Function();
typedef _GetCurrentProcessD = int Function();
typedef _IsProcessInJobC = Int32 Function(IntPtr, IntPtr, Pointer<Int32>);
typedef _IsProcessInJobD = int Function(int, int, Pointer<Int32>);
typedef _MallocC = Pointer<Uint8> Function(IntPtr);
typedef _MallocD = Pointer<Uint8> Function(int);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeD = void Function(Pointer<Uint8>);

DynamicLibrary _openCrt() {
  for (final name in ['ucrtbase.dll', 'msvcrt.dll']) {
    try {
      return DynamicLibrary.open(name);
    } catch (_) {
      // try the next one
    }
  }
  throw StateError('no C runtime found');
}

/// PowerShell script performed by a detached hidden helper AFTER this
/// process has exited (two-phase update, Windows only).
///
/// Why: the running app maps `data\app.so` and `flutter_windows.dll` into
/// its address space; Windows refuses to rename those files (or the `data`
/// directory containing `app.so`) while they are loaded
/// (ERROR_ACCESS_DENIED). The helper waits for the app PID to disappear,
/// then performs the same `.old` backup + swap + relaunch dance the
/// POSIX in-process path does, cleans up and writes [kUpdateLogName].
/// All values are passed as `-File` arguments (no string interpolation),
/// so paths with spaces need no escaping here.
String windowsUpdateHelperScript() => r'''param(
  [Parameter(Mandatory = $true)][string]$AppDir,
  [Parameter(Mandatory = $true)][string]$ExeName,
  [Parameter(Mandatory = $true)][string]$StageDir,
  [Parameter(Mandatory = $true)][int]$WaitPid,
  [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$msg) {
  if ([string]::IsNullOrEmpty($LogPath)) { return }
  try {
    Add-Content -LiteralPath $LogPath -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
  } catch { }
}

try {
  Write-Log ('start: app={0} pid={1}' -f $AppDir, $WaitPid)

  # Phase 1: wait until the app exited (mapped libraries unlock then).
  $deadline = (Get-Date).AddSeconds(30)
  while ($null -ne (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -gt $deadline) {
      Write-Log ('timeout waiting for pid {0}' -f $WaitPid)
      exit 1
    }
    Start-Sleep -Milliseconds 200
  }
  Write-Log 'app exited'

  # Phase 2: drop stale *.old leftovers, then backup + swap per staged entry
  # (same semantics as the POSIX swapInstall: only staged names are touched,
  # user files like desktop.config.json / favorites.txt stay in place).
  Get-ChildItem -LiteralPath $AppDir -Force |
    Where-Object { $_.Name -like '*.old' } |
    ForEach-Object {
      try {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        Write-Log ('removed stale {0}' -f $_.Name)
      } catch {
        Write-Log ('stale kept {0}: {1}' -f $_.Name, $_.Exception.Message)
      }
    }

  foreach ($entity in @(Get-ChildItem -LiteralPath $StageDir -Force)) {
    $name = $entity.Name
    if ($name -eq '__MACOSX') { continue }
    $target = Join-Path $AppDir $name
    if (Test-Path -LiteralPath $target) {
      Move-Item -LiteralPath $target -Destination ($target + '.old') -Force -ErrorAction Stop
      Write-Log ('backed up {0}' -f $name)
    }
    Move-Item -LiteralPath $entity.FullName -Destination $target -Force -ErrorAction Stop
    Write-Log ('installed {0}' -f $name)
  }

  # Phase 3: relaunch (restore the previous exe if the swap died halfway).
  $exePath = Join-Path $AppDir $ExeName
  if (-not (Test-Path -LiteralPath $exePath)) {
    if (Test-Path -LiteralPath ($exePath + '.old')) {
      Move-Item -LiteralPath ($exePath + '.old') -Destination $exePath -Force -ErrorAction Stop
      Write-Log 'restored previous exe after failed swap'
    } else {
      Write-Log 'no executable to launch'
      exit 1
    }
  }
  Start-Process -FilePath $exePath -WorkingDirectory $AppDir
  Write-Log 'relaunched'

  # Phase 4: best-effort cleanup of backups and the staging dir.
  Get-ChildItem -LiteralPath $AppDir -Force |
    Where-Object { $_.Name -like '*.old' } |
    ForEach-Object {
      try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { }
    }
  try { Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction Stop } catch { }
  Write-Log 'done'
  exit 0
} catch {
  Write-Log ('error: {0}' -f $_.Exception.Message)
  exit 1
}
''';

/// Arguments for the hidden PowerShell helper running
/// [windowsUpdateHelperScript] (`-File` binds them to the param block;
/// each path is one list entry, so spaces are handled by the Dart
/// launcher's quoting).
List<String> windowsUpdateHelperArgs({
  required String scriptPath,
  required String appDir,
  required String exeName,
  required String stageDir,
  required int waitPid,
  required String logPath,
}) =>
    [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
      '-AppDir',
      appDir,
      '-ExeName',
      exeName,
      '-StageDir',
      stageDir,
      '-WaitPid',
      '$waitPid',
      '-LogPath',
      logPath,
    ];

/// Installs the extracted release [from] over [into]: every top-level entry
/// is renamed to `<name>.old` first and then replaced by the new version.
/// User files not contained in the zip (`desktop.config.json`,
/// `favorites.txt`, `TOS.IMG`, …) are never touched. The `.old` leftovers
/// are removed by [cleanupOldFiles] on the next start.
///
/// Used in-process on macOS/Linux only: renaming a *running* executable is
/// fine everywhere, but Windows additionally locks loaded libraries
/// (`data\app.so`, `flutter_windows.dll`) against rename — see
/// [windowsUpdateHelperScript] for the two-phase Windows path.
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

  /// App-side log next to the installed app (see [UpdateLog]).
  late final UpdateLog _log = UpdateLog(p.join(
      installTargetDir(
          resolvedExecutable: Platform.resolvedExecutable,
          isMacOS: Platform.isMacOS),
      kUpdateLogName));

  /// Where the update log lives (shown in the error dialog).
  String get logPath => _log.path;

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
        _log.line('check: current=$currentVersion '
            'latest=${available?.version ?? 'none'} (asset tag $tag)');
      } finally {
        client.close(force: true);
      }
      phase = UpdatePhase.none;
    } catch (e) {
      // offline / rate-limited / API down — stay silent, keep old state
      _log.line('check failed (ignored): $e');
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
    final installDir = installTargetDir(
        resolvedExecutable: Platform.resolvedExecutable,
        isMacOS: Platform.isMacOS);
    final log = _log;
    Directory? tmp;
    try {
      phase = UpdatePhase.downloading;
      progress = 0;
      error = null;
      notifyListeners();

      log.line('--- update start: $currentVersion -> ${info.version} '
          '(${info.assetName})');
      log.line('install dir: $installDir');
      log.line('exe: ${Platform.resolvedExecutable}');
      log.line('pid: ${selfPid ?? 'unknown'}  '
          'in job: ${currentProcessInJob() ?? 'unknown'}');

      tmp = Directory.systemTemp.createTempSync('marcer_update_');
      final zipFile = File(p.join(tmp.path, 'update.zip'));
      await _download(info.assetUrl, zipFile);
      log.line('download ok: ${zipFile.lengthSync()} bytes');

      phase = UpdatePhase.installing;
      notifyListeners();
      final extractDir = Directory(p.join(tmp.path, 'extract'));
      extractDir.createSync(recursive: true);
      await extractZipToDir(zipFile, extractDir);
      log.line('extracted ${extractDir.listSync().length} top-level '
          'entries to ${extractDir.path}');

      if (Platform.isWindows) {
        // Two-phase: the running app maps data\app.so and
        // flutter_windows.dll, which Windows refuses to rename. Stage a
        // hidden helper that waits for our exit, swaps and relaunches.
        phase = UpdatePhase.restarting;
        notifyListeners();
        await _startWindowsHelper(
            tmp: tmp,
            installDir: Directory(installDir),
            stageDir: extractDir,
            log: log);
        log.line('helper spawned; exiting app now');
        exit(0);
      }

      swapInstall(from: extractDir, into: Directory(installDir));
      log.line('in-process swap done');

      phase = UpdatePhase.restarting;
      notifyListeners();
      relaunch(installDir);
      log.line('relaunched; exiting app now');
      exit(0);
    } catch (e) {
      log.line('ERROR: $e');
      phase = UpdatePhase.failed;
      final writeNote = log.writeErrors.isEmpty
          ? ''
          : '\n\n(Update log could not be written: '
              '${log.writeErrors.join('; ')})';
      error = '$e\n\nUpdate log: ${log.path}$writeNote';
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

  /// Writes [windowsUpdateHelperScript] into [tmp] and starts it detached
  /// and hidden; the helper performs the swap once this process has exited
  /// (Windows only — see the script for the rationale). [tmp] (staging +
  /// script) is removed by the helper on success.
  ///
  /// Uses [ProcessStartMode.detachedWithStdio] (not plain `detached`, which
  /// routes all three stdio streams to NUL) and briefly drains stdout/stderr
  /// into [log] — a PowerShell that refuses to start (policy, job kill,
  /// missing console) then leaves a trace instead of dying silently.
  Future<void> _startWindowsHelper(
      {required Directory tmp,
      required Directory installDir,
      required Directory stageDir,
      required UpdateLog log}) async {
    final pid = selfPid;
    if (pid == null || pid == 0) {
      throw StateError('Cannot determine own process id for the update helper');
    }
    final script = File(p.join(tmp.path, 'updater.ps1'));
    script.writeAsStringSync(windowsUpdateHelperScript());
    final exeName = p.basename(Platform.resolvedExecutable);
    final args = windowsUpdateHelperArgs(
      scriptPath: script.path,
      appDir: installDir.path,
      exeName: exeName,
      stageDir: stageDir.path,
      waitPid: pid,
      logPath: p.join(installDir.path, kUpdateLogName),
    );
    log.line('spawning helper: powershell.exe ${args.join(' ')}');

    final Process proc;
    try {
      proc = await Process.start(
        'powershell.exe',
        args,
        mode: ProcessStartMode.detachedWithStdio,
      );
    } catch (e) {
      log.line('helper spawn FAILED: $e');
      rethrow;
    }
    log.line('helper pid=${proc.pid}');

    // Drain the pipes briefly so startup errors land in the log, then stop
    // listening; the child keeps running detached after we exit.
    final out = StringBuffer();
    final err = StringBuffer();
    proc.stdout.transform(utf8.decoder).listen(out.write);
    proc.stderr.transform(utf8.decoder).listen(err.write);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final o = out.toString().trim();
    final e = err.toString().trim();
    if (o.isNotEmpty) log.line('helper stdout: $o');
    if (e.isNotEmpty) log.line('helper stderr: $e');
    if (o.isEmpty && e.isEmpty) {
      log.line('helper produced no output in 700ms (started or died silently)');
    }
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
