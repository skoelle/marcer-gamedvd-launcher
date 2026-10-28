// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/widgets/close_button.dart';
import 'package:marcer_desktop/widgets/game_lightbox.dart';

/// Previous/next navigation arrows next to the game lightbox (user request
/// 2026-10-28): arrows sit outside the image so they cannot be mistaken for
/// switching the screenshot; hidden when the window is too narrow.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const crackedTree = 'Title Sorted/Cracked Games - Title Sorted';
  const relAlpha = '$crackedTree/A/Alpha/alpha.zip';
  const relBeta = '$crackedTree/B/Beta/beta.zip';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('game_lightbox_test');
    for (final rel in [relAlpha, relBeta]) {
      final file = File('${tmp.path}/root/$rel');
      file.parent.createSync(recursive: true);
      file.createSync();
    }
    Directory('${tmp.path}/patch/$crackedTree').createSync(recursive: true);
    Directory('${tmp.path}/data').createSync(recursive: true);
    Directory('${tmp.path}/out').createSync(recursive: true);
    File('${tmp.path}/out/index.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'entries': {
          relAlpha: {
            'rel': relAlpha,
            'name': 'alpha.zip',
            'status': 'done',
            'kind': 'game',
            'layer': 'ROOT',
            'preview': 'alpha.png',
            'candidates': <String>[],
          },
          relBeta: {
            'rel': relBeta,
            'name': 'beta.zip',
            'status': 'done',
            'kind': 'game',
            'layer': 'ROOT',
            'preview': 'beta.png',
            'candidates': <String>[],
          },
        },
      }),
    );
    c = CatalogController(
      DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        patchDirectory: '${tmp.path}/patch',
        screenshotDirectory: '${tmp.path}/out',
        gameinfoDirectory: '${tmp.path}/data',
      ),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpLightbox(
    WidgetTester tester, {
    Size size = const Size(1700, 900),
    int selected = 0,
    List<String>? fixedRels,
    int initialIndex = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await c.init();
    });
    c.selectedIndex = selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GameLightbox(
            controller: c,
            fixedRels: fixedRels,
            initialIndex: initialIndex,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('wide windows show the neighbour title next to the arrow', (
    tester,
  ) async {
    await pumpLightbox(tester);
    expect(c.catalogCards, hasLength(2));
    expect(find.byType(DialogCloseButton), findsOneWidget);
    final position = tester.getRect(
      find.byKey(const ValueKey('lightbox-position')),
    );
    final close = tester.getRect(find.byType(DialogCloseButton));
    expect(close.left - position.right, greaterThanOrEqualTo(11));

    expect(find.byKey(const ValueKey('lightbox-prev-item')), findsNothing);
    final next = find.byKey(const ValueKey('lightbox-next-item'));
    expect(next, findsOneWidget);
    expect(
      find.descendant(of: next, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: next, matching: find.text(c.catalogCards[1].name)),
      findsOneWidget,
    );
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: next, matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, contains(c.catalogCards[1].name));
  });

  testWidgets('explicit release list navigates across games', (tester) async {
    await pumpLightbox(tester, fixedRels: [relAlpha, relBeta]);
    final names = c.catalogCards.map((card) => card.name).toList();
    expect(names, hasLength(2));

    expect(find.byKey(const ValueKey('lightbox-prev-item')), findsNothing);
    final next = find.byKey(const ValueKey('lightbox-next-item'));
    expect(
      find.descendant(of: next, matching: find.text(names[1])),
      findsOneWidget,
    );

    await tester.tap(next);
    await tester.pump();

    expect(
      c.selectedIndex,
      0,
      reason: 'crew navigation must not move the catalog selection',
    );
    final prev = find.byKey(const ValueKey('lightbox-prev-item'));
    expect(prev, findsOneWidget);
    expect(
      find.descendant(of: prev, matching: find.text(names[0])),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('lightbox-next-item')), findsNothing);
  });

  testWidgets('clicking an arrow navigates like the arrow key', (tester) async {
    await pumpLightbox(tester);

    await tester.tap(find.byKey(const ValueKey('lightbox-next-item')));
    await tester.pump();

    expect(find.byKey(const ValueKey('lightbox-next-item')), findsNothing);
    final prev = find.byKey(const ValueKey('lightbox-prev-item'));
    expect(prev, findsOneWidget);
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: prev, matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, contains(c.catalogCards[0].name));

    await tester.tap(prev);
    await tester.pump();

    expect(find.byKey(const ValueKey('lightbox-prev-item')), findsNothing);
    expect(find.byKey(const ValueKey('lightbox-next-item')), findsOneWidget);
  });

  testWidgets('tight space shows the arrow without a title', (tester) async {
    await pumpLightbox(tester, size: const Size(1366, 800));

    final next = find.byKey(const ValueKey('lightbox-next-item'));
    expect(next, findsOneWidget);
    expect(
      find.descendant(of: next, matching: find.byIcon(Icons.chevron_right)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: next, matching: find.text(c.catalogCards[1].name)),
      findsNothing,
    );
  });

  testWidgets('arrows are hidden when the window is too narrow', (
    tester,
  ) async {
    await pumpLightbox(tester, size: const Size(1280, 800), selected: 1);

    expect(find.byKey(const ValueKey('lightbox-prev-item')), findsNothing);
    expect(find.byKey(const ValueKey('lightbox-next-item')), findsNothing);
  });
}
