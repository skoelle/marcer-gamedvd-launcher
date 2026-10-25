// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/ftp_downloader.dart';
import 'package:path/path.dart' as p;

/// Fake recursive downloader: records its arguments and materialises [files]
/// (relative to `localDir`) so the test can assert that the local layer/missing
/// caches refresh. Optionally fails after the transfer.
class _FakeDownloader implements Downloader {
  _FakeDownloader({this.fail});

  final String? fail;
  int calls = 0;
  String? remoteDir;
  String? localDir;
  String? host;
  int? port;
  String? user;
  String? password;

  @override
  Future<void> downloadDirectory({
    required String host,
    required int port,
    required String user,
    required String password,
    required String remoteDir,
    required String localDir,
    DownloadProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    const files = ['beta.zip'];
    calls++;
    this.host = host;
    this.port = port;
    this.user = user;
    this.password = password;
    this.remoteDir = remoteDir;
    this.localDir = localDir;
    onProgress?.call(0, files.length);
    var done = 0;
    for (final rel in files) {
      if (isCancelled?.call() ?? false) {
        throw const DownloadCancelledException();
      }
      final f = File(p.join(localDir, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('downloaded');
      onProgress?.call(++done, files.length);
    }
    if (fail != null) throw DownloadException(fail!);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const tree = 'Title Sorted/Cracked Games - Title Sorted';
  const relBeta = '$tree/B/Beta/beta.zip';
  const folder = '$tree/B/Beta';

  Map<String, dynamic> entry(String rel) => {
        'rel': rel,
        'name': rel.split('/').last,
        'status': 'done',
        'kind': 'game',
        'layer': 'ROOT',
        'preview': null,
        'candidates': <String>[],
      };

  DesktopConfig cfg(
          {String ftpHost = 'ftp.example.com',
          String patch = '',
          String remoteBase = ''}) =>
      DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        patchDirectory: patch.isEmpty ? '${tmp.path}/patch' : patch,
        screenshotDirectory: '${tmp.path}/out',
        gameinfoDirectory: '${tmp.path}/data',
        ftpHost: ftpHost,
        ftpUser: 'anonymous',
        ftpPassword: 'pw',
        ftpRemoteBase: remoteBase,
      );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('download_test');
    // Beta exists only in the index (no file on disk → MISSING).
    Directory('${tmp.path}/root/$tree/A').createSync(recursive: true);
    Directory('${tmp.path}/patch').createSync(recursive: true);
    Directory('${tmp.path}/data').createSync(recursive: true);
    Directory('${tmp.path}/out').createSync(recursive: true);
    File('${tmp.path}/out/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {relBeta: entry(relBeta)},
    }));
    c = CatalogController(cfg());
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  GameCard beta() =>
      c.universe.cracked.firstWhere((x) => x.letter == 'B' && x.folder == 'Beta');

  test('downloads the card folder into the patch layer and clears MISSING',
      () async {
    await c.init();
    final card = beta();
    expect(c.cardMissing(card), isTrue);

    final fake = _FakeDownloader();
    c.downloader = fake;
    await c.downloadMissing(card);

    expect(fake.calls, 1);
    expect(fake.host, 'ftp.example.com');
    expect(fake.port, 21);
    expect(fake.user, 'anonymous');
    expect(fake.remoteDir, folder, reason: 'no RemoteBase → tree-relative path');
    expect(fake.localDir, p.join('${tmp.path}/patch', folder));
    expect(c.cardMissing(card), isFalse);
    expect(c.cardLayer(card), 'PATCH');
    expect(c.downloading, isFalse);
    expect(c.downloadingCard, isNull);
    expect(c.downloadError, isNull);
  });

  test('resolves the game folder from the index rel when the first ZIP is '
      'nested (no section tree discovered)', () async {
    // Empty RootDirectory / no tree on disk — exactly the Download-missing
    // case. The first (only) ZIP lives in Original/, so the folder must not
    // shrink to …/Nested/Original (bug 2026-10-25).
    const nestedRel = '$tree/N/Nested/Original/n.zip';
    File('${tmp.path}/out/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {nestedRel: entry(nestedRel)},
    }));
    await c.init();
    final card = c.universe.cracked
        .firstWhere((x) => x.letter == 'N' && x.folder == 'Nested');
    expect(c.cardFolderRel(card), '$tree/N/Nested');

    final fake = _FakeDownloader();
    c.downloader = fake;
    await c.downloadMissing(card);
    expect(fake.remoteDir, '$tree/N/Nested');
    expect(fake.localDir, p.join('${tmp.path}/patch', '$tree/N/Nested'));
  });

  test('nested magazine ZIPs download their issue folder', () async {
    const magazineTree = 'Bonus/Magazine Cover Disks';
    const rel = '$magazineTree/ST Computer/1990-01/Disk1/st.zip';
    File('${tmp.path}/out/index-magazine.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {rel: entry(rel)},
    }));
    await c.init();
    final card = c.universe.magazine.single;
    const folder = '$magazineTree/ST Computer/1990-01';
    expect(c.cardFolderRel(card), folder);

    final fake = _FakeDownloader();
    c.downloader = fake;
    await c.downloadMissing(card);
    expect(fake.remoteDir, folder);
    expect(fake.localDir, p.join('${tmp.path}/patch', folder));
  });

  test('uses a non-standard port given inline as host:port', () async {
    final fake = _FakeDownloader();
    c = CatalogController(cfg(ftpHost: 'ftp.example.com:2121'))
      ..downloader = fake;
    await c.init();
    await c.downloadMissing(beta());
    expect(fake.host, 'ftp.example.com');
    expect(fake.port, 2121);
  });

  test('prefixes the remote path with Ftp.RemoteBase', () async {
    final fake = _FakeDownloader();
    c = CatalogController(cfg(remoteBase: '/dvd/'))..downloader = fake;
    await c.init();
    await c.downloadMissing(beta());
    expect(fake.remoteDir, '/dvd/$folder');
  });

  test('the default RemoteBase is /GameDVD/', () async {
    final fake = _FakeDownloader();
    // Uses the DesktopConfig default for Ftp.RemoteBase (no explicit value).
    c = CatalogController(DesktopConfig(
      rootDirectory: '${tmp.path}/root',
      patchDirectory: '${tmp.path}/patch',
      screenshotDirectory: '${tmp.path}/out',
      gameinfoDirectory: '${tmp.path}/data',
      ftpHost: 'ftp.example.com',
    ))
      ..downloader = fake;
    await c.init();
    await c.downloadMissing(beta());
    expect(fake.remoteDir, '/GameDVD/$folder');
  });

  test('falls back to the root layer when no PatchDirectory is set', () async {
    c = CatalogController(DesktopConfig(
      rootDirectory: '${tmp.path}/root',
      patchDirectory: '',
      screenshotDirectory: '${tmp.path}/out',
      gameinfoDirectory: '${tmp.path}/data',
      ftpHost: 'ftp.example.com',
      ftpRemoteBase: '',
    ));
    await c.init();
    final fake = _FakeDownloader();
    c.downloader = fake;
    await c.downloadMissing(beta());
    expect(fake.localDir, p.join('${tmp.path}/root', folder));
    expect(c.cardLayer(beta()), 'ROOT');
  });

  test('reports an error and skips the transfer when FTP is not configured',
      () async {
    c = CatalogController(cfg(ftpHost: ''));
    await c.init();
    final fake = _FakeDownloader();
    c.downloader = fake;
    await c.downloadMissing(beta());
    expect(fake.calls, 0);
    expect(c.downloadError, contains('FTP not configured'));
    expect(c.downloading, isFalse);
  });

  test('surfaces transfer failures as downloadError', () async {
    await c.init();
    final fake = _FakeDownloader(fail: 'login failed');
    c.downloader = fake;
    await c.downloadMissing(beta());
    expect(c.downloadError, contains('login failed'));
    expect(c.downloading, isFalse);
    c.clearDownloadError();
    expect(c.downloadError, isNull);
  });
}
