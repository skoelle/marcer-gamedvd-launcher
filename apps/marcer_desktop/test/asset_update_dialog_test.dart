// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/asset_updater.dart';
import 'package:marcer_desktop/catalog_assets.dart';
import 'package:marcer_desktop/piratefinder_data.dart';
import 'package:marcer_desktop/widgets/asset_update_dialog.dart';

void main() {
  testWidgets('shows gameinfo before screenshots with update/skip/close', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tmp = Directory.systemTemp.createTempSync('asset_dialog_test');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    Directory('${tmp.path}/root').createSync();
    Directory('${tmp.path}/screens').createSync();
    Directory('${tmp.path}/data').createSync();

    final controller = AssetUpdateController(
      fetcher: (_) async {
        return jsonEncode({
          'screenshots': {'archive': 'screenshots-2.zip'},
          'gameinfo': {'archive': 'gameinfo-2.zip'},
        });
      },
    );
    controller.config = DesktopConfig(
      rootDirectory: '${tmp.path}/root',
      screenshotDirectory: '${tmp.path}/screens',
      gameinfoDirectory: '${tmp.path}/data',
      ftpHost: 'ftp.example.com',
    );
    await controller.check(force: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAssetUpdateDialog(
                  context,
                  controller: controller,
                  onApplied: () {},
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

    expect(find.text('game info'), findsOneWidget);
    expect(find.text('screenshots'), findsOneWidget);
    // gameinfo row is rendered above the screenshots row.
    expect(
      tester.getTopLeft(find.text('game info')).dy,
      lessThan(tester.getTopLeft(find.text('screenshots')).dy),
    );
    // Both are pending (nothing applied) → Install buttons + skip + close.
    expect(find.text('Install'), findsNWidgets(2));
    expect(find.text('Skip this version'), findsNWidgets(2));
    expect(find.text('Close'), findsOneWidget);

    // Skip gameinfo → its row becomes up to date, screenshots stays pending.
    await tester.tap(find.text('Skip this version').first);
    await tester.pumpAndSettle();
    expect(controller.pendingAssets(), [CatalogAsset.screenshots]);
    expect(find.text('up to date'), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
  });

  testWidgets('shows version unknown + Overwrite when data is present', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tmp = Directory.systemTemp.createTempSync('asset_dialog_unknown');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    Directory('${tmp.path}/root').createSync();
    Directory('${tmp.path}/screens').createSync();
    Directory('${tmp.path}/data').createSync();
    // Screenshots data present but no marker (version unknown); gameinfo absent.
    File('${tmp.path}/screens/index.json').writeAsStringSync('{}');

    final controller = AssetUpdateController(
      fetcher: (_) async {
        return jsonEncode({
          'screenshots': {'archive': 'screenshots-2.zip'},
          'gameinfo': {'archive': 'gameinfo-2.zip'},
        });
      },
    );
    controller.config = DesktopConfig(
      rootDirectory: '${tmp.path}/root',
      screenshotDirectory: '${tmp.path}/screens',
      gameinfoDirectory: '${tmp.path}/data',
      ftpHost: 'ftp.example.com',
    );
    await controller.check(force: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAssetUpdateDialog(
                  context,
                  controller: controller,
                  onApplied: () {},
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

    expect(find.text('local:  version unknown (data present)'), findsOneWidget);
    expect(find.text('Overwrite'), findsOneWidget); // screenshots
    expect(find.text('Install'), findsOneWidget); // gameinfo (no data)
  });
  testWidgets(
    'shows PirateFinder-Catalog install hint and license in the same dialog',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tmp = Directory.systemTemp.createTempSync('asset_dialog_pf');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      Directory('${tmp.path}/root').createSync();

      final assets = AssetUpdateController(fetcher: (_) async => '{}');
      assets.config = DesktopConfig(rootDirectory: '${tmp.path}/root');
      await assets.check(force: true);

      final pf = PirateFinderDataController(
        fetcher: (_) async {
          return jsonEncode({
            'generated_at': '2026-10-24T12:34:16Z',
            'source': {'tag': 'catalogue-2026-10-19'},
            'assets': {
              'atari-st': {
                'file': 'piratefinder-catalog-atari-st.json.gz',
                'size': 10,
                'sha256': 'abc',
              },
            },
          });
        },
      );
      pf.config = DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        appDir: tmp.path,
      );
      await pf.check(force: true);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showAssetUpdateDialog(
                    context,
                    controller: assets,
                    pirateFinder: pf,
                    onApplied: () {},
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

      expect(find.text('PirateFinder-Catalog'), findsOneWidget);
      expect(find.text('local:  not installed'), findsOneWidget);
      expect(find.text('Install'), findsOneWidget);
      expect(find.text('PirateFinder-Catalog on GitHub'), findsOneWidget);
      expect(
        find.text(' · CC BY-NC-SA 4.0 · not part of the Marcer catalog'),
        findsOneWidget,
      );
    },
  );
}
