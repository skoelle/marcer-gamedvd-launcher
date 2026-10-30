// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/widgets/detail_panel.dart';

/// Browse-mode detail panel: release fields from an ambiguous/first gameinfo
/// variant must be hidden, while reliable `crews.json` fallback values (not
/// inferred) must stay visible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const tree = 'Title Sorted/Cracked Games - Title Sorted';
  const relA = '$tree/A/Alpha/a.zip';
  const relB = '$tree/B/Beta/b.zip';

  Map<String, dynamic> screenshotEntry(String rel, String name) => {
    'rel': rel,
    'name': name,
    'status': 'done',
    'kind': 'game',
    'layer': 'ROOT',
    'preview': null,
    'candidates': <String>[],
  };

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('detail_panel_test');
    for (final rel in [relA, relB]) {
      final file = File('${tmp.path}/root/$rel');
      file.parent.createSync(recursive: true);
      file.createSync();
    }
    Directory('${tmp.path}/data').createSync(recursive: true);
    Directory('${tmp.path}/out').createSync(recursive: true);

    File('${tmp.path}/out/index.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'entries': {
          relA: screenshotEntry(relA, 'a.zip'),
          relB: screenshotEntry(relB, 'b.zip'),
        },
      }),
    );

    File('${tmp.path}/data/games-cracked.json').writeAsStringSync(
      jsonEncode({
        'games': [
          {
            'letter': 'A',
            'folder': 'Alpha',
            'layers': ['ROOT'],
            'matched_via': 'folder',
            'matched_title': 'Alpha',
            'variants': [
              {
                'title': 'Alpha',
                'publisher': 'Publisher A',
                'crew': '',
                'cracked_by': '',
                'release': '1990',
              },
              {
                'title': 'Alpha',
                'publisher': 'Publisher A',
                'crew': 'Unrelated Crew',
                'cracked_by': 'Unrelated Cracker',
                'release': '1991',
              },
            ],
          },
          {
            'letter': 'B',
            'folder': 'Beta',
            'layers': ['ROOT'],
            'matched_via': 'folder',
            'matched_title': 'Beta',
            'variants': [
              {
                'title': 'Beta',
                'publisher': 'Publisher B',
                'crew': 'Wrong Crew',
                'cracked_by': 'Wrong Cracker',
                'release': '1990',
              },
              {
                'title': 'Beta',
                'publisher': 'Publisher B',
                'crew': 'Other Crew',
                'cracked_by': 'Other Cracker',
                'release': '1991',
              },
            ],
          },
        ],
      }),
    );

    File('${tmp.path}/data/crews.json').writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'generated_at': '2026-10-24T00:00:00Z',
        'groups': [
          {
            'id': 'reliable-crew',
            'name': 'Reliable Crew',
            'kind': 'crew',
            'rank': 1,
            'zips': 1,
            'aliases': ['Reliable Crew'],
            'image': null,
            'releases': [
              {
                'rel': relA,
                'letter': 'A',
                'folder': 'Alpha',
                'zip': 'a.zip',
                'title': 'Alpha',
                'year': '1990',
                'publisher': 'Publisher A',
                'crew': 'Reliable Crew',
                'cracked_by': 'Reliable Cracker',
                'source': 'exact',
                'disks': 1,
              },
            ],
          },
        ],
      }),
    );

    c = CatalogController(
      DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        screenshotDirectory: '${tmp.path}/out',
        gameinfoDirectory: '${tmp.path}/data',
      ),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> openZip(
    WidgetTester tester,
    String folderRel,
    String zipName,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() => c.init());
    c.toggleView();
    c.setPath(folderRel);
    final index = c.visibleEntries.indexWhere((e) => e.name == zipName);
    expect(index, isNonNegative, reason: '$zipName must be listed');
    c.moveSelectionTo(index);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 520,
            height: 1200,
            child: DetailPanel(controller: c),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'shows reliable crews.json fallback when no variant matches the ZIP',
    (tester) async {
      await openZip(tester, '$tree/A/Alpha', 'a.zip');

      expect(
        find.text('Reliable Crew', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text('Reliable Cracker', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('inferred', findRichText: true),
        findsNothing,
      );
      expect(
        find.text('Unrelated Crew', findRichText: true),
        findsNothing,
      );
      expect(
        find.text('Unrelated Cracker', findRichText: true),
        findsNothing,
      );
    },
  );

  testWidgets(
    'still hides release fields from the non-matching first variant',
    (tester) async {
      await openZip(tester, '$tree/B/Beta', 'b.zip');

      expect(find.text('Wrong Crew', findRichText: true), findsNothing);
      expect(find.text('Wrong Cracker', findRichText: true), findsNothing);
      expect(find.text('Other Crew', findRichText: true), findsNothing);
      expect(find.text('Other Cracker', findRichText: true), findsNothing);
    },
  );
}
