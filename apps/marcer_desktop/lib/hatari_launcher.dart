// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';

/// Starts Hatari for one ZIP (SPEC.md §12). Non-blocking: the process runs in
/// the background and the caller is notified when it exits.
class HatariProcess {
  HatariProcess(this._process);

  final Process _process;

  /// Completes when the emulator exits.
  Future<int> get exitCode => _process.exitCode;
}

/// Launches Hatari for [zipPath]. Returns a [HatariProcess] on success or an
/// error message when the configuration/ZIP is invalid (SPEC.md §5.4, E3/E4,E7).
Future<({HatariProcess? process, String? error})> launchHatari(
    DesktopConfig config, String zipPath,
    {HatariVariant? variant}) async {
  final (:command, :error) =
      buildHatariCommand(config, zipPath, variant: variant);
  if (command == null) return (process: null, error: error);
  try {
    final process = await Process.start(
      command.executable,
      command.arguments,
      workingDirectory: command.workingDirectory,
      runInShell: false,
    );
    return (process: HatariProcess(process), error: null);
  } catch (e) {
    return (process: null, error: 'Error starting Hatari: $e');
  }
}
