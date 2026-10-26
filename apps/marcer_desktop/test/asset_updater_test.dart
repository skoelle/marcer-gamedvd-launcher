// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/asset_updater.dart';
import 'package:marcer_desktop/catalog_assets.dart';

/// Fake downloader that records the applied version (like the real one).
class _FakeDownloader implements CatalogAssetDownloader {
  String? lastExpectedSha256;

  @override
  Future<AssetDownloadResult> download({
    required CatalogAsset asset,
    required DesktopConfig config,
    required String targetDir,
    bool force = false,
    String? expectedSha256,
    AssetProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    lastExpectedSha256 = expectedSha256;
    onProgress?.call('Extracting 1/1 files…', 1, 1);
    writeAppliedAssetVersion(targetDir, asset, 'screenshots-2.zip');
    return const AssetDownloadResult(archive: 'x', upToDate: false);
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('asset_updater_test');
    Directory('${tmp.path}/root').createSync();
    Directory('${tmp.path}/screens').createSync();
    Directory('${tmp.path}/data').createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DesktopConfig config() => DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        screenshotDirectory: '${tmp.path}/screens',
        gameinfoDirectory: '${tmp.path}/data',
        ftpHost: 'ftp.example.com',
      );

  test('parseCatalogLatest reads archive/size/sha256 per asset', () {
    final parsed = parseCatalogLatest(jsonEncode({
      'schema': 1,
      'screenshots': {'archive': 'screenshots-2.zip', 'size': 5, 'sha256': 'AB'},
      'gameinfo': {'archive': 'gameinfo-2.zip'},
      'unknown': {'archive': 'x'},
    }))!;
    expect(parsed.assets[CatalogAsset.screenshots]!.archive, 'screenshots-2.zip');
    expect(parsed.assets[CatalogAsset.screenshots]!.size, 5);
    expect(parsed.assets[CatalogAsset.screenshots]!.sha256, 'AB');
    expect(parsed.assets[CatalogAsset.gameinfo]!.archive, 'gameinfo-2.zip');
    expect(parsed.assets, hasLength(2));
  });

  test('parseCatalogLatest returns null on malformed input', () {
    expect(parseCatalogLatest('not json'), isNull);
  });

  test('assetNeedsUpdate compares archive + skip + data presence', () {
    const remote = RemoteAsset(archive: 'screenshots-2.zip');
    expect(assetNeedsUpdate(remote: remote, local: null, skipped: null), isTrue);
    expect(
        assetNeedsUpdate(
            remote: remote, local: 'screenshots-2.zip', skipped: null),
        isFalse);
    // Marker matches but the data was removed → still an update.
    expect(
        assetNeedsUpdate(
            remote: remote,
            local: 'screenshots-2.zip',
            skipped: null,
            dataPresent: false),
        isTrue);
    // Skipped remote → never an update.
    expect(
        assetNeedsUpdate(
            remote: remote, local: 'screenshots-1.zip', skipped: 'screenshots-2.zip'),
        isFalse);
    expect(assetNeedsUpdate(remote: null, local: null, skipped: null), isFalse);
  });

  test('marker skip helpers round-trip and stay backward compatible', () {
    final dir = '${tmp.path}/screens';
    // Legacy marker (applied version only) → no skip entry.
    writeAppliedAssetVersion(dir, CatalogAsset.screenshots, 'screenshots-1.zip');
    expect(readAppliedAssetVersion(dir, CatalogAsset.screenshots),
        'screenshots-1.zip');
    expect(readSkippedAsset(dir, CatalogAsset.screenshots), isNull);

    writeSkippedAsset(dir, CatalogAsset.screenshots, 'screenshots-2.zip');
    expect(readSkippedAsset(dir, CatalogAsset.screenshots), 'screenshots-2.zip');
    // Applied version still readable next to the skip entry.
    expect(readAppliedAssetVersion(dir, CatalogAsset.screenshots),
        'screenshots-1.zip');

    clearSkippedAsset(dir, CatalogAsset.screenshots);
    expect(readSkippedAsset(dir, CatalogAsset.screenshots), isNull);
  });

  test('controller check marks newer archives pending (gameinfo first)', () async {
    final body = jsonEncode({
      'screenshots': {'archive': 'screenshots-2.zip'},
      'gameinfo': {'archive': 'gameinfo-2.zip'},
    });
    final c = AssetUpdateController(fetcher: (_) async => body);
    c.config = config();
    await c.check(force: true);

    expect(c.latest, isNotNull);
    expect(c.pendingAssets(),
        [CatalogAsset.gameinfo, CatalogAsset.screenshots]);
    expect(c.hasPending, isTrue);
  });

  test('skip suppresses an asset until a newer archive appears', () async {
    final body = jsonEncode({
      'screenshots': {'archive': 'screenshots-2.zip'},
      'gameinfo': {'archive': 'gameinfo-2.zip'},
    });
    final c = AssetUpdateController(fetcher: (_) async => body);
    c.config = config();
    await c.check(force: true);

    c.skip(CatalogAsset.gameinfo);
    expect(c.pendingAssets(), [CatalogAsset.screenshots]);
  });

  test('marker matches but data removed is still pending', () async {
    final body = jsonEncode({
      'screenshots': {'archive': 'screenshots-2.zip'},
    });
    final c = AssetUpdateController(fetcher: (_) async => body);
    c.config = config();
    await c.check(force: true);
    writeAppliedAssetVersion(
        '${tmp.path}/screens', CatalogAsset.screenshots, 'screenshots-2.zip');

    // Applied marker but no extracted index → data gone → pending.
    expect(c.isPending(CatalogAsset.screenshots), isTrue);
    File('${tmp.path}/screens/index.json').writeAsStringSync('{}');
    expect(c.isPending(CatalogAsset.screenshots), isFalse);
  });

  test('missing marker with data present is pending (version unknown)',
      () async {
    final body = jsonEncode({
      'screenshots': {'archive': 'screenshots-2.zip'},
    });
    final c = AssetUpdateController(fetcher: (_) async => body);
    c.config = config();
    await c.check(force: true);
    File('${tmp.path}/screens/index.json').writeAsStringSync('{}');

    expect(c.dataPresentFor(CatalogAsset.screenshots), isTrue);
    expect(c.localFor(CatalogAsset.screenshots), isNull);
    expect(c.isPending(CatalogAsset.screenshots), isTrue);
  });

  test('update applies the asset, clears skip and forwards sha256', () async {
    final body = jsonEncode({
      'screenshots': {
        'archive': 'screenshots-2.zip',
        'sha256': 'deadbeef',
      },
    });
    final dl = _FakeDownloader();
    final c = AssetUpdateController(fetcher: (_) async => body, downloader: dl);
    c.config = config();
    await c.check(force: true);
    c.skip(CatalogAsset.screenshots);
    expect(c.hasPending, isFalse);

    final ok = await c.update(CatalogAsset.screenshots);
    expect(ok, isTrue);
    expect(dl.lastExpectedSha256, 'deadbeef');
    expect(c.localFor(CatalogAsset.screenshots), 'screenshots-2.zip');
    expect(readSkippedAsset('${tmp.path}/screens', CatalogAsset.screenshots),
        isNull);
  });

  test('update without FTP config reports an error', () async {
    final c = AssetUpdateController(
        fetcher: (_) async =>
            jsonEncode({'screenshots': {'archive': 'screenshots-2.zip'}}));
    c.config = DesktopConfig(
      rootDirectory: '${tmp.path}/root',
      screenshotDirectory: '${tmp.path}/screens',
    );
    await c.check(force: true);
    final ok = await c.update(CatalogAsset.screenshots);
    expect(ok, isFalse);
    expect(c.error, contains('FTP not configured'));
  });

  test('manual check reports failures while the automatic check stays silent',
      () async {
    final c = AssetUpdateController(
        fetcher: (_) async => throw Exception('offline'));
    c.config = config();

    await c.check(force: true);
    expect(c.checkError, isNull);

    await c.check(force: true, manual: true);
    expect(c.checkError, contains('offline'));
    expect(c.checking, isFalse);
  });

  test('check exposes the checking state while fetching', () async {
    final body = Completer<String>();
    final c = AssetUpdateController(fetcher: (_) => body.future);
    c.config = config();

    final future = c.check(force: true, manual: true);
    expect(c.checking, isTrue);
    body.complete('{}');
    await future;

    expect(c.checking, isFalse);
    expect(c.checkError, isNull);
  });
}
