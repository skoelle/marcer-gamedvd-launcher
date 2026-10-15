// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Lock file name in the screenshot output directory, identical to
/// `shotgen.py LOCK_NAME` — the manual curation Save flow and the preview
/// swap both refuse to touch the directory while a live shotgen run holds
/// this PID lock.
const String kShotgenLockName = 'shotgen.lock';

/// Thrown when a live shotgen process (pid in the lock file) is active.
class ShotgenLockedException implements Exception {
  ShotgenLockedException(this.pid);

  final int? pid;

  @override
  String toString() => pid == null
      ? 'shotgen is running (lock file present)'
      : 'shotgen is running (pid $pid)';
}

String shotgenLockPath(String outDir) => '$outDir/$kShotgenLockName';

/// PID from the lock file, or null when absent/blank/not a number.
int? readShotgenLockPid(String outDir) {
  final lock = File(shotgenLockPath(outDir));
  if (!lock.existsSync()) return null;
  return int.tryParse(lock.readAsStringSync().trim());
}

/// Best-effort liveness probe for a pid (POSIX: signal 0 via SIGCONT;
/// Windows: `tasklist`). Never throws.
bool isPidAlive(int pid) {
  if (pid <= 0) return false;
  try {
    if (Platform.isWindows) {
      final r = Process.runSync(
          'tasklist', ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV']);
      return r.stdout.toString().contains('$pid');
    }
    return Process.killPid(pid, ProcessSignal.sigcont);
  } catch (_) {
    return false;
  }
}

/// True when the lock file exists and its pid is still alive (stale locks
/// from crashed runs are ignored, like `shotgen.acquire_lock`).
bool isShotgenActive(String outDir) {
  final pid = readShotgenLockPid(outDir);
  return pid != null && isPidAlive(pid);
}

/// Own process id via libc/kernel32 (dart:io has no portable pid API).
/// Returns null when the FFI lookup fails; the lock is then claimed
/// best-effort without a verifiable pid.
int? get selfPid {
  try {
    final fn = DynamicLibrary.process().lookupFunction<Int32 Function(), int Function()>(
        Platform.isWindows ? 'GetCurrentProcessId' : 'getpid');
    return fn();
  } catch (_) {
    return null;
  }
}

/// Claims the shotgen lock for this process; throws [ShotgenLockedException]
/// when a live run holds it (stale locks are overwritten).
void acquireShotgenLock(String outDir) {
  final pid = readShotgenLockPid(outDir);
  if (pid != null && isPidAlive(pid)) throw ShotgenLockedException(pid);
  File(shotgenLockPath(outDir)).writeAsStringSync('${selfPid ?? 0}');
}

void releaseShotgenLock(String outDir) {
  try {
    File(shotgenLockPath(outDir)).deleteSync();
  } catch (_) {
    // already gone
  }
}

/// Swaps the preview PNG (`<base>.png`) with one candidate
/// (`<base>_cNN.png`) in place: the names stay fixed, only the file
/// contents trade places (manual curation `M` in the lightbox). Both paths
/// must exist and live in the same mirror directory.
void swapPreviewCandidate(
    {required String previewPath, required String candidatePath}) {
  final preview = File(previewPath);
  final candidate = File(candidatePath);
  if (!preview.existsSync() || !candidate.existsSync()) {
    throw FileSystemException('preview or candidate PNG missing',
        preview.existsSync() ? candidatePath : previewPath);
  }
  if (preview.parent.path != candidate.parent.path) {
    throw ArgumentError(
        'preview and candidate must be in the same directory: '
        '${preview.parent.path} vs ${candidate.parent.path}');
  }
  final tmp = File('$previewPath.__swap__');
  try {
    preview.renameSync(tmp.path);
    candidate.renameSync(previewPath);
    tmp.renameSync(candidatePath);
  } catch (_) {
    // best-effort restore of the original preview name
    if (tmp.existsSync() && !preview.existsSync()) {
      try {
        tmp.renameSync(previewPath);
      } catch (_) {}
    }
    rethrow;
  }
}

/// One pending manual status/kind change (controller pending map).
typedef StatusKindChange = ({String status, String? kind});

/// Persists manual curation changes: claims the shotgen lock, updates
/// `index.json` atomically (same format as `shotgen.save_index`: 1-space
/// indent, sorted keys, tmp + rename) and mirrors `status`/`kind`/
/// `preview_is_desktop` into the per-entry `<base>.json` meta when present.
/// The lock is always released, also on error.
Future<void> applyStatusChanges({
  required String outDir,
  required Map<String, StatusKindChange> changes,
}) async {
  if (changes.isEmpty) return;
  acquireShotgenLock(outDir);
  try {
    final indexFile = File('$outDir/index.json');
    if (!indexFile.existsSync()) {
      throw const FileSystemException('index.json not found', 'index.json');
    }
    final map =
        jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;
    final entries = (map['entries'] as Map<String, dynamic>?) ??
        <String, dynamic>{};
    for (final e in changes.entries) {
      final entry = entries[e.key] as Map<String, dynamic>?;
      if (entry == null) continue;
      entry['status'] = e.value.status;
      entry['kind'] = e.value.kind;
    }
    final tmp = File('$outDir/index.json.tmp');
    tmp.writeAsStringSync(_encodeSorted(map));
    tmp.renameSync(indexFile.path);
    for (final e in changes.entries) {
      _updateMirrorMeta(outDir, e.key, e.value.status, e.value.kind);
    }
  } finally {
    releaseShotgenLock(outDir);
  }
}

/// Mirrors the new status/kind into the sidecar meta
/// `<OutDirectory>/<dirname(rel)>/<base>.json` when it exists (written for
/// `done`/`desktop` entries by shotgen). A broken sidecar must not abort
/// the save. `preview_is_desktop` matches shotgen's definition.
void _updateMirrorMeta(
    String outDir, String rel, String status, String? kind) {
  final idx = rel.lastIndexOf('/');
  final dir = idx == -1 ? '' : rel.substring(0, idx);
  final name = idx == -1 ? rel : rel.substring(idx + 1);
  final base =
      name.toLowerCase().endsWith('.zip') ? name.substring(0, name.length - 4) : name;
  final metaPath =
      dir.isEmpty ? '$outDir/$base.json' : '$outDir/$dir/$base.json';
  final metaFile = File(metaPath);
  if (!metaFile.existsSync()) return;
  try {
    final meta =
        jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
    meta['status'] = status;
    meta['kind'] = kind;
    meta['preview_is_desktop'] = kind == 'desktop' ||
        kind == 'textscreen' ||
        kind == 'darkscreen';
    metaFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(meta));
  } catch (_) {
    // ignore broken sidecar meta
  }
}

/// `jsonEncode` with recursive key sorting and shotgen's 1-space indent,
/// so a manually saved `index.json` keeps the tool's exact layout.
String _encodeSorted(Object? value) {
  Object? sort(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: sort(v[k])};
    }
    if (v is List) return v.map(sort).toList();
    return v;
  }

  return const JsonEncoder.withIndent(' ').convert(sort(value));
}
