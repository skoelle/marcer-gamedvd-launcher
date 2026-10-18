// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:path/path.dart' as p;

/// Default config file name (see PLAN.md §3).
const String kConfigFileName = 'desktop.config.json';

/// Ordered directories searched for [kConfigFileName]:
///
/// 1. current working directory — developer convenience (`run.sh`, tests)
/// 2. directory of the executable — portable ZIP release (Windows/Linux)
/// 3. macOS only: the folder *containing* the `.app` bundle, since the
///    executable itself lives inside `Foo.app/Contents/MacOS`
/// 4. [extraDir] (when non-empty) — a stable writable fallback, e.g. the
///    macOS per-user data directory, so a config saved while the app runs
///    translocated is still found
///
/// Duplicates (e.g. CWD == exe dir when double-clicked) are removed while
/// preserving order.
List<String> configSearchDirs({
  required String cwd,
  required String exeDir,
  bool isMacOS = false,
  String extraDir = '',
}) {
  final dirs = <String>[cwd, exeDir];
  if (isMacOS) {
    dirs.add(macAppParent(exeDir));
  }
  if (extraDir.isNotEmpty) dirs.add(extraDir);
  final seen = <String>{};
  return [
    for (final d in dirs)
      if (seen.add(d)) d,
  ];
}

/// Folder *containing* the macOS `.app` bundle, given the directory of the
/// executable inside `Foo.app/Contents/MacOS`.
String macAppParent(String exeDir) =>
    p.normalize(p.join(exeDir, '..', '..', '..'));

/// Ordered directories for writing a **new** `desktop.config.json` when none
/// exists (first-run setup), most portable first, current working directory
/// as a writability fallback, and [extraDir] last:
///
/// - macOS: the folder containing the `.app` bundle, then CWD, then [extraDir]
/// - Windows/Linux: the executable's directory, then CWD, then [extraDir]
///
/// [extraDir] (e.g. the macOS per-user data directory) is the last-resort
/// fallback for a read-only install (App Translocation).
///
/// Duplicates are removed while preserving order.
List<String> configSaveDirs({
  required String cwd,
  required String exeDir,
  bool isMacOS = false,
  String extraDir = '',
}) {
  final primary = isMacOS ? macAppParent(exeDir) : exeDir;
  final seen = <String>{};
  return [
    for (final d in [primary, cwd, extraDir])
      if (d.isNotEmpty && seen.add(d)) d,
  ];
}

/// Writes a new config by calling [write] with `<dir>/<fileName>` for each
/// directory in [dirs] until one succeeds, returning that full path; `null`
/// when none is writable. Used by the first-run setup (e.g. a read-only
/// install dir falls back to the next candidate).
String? writeFirstWritable(
  List<String> dirs, {
  required String fileName,
  required void Function(String path) write,
}) {
  for (final dir in dirs) {
    final candidate = p.join(dir, fileName);
    try {
      write(candidate);
      return candidate;
    } catch (_) {
      // Try the next candidate (read-only install dir, missing parent, …).
    }
  }
  return null;
}

/// Returns the full path of the first `<dir>/<fileName>` for which [exists]
/// returns true, or `null` when none matches.
String? resolveConfigPath({
  required List<String> dirs,
  required bool Function(String path) exists,
  String fileName = kConfigFileName,
}) {
  for (final dir in dirs) {
    final candidate = p.join(dir, fileName);
    if (exists(candidate)) return candidate;
  }
  return null;
}
