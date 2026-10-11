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
///    executable itself lives inside `Foo.app/Contents/MacOS`.
///
/// Duplicates (e.g. CWD == exe dir when double-clicked) are removed while
/// preserving order.
List<String> configSearchDirs({
  required String cwd,
  required String exeDir,
  bool isMacOS = false,
}) {
  final dirs = <String>[cwd, exeDir];
  if (isMacOS) {
    // exeDir = <...>/Foo.app/Contents/MacOS → parent of the .app bundle.
    dirs.add(p.normalize(p.join(exeDir, '..', '..', '..')));
  }
  final seen = <String>{};
  return [
    for (final d in dirs)
      if (seen.add(d)) d,
  ];
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
