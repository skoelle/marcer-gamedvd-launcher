// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/widgets/filter_bar.dart';

/// A reset of the global filters (`clear`, Backspace in catalog mode, a
/// reloaded controller) must also clear the visible search field, not just
/// `filter.q`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('filter_bar_search_test');
    for (final d in ['root', 'out', 'data']) {
      Directory('${tmp.path}/$d').createSync();
    }
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  final searchField = find.byKey(const ValueKey('catalog-search'));

  Future<CatalogController> pumpFilterBar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final c = (await tester.runAsync(() async {
      final c = CatalogController(DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        screenshotDirectory: '${tmp.path}/out',
        gameinfoDirectory: '${tmp.path}/data',
      ));
      await c.init();
      return c;
    }))!;
    addTearDown(c.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FilterBar(controller: c, searchFocus: focus),
      ),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(searchField).controller!.text;

  testWidgets('clear empties the search field and the query', (tester) async {
    final c = await pumpFilterBar(tester);

    await tester.enterText(searchField, 'zzz');
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.filter.q, 'zzz');
    expect(fieldText(tester), 'zzz');

    await tester.ensureVisible(find.text('clear'));
    await tester.tap(find.text('clear'));
    await tester.pumpAndSettle();

    expect(c.filter.q, '');
    expect(fieldText(tester), '');
  });

  testWidgets('Backspace reset in catalog mode also empties the field',
      (tester) async {
    final c = await pumpFilterBar(tester);

    await tester.enterText(searchField, 'zzz');
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.filter.q, 'zzz');

    c.parent();
    await tester.pumpAndSettle();

    expect(c.filter.q, '');
    expect(fieldText(tester), '');
  });

  testWidgets('facet menu filters and selects a publisher', (tester) async {
    const rel =
        'Title Sorted/Cracked Games - Title Sorted/P/Publisher Test/pt.zip';
    File('${tmp.path}/out/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        rel: {
          'rel': rel,
          'name': 'pt.zip',
          'status': 'done',
          'kind': 'game',
          'layer': 'ROOT',
          'preview': null,
          'candidates': <String>[],
        },
      },
    }));
    File('${tmp.path}/data/games-cracked.json').writeAsStringSync(jsonEncode({
      'games': [
        {
          'letter': 'P',
          'folder': 'Publisher Test',
          'layers': ['ROOT'],
          'matched_via': 'folder',
          'matched_title': 'Publisher Test',
          'variants': [
            {'publisher': 'Acme', 'release': '1990'},
            {'publisher': 'Beta', 'release': '1991'},
          ],
        },
      ],
    }));

    final c = await pumpFilterBar(tester);
    expect(c.facets.publishers, containsAll(<String>['Acme', 'Beta']));

    await tester.tap(find.text('Publisher: any'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Acme'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    // The menu is virtualized; typing filters the list without rebuilding all
    // entries (the filter field is the last TextField in the overlay).
    await tester.enterText(find.byType(TextField).last, 'acme');
    await tester.pump();
    expect(find.text('Acme'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);

    await tester.tap(find.text('Acme'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.filter.publisher, 'Acme');
  });
}
