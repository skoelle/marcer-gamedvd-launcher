// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/widgets/open_folder_button.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('open_folder_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Widget build({
    required String? path,
    required Future<bool> Function(String) open,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: OpenFolderButton(
            path: path,
            label: 'ROOT',
            open: open,
          ),
        ),
      );

  testWidgets('opens the folder with the injected opener', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(build(
      path: tmp.path,
      open: (path) async {
        opened.add(path);
        return true;
      },
    ));

    await tester.tap(find.byIcon(Icons.folder_open));
    await tester.pumpAndSettle();

    expect(opened, [tmp.path]);
  });

  testWidgets('reports a missing folder without calling the opener',
      (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(build(
      path: p.join(tmp.path, 'missing'),
      open: (path) async {
        opened.add(path);
        return true;
      },
    ));

    await tester.tap(find.byIcon(Icons.folder_open));
    await tester.pumpAndSettle();

    expect(opened, isEmpty);
    expect(find.textContaining('Game folder not found'), findsOneWidget);
  });

  testWidgets('reports a failed launch', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(build(
      path: tmp.path,
      open: (path) async {
        opened.add(path);
        return false;
      },
    ));

    await tester.tap(find.byIcon(Icons.folder_open));
    await tester.pumpAndSettle();

    expect(opened, [tmp.path]);
    expect(find.textContaining('Could not open game folder'), findsOneWidget);
  });

  testWidgets('is disabled without a path', (tester) async {
    await tester.pumpWidget(build(path: null, open: (_) async => true));

    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('shows only existing layer folders and clears on change',
      (tester) async {
    final first = Completer<Set<String>>();
    final second = Completer<Set<String>>();

    Widget buildLayers(Future<Set<String>> layers) => MaterialApp(
          home: Scaffold(
            body: CardFolderButtons(
              layers: layers,
              pathFor: (_) => tmp.path,
            ),
          ),
        );

    await tester.pumpWidget(buildLayers(first.future));
    await tester.pump();
    expect(find.byIcon(Icons.folder_open), findsNothing);

    first.complete({'ROOT'});
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.folder_open), findsOneWidget);

    await tester.pumpWidget(buildLayers(second.future));
    await tester.pump();
    expect(find.byIcon(Icons.folder_open), findsNothing);

    second.complete({'ROOT', 'PATCH'});
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.folder_open), findsNWidgets(2));
  });
}
