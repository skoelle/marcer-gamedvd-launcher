// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/widgets/close_button.dart';
import 'package:marcer_desktop/widgets/help_overlay.dart';

void main() {
  testWidgets('lists catalog, lightbox and mouse controls', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HelpOverlay(onClose: () {}),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('CATALOG / FOLDER VIEW'), findsOneWidget);
    expect(find.textContaining('LIGHTBOX'), findsOneWidget);
    expect(find.textContaining('Previous / next image'), findsOneWidget);
    expect(find.textContaining('MOUSE / DETAILS'), findsOneWidget);
    expect(find.textContaining('ROOT / PATCH'), findsOneWidget);
  });

  testWidgets('lays out catalog and lightbox side by side', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: HelpOverlay(onClose: () {}),
    ));
    await tester.pumpAndSettle();

    final catalog = tester.getTopLeft(find.byKey(const Key('help-catalog')));
    final lightbox = tester.getTopLeft(find.byKey(const Key('help-lightbox')));
    final mouse = tester.getTopLeft(find.byKey(const Key('help-mouse')));
    final notes = tester.getTopLeft(find.byKey(const Key('help-notes')));

    expect(catalog.dy, closeTo(lightbox.dy, 0.5));
    expect(catalog.dx, lessThan(lightbox.dx));
    expect(mouse.dy, greaterThan(catalog.dy));
    expect(mouse.dy, closeTo(notes.dy, 0.5));
    expect(mouse.dx, lessThan(notes.dx));
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, 0);
  });

  testWidgets('stacks the sections in narrow windows', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: HelpOverlay(onClose: () {}),
    ));
    await tester.pumpAndSettle();

    final catalog = tester.getTopLeft(find.byKey(const Key('help-catalog')));
    final lightbox = tester.getTopLeft(find.byKey(const Key('help-lightbox')));
    final mouse = tester.getTopLeft(find.byKey(const Key('help-mouse')));
    final notes = tester.getTopLeft(find.byKey(const Key('help-notes')));

    expect(lightbox.dy, greaterThan(catalog.dy));
    expect(mouse.dy, greaterThan(lightbox.dy));
    expect(notes.dy, greaterThan(mouse.dy));
  });

  testWidgets('any key dismisses the overlay', (tester) async {
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      home: HelpOverlay(onClose: () => closed = true),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  testWidgets('the header close button dismisses the overlay', (tester) async {
    var closed = false;
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: HelpOverlay(onClose: () => closed = true),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(DialogCloseButton), findsOneWidget);
    await tester.tap(find.byType(DialogCloseButton));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });
}
