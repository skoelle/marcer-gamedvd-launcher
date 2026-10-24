// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

/// Outcome of the one-time data-directory migration.
class DataLayoutMigrationResult {
  const DataLayoutMigrationResult({
    this.gameinfoFiles = 0,
    this.atariLegendFiles = 0,
    this.errors = const [],
  });

  final int gameinfoFiles;
  final int atariLegendFiles;
  final List<String> errors;

  bool get changed => gameinfoFiles > 0 || atariLegendFiles > 0;
}

/// Moves the legacy layout into the `GameinfoDirectory` subfolders:
///
/// ```
/// <DataDir>/games-*.json, crews.json, …  ->  <DataDir>/gameinfo/
/// <AtariLegendDirectory>/atarilegend*.json -> <DataDir>/atarilegend/
/// ```
///
/// Runs at app start, is idempotent and never overwrites an existing target
/// file. Cross-device moves fall back to copy + delete.
DataLayoutMigrationResult migrateDataLayout(DesktopConfig config) {
  final root = config.resolveDataDirectory();
  if (root.isEmpty) return const DataLayoutMigrationResult();
  final errors = <String>[];
  var gameinfoFiles = 0;
  var atariLegendFiles = 0;

  final rootDir = Directory(root);
  if (!rootDir.existsSync()) {
    return DataLayoutMigrationResult(
      errors: ['Data directory does not exist: $root'],
    );
  }

  // 1. Gameinfo files still directly in the data root.
  const gameinfoNames = {
    'manifest.json',
    'unmatched-report.txt',
    'crews.json',
    'crew-images.json',
    '.marcer-assets.json',
  };
  final gameinfoDir = p.join(root, 'gameinfo');
  try {
    for (final entity in rootDir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!gameinfoNames.contains(name) &&
          !RegExp(r'^games-.*\.json$').hasMatch(name)) {
        continue;
      }
      if (_moveFile(entity, File(p.join(gameinfoDir, name)), errors)) {
        gameinfoFiles++;
      }
    }
  } catch (e) {
    errors.add('Could not inspect $root: $e');
  }

  // 2. The legacy AtariLegend directory (only the cache files).
  final legacyLegend = config.atariLegendDirectory.trim();
  if (legacyLegend.isNotEmpty) {
    final legendDir = Directory(legacyLegend);
    if (legendDir.existsSync()) {
      final target = p.join(root, 'atarilegend');
      for (final name in const [
        kAtariLegendFileName,
        kAtariLegendTextsFileName,
      ]) {
        final source = File(p.join(legacyLegend, name));
        if (!source.existsSync()) continue;
        if (_moveFile(source, File(p.join(target, name)), errors)) {
          atariLegendFiles++;
        }
      }
    }
  }

  // 3. PF was never released; its directory is simply created for later use.
  try {
    Directory(p.join(root, 'piratefinder')).createSync(recursive: true);
  } catch (e) {
    errors.add('Could not create ${p.join(root, 'piratefinder')}: $e');
  }

  return DataLayoutMigrationResult(
    gameinfoFiles: gameinfoFiles,
    atariLegendFiles: atariLegendFiles,
    errors: errors,
  );
}

bool _moveFile(File source, File target, List<String> errors) {
  if (!source.existsSync()) return false;
  if (target.existsSync()) return false; // target wins, source stays put
  try {
    target.parent.createSync(recursive: true);
    try {
      source.renameSync(target.path);
    } on FileSystemException {
      // Cross-device (or a locked source): copy and delete.
      target.writeAsBytesSync(source.readAsBytesSync(), flush: true);
      source.deleteSync();
    }
    return true;
  } catch (e) {
    errors.add('Could not move ${source.path} -> ${target.path}: $e');
    return false;
  }
}
