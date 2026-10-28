// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:path/path.dart' as p;

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
  final normalized = p.normalize(path);
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('open', [normalized]);
      return r.exitCode == 0;
    }
    if (Platform.isWindows) {
      if (directory) {
        await Process.start(
          'explorer',
          [normalized],
          mode: ProcessStartMode.detached,
        );
        return true;
      }
      // ShellExecute via rundll32: no shell involved, so `&`, `|`, `^`, … in
      // the path can never be interpreted as commands (unlike
      // `cmd /c start`). Opens the file with its default application.
      final r = await Process.run(
        'rundll32.exe',
        ['url.dll,FileProtocolHandler', normalized],
      );
      return r.exitCode == 0;
    }
    final r = await Process.run('xdg-open', [normalized]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}
