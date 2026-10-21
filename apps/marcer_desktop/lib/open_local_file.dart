// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

/// Opens [path] with the operating system's default application (PDF viewer,
/// text editor, word processor, …). Returns `false` when the launcher could
/// not be started or reported a failure.
Future<bool> openLocalFile(String path) => _openLocalPath(path);

/// Opens the directory [path] in the operating system's file manager
/// (Explorer, Finder, the default `xdg-open` handler). Returns `false` when
/// the launcher could not be started or reported a failure.
Future<bool> openLocalDirectory(String path) =>
    _openLocalPath(path, directory: true);

Future<bool> _openLocalPath(String path, {bool directory = false}) async {
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('open', [path]);
      return r.exitCode == 0;
    }
    if (Platform.isWindows) {
      if (directory) {
        await Process.start(
          'explorer',
          [path],
          mode: ProcessStartMode.detached,
        );
        return true;
      }
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
