// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/config_locator.dart';
import 'package:marcer_desktop/widgets/setup_page.dart';
import 'package:path/path.dart' as p;

FilledButton _saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));

void main() {
  testWidgets('first-run setup writes the config and reports the path',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tmp = Directory.systemTemp.createTempSync('setup_page_test');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final root = Directory('${tmp.path}/root')..createSync();
    final saveDir = Directory('${tmp.path}/save')..createSync();

    DesktopConfig? configured;
    String? configuredPath;
    await tester.pumpWidget(MaterialApp(
      home: SetupPage(
        saveDirs: [saveDir.path],
        onConfigured: (config, path) {
          configured = config;
          configuredPath = path;
        },
      ),
    ));
    await tester.pumpAndSettle();

    // No config yet: Save blocked until the mandatory root is valid.
    expect(_saveButton(tester).onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, root.path);
    await tester.pumpAndSettle();
    expect(_saveButton(tester).onPressed, isNotNull);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(configured, isNotNull);
    expect(configuredPath, p.join(saveDir.path, kConfigFileName));
    expect(File(configuredPath!).existsSync(), isTrue);
    expect(DesktopConfig.load(configuredPath!).rootDirectory, root.path);
  });

  testWidgets('setup overwrites a known config path (error recovery)',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tmp = Directory.systemTemp.createTempSync('setup_page_test');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final root = Directory('${tmp.path}/root')..createSync();
    final target = '${tmp.path}/$kConfigFileName';
    File(target).writeAsStringSync('{ not json');

    String? configuredPath;
    await tester.pumpWidget(MaterialApp(
      home: SetupPage(
        saveDirs: [tmp.path],
        configPath: target,
        onConfigured: (config, path) => configuredPath = path,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, root.path);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(configuredPath, target);
    expect(DesktopConfig.load(target).rootDirectory, root.path);
  });

  testWidgets('lists the searched config locations', (tester) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tmp = Directory.systemTemp.createTempSync('setup_page_test');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    await tester.pumpWidget(MaterialApp(
      home: SetupPage(
        saveDirs: [tmp.path],
        searchDirs: ['/search/one', '/search/two'],
        onConfigured: (_, _) {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('/search/one'), findsOneWidget);
    expect(find.textContaining('/search/two'), findsOneWidget);
  });
}
