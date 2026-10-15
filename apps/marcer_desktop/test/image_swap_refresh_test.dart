// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:path/path.dart' as p;

/// 1x1 red PNG.
const List<int> kRed1x1 = [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0,
  0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 120,
  156, 99, 248, 207, 192, 0, 0, 3, 1, 1, 0, 201, 254, 146, 239, 0, 0, 0, 0, 73,
  69, 78, 68, 174, 66, 96, 130
];

/// 2x2 blue PNG.
const List<int> kBlue2x2 = [
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0,
  0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 15, 73, 68, 65, 84, 120,
  156, 99, 96, 96, 248, 15, 70, 96, 10, 0, 23, 246, 3, 253, 126, 235, 55, 243,
  0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130
];

double? renderedWidth(WidgetTester tester) {
  final found = find.byType(RawImage);
  if (found.evaluate().isEmpty) return null;
  return tester.widget<RawImage>(found).image?.width.toDouble();
}

/// Runs real async work (file IO + decode) until [done] or the attempt cap.
Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  testWidgets('M swap: keyed Image re-reads the swapped file from disk',
      (tester) async {
    final tmp = Directory.systemTemp.createTempSync('swap_refresh_test_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    // The pair `M` exchanges: main preview (1x1) and a candidate (2x2).
    final preview = File(p.join(tmp.path, 'a.png'))..writeAsBytesSync(kRed1x1);
    final cand = File(p.join(tmp.path, 'a_c01.png'))
      ..writeAsBytesSync(kBlue2x2);

    final c = CatalogController(DesktopConfig(
      rootDirectory: p.join(tmp.path, 'root'),
      outDirectory: tmp.path,
      dataDirectory: p.join(tmp.path, 'data'),
    ));

    // Same wiring as the real call sites (grid/detail/filmstrip): a
    // per-path ValueKey fed by imageVersionOf, rebuilt via the controller.
    Widget tree() => ListenableBuilder(
          listenable: c,
          builder: (context, _) => MaterialApp(
            home: Scaffold(
              body: Image.file(
                preview,
                key: ValueKey(
                    '${preview.path}#${c.imageVersionOf(preview.path)}'),
              ),
            ),
          ),
        );

    await tester.pumpWidget(tree());
    await settleUntil(tester, () => renderedWidth(tester) == 1.0);
    expect(renderedWidth(tester), 1.0, reason: 'initial decode (1x1 red)');

    // The production swap: files exchange contents, image caches (keepAlive
    // AND live) are flushed, versions bump, views rebuild.
    final err =
        c.swapPreviewImage(previewPath: preview.path, candidatePath: cand.path);
    expect(err, isNull);
    expect(preview.readAsBytesSync(), kBlue2x2,
        reason: 'preview now holds the candidate bytes');

    await tester.pump(); // rebuild with the bumped ValueKey
    await settleUntil(tester, () => renderedWidth(tester) == 2.0);
    expect(renderedWidth(tester), 2.0,
        reason: 'the recreated Image must re-read the swapped file — '
            'a stale (live) ImageStreamCompleter would keep painting 1x1');
  });
}
