// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/data_layout_migration.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('data_layout_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DesktopConfig config({
    String? gameinfo,
    String atariLegend = '',
  }) =>
      DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        gameinfoDirectory: gameinfo ?? '${tmp.path}/data',
        atariLegendDirectory: atariLegend,
      );

  test('moves root gameinfo files and the legacy AtariLegend cache', () {
    final data = Directory('${tmp.path}/data')..createSync();
    File('${data.path}/games-cracked.json').writeAsStringSync('{}');
    File('${data.path}/crews.json').writeAsStringSync('[]');
    File('${data.path}/.marcer-assets.json').writeAsStringSync('{}');
    final legacy = Directory('${tmp.path}/AtariLegend')..createSync();
    File('${legacy.path}/atarilegend.json').writeAsStringSync('{}');
    File('${legacy.path}/atarilegend-texts.json').writeAsStringSync('{}');

    final cfg = config(atariLegend: legacy.path);
    expect(cfg.resolveGameinfoDirectory(), data.path); // legacy fallback
    expect(cfg.resolveAtariLegendDirectory(), legacy.path);

    final result = migrateDataLayout(cfg);
    expect(result.errors, isEmpty);
    expect(result.gameinfoFiles, 3);
    expect(result.atariLegendFiles, 2);

    expect(File('${data.path}/gameinfo/games-cracked.json').existsSync(), isTrue);
    expect(File('${data.path}/gameinfo/crews.json').existsSync(), isTrue);
    expect(File('${data.path}/gameinfo/.marcer-assets.json').existsSync(), isTrue);
    expect(File('${data.path}/games-cracked.json').existsSync(), isFalse);

    expect(File('${data.path}/atarilegend/atarilegend.json').existsSync(), isTrue);
    expect(
      File('${data.path}/atarilegend/atarilegend-texts.json').existsSync(),
      isTrue,
    );
    expect(File('${legacy.path}/atarilegend.json').existsSync(), isFalse);
    expect(Directory('${data.path}/piratefinder').existsSync(), isTrue);

    expect(cfg.resolveGameinfoDirectory(), '${data.path}/gameinfo');
    expect(cfg.resolveAtariLegendDirectory(), '${data.path}/atarilegend');
    expect(cfg.resolvePirateFinderDirectory(), '${data.path}/piratefinder');

    final again = migrateDataLayout(cfg);
    expect(again.gameinfoFiles, 0);
    expect(again.atariLegendFiles, 0);
    expect(again.errors, isEmpty);
  });

  test('does not overwrite an existing target file', () {
    final data = Directory('${tmp.path}/data')..createSync();
    File('${data.path}/games-pd.json').writeAsStringSync('old');
    final target = Directory('${data.path}/gameinfo')..createSync();
    File('${target.path}/games-pd.json').writeAsStringSync('new');

    final result = migrateDataLayout(config());
    expect(result.errors, isEmpty);
    expect(result.gameinfoFiles, 0);
    expect(File('${target.path}/games-pd.json').readAsStringSync(), 'new');
    expect(File('${data.path}/games-pd.json').readAsStringSync(), 'old');
  });

  test('missing data directory is reported, empty config is a no-op', () {
    final result = migrateDataLayout(
      DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        gameinfoDirectory: '${tmp.path}/missing',
      ),
    );
    expect(result.errors, isNotEmpty);

    expect(migrateDataLayout(DesktopConfig(rootDirectory: '')).changed, isFalse);
  });

  test('resolves subdirectories for a fresh data directory', () {
    final data = Directory('${tmp.path}/data')..createSync();
    final cfg = config(gameinfo: data.path);
    expect(cfg.resolveGameinfoDirectory(), '${data.path}/gameinfo');
    expect(cfg.resolveAtariLegendDirectory(), '${data.path}/atarilegend');
    expect(cfg.resolvePirateFinderDirectory(), '${data.path}/piratefinder');
  });
}
