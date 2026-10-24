// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/piratefinder_data.dart';
import 'package:marcer_desktop/widgets/piratefinder_dialog.dart';

PirateFinderIndex _index() => PirateFinderIndex.fromJson({
      'generated_at': '2026-10-24T12:34:16Z',
      'source': {'tag': 'catalogue-2026-10-19'},
      'sources': [
        {
          'id': 'atari-legend',
          'name': 'Atari Legend',
          'url': 'https://atarilegend.com',
          'licence': 'CC BY-NC-SA 4.0',
          'records': 10,
        },
      ],
      'series': [
        {
          'id': 'automation',
          'name': 'Automation',
          'platform': 'atari-st',
          'kind': 'menu',
          'group_name': 'Automation',
        },
      ],
      'crews': [
        {
          'id': 1,
          'name': 'Replicants',
          'platform': 'atari-st',
          'members': 'Orion, Snake',
          'founded': '1988',
          'notes': 'A crew founded in 1988.',
          'disk_count': 1,
        },
      ],
      'disks': [
        {
          'id': 1,
          'kind': 'single',
          'title': 'Arkanoid (1987)(Imagine)[cr Replicants]',
          'label': 'Arkanoid [cr Replicants]',
          'publisher': 'Imagine',
          'cracker': 'Replicants',
          'crew': 'Replicants',
          'crew_id': 1,
          'year': 1987,
        },
        {
          'id': 2,
          'series_id': 'automation',
          'kind': 'menu',
          'number': 250,
          'label': 'Automation 250',
          'title': 'Automation 250',
          'crew': 'Automation',
          'year': 1990,
        },
      ],
      'contents': [
        {'id': 10, 'disk_id': 1, 'position': 1, 'title': 'Arkanoid', 'kind': 'game'},
        {'id': 11, 'disk_id': 2, 'position': 1, 'title': 'Arkanoid', 'kind': 'game'},
      ],
      'trivia': [
        {
          'id': 900,
          'disk_id': 1,
          'kind': 'fact',
          'text': 'Cleaned and upscaled box art.',
          'source': 'atari-legend',
          'licence': 'CC BY-NC-SA 4.0',
        },
      ],
      'links': [
        {
          'disk_id': 1,
          'label': 'Atari Legend',
          'url': 'https://atarilegend.com/games/x',
        },
      ],
    });

class _FakeData extends PirateFinderDataController {
  _FakeData(this.index);

  final PirateFinderIndex index;

  @override
  Future<PirateFinderIndex?> ensureIndex({bool force = false}) async => index;
}

class _FakeController extends CatalogController {
  _FakeController(this.index) : super(DesktopConfig(rootDirectory: '')) {
    pirateFinderData = _FakeData(index);
  }

  final PirateFinderIndex index;

  @override
  Future<PirateFinderMatch?> pirateFinderMatchForEntry(
    Entry entry, {
    String? rel,
  }) async =>
      PirateFinderMatch(
        disk: index.disk(1)!,
        candidates: [index.disk(1)!, index.disk(2)!],
        method: 'hash',
        confidence: 'exact',
      );
}

void main() {
  testWidgets('PF dialog shows the tabs and attribution', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final index = _index();
    final controller = _FakeController(index);
    final entry = Entry(
      name: 'arkanoid.zip',
      kind: EntryKind.zip,
      inRoot: true,
      inPatch: false,
      rootPath: '/tmp/arkanoid.zip',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showPirateFinderDialog(
                  context,
                  controller: controller,
                  entry: entry,
                  rel: 'arkanoid.zip',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('PirateFinder'), findsOneWidget);
    expect(find.text('EXACT'), findsOneWidget);
    for (final tab in ['Release', 'Crew', 'Menus', 'Trivia', 'Sources']) {
      expect(find.widgetWithText(Tab, tab), findsOneWidget);
    }
    await tester.tap(find.widgetWithText(Tab, 'Crew'));
    await tester.pumpAndSettle();
    expect(find.textContaining('A crew founded in 1988.'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, 'Menus'));
    await tester.pumpAndSettle();
    expect(find.text('Automation 250'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, 'Sources'));
    await tester.pumpAndSettle();
    expect(find.textContaining('CC BY-NC-SA 4.0'), findsWidgets);
  });
}
