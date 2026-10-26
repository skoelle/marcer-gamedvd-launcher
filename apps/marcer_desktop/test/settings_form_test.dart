// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/atarilegend_fetcher.dart';
import 'package:marcer_desktop/catalog_assets.dart';
import 'package:marcer_desktop/hatari_installer.dart';
import 'package:marcer_desktop/piratefinder_data.dart';
import 'package:marcer_desktop/widgets/settings_form.dart';
import 'package:path/path.dart' as p;

/// Downloader whose future only completes when the test says so.
class _HangingDownloader implements CatalogAssetDownloader {
  final Completer<AssetDownloadResult> completer =
      Completer<AssetDownloadResult>();

  @override
  Future<AssetDownloadResult> download({
    required CatalogAsset asset,
    required DesktopConfig config,
    required String targetDir,
    bool force = false,
    String? expectedSha256,
    AssetProgress? onProgress,
    bool Function()? isCancelled,
  }) => completer.future;
}

/// Fake Hatari downloader that writes a stand-in executable into the install
/// directory and returns its path.
class _FakeHatariDownloader implements HatariDownloader {
  @override
  Future<String> download(
    HatariBuild build,
    String installDir, {
    HatariInstallProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    Directory(installDir).createSync(recursive: true);
    final exe = File(p.join(installDir, 'hatari.exe'))
      ..writeAsBytesSync(List<int>.filled(8, 0x7F));
    return exe.path;
  }
}

/// Fake AtariLegend fetcher whose future only completes on demand.
class _HangingAtariLegendFetcher implements AtariLegendFetcher {
  final Completer<AtariLegendFetchResult> completer =
      Completer<AtariLegendFetchResult>();
  String? lastTargetDir;

  @override
  Future<AtariLegendFetchResult> fetch({
    required String targetDir,
    AtariLegendProgress? onProgress,
    bool Function()? isCancelled,
  }) {
    lastTargetDir = targetDir;
    return completer.future;
  }

  @override
  Future<String?> latestDump() async => null;
}

class _FakePirateFinderDownloader implements PirateFinderDownloader {
  String? lastTargetDir;
  int calls = 0;

