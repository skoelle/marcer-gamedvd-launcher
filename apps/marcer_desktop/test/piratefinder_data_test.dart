// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/piratefinder_data.dart';
import 'package:path/path.dart' as p;

class _FakeDownloader implements PirateFinderDownloader {
  String? expectedSha256;

  @override
  Future<void> download({
    required PirateFinderRemoteAsset asset,
    required String targetDir,
    PirateFinderProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    expectedSha256 = asset.sha256;
    Directory(targetDir).createSync(recursive: true);
    File(p.join(targetDir, asset.file)).writeAsStringSync('fake catalogue');
    onProgress?.call('Downloading…', 1, 1);
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('piratefinder_data_test');
    Directory('${tmp.path}/root').createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DesktopConfig config() => DesktopConfig(
    rootDirectory: '${tmp.path}/root',
    gameinfoDirectory: '${tmp.path}/data',
    appDir: tmp.path,
  );

  String latestBody({
    String generatedAt = '2026-10-24T12:34:16Z',
    String tag = 'catalogue-2026-10-19',
    String sha = 'abc123',
    String file = 'piratefinder-catalog-atari-st.json.gz',
  }) => jsonEncode({
    'schema': 1,
    'generated_at': generatedAt,
    'source': {'tag': tag, 'commit': 'deadbeef'},
    'assets': {
      'all': {'file': 'all.json.gz', 'size': 10, 'sha256': 'allsha'},
      'atari-st': {
        'file': file,
        'size': 123,
        'sha256': sha,
        'counts': {'disks': 1, 'media': 2},
      },
    },
  });

  test('parsePirateFinderLatest reads source and assets', () {
    final parsed = parsePirateFinderLatest(latestBody())!;
    expect(parsed.generatedAt, '2026-10-24T12:34:16Z');
    expect(parsed.sourceTag, 'catalogue-2026-10-19');
    expect(parsed.sourceCommit, 'deadbeef');
    expect(parsed.atariSt!.file, 'piratefinder-catalog-atari-st.json.gz');
    expect(parsed.atariSt!.size, 123);
    expect(parsed.atariSt!.sha256, 'abc123');
    expect(parsed.atariSt!.counts['disks'], 1);
  });

  test('parsePirateFinderLatest returns null on malformed input', () {
    expect(parsePirateFinderLatest('not json'), isNull);
  });

  test('marker round-trip and data presence', () {
    final dir = pirateFinderDataDir(config());
    const marker = PirateFinderLocalVersion(
      sourceTag: 'catalogue-2026-10-19',
      generatedAt: '2026-10-24T12:34:16Z',
      asset: 'piratefinder-catalog-atari-st.json.gz',
      sha256: 'abc123',
      appliedAt: '2026-10-24T12:40:00Z',
    );
    expect(readPirateFinderLocal(dir), isNull);
    expect(pirateFinderDataPresent(dir, marker), isFalse);

    writePirateFinderLocal(dir, marker);
    File(p.join(dir, marker.asset)).writeAsStringSync('data');
    final read = readPirateFinderLocal(dir)!;
    expect(read.sourceTag, marker.sourceTag);
    expect(read.sha256, marker.sha256);
    expect(pirateFinderDataPresent(dir, read), isTrue);
  });

  test('needs update compares sha and file presence', () {
    final latest = parsePirateFinderLatest(latestBody())!;
    const local = PirateFinderLocalVersion(
      sourceTag: 'catalogue-2026-10-19',
      generatedAt: '2026-10-24T12:34:16Z',
      asset: 'piratefinder-catalog-atari-st.json.gz',
      sha256: 'abc123',
      appliedAt: '2026-10-24T12:40:00Z',
    );
    expect(
      pirateFinderNeedsUpdate(latest: latest, local: null, dataPresent: false),
      isTrue,
    );
    expect(
      pirateFinderNeedsUpdate(latest: latest, local: local, dataPresent: true),
      isFalse,
    );
    expect(
      pirateFinderNeedsUpdate(latest: latest, local: local, dataPresent: false),
      isTrue,
    );
    final newer = parsePirateFinderLatest(latestBody(sha: 'def456'))!;
    expect(
      pirateFinderNeedsUpdate(latest: newer, local: local, dataPresent: true),
      isTrue,
    );
  });

  test(
    'check marks missing data pending and update writes the marker',
    () async {
      final downloader = _FakeDownloader();
      final c = PirateFinderDataController(
        fetcher: (_) async => latestBody(),
        downloader: downloader,
      );
      c.config = config();
      await c.check(force: true);

      expect(c.latest, isNotNull);
      expect(c.remote!.file, 'piratefinder-catalog-atari-st.json.gz');
      expect(c.hasPending, isTrue); // not installed yet
      expect(c.local, isNull);

      final ok = await c.update();
      expect(ok, isTrue);
      expect(downloader.expectedSha256, 'abc123');
      expect(c.local!.sourceTag, 'catalogue-2026-10-19');
      expect(c.local!.sha256, 'abc123');
      expect(c.hasPending, isFalse);
      expect(
        File(p.join(c.dataDir, 'piratefinder-catalog-atari-st.json.gz'))
            .existsSync(),
        isTrue,
      );
    },
  );

  test('downloadLatest refreshes the pointer before downloading', () async {
    final downloader = _FakeDownloader();
    var fetches = 0;
    final c = PirateFinderDataController(
      fetcher: (_) async {
        fetches++;
        return latestBody(tag: 'catalogue-2026-11-02');
      },
      downloader: downloader,
    );
    c.config = config();

    final ok = await c.downloadLatest();

    expect(ok, isTrue);
    expect(fetches, 1);
    expect(downloader.expectedSha256, 'abc123');
    expect(c.local!.sourceTag, 'catalogue-2026-11-02');
    expect(c.hasPending, isFalse);
  });

  test(
    'downloadLatest does not download when the pointer check fails',
    () async {
      final downloader = _FakeDownloader();
      final c = PirateFinderDataController(
        fetcher: (_) async => throw const SocketException('offline'),
        downloader: downloader,
      );
      c.config = config();

      final ok = await c.downloadLatest();

      expect(ok, isFalse);
      expect(c.error, contains('Could not check'));
      expect(downloader.expectedSha256, isNull);
    },
  );

  test('check failure keeps an error and no pending state', () async {
    final c = PirateFinderDataController(
      fetcher: (_) async => throw const SocketException('offline'),
    );
    c.config = config();
    await c.check(force: true);
    expect(c.latest, isNull);
    expect(c.hasPending, isFalse);
    expect(c.error, contains('Could not check'));
  });
  test('ensureIndex parses the downloaded gzip in an isolate', () async {
    final c = PirateFinderDataController(fetcher: (_) async => latestBody());
    c.config = config();
    final dir = pirateFinderDataDir(c.config);
    Directory(dir).createSync(recursive: true);
    const local = PirateFinderLocalVersion(
      sourceTag: 'catalogue-2026-10-19',
      generatedAt: '2026-10-24T12:34:16Z',
      asset: 'piratefinder-catalog-atari-st.json.gz',
      sha256: 'abc',
      appliedAt: '2026-10-24T12:40:00Z',
    );
    writePirateFinderLocal(dir, local);
    File(p.join(dir, local.asset)).writeAsBytesSync(
      gzip.encode(
        utf8.encode(
          jsonEncode({
            'generated_at': '2026-10-24T12:34:16Z',
            'source': {'tag': 'catalogue-2026-10-19'},
            'disks': [
              {'id': 1, 'kind': 'single', 'title': 'Alpha', 'label': 'Alpha'},
            ],
          }),
        ),
      ),
    );
    c.refreshLocal();
    final index = await c.ensureIndex();
    expect(index, isNotNull);
    expect(index!.length, 1);
    expect(c.hasIndex, isTrue);
  });
}
