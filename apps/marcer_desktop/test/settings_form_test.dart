// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_assets.dart';
import 'package:marcer_desktop/widgets/settings_form.dart';

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
    AssetProgress? onProgress,
    bool Function()? isCancelled,
  }) =>
      completer.future;
}

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

  testWidgets('FTP fields are free text, never block and round-trip',
      (tester) async {
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
    await tester.pumpWidget(MaterialApp(
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
    ));
    await tester.pumpAndSettle();
    expect(busy, isNot(true));

    await tester.tap(find.text('Download from FTP').first);
    await tester.pump();
    expect(busy, isTrue);

    downloader.completer.complete(const AssetDownloadResult(
        archive: 'screenshots-20261017-080230.zip', upToDate: false));
    await tester.pumpAndSettle();
    expect(busy, isFalse);
  });
}
