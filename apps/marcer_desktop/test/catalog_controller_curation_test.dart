// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/index_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const rel = 'A/Alpha/a.zip';
  const outRel = 'out';

  Map<String, dynamic> diskEntry() {
    final idx = jsonDecode(
            File('${tmp.path}/$outRel/index.json').readAsStringSync())
        as Map<String, dynamic>;
    return ((idx['entries'] as Map)[rel] as Map).cast<String, dynamic>();
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('curation_test');
    Directory('${tmp.path}/$outRel/A/Alpha').createSync(recursive: true);
    Directory('${tmp.path}/root').createSync(recursive: true);
    File('${tmp.path}/$outRel/A/Alpha/a.png').createSync();
    File('${tmp.path}/$outRel/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        rel: {
          'rel': rel,
          'name': 'a.zip',
          'status': 'desktop',
          'kind': 'textscreen',
          'layer': 'ROOT',
          'preview': 'a.png',
          'candidates': <String>[],
        },
      },
    }));
    c = CatalogController(DesktopConfig(
      rootDirectory: '${tmp.path}/root',
      outDirectory: '${tmp.path}/$outRel',
      dataDirectory: '${tmp.path}/data',
    ));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('applyStatusChange stays in-memory pending until save', () async {
    await c.init();
    expect(c.hasPendingStatusChanges, isFalse);

    c.applyStatusChange(rel, 'done', 'game');
    expect(c.hasPendingStatusChanges, isTrue);
    expect(c.pendingStatusCount, 1);
    expect(c.screenshots[rel]!.status, 'done');
    expect(c.screenshots[rel]!.kind, 'game');

    // cards rebuild from the mutated entry
    final card = c.catalogCards.first;
    expect(card.displayStatus, 'done');
    expect(card.variants.single.kind, 'game');

    // disk unchanged while pending
    expect(diskEntry()['status'], 'desktop');
    expect(diskEntry()['kind'], 'textscreen');

    final err = await c.savePendingStatusChanges();
    expect(err, isNull);
    expect(c.hasPendingStatusChanges, isFalse);
    expect(diskEntry()['status'], 'done');
    expect(diskEntry()['kind'], 'game');
  });

  test('discard restores the original values', () async {
    await c.init();
    c.applyStatusChange(rel, 'done', 'game');
    c.applyStatusChange(rel, 'desktop', 'darkscreen'); // second edit
    c.discardPendingStatusChanges();
    expect(c.hasPendingStatusChanges, isFalse);
    expect(c.screenshots[rel]!.status, 'desktop');
    expect(c.screenshots[rel]!.kind, 'textscreen');
  });

  test('save error (live lock) keeps the pending list intact', () async {
    await c.init();
    c.applyStatusChange(rel, 'done', 'game');
    final me = selfPid;
    if (me == null) {
      markTestSkipped('FFI pid lookup unavailable on this platform');
      return;
    }
    File('${tmp.path}/$outRel/shotgen.lock').writeAsStringSync('$me');
    final err = await c.savePendingStatusChanges();
    expect(err, isNotNull);
    expect(c.hasPendingStatusChanges, isTrue);
    expect(diskEntry()['status'], 'desktop');
    // lock file still there (ours refused; shotgen's untouched)
    expect(File('${tmp.path}/$outRel/shotgen.lock').existsSync(), isTrue);
  });

  group('swapPreviewImage (M)', () {
    late String preview;
    late String cand;

    setUp(() async {
      await c.init();
      preview = '${tmp.path}/$outRel/A/Alpha/a.png';
      cand = '${tmp.path}/$outRel/A/Alpha/a_c01.png';
      File(preview).writeAsStringSync('MAIN');
      File(cand).writeAsStringSync('CAND');
    });

    test('swaps contents, bumps both versions and notifies', () {
      expect(c.imageVersionOf(preview), '0');
      expect(c.imageVersionOf(cand), '0');
      var notified = 0;
      c.addListener(() => notified++);

      final err =
          c.swapPreviewImage(previewPath: preview, candidatePath: cand);

      expect(err, isNull);
      expect(File(preview).readAsStringSync(), 'CAND');
      expect(File(cand).readAsStringSync(), 'MAIN');
      // both paths share the bump; untouched paths stay at the default key
      expect(c.imageVersionOf(preview), '1');
      expect(c.imageVersionOf(cand), '1');
      expect(c.imageVersionOf('${tmp.path}/$outRel/A/Alpha/x.png'), '0');
      expect(notified, 1);

      // a second swap bumps again → keys change again
      expect(
          c.swapPreviewImage(previewPath: preview, candidatePath: cand),
          isNull);
      expect(c.imageVersionOf(preview), '2');
      expect(c.imageVersionOf(cand), '2');
    });

    test('refuses while the shotgen lock is live', () {
      final me = selfPid;
      if (me == null) {
        markTestSkipped('FFI pid lookup unavailable on this platform');
        return;
      }
      File('${tmp.path}/$outRel/shotgen.lock').writeAsStringSync('$me');

      final err =
          c.swapPreviewImage(previewPath: preview, candidatePath: cand);

      expect(err, isNotNull);
      expect(File(preview).readAsStringSync(), 'MAIN');
      expect(File(cand).readAsStringSync(), 'CAND');
      expect(c.imageVersionOf(preview), '0');
      expect(c.imageVersionOf(cand), '0');
    });

    test('reports a missing candidate without touching versions', () {
      final missing = '${tmp.path}/$outRel/A/Alpha/nope.png';

      final err =
          c.swapPreviewImage(previewPath: preview, candidatePath: missing);

      expect(err, startsWith('Swap failed'));
      expect(File(preview).readAsStringSync(), 'MAIN');
      expect(c.imageVersionOf(preview), '0');
      expect(c.imageVersionOf(missing), '0');
    });
  });
}
