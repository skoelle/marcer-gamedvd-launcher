// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';

import 'boot_media.dart';
import 'hatari_launcher.dart';

/// Builds the Falcon Hatari command for [zipPath] or returns an error.
///
/// Falcon never uses the ST config/args template: it boots `--machine falcon`
/// with its own TOS 4.04 and either a floppy image (`--disk-a`) or an
/// extracted GEMDOS directory with an autostarted program (`-d` + `--auto`).
({HatariCommand? command, String? error}) buildFalconCommand(
    DesktopConfig config, String zipPath,
    {HatariVariant? variant}) {
  if (config.hatariExecutable.trim().isEmpty) {
    return (command: null, error: 'Hatari.Executable must be set in desktop.config.json.');
  }
  final exe = config.resolveHatariExecutable();
  if (!File(exe).existsSync()) {
    return (command: null, error: 'Hatari executable not found: $exe');
  }
  if (zipPath.trim().isEmpty || !File(zipPath).existsSync()) {
    return (command: null, error: 'ZIP file not found: $zipPath');
  }
  final tosPath = config.resolveFalconTosPath();
  if (!File(tosPath).existsSync()) {
    return (
      command: null,
      error: 'Falcon needs the TOS ROM ${config.falconTosFile} '
          '(not found next to the app).'
    );
  }

  final args = <String>[
    '--machine', 'falcon',
    '--tos', tosPath,
    '--memsize', config.falconMemsize,
    '--monitor', config.falconMonitor,
    '--dsp', config.falconDsp,
    '--cpuclock', config.falconCpuClock,
    '--fpu', config.falconFpu,
    '--fast-boot', 'on',
    '--confirm-quit', 'off',
  ];
  if (config.falconExtraArgs.trim().isNotEmpty) {
    args.addAll(splitCommandLine(config.falconExtraArgs));
  }
  if (variant != null) args.addAll(variant.extraArgs);

  final BootMedia boot;
  try {
    boot = prepareBoot(zipPath);
  } catch (e) {
    return (command: null, error: 'Cannot read the Falcon ZIP: $e');
  }
  args.addAll(boot.args);

  final workingDirectory = config.hatariWorkingDirectory.isNotEmpty
      ? config.hatariWorkingDirectory
      : (config.appDir.isEmpty ? Directory.current.path : config.appDir);
  return (
    command: HatariCommand(exe, args, workingDirectory),
    error: null,
  );
}

/// Launches Hatari in Falcon mode for [zipPath] (non-blocking).
Future<({HatariProcess? process, String? error})> launchFalcon(
    DesktopConfig config, String zipPath,
    {HatariVariant? variant}) async {
  final (:command, :error) =
      buildFalconCommand(config, zipPath, variant: variant);
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
