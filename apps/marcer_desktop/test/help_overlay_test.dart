// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
