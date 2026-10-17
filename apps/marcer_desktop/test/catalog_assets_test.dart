// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/catalog_assets.dart';
import 'package:marcer_desktop/ftp_downloader.dart';
import 'package:path/path.dart' as p;

List<int> _zipOf(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

void main() {
  test('picks the newest screenshots archive by name timestamp', () {
    final names = [
      'screenshots-20260101-101010.zip',
      'screenshots-20261017-080230.zip',
      'screenshots-20260505-000000.zip',
      'gameinfo-20261017-080230.zip',
      'readme.txt',
    ];
    expect(newestAssetArchiveName(names, CatalogAsset.screenshots),
        'screenshots-20261017-080230.zip');
    expect(newestAssetArchiveName(names, CatalogAsset.gameinfo),
        'gameinfo-20261017-080230.zip');
  });

  test('ignores non-matching names and is case-insensitive on the prefix', () {
    final names = [
      'Screenshots-20261017-080230.ZIP',
      'screenshots-2026.zip',
      'screenshots-20261017-080230.7z',
      'gameinfos-20261017-080230.zip',
    ];
    expect(newestAssetArchiveName(names, CatalogAsset.screenshots),
        'Screenshots-20261017-080230.ZIP');
    expect(newestAssetArchiveName(names, CatalogAsset.gameinfo), isNull);
  });

  test('returns null when no archive matches', () {
    expect(newestAssetArchiveName(const [], CatalogAsset.screenshots), isNull);
    expect(
        newestAssetArchiveName(const ['other-20261017-080230.zip'],
            CatalogAsset.gameinfo),
        isNull);
  });

  test('extracts a ZIP in an isolate and reports per-file progress', () async {
    final dir = Directory.systemTemp.createTempSync('catalog_assets_test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final zip = File(p.join(dir.path, 'screenshots-x.zip'))
      ..writeAsBytesSync(_zipOf({
        'a/one.png': List<int>.filled(10, 1),
        'a/two.png': List<int>.filled(20, 2),
        'root.png': List<int>.filled(5, 3),
      }));

    final out = Directory(p.join(dir.path, 'out'));
    final progress = <int>[];
    int? total;
    await extractZipWithProgress(
      archivePath: zip.path,
      targetDir: out.path,
      onProgress: (done, t) {
        progress.add(done);
        total = t;
      },
    );

    expect(File(p.join(out.path, 'a/one.png')).lengthSync(), 10);
    expect(File(p.join(out.path, 'a/two.png')).lengthSync(), 20);
    expect(File(p.join(out.path, 'root.png')).lengthSync(), 5);
    expect(total, 3);
    expect(progress.first, 0);
    expect(progress.last, 3);
  });

  test('extraction aborts when already cancelled', () {
    expect(
      () => extractZipWithProgress(
        archivePath: '/does/not/matter.zip',
        targetDir: '/tmp/out',
        isCancelled: () => true,
      ),
      throwsA(isA<DownloadCancelledException>()),
    );
  });

  test('downloadSizeError flags truncated/corrupted transfers', () {
    expect(downloadSizeError(100, 100), isNull);
    expect(downloadSizeError(100, 0), isNull, reason: 'unknown size not checked');
    expect(downloadSizeError(90, 100), contains('incomplete'));
  });

  test('a missing archive fails instead of hanging', () {
    expect(
      () => extractZipWithProgress(
        archivePath: '/definitely/missing.zip',
        targetDir: '/tmp/out',
      ),
      throwsA(isA<DownloadException>()),
    );
  });
}
