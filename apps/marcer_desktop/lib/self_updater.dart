// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';
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

/// Fetches the GitHub `/releases` payload (injectable for tests).
typedef ReleaseListFetcher = Future<List<Map<String, dynamic>>> Function();

/// Default fetcher for the GitHub releases API.
Future<List<Map<String, dynamic>>> httpReleaseListFetcher() async {
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
    return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
  } finally {
    client.close(force: true);
  }
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
    } else if (Link(path).existsSync()) {
      Link(path).deleteSync();
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
    if (e is Link) {
      // Preserve symlinks (macOS *.framework structure); copying the target
      // as a file would break the framework.
      _deletePathBestEffort(dest);
      Link(dest).createSync(e.targetSync());
    } else if (e is Directory) {
      _copyDir(e, dest);
    } else if (e is File) {
      e.copySync(dest);
    }
  }
}

/// Best-effort removal of the one-shot update task in case an aborted update
/// left it behind (the helper normally deletes it itself). Runs on every
/// start; ignored on non-Windows or failure.
void cleanupUpdateTask() {
  if (!Platform.isWindows) return;
  try {
    Process.runSync('schtasks.exe', schtasksDeleteArgs(kUpdateTaskName));
  } catch (_) {
    // best effort
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
  String? _effectivePath;

  /// Paths the log could not be written to (surfaced in the error dialog when
  /// no candidate worked).
  List<String> get writeErrors => List.unmodifiable(_writeErrors);

  /// Path that actually received the log lines (the temp fallback when the
  /// preferred path is not writable); [path] when nothing was written yet.
  String get effectivePath => _effectivePath ?? path;

  /// True when at least one line was written successfully.
  bool get wroteAny => _effectivePath != null;

  void line(String message) {
    final stamp = DateTime.now().toIso8601String();
    final entry = '$stamp [app] $message\n';
    for (final candidate in _candidates()) {
      try {
        File(candidate).writeAsStringSync(entry, mode: FileMode.append);
        _effectivePath = candidate;
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

/// Outcome of a `schtasks.exe` invocation (see [CatalogController] updates).
class _SchtasksResult {
  const _SchtasksResult(
      {required this.ok, required this.code, required this.output});

  final bool ok;
  final int code;
  final String output;
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
  [string]$LogPath = '',
  [string]$TaskName = ''
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$msg) {
  if ([string]::IsNullOrEmpty($LogPath)) { return }
  try {
    Add-Content -LiteralPath $LogPath -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
  } catch { }
}

# The helper is normally launched through the Task Scheduler (it runs
# outside the app's job object, which would otherwise kill it on exit);
# remove that one-shot task again in every outcome.
function Remove-UpdateTask {
  if ([string]::IsNullOrEmpty($TaskName)) { return }
  try {
    Start-Process -FilePath 'schtasks.exe' -ArgumentList @('/Delete', '/TN', $TaskName, '/F') -WindowStyle Hidden -Wait | Out-Null
    Write-Log ('update task {0} deleted' -f $TaskName)
  } catch {
    Write-Log ('update task delete failed: {0}' -f $_.Exception.Message)
  }
}

try {
  Write-Log ('start: app={0} pid={1}' -f $AppDir, $WaitPid)

  # Phase 1: wait until the app exited (mapped libraries unlock then).
  $deadline = (Get-Date).AddSeconds(30)
  while ($null -ne (Get-Process -Id $WaitPid -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -gt $deadline) {
      Write-Log ('timeout waiting for pid {0}' -f $WaitPid)
      Remove-UpdateTask
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
      Remove-UpdateTask
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
  Remove-UpdateTask
  exit 0
} catch {
  Write-Log ('error: {0}' -f $_.Exception.Message)
  Remove-UpdateTask
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
  String taskName = '',
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
      if (taskName.isNotEmpty) ...['-TaskName', taskName],
    ];

/// Name of the one-shot scheduled task used to launch the helper outside the
/// app's job object (see [schtasksCreateArgs]).
const String kUpdateTaskName = 'MarcerGameDVDLauncherUpdate';

/// Base64 UTF-16LE representation for `powershell.exe -EncodedCommand`.
/// (Kept as a small tested primitive; the scheduled task itself uses a
/// launcher file instead, see [windowsUpdateTaskCommand].)
String powershellEncodedCommand(String script) =>
    base64.encode(utf16LeNoBom(script.replaceAll('\n', '\r\n')));

/// UTF-16 little-endian bytes without a BOM — the exact encoding
/// `-EncodedCommand` expects.
List<int> utf16LeNoBom(String s) {
  final out = <int>[];
  for (final unit in s.codeUnits) {
    out.add(unit & 0xff);
    out.add((unit >> 8) & 0xff);
  }
  return out;
}

/// `schtasks /Create` args for the one-shot helper task: runs as the current
/// interactive user (`/IT`) so it gets a desktop, and is deleted by the
/// helper itself once done (`/F` overwrites a stale leftover).
List<String> schtasksCreateArgs({
  required String taskName,
  required String command,
}) =>
    [
      '/Create',
      '/TN',
      taskName,
      '/TR',
      command,
      '/SC',
      'ONCE',
      '/ST',
      '00:00',
      '/IT',
      '/F',
    ];

/// `schtasks /Run` args to start the task immediately.
List<String> schtasksRunArgs(String taskName) => ['/Run', '/TN', taskName];

/// `schtasks /Delete` args (stale-task cleanup on startup).
List<String> schtasksDeleteArgs(String taskName) =>
    ['/Delete', '/TN', taskName, '/F'];

/// Body of the tiny launcher script written next to the helper and invoked
/// by the scheduled task. Single-quoted paths (a literal `'` is doubled) —
/// a script file needs no command-line escaping at all.
String windowsUpdateLauncherScript({
  required String scriptPath,
  required String appDir,
  required String exeName,
  required String stageDir,
  required int waitPid,
  required String logPath,
  required String taskName,
}) {
  String q(String v) => "'${v.replaceAll("'", "''")}'";
  return '& ${q(scriptPath)} -AppDir ${q(appDir)} -ExeName ${q(exeName)} '
      '-StageDir ${q(stageDir)} -WaitPid $waitPid -LogPath ${q(logPath)} '
      '-TaskName ${q(taskName)}\n';
}

/// The `schtasks /TR` value: a short `powershell -File <launcher>` call.
///
/// Deliberately NOT `-EncodedCommand`: `/TR` is capped at ~261 characters
/// and the fully-encoded invocation (all paths + params, UTF-16 base64)
/// would exceed that. The launcher file carries the arguments instead.
String windowsUpdateTaskCommand({required String launcherPath}) =>
    'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden '
    '-ExecutionPolicy Bypass -File $launcherPath';

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
///
/// Returns the list of staged top-level entry names that were installed (the
/// non-`__MACOSX` entries), so the caller can verify or roll back.
List<String> swapInstall({required Directory from, required Directory into}) {
  into.createSync(recursive: true);
  final installed = <String>[];
  for (final entity in from.listSync(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name == '__MACOSX') continue;
    final target = p.join(into.path, name);
    final oldPath = '$target.old';
    _deletePathBestEffort(oldPath);
    final existing = FileSystemEntity.typeSync(target, followLinks: false);
    if (existing != FileSystemEntityType.notFound) {
      final backup = _entry(target);
      if (backup is Directory) {
        backup.renameSync(oldPath);
      } else if (backup is File) {
        backup.renameSync(oldPath);
      } else if (Link(target).existsSync()) {
        Link(target).renameSync(oldPath);
      }
    }
    if (entity is Link) {
      _deletePathBestEffort(target);
      Link(target).createSync(entity.targetSync());
    } else if (entity is Directory) {
      _copyDir(entity, target);
    } else if (entity is File) {
      entity.copySync(target);
    }
    installed.add(name);
  }
  return installed;
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

/// macOS: the framework symlinks that must still be *links* after an install
/// (relative to the staged top-level entry). A regular file here means the
/// extraction broke the bundle and the app would fail to launch.
const List<String> kMacOsRequiredSymlinks = [
  'MarcerGameDVDLauncher.app/Contents/Frameworks/App.framework/App',
  'MarcerGameDVDLauncher.app/Contents/Frameworks/App.framework/Resources',
  'MarcerGameDVDLauncher.app/Contents/Frameworks/App.framework/Versions/Current',
  'MarcerGameDVDLauncher.app/Contents/Frameworks/FlutterMacOS.framework/'
      'FlutterMacOS',
  'MarcerGameDVDLauncher.app/Contents/Frameworks/FlutterMacOS.framework/'
      'Resources',
  'MarcerGameDVDLauncher.app/Contents/Frameworks/FlutterMacOS.framework/'
      'Versions/Current',
];

/// Verifies that [into] still contains the macOS framework symlinks listed in
/// [kMacOsRequiredSymlinks] as real links. Returns the missing/broken paths
/// (empty = OK). No-op on other platforms.
List<String> verifyMacOsFrameworkLinks(Directory into) {
  if (!Platform.isMacOS) return const [];
  final broken = <String>[];
  for (final rel in kMacOsRequiredSymlinks) {
    final path = p.join(into.path, rel);
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.link) {
      broken.add(rel);
    }
  }
  return broken;
}

/// Rolls back the entries named in [installed] to their `<name>.old` backups
/// (best effort) — used when a macOS install failed verification, so a broken
/// swap never leaves an unstartable app behind.
void rollbackInstall({
  required Directory into,
  required List<String> installed,
}) {
  for (final name in installed) {
    final target = p.join(into.path, name);
    final oldPath = '$target.old';
    if (FileSystemEntity.typeSync(oldPath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      continue;
    }
    _deletePathBestEffort(target);
    final backup = _entry(oldPath);
    if (backup is Directory) {
      backup.renameSync(target);
    } else if (backup is File) {
      backup.renameSync(target);
    } else if (Link(oldPath).existsSync()) {
      Link(oldPath).renameSync(target);
    }
  }
}

/// Ad-hoc re-signs the macOS app bundle with `codesign --force --deep -s -`
/// after a swap (best effort; the copied bundle would otherwise carry a stale
/// signature). No-op on other platforms or when `codesign` is unavailable.
void resignMacOsBundle(Directory installDir) {
  if (!Platform.isMacOS) return;
  try {
    String? appPath;
    for (final e in installDir.listSync(followLinks: false)) {
      if (e is Directory && e.path.endsWith('.app')) {
        appPath = e.path;
        break;
      }
    }
    if (appPath == null) return;
    Process.runSync('codesign', [
      '--force',
      '--deep',
      '--sign',
      '-',
      appPath,
    ]);
  } catch (_) {
    // best effort — an unsigned bundle still runs from a normal location
  }
}

enum UpdatePhase { none, checking, downloading, installing, restarting, failed }

/// Owns the update state and drives check/download/install/relaunch.
/// Only active in release builds (workflow passes `--dart-define=
/// RELEASE_BUILD=true`); dev runs via `run.sh` never check.
class SelfUpdateController extends ChangeNotifier {
  SelfUpdateController({
    ReleaseListFetcher? fetcher,
    bool? enabled,
    bool? translocated,
  })  : _fetch = fetcher ?? httpReleaseListFetcher,
        isEnabled = enabled ?? SelfUpdateController.enabled,
        isTranslocated = translocated ?? isAppTranslocated();

  static const bool enabled = bool.fromEnvironment('RELEASE_BUILD');

  final ReleaseListFetcher _fetch;

  bool _disposed = false;

  /// Notifies listeners unless the controller was already disposed (async
  /// checks/downloads can finish after the home page is gone).
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Whether this controller may check for updates (release builds; tests can
  /// override it through the constructor).
  final bool isEnabled;

  /// macOS runs the app from a read-only App-Translocation copy: updating is
  /// impossible, so check/install abort with actionable guidance. Tests can
  /// override it through the constructor.
  final bool isTranslocated;

  String currentVersion = '0.0.0';
  UpdateInfo? available;
  UpdatePhase phase = UpdatePhase.none;
  double? progress; // 0..1 while downloading
  String? error;

  /// Error of a **manual** check (`null` for the silent startup check).
  String? checkError;

  /// App-side log next to the installed app (see [UpdateLog]).
  late final UpdateLog _log = UpdateLog(p.join(
      installTargetDir(
          resolvedExecutable: Platform.resolvedExecutable,
          isMacOS: Platform.isMacOS),
      kUpdateLogName));

  /// Where the update log lives (shown in the error dialog): the fallback
  /// path when the preferred one next to the app was not writable.
  String get logPath => _log.effectivePath;

  /// Checks the GitHub releases. The automatic startup check stays silent;
  /// [manual] reports failures through [checkError].
  Future<void> check({bool manual = false}) async {
    if (!isEnabled) {
      if (manual) {
        checkError = 'Update checks are only available in release builds.';
        _notify();
      }
      return;
    }
    if (isTranslocated) {
      // The translocated bundle is read-only; do not offer a badge that can
      // never be installed.
      available = null;
      if (manual) checkError = kAppTranslocatedUpdateError;
      _log.line('check skipped: app runs from App Translocation (read-only)');
      _notify();
      return;
    }
    if (phase == UpdatePhase.downloading ||
        phase == UpdatePhase.installing ||
        phase == UpdatePhase.restarting) {
      return;
    }
    phase = UpdatePhase.checking;
    error = null;
    if (manual) checkError = null;
    _notify();
    try {
      final list = await _fetch();
      final tag = platformAssetTag();
      available =
          tag == null ? null : pickRelease(list, current: currentVersion, assetTag: tag);
      checkError = null;
      _log.line('check: current=$currentVersion '
          'latest=${available?.version ?? 'none'} (asset tag $tag)');
    } catch (e) {
      // offline / rate-limited / API down
      _log.line(manual ? 'check failed: $e' : 'check failed (ignored): $e');
      available = null;
      if (manual) checkError = 'Update check failed: $e';
    } finally {
      phase = UpdatePhase.none;
      _notify();
    }
  }

  /// Downloads the available release, installs it over the app directory
  /// and relaunches; errors surface via [error] and phase [failed].
  Future<void> install() async {
    final info = available;
    if (!isEnabled || info == null) return;
    if (phase == UpdatePhase.downloading ||
        phase == UpdatePhase.installing ||
        phase == UpdatePhase.restarting) {
      // A second call while a run is active must never start another
      // download/swap.
      return;
    }
    if (isTranslocated) {
      // Defense in depth (e.g. a badge found before the guard was added):
      // never download or copy into the read-only translocation directory.
      _log.line('install aborted: app runs from App Translocation (read-only)');
      phase = UpdatePhase.failed;
      error = kAppTranslocatedUpdateError;
      _notify();
      return;
    }
    final installDir = installTargetDir(
        resolvedExecutable: Platform.resolvedExecutable,
        isMacOS: Platform.isMacOS);
    final log = _log;
    Directory? tmp;
    try {
      phase = UpdatePhase.downloading;
      progress = 0;
      error = null;
      _notify();

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
      _notify();
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
        _notify();
        await _launchWindowsHelper(
            tmp: tmp,
            installDir: Directory(installDir),
            stageDir: extractDir,
            log: log);
        log.line('helper launched; exiting app now');
        exit(0);
      }

      final installed = swapInstall(from: extractDir, into: Directory(installDir));
      log.line('in-process swap done (${installed.length} entries)');

      // macOS: a broken framework symlink makes the app unstartable. Verify
      // and roll back to the previous install instead of leaving a broken one.
      final broken = verifyMacOsFrameworkLinks(Directory(installDir));
      if (broken.isNotEmpty) {
        log.line('macOS framework link check FAILED: ${broken.join(', ')}');
        rollbackInstall(into: Directory(installDir), installed: installed);
        log.line('rolled back to the previous install');
        throw StateError(
            'Update verification failed (broken framework links: '
            '${broken.join(', ')}). The previous version was restored.');
      }
      if (Platform.isMacOS) {
        log.line('framework link check ok');
        resignMacOsBundle(Directory(installDir));
        log.line('re-signed app bundle (ad-hoc)');
      }

      phase = UpdatePhase.restarting;
      _notify();
      await relaunch(installDir, log: log);
      log.line('relaunched; exiting app now');
      exit(0);
    } catch (e) {
      log.line('ERROR: $e');
      phase = UpdatePhase.failed;
      // The dialog shows the effective log path. Only complain when no
      // candidate could be written at all (e.g. the read-only translocated
      // bundle plus an unwritable temp dir).
      final writeNote = log.wroteAny
          ? ''
          : '\n\n(Update log could not be written: '
              '${log.writeErrors.join('; ')})';
      error = '$e$writeNote';
      _notify();
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
    _notify();
  }

  /// Launches the Windows helper that swaps the files after this process has
  /// exited. [tmp] (staging + script) is removed by the helper on success.
  ///
  /// Primary route: a one-shot **Task Scheduler** task, because the app runs
  /// inside a job object (`in job: true` in the log) with
  /// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` — a plain child process (even
  /// `detached`, which never sets `CREATE_BREAKAWAY_FROM_JOB`) is killed the
  /// moment the app calls `exit(0)`. The task is created/run by the service
  /// outside the job, and the helper deletes it again when done.
  ///
  /// Fallback: the previous direct `detachedWithStdio` spawn (works when the
  /// app is *not* in a job, e.g. launched from a terminal) with a short
  /// stdout/stderr drain so a start failure leaves a trace.
  Future<void> _launchWindowsHelper(
      {required Directory tmp,
      required Directory installDir,
      required Directory stageDir,
      required UpdateLog log}) async {
    final pid = selfPid;
    if (pid == null || pid == 0) {
      throw StateError('Cannot determine own process id for the update helper');
    }
    final exeName = p.basename(Platform.resolvedExecutable);
    final logPath = p.join(installDir.path, kUpdateLogName);
    final script = File(p.join(tmp.path, 'updater.ps1'));
    script.writeAsStringSync(windowsUpdateHelperScript());
    final launcher = File(p.join(tmp.path, 'updater_launch.ps1'));
    launcher.writeAsStringSync(windowsUpdateLauncherScript(
      scriptPath: script.path,
      appDir: installDir.path,
      exeName: exeName,
      stageDir: stageDir.path,
      waitPid: pid,
      logPath: logPath,
      taskName: kUpdateTaskName,
    ));

    // Best-effort: drop a leftover task from an earlier aborted update.
    _runSchtasks(schtasksDeleteArgs(kUpdateTaskName), log, 'cleanup');

    final command = windowsUpdateTaskCommand(launcherPath: launcher.path);

    log.line('creating scheduled task $kUpdateTaskName');
    final create = _runSchtasks(
        schtasksCreateArgs(taskName: kUpdateTaskName, command: command),
        log,
        'create');
    final run = create.ok
        ? _runSchtasks(schtasksRunArgs(kUpdateTaskName), log, 'run')
        : _SchtasksResult(ok: false, code: -1, output: 'skipped (create failed)');

    if (create.ok && run.ok) {
      log.line('helper started via Task Scheduler ($kUpdateTaskName)');
      return;
    }

    // Fallback: direct detached spawn (survives only outside a job object).
    log.line('Task Scheduler route failed — falling back to direct spawn');
    final args = windowsUpdateHelperArgs(
      scriptPath: script.path,
      appDir: installDir.path,
      exeName: exeName,
      stageDir: stageDir.path,
      waitPid: pid,
      logPath: logPath,
      taskName: kUpdateTaskName,
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

  /// Runs `schtasks.exe` with [args] and logs the outcome; never throws.
  _SchtasksResult _runSchtasks(
      List<String> args, UpdateLog log, String label) {
    try {
      final r = Process.runSync('schtasks.exe', args);
      final out = '${r.stdout}${r.stderr}'.trim().replaceAll('\n', ' | ');
      log.line('schtasks $label rc=${r.exitCode}'
          '${out.isEmpty ? '' : ' :: $out'}');
      return _SchtasksResult(ok: r.exitCode == 0, code: r.exitCode, output: out);
    } catch (e) {
      log.line('schtasks $label FAILED: $e');
      return _SchtasksResult(ok: false, code: -1, output: '$e');
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
            _notify();
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
  extractArchiveToDir(archive, into);
}

/// Extracts a decoded [archive] into [into] (see [extractZipToDir]).
/// Recreates Unix symlinks as real links (macOS `ditto` zips).
void extractArchiveToDir(Archive archive, Directory into) {
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
    if (entry.isSymbolicLink) {
      // macOS `ditto` zips (Frameworks/*.framework) rely on symlinks
      // (`App` -> `Versions/Current/App`, `Versions/Current` -> `A`).
      // Recreate them as real links; turning them into files breaks the
      // framework resources and the app fails to launch after an update.
      File(outPath).parent.createSync(recursive: true);
      _deletePathBestEffort(outPath);
      Link(outPath).createSync(entry.nameOfLinkedFile);
    } else if (entry.isFile) {
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
Future<void> relaunch(String installDir, {UpdateLog? log}) {
  final exeName = p.basename(Platform.resolvedExecutable);
  final exe = Platform.isMacOS
      ? p.join(installDir, 'MarcerGameDVDLauncher.app', 'Contents',
          'MacOS', exeName)
      : p.join(installDir, exeName);
  return relaunchExecutable(exe, log: log);
}

/// Starts [exe] detached and completes only once the OS has spawned it.
/// Callers must await this before exiting: a non-awaited `Process.start`
/// followed by `exit` can abort the spawn.
Future<void> relaunchExecutable(String exe, {UpdateLog? log}) async {
  if (Platform.isLinux || Platform.isMacOS) {
    try {
      Process.runSync('chmod', ['+x', exe]);
    } catch (_) {
      // best effort — extraction may already have preserved the bit
    }
  }
  final process = await Process.start(
    exe,
    const [],
    mode: ProcessStartMode.detached,
  ).timeout(const Duration(seconds: 5));
  log?.line('relaunch pid=${process.pid}');
}
