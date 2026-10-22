// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';

import 'boot_media.dart';
import 'hatari_launcher.dart';

/// Builds an ST Hatari command for a GEMDOS magazine cover disk: the ZIP is
/// extracted and its largest program autostarted (`-d` + `--auto`), using the
/// bundled ST config (`{cfg}`) and TOS. Floppy-image ZIPs and non-GEMDOS
/// entries are left to the normal `--disk-a` launch.
({HatariCommand? command, String? error}) buildStGemdosCommand(
    DesktopConfig config, String zipPath, BootMedia boot,
    {HatariVariant? variant}) {
  final validation = validateHatariConfig(config);
  if (validation != null) return (command: null, error: validation);
  if (boot.mode != 'gemdos') {
    return (command: null, error: 'not a GEMDOS archive');
  }
  final args = <String>['-c', config.resolveHatariConfigFile()] + boot.args;
  if (variant != null) {
    args.addAll(variant.extraArgs);
    final tosFile = variant.tosFileName;
    if (tosFile != null && tosFile.isNotEmpty) {
      final tosBase = config.hatariWorkingDirectory.isNotEmpty
          ? config.hatariWorkingDirectory
          : config.appDir;
      final tosPath = tosBase.isEmpty ? tosFile : '$tosBase/$tosFile';
      if (!File(tosPath).existsSync()) {
        return (
          command: null,
          error: '${variant.name} needs the TOS ROM $tosFile '
              '(not found next to the app).'
        );
      }
      args
        ..add('--tos')
        ..add(tosPath);
    }
  }
  final workingDirectory = config.hatariWorkingDirectory.isNotEmpty
      ? config.hatariWorkingDirectory
      : (config.appDir.isEmpty ? Directory.current.path : config.appDir);
  return (
    command: HatariCommand(
        config.resolveHatariExecutable(), args, workingDirectory),
    error: null,
  );
}

/// Launches a magazine cover disk: GEMDOS archives are extracted + autostarted
/// as ST, floppy-image archives use the normal ST `--disk-a` path.
Future<({HatariProcess? process, String? error})> launchStGemdos(
    DesktopConfig config, String zipPath,
    {HatariVariant? variant}) async {
  final BootMedia boot;
  try {
    boot = prepareBoot(zipPath);
  } catch (e) {
    return (process: null, error: 'Cannot read the ZIP: $e');
  }
  if (boot.mode != 'gemdos') {
    return launchHatari(config, zipPath, variant: variant);
  }
  final (:command, :error) =
      buildStGemdosCommand(config, zipPath, boot, variant: variant);
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
