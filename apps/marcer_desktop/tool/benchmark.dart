// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

/// Offline benchmark for the catalog data layer, run against the real
/// artifacts of a `desktop.config.json`.
///
/// Usage (from `apps/marcer_desktop`):
///   ../../flutter/bin/dart run tool/benchmark.dart [desktop.config.json]
///
/// Measures the startup build, the filter/sort pipeline, the status-line
/// counts and the synchronous layer existence checks (the cost the grid
/// currently pays per newly visible card).
library;

import 'dart:convert';
import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final configPath = args.isNotEmpty ? args[0] : 'desktop.config.json';
  final config =
      jsonDecode(File(configPath).readAsStringSync()) as Map<String, dynamic>;
  String str(String key) => ((config[key] ?? '') as String).trim();

  final root = str('RootDirectory');
  final patch = str('PatchDirectory');
  final shots = str('ScreenshotDirectory');
  final gameinfo = str('GameinfoDirectory');
  final atariLegend = str('AtariLegendDirectory');

  stdout.writeln('config: $configPath');
  stdout.writeln('  root:      $root');
  stdout.writeln('  patch:     $patch');
  stdout.writeln('  shots:     $shots');
  stdout.writeln('  gameinfo:  $gameinfo');
  stdout.writeln('  legend:    ${atariLegend.isEmpty ? '(none)' : atariLegend}');

  final sw = Stopwatch()..start();
  final index = ScreenshotIndices.load(shots);
  final tIndex = sw.elapsedMilliseconds;
  sw.reset();
  final info = GameInfoIndex.load(gameinfo);
  final tInfo = sw.elapsedMilliseconds;
  sw.reset();
  final legend = AtariLegendIndex.load(atariLegend);
  final tLegend = sw.elapsedMilliseconds;
  sw.reset();
  final universe = CatalogUniverse.build(
    indices: index,
    info: info,
    screenshotDir: shots,
    atariLegend: legend,
  );
  final tUniverse = sw.elapsedMilliseconds;

  stdout.writeln('\n== load ==');
  stdout.writeln('screenshot index: $tIndex ms');
  stdout.writeln('gameinfo:         $tInfo ms');
  stdout.writeln('atarilegend:      $tLegend ms');
  stdout.writeln('universe build:   $tUniverse ms');

  stdout.writeln('\n== section sizes ==');
  for (final section in kSections) {
    final cards = universe.cardsFor(section);
    final variants =
        cards.fold<int>(0, (n, c) => n + c.variants.length);
    final avg = cards.isEmpty ? 0 : variants / cards.length;
    stdout.writeln('$section: ${cards.length} cards, '
        '$variants variants (avg ${avg.toStringAsFixed(1)})');
  }

  void bench(String label, void Function() fn,
      {int reps = 20, int warmup = 2}) {
    for (var i = 0; i < warmup; i++) {
      fn();
    }
    final s = Stopwatch()..start();
    for (var i = 0; i < reps; i++) {
      fn();
    }
    s.stop();
    final ms = s.elapsedMicroseconds / reps / 1000.0;
    stdout.writeln('${label.padRight(52)} ${ms.toStringAsFixed(2)} ms');
  }

  stdout.writeln('\n== filter + sort pipeline (queryCards) ==');
  for (final section in kSections) {
    final cards = universe.cardsFor(section);
    for (final status in ['any', 'with_screenshot']) {
      final f = CatalogFilter(section: section, status: status);
      bench('$section status=$status', () => queryCards(cards, f));
    }
    bench('$section q="10th"',
        () => queryCards(cards, CatalogFilter(section: section, status: 'any', q: '10th')));
    bench('$section sort=publisher',
        () => queryCards(cards, CatalogFilter(section: section, status: 'any', sort: 'publisher')));
    bench('$section sort=year',
        () => queryCards(cards, CatalogFilter(section: section, status: 'any', sort: 'year')));
    bench('$section focus=crew',
        () => queryCards(cards, CatalogFilter(section: section, status: 'any', crew: 'any')));
  }

  stdout.writeln('\n== sortCards only ==');
  for (final key in ['name', 'publisher', 'year']) {
    final copy = [...universe.cracked];
    bench('cracked sort=$key',
        () => sortCards(copy, key, 'asc'));
  }

  stdout.writeln('\n== status line counts (called on every rebuild) ==');
  for (final section in kSections) {
    bench('$section counts (3 scans)', () {
      universe.withScreenshotFor(section);
      universe.pendingAnyVariantCountFor(section);
      universe.noInfoFor(section);
    }, reps: 200);
  }

  stdout.writeln('\n== synchronous layer existence checks ==');
  if (root.isEmpty) {
    stdout.writeln('(RootDirectory not configured — skipped)');
  } else {
    final rels = index.forSection('cracked').entries.keys.take(80).toList();
    var found = 0;
    for (final rel in rels) {
      if (File(p.join(root, rel)).existsSync()) found++;
      if (patch.isNotEmpty) File(p.join(patch, rel)).existsSync();
    }
    final s = Stopwatch()..start();
    for (final rel in rels) {
      File(p.join(root, rel)).existsSync();
      if (patch.isNotEmpty) File(p.join(patch, rel)).existsSync();
    }
    s.stop();
    final per = s.elapsedMicroseconds / rels.length / 1000.0;
    final avgVariants = universe.cracked.isEmpty
        ? 0.0
        : universe.cracked.fold<int>(0, (n, c) => n + c.variants.length) /
            universe.cracked.length;
    stdout.writeln('${rels.length} rels, $found found in root');
    stdout.writeln('per rel (root+patch): ${per.toStringAsFixed(3)} ms');
    stdout.writeln('estimated per cracked card '
        '(${avgVariants.toStringAsFixed(1)} variants): '
        '${(per * avgVariants).toStringAsFixed(1)} ms');
  }

  stdout.writeln('\n== folder scan (new async path) ==');
  if (root.isEmpty) {
    stdout.writeln('(RootDirectory not configured — skipped)');
    return;
  }
  final cards = universe.cracked.take(200).toList();
  final dirs = <String>{};
  for (final card in cards) {
    for (final v in card.variants) {
      final i = v.rel.lastIndexOf('/');
      if (i > 0) dirs.add(v.rel.substring(0, i));
    }
  }
  final samples = dirs.toList();
  Future<int> listDir(String dir) async {
    var count = 0;
    try {
      await for (final e
          in Directory(p.join(root, dir)).list(followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.zip')) count++;
      }
    } catch (_) {}
    if (patch.isNotEmpty) {
      try {
        await for (final e
            in Directory(p.join(patch, dir)).list(followLinks: false)) {
          if (e is File && e.path.toLowerCase().endsWith('.zip')) count++;
        }
      } catch (_) {}
    }
    return count;
  }

  final seq = Stopwatch()..start();
  for (final d in samples) {
    await listDir(d);
  }
  seq.stop();
  stdout.writeln('${cards.length} cracked cards, ${samples.length} unique dirs');
  stdout.writeln('sequential: ${seq.elapsedMilliseconds} ms total, '
      '${(seq.elapsedMilliseconds / cards.length).toStringAsFixed(1)} ms/card');

  var next = 0;
  Future<void> worker() async {
    while (next < samples.length) {
      final d = samples[next++];
      await listDir(d);
    }
  }

  final conc = Stopwatch()..start();
  await Future.wait([for (var i = 0; i < 6; i++) worker()]);
  conc.stop();
  stdout.writeln('concurrent (6 workers): ${conc.elapsedMilliseconds} ms total, '
      '${(conc.elapsedMilliseconds / cards.length).toStringAsFixed(2)} ms/card '
      '(runs in the background)');
}
