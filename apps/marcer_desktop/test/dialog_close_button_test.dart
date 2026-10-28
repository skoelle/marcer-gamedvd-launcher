// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/widgets/close_button.dart';

void main() {
  Future<void> pumpButton(
    WidgetTester tester, {
    required double width,
    required VoidCallback onPressed,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: DialogCloseButton(onPressed: onPressed)),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows the label at normal window widths', (tester) async {
    var taps = 0;
    await pumpButton(tester, width: 1000, onPressed: () => taps++);

    expect(find.text('Close (Esc)'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byTooltip('Close (Esc)'), findsOneWidget);
    expect(tester.getSize(find.byType(DialogCloseButton)).height, 28);

    await tester.tap(find.byType(DialogCloseButton));
    expect(taps, 1);
  });

  testWidgets('collapses to the icon on narrow windows', (tester) async {
    var taps = 0;
    await pumpButton(tester, width: 600, onPressed: () => taps++);

    expect(find.text('Close (Esc)'), findsNothing);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byTooltip('Close (Esc)'), findsOneWidget);

    await tester.tap(find.byType(DialogCloseButton));
    expect(taps, 1);
  });
}