  @override
  Future<void> download({
    required PirateFinderRemoteAsset asset,
    required String targetDir,
    PirateFinderProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    calls++;
    lastTargetDir = targetDir;
    Directory(targetDir).createSync(recursive: true);
    File(p.join(targetDir, asset.file)).writeAsStringSync('fake catalogue');
    onProgress?.call('Downloading…', 1, 1);
  }
}

Future<void> _pumpForm(
  WidgetTester tester,
  DesktopConfig initial,
  void Function(DesktopConfig config, bool valid) onChanged,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsForm(initial: initial, onChanged: onChanged),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('required root: empty blocks, valid directory enables', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('settings_form_test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    DesktopConfig? latest;
    bool? valid;
    await _pumpForm(tester, DesktopConfig(rootDirectory: ''), (c, v) {
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

  testWidgets('optional field: empty is fine, invalid value blocks saving', (
    tester,
  ) async {
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

  testWidgets('FTP fields are free text, never block and round-trip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('settings_form_ftp');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    DesktopConfig? latest;
    bool? valid;
    await _pumpForm(tester, DesktopConfig(rootDirectory: dir.path), (c, v) {
      latest = c;
      valid = v;
    });
    // Fields 2..6 are the FTP fields (host/user/password/remote base/assets).
    await tester.enterText(find.byType(TextField).at(2), 'ftp.example.com');
    await tester.enterText(find.byType(TextField).at(3), 'anon');
    await tester.enterText(find.byType(TextField).at(4), 'secret');
    await tester.enterText(find.byType(TextField).at(5), 'not/a/real/path');
    await tester.enterText(find.byType(TextField).at(6), '/upload/assets');
    await tester.pump();

    expect(valid, isTrue, reason: 'FTP fields are never path-validated');
    expect(find.byIcon(Icons.cancel), findsNothing);
    expect(latest!.ftpHost, 'ftp.example.com');
    expect(latest!.ftpUser, 'anon');
    expect(latest!.ftpPassword, 'secret');
    expect(latest!.ftpRemoteBase, 'not/a/real/path');
    expect(latest!.ftpAssetsRemote, '/upload/assets');
  });

  testWidgets('CosmosEx fields round-trip and validate the share directory', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('settings_form_cosmosex');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final share = Directory(p.join(dir.path, 'floppyImages'))..createSync();

    DesktopConfig? latest;
    bool? valid;
    await _pumpForm(tester, DesktopConfig(rootDirectory: dir.path), (c, v) {
      latest = c;
      valid = v;
    });

    await tester.tap(find.byKey(const Key('settings-tab-cosmosex')));
    await tester.pumpAndSettle();

    // On the CosmosEx tab: host/password/MAC/share are fields 0..3.
    await tester.enterText(find.byType(TextField).at(0), 'cosmosex.local');
    await tester.enterText(find.byType(TextField).at(1), 'secret');
    await tester.enterText(find.byType(TextField).at(2), 'AA:BB:CC:DD:EE:FF');
    await tester.enterText(find.byType(TextField).at(3), share.path);
    await tester.pump();

    expect(valid, isTrue);
    expect(latest!.cosmosExHost, 'cosmosex.local');
    expect(latest!.cosmosExPassword, 'secret');
    expect(latest!.cosmosExMac, 'AA:BB:CC:DD:EE:FF');
    expect(latest!.cosmosExShareDirectory, share.path);
    expect(latest!.cosmosExMode, 'auto');

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('legacy — ce-atari ZIP upload').last);
    await tester.pumpAndSettle();
    expect(latest!.cosmosExMode, 'legacy');

    // A filled but missing share blocks saving (optional when empty) and
    // marks the CosmosEx tab with a red dot.
    await tester.enterText(find.byType(TextField).at(3), '/missing/share');
    await tester.pump();
    expect(valid, isFalse);
    expect(
      find.byKey(const Key('settings-tab-error-cosmosex')),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField).at(3), '');
    await tester.pump();
    expect(valid, isTrue);
    expect(find.byKey(const Key('settings-tab-error-cosmosex')), findsNothing);

    // Values survive a tab switch; Library still holds the valid root.
    await tester.tap(find.byKey(const Key('settings-tab-library')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller?.text,
      dir.path,
    );
    await tester.tap(find.byKey(const Key('settings-tab-cosmosex')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller?.text,
      'cosmosex.local',
    );
  });

  testWidgets('reports busy while a download/extraction runs', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('settings_form_busy');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final downloader = _HangingDownloader();
    bool? busy;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsForm(
              initial: DesktopConfig(
                rootDirectory: dir.path,
                ftpHost: 'ftp.example.com',
                screenshotDirectory: dir.path,
              ),
              onChanged: (_, _) {},
              onBusyChanged: (b) => busy = b,
              assetDownloader: downloader,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(busy, isNot(true));

    await tester.tap(find.text('Download from FTP').first);
    await tester.pump();
    expect(busy, isTrue);

    downloader.completer.complete(
      const AssetDownloadResult(
        archive: 'screenshots-20261017-080230.zip',
        upToDate: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(busy, isFalse);
  });

  testWidgets('installing Hatari fills the executable field', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('settings_form_hatari');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    DesktopConfig? latest;
    const build = HatariBuild(
      os: 'test',
      label: 'Test',
      url: 'https://x/y.zip',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsForm(
              initial: DesktopConfig(rootDirectory: dir.path, appDir: dir.path),
              onChanged: (c, _) => latest = c,
              hatariDownloader: _FakeHatariDownloader(),
              hatariBuild: build,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings-tab-hatari')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install Hatari…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install Hatari'));
    await tester.pumpAndSettle();

    expect(latest!.hatariExecutable, p.join('hatari', 'hatari.exe'));
    expect(find.text('Hatari is installed'), findsOneWidget);
  });

  testWidgets('AtariLegend download targets DataDir/atarilegend', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('settings_form_al');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final fetcher = _HangingAtariLegendFetcher();
    DesktopConfig? latest;
    bool? valid;
    bool? busy;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsForm(
              initial: DesktopConfig(
                rootDirectory: dir.path,
                gameinfoDirectory: dir.path,
              ),
              onChanged: (c, v) {
                latest = c;
                valid = v;
              },
              onBusyChanged: (b) => busy = b,
              atariLegendFetcher: fetcher,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(valid, isTrue);
    expect(latest!.gameinfoDirectory, dir.path);

    final button = find.text('Download AtariLegend data');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(busy, isTrue);
    expect(fetcher.lastTargetDir, p.join(dir.path, 'atarilegend'));

    fetcher.completer.complete(
      AtariLegendFetchResult(
        games: 42,
        dumpFile: '2026-10-11.sql.gz',
        cachePath: p.join(dir.path, 'atarilegend', 'atarilegend.json'),
      ),
    );
    await tester.pumpAndSettle();
    expect(busy, isFalse);
  });

  testWidgets('AtariLegend row shows the applied dump date', (tester) async {
    tester.view.physicalSize = const Size(1400, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('settings_form_al_date');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    Directory(p.join(dir.path, 'atarilegend')).createSync();
    File(p.join(dir.path, 'atarilegend', kAtariLegendFileName))
        .writeAsStringSync(
          AtariLegendCache(
            generatedAt: '2026-10-19T10:00:00Z',
            sourceFile: '2026-10-18.sql.gz',
            dumpDate: '2026-10-18',
            games: const [],
          ).toJsonString(),
        );

    await _pumpForm(
      tester,
      DesktopConfig(rootDirectory: dir.path, gameinfoDirectory: dir.path),
      (_, _) {},
    );

    expect(find.text('installed · dump 2026-10-18'), findsOneWidget);
  });

  testWidgets(
    'PirateFinder-Catalog row has one download action and a GitHub link',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final dir = Directory.systemTemp.createTempSync('settings_form_pf');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      final downloader = _FakePirateFinderDownloader();
      var fetches = 0;
      final pf = PirateFinderDataController(
        fetcher: (_) async {
          fetches++;
          return jsonEncode({
            'generated_at': '2026-10-24T12:34:16Z',
            'source': {'tag': 'catalogue-2026-10-19'},
            'assets': {
              'atari-st': {
                'file': 'piratefinder-catalog-atari-st.json.gz',
                'size': 123,
                'sha256': 'abc123',
              },
            },
          });
        },
        downloader: downloader,
      );

      DesktopConfig? latest;
      bool? valid;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SettingsForm(
                initial: DesktopConfig(
                  rootDirectory: dir.path,
                  gameinfoDirectory: dir.path,
                ),
                onChanged: (c, v) {
                  latest = c;
                  valid = v;
                },
                pirateFinderData: pf,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(valid, isTrue);
      expect(latest!.gameinfoDirectory, dir.path);
      final button = find.widgetWithText(FilledButton, 'PirateFinder-Catalog');
      expect(button, findsOneWidget);
      expect(find.text('Check'), findsNothing);
      expect(find.text('Install'), findsNothing);
      expect(find.text('PirateFinder-Catalog on GitHub'), findsOneWidget);

      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(fetches, 1);
      expect(downloader.calls, 1);
      expect(downloader.lastTargetDir, p.join(dir.path, 'piratefinder'));
      expect(find.textContaining('installed · catalogue'), findsOneWidget);
    },
  );
}
