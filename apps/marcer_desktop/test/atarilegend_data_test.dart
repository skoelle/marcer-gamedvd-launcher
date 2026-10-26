// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/atarilegend_data.dart';
import 'package:marcer_desktop/atarilegend_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAtariLegendFetcher implements AtariLegendFetcher {
  String? latest = '2026-10-25.sql.gz';
  Object? latestError;
  int latestCalls = 0;
  int fetchCalls = 0;
  String resultDump = '2026-10-25.sql.gz';

  @override
  Future<String?> latestDump() async {
    latestCalls++;
    final err = latestError;
    if (err != null) throw err;
    return latest;
  }

  @override
  Future<AtariLegendFetchResult> fetch({
    required String targetDir,
    AtariLegendProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    fetchCalls++;
    onProgress?.call('Downloading…', 1, 2);
    return AtariLegendFetchResult(
      games: 6200,
      dumpFile: resultDump,
      cachePath: '$targetDir/$kAtariLegendFileName',
    );
  }
}

void main() {
  late Directory tmp;
  late _FakeAtariLegendFetcher fetcher;
  late AtariLegendUpdateController controller;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('atarilegend_data_test');
    fetcher = _FakeAtariLegendFetcher();
    controller = AtariLegendUpdateController(fetcher: fetcher)
      ..config = DesktopConfig(
        rootDirectory: tmp.path,
        gameinfoDirectory: tmp.path,
      )
      ..refreshLocal();
  });

  tearDown(() {
    controller.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('construction/refresh never checks the remote dump', () {
    expect(fetcher.latestCalls, 0);
    expect(controller.remoteDumpFile, isNull);
    expect(controller.hasPending, isFalse);
  });

  test('local cache header is shown without a network check', () {
    final dir = Directory('${tmp.path}/atarilegend')..createSync();
    File('${dir.path}/$kAtariLegendFileName').writeAsStringSync(
      AtariLegendCache(
        generatedAt: '2026-10-19T10:00:00Z',
        sourceFile: '2026-10-18.sql.gz',
        dumpDate: '2026-10-18',
        games: const [],
      ).toJsonString(),
    );

    controller.refreshLocal();

    expect(fetcher.latestCalls, 0);
    expect(controller.localLabel, 'dump 2026-10-18');
    expect(controller.localDate, '2026-10-18');
  });

  test('check fetches the remote date and reports a newer dump', () async {
    await controller.check();

    expect(fetcher.latestCalls, 1);
    expect(controller.remoteDumpFile, '2026-10-25.sql.gz');
    expect(controller.remoteDate, '2026-10-25');
    expect(controller.hasPending, isTrue);
    expect(controller.error, isNull);
  });

  test('check reports up to date when the dates match', () async {
    final dir = Directory('${tmp.path}/atarilegend')..createSync();
    File('${dir.path}/$kAtariLegendFileName').writeAsStringSync(
      AtariLegendCache(
        generatedAt: '2026-10-25T10:00:00Z',
        sourceFile: '2026-10-25.sql.gz',
        dumpDate: '2026-10-25',
        games: const [],
      ).toJsonString(),
    );
    controller.refreshLocal();

    await controller.check();

    expect(controller.hasPending, isFalse);
  });

  test('check records errors', () async {
    fetcher.latestError = const AtariLegendFetchException('offline');
    await controller.check();

    expect(controller.checking, isFalse);
    expect(controller.error, contains('offline'));
    expect(controller.remoteDumpFile, isNull);
  });

  test('update downloads and applies the new dump date', () async {
    await controller.check();
    final ok = await controller.update();

    expect(ok, isTrue);
    expect(fetcher.fetchCalls, 1);
    expect(controller.localLabel, 'dump 2026-10-25');
    expect(controller.hasPending, isFalse);
    expect(controller.error, isNull);
  });
}
