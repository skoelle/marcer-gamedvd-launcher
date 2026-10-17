// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/widgets/settings_dialog.dart';

Future<void> _openDialog(WidgetTester tester, DesktopConfig config,
    void Function(DesktopConfig?) onResult) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              onResult(await showSettingsDialog(context, config: config));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

FilledButton _saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));

void main() {
  testWidgets('settings dialog saves edits once the paths are valid',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('settings_dialog_test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final exe = File('${dir.path}/hatari')..createSync();
    final original = DesktopConfig(rootDirectory: '/old', hatariExecutable: exe.path);
    DesktopConfig? result;

    await _openDialog(tester, original, (r) => result = r);

    expect(find.text('Settings'), findsOneWidget);
    // 7 path fields + 5 FTP fields (host/user/password/remote base/assets).
    expect(find.byType(TextField), findsNWidgets(11));
    // Invalid mandatory root + optional fields empty: Save is disabled.
    expect(_saveButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, dir.path);
    await tester.pumpAndSettle();
    expect(_saveButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.rootDirectory, dir.path);
    // Untouched fields are preserved by copyWith.
    expect(result!.hatariExecutable, exe.path);
  });

  testWidgets('settings dialog keeps Save disabled on an invalid root',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final original = DesktopConfig(rootDirectory: '/old');
    DesktopConfig? result;

    await _openDialog(tester, original, (r) => result = r);

    await tester.enterText(find.byType(TextField).first, '/definitely/missing');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(_saveButton(tester).onPressed, isNull);
    expect(result, isNull);
    expect(find.text('Settings'), findsOneWidget);
  });
}
