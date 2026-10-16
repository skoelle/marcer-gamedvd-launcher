// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/widgets/settings_form.dart';

Future<void> _pumpForm(WidgetTester tester, DesktopConfig initial,
    void Function(DesktopConfig config, bool valid) onChanged) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SettingsForm(initial: initial, onChanged: onChanged),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('required root: empty blocks, valid directory enables',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('settings_form_test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    DesktopConfig? latest;
    bool? valid;
    await _pumpForm(tester, DesktopConfig(rootDirectory: ''),
        (c, v) {
      latest = c;
      valid = v;
    });

    // Empty mandatory field is invalid (red cross), saving blocked.
    expect(valid, isFalse);
    expect(find.byIcon(Icons.cancel), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);

    await tester.enterText(find.byType(TextField).first, dir.path);
    await tester.pump();

    expect(valid, isTrue);
    expect(latest!.rootDirectory, dir.path);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.cancel), findsNothing);
  });

  testWidgets('optional field: empty is fine, invalid value blocks saving',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('settings_form_test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    bool? valid;
    await _pumpForm(tester, DesktopConfig(rootDirectory: dir.path), (c, v) {
      valid = v;
    });

    // Root valid, PatchDirectory empty → only the root check icon.
    expect(valid, isTrue);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.cancel), findsNothing);

    // A filled but non-existent optional directory turns invalid and blocks.
    await tester.enterText(find.byType(TextField).at(1), '/definitely/missing');
    await tester.pump();
    expect(valid, isFalse);
    expect(find.byIcon(Icons.cancel), findsOneWidget);

    // Clearing it again is fine.
    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.pump();
    expect(valid, isTrue);
    expect(find.byIcon(Icons.cancel), findsNothing);
  });
}
