// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

/// Opens [path] with the operating system's default application (PDF viewer,
/// text editor, word processor, …). Returns `false` when the launcher could
/// not be started or reported a failure.
Future<bool> openLocalFile(String path) async {
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('open', [path]);
      return r.exitCode == 0;
    }
    if (Platform.isWindows) {
      // `start` is a cmd built-in; the empty title argument is required so a
      // quoted path with spaces is not mistaken for the window title.
      final r =
          await Process.run('cmd', ['/c', 'start', '', path], runInShell: true);
      return r.exitCode == 0;
    }
    final r = await Process.run('xdg-open', [path]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}
