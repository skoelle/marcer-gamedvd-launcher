// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/cosmos_ex.dart';
import 'package:path/path.dart' as p;

Future<HttpServer> _serve(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      await handler(request);
    } catch (_) {
      request.response.statusCode = HttpStatus.internalServerError;
    } finally {
      await request.response.close();
    }
  });
  return server;
}

Future<List<int>> _readBody(HttpRequest request) async {
  final bytes = <int>[];
  await for (final chunk in request) {
    bytes.addAll(chunk);
  }
  return bytes;
}

void _json(HttpRequest request, Object body, {int status = 200}) {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
}

Directory _tempDir(String name) {
  final dir = Directory.systemTemp.createTempSync(name);
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

File _zipWith(
  Directory dir, {
  String name = 'game.zip',
  Map<String, List<int>> files = const {
    'DISK1.ST': [1, 2, 3, 4],
  },
}) {
  final archive = Archive();
  files.forEach((path, bytes) {
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  });
  final zipBytes = ZipEncoder().encode(archive);
  return File(p.join(dir.path, name))..writeAsBytesSync(zipBytes);
}

DesktopConfig _config({
  required String host,
  String mode = 'auto',
  String password = '',
  String mac = '',
  String share = '',
}) => DesktopConfig(
  rootDirectory: '/r',
  cosmosExMode: mode,
  cosmosExHost: host,
  cosmosExPassword: password,
  cosmosExMac: mac,
  cosmosExShareDirectory: share,
);

void main() {
  test('legacy upload sends the ZIP to slot 0 and activates it', () async {
    final dir = _tempDir('cosmos_ex_legacy');
    final zip = File(p.join(dir.path, 'game.zip'))
      ..writeAsStringSync('ZIPDATA');

    var posted = false;
    var activated = false;
    String? contentType;
    String? multipart;
    final server = await _serve((request) async {
      if (request.uri.path == '/api/v1/floppy') {
        _json(request, {
          'slots': ['', '', ''],
          'active': null,
          'encoding_ready': true,
        });
        return;
      }
      if (request.uri.path == '/api/v1/floppy/0') {
        if (request.method == 'POST') {
          posted = true;
          contentType = request.headers.contentType?.mimeType;
          multipart = utf8.decode(
            await _readBody(request),
            allowMalformed: true,
          );
          request.response.statusCode = 200;
          return;
        }
        if (request.method == 'PUT') {
          activated = true;
          request.response.statusCode = 200;
          return;
        }
      }
      request.response.statusCode = 404;
    });
    addTearDown(() => server.close(force: true));

    final result = await const HttpCosmosExUploader().send(
      config: _config(host: 'http://127.0.0.1:${server.port}', mode: 'legacy'),
      zipPath: zip.path,
    );

    expect(result.mode, 'legacy');
    expect(posted, isTrue);
    expect(activated, isTrue);
    expect(contentType, 'multipart/form-data');
    expect(multipart, contains('name="file"'));
    expect(multipart, contains('filename="game.zip"'));
    expect(multipart, contains('ZIPDATA'));
  });

  test('auto prefers the legacy upload when both APIs exist', () async {
    final dir = _tempDir('cosmos_ex_auto');
    final zip = File(p.join(dir.path, 'game.zip'))..writeAsStringSync('ZIP');

    var uploaded = false;
    final server = await _serve((request) async {
      if (request.uri.path == '/ping') {
        request.response.statusCode = 200;
        return;
      }
      if (request.uri.path == '/api/v1/floppy') {
        _json(request, {
          'slots': ['', '', ''],
        });
        return;
      }
      if (request.uri.path == '/api/v1/floppy/0') {
        if (request.method == 'POST') {
          uploaded = true;
          await _readBody(request);
          request.response.statusCode = 200;
        } else {
          request.response.statusCode = 200;
        }
        return;
      }
      request.response.statusCode = 404;
    });
    addTearDown(() => server.close(force: true));

    final result = await const HttpCosmosExUploader().send(
      config: _config(host: 'http://127.0.0.1:${server.port}'),
      zipPath: zip.path,
    );

    expect(result.mode, 'legacy');
    expect(uploaded, isTrue);
  });

  test('auto falls back to cosmo2ex when legacy is absent', () async {
    final dir = _tempDir('cosmos_ex_auto_web');
    final share = Directory(p.join(dir.path, 'floppyImages'))..createSync();
    final zip = _zipWith(dir);

    final server = await _serve((request) async {
      final path = request.uri.path;
      if (path == '/ca.crt') {
        request.response.statusCode = 200;
        request.response.write('certificate');
        return;
      }
      if (path == '/auth/login') {
        await _readBody(request);
        _json(request, {'token': 'tok', 'mustSetPassword': false});
        return;
      }
      if (path == '/devices') {
        _json(request, [
          {'mac': 'aa:bb:cc:dd:ee:01', 'name': 'Atari'},
        ]);
        return;
      }
      if (path == '/fdd/aabbccddee01/image') {
        if (request.method == 'GET') {
          _json(request, {'image': '', 'defaultDir': '/opt/ce/floppyImages'});
          return;
        }
        if (request.method == 'PUT') {
          await _readBody(request);
          request.response.statusCode = HttpStatus.noContent;
          return;
        }
      }
      // No legacy /api/v1/floppy endpoint.
      request.response.statusCode = 404;
    });
    addTearDown(() => server.close(force: true));

    final result = await const HttpCosmosExUploader().send(
      config: _config(
        host: 'http://127.0.0.1:${server.port}',
        password: 'secret',
        share: share.path,
      ),
      zipPath: zip.path,
    );

    expect(result.mode, 'cosmo2ex');
    expect(Directory(share.path).listSync().whereType<File>(), hasLength(1));
  });

  test(
    'cosmo2ex copies the first image to the share and inserts its path',
    () async {
      final dir = _tempDir('cosmos_ex_web');
      final share = Directory(p.join(dir.path, 'floppyImages'))..createSync();
      final zip = _zipWith(
        dir,
        files: {
          'DISK2.ST': [9, 9, 9],
          'DISK1.ST': [1, 2, 3],
          'README.TXT': [4, 5],
        },
      );

      var loginPassword = '';
      var inserted = '';
      var auth = '';
      final server = await _serve((request) async {
        final path = request.uri.path;
        if (path == '/ping') {
          request.response.statusCode = 200;
          return;
        }
        if (path == '/auth/login' && request.method == 'POST') {
          final body = jsonDecode(
            utf8.decode(await _readBody(request)),
          ) as Map<String, dynamic>;
          loginPassword = body['password'] as String? ?? '';
          _json(request, {'token': 'tok', 'mustSetPassword': false});
          return;
        }
        if (path == '/devices') {
          auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
          _json(request, [
            {'mac': 'aa:bb:cc:dd:ee:01', 'name': 'Atari', 'connected': false},
          ]);
          return;
        }
        if (path == '/fdd/aabbccddee01/image') {
          auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
          if (request.method == 'GET') {
            _json(request, {
              'mac': 'aabbccddee01',
              'image': '',
              'defaultDir': '/opt/ce/floppyImages',
            });
            return;
          }
          if (request.method == 'PUT') {
            final body = jsonDecode(
              utf8.decode(await _readBody(request)),
            ) as Map<String, dynamic>;
            inserted = body['image'] as String? ?? '';
            request.response.statusCode = HttpStatus.noContent;
            return;
          }
        }
        request.response.statusCode = 404;
      });
      addTearDown(() => server.close(force: true));

      final result = await const HttpCosmosExUploader().send(
        config: _config(
          host: 'http://127.0.0.1:${server.port}',
          mode: 'cosmo2ex',
          password: 'secret',
          share: share.path,
        ),
        zipPath: zip.path,
      );

      expect(result.mode, 'cosmo2ex');
      expect(loginPassword, 'secret');
      expect(auth, 'Bearer tok');
      expect(inserted, startsWith('/opt/ce/floppyImages/marcer-game-'));
      expect(inserted, endsWith('.st'));

      final shared = Directory(share.path)
          .listSync()
          .whereType<File>()
          .toList();
      expect(shared, hasLength(1));
      expect(p.basename(shared.single.path), p.basename(inserted));
      expect(shared.single.readAsBytesSync(), [1, 2, 3]);
      expect(result.message, contains('inserted'));
    },
  );

  test('cosmo2ex rejects a ZIP without a floppy image', () async {
    final dir = _tempDir('cosmos_ex_no_image');
    final share = Directory(p.join(dir.path, 'floppyImages'))..createSync();
    final zip = _zipWith(
      dir,
      files: {
        'README.TXT': [1, 2, 3],
      },
    );
    final server = await _serve((request) async {
      final path = request.uri.path;
      if (path == '/auth/login') {
        await _readBody(request);
        _json(request, {'token': 'tok', 'mustSetPassword': false});
        return;
      }
      if (path == '/devices') {
        _json(request, [
          {'mac': 'aa:bb:cc:dd:ee:01', 'name': 'Atari'},
        ]);
        return;
      }
      if (path == '/fdd/aabbccddee01/image') {
        _json(request, {'image': '', 'defaultDir': '/opt/ce/floppyImages'});
        return;
      }
      request.response.statusCode = 404;
    });
    addTearDown(() => server.close(force: true));

    await expectLater(
      const HttpCosmosExUploader().send(
        config: _config(
          host: 'http://127.0.0.1:${server.port}',
          mode: 'cosmo2ex',
          password: 'secret',
          share: share.path,
        ),
        zipPath: zip.path,
      ),
      throwsA(
        isA<CosmosExException>().having(
          (e) => e.message,
          'message',
          contains('no .st/.msa'),
        ),
      ),
    );
  });

  test('cosmo2ex requires a share and reports multiple devices', () async {
    final dir = _tempDir('cosmos_ex_errors');
    final zip = _zipWith(dir);
    final server = await _serve((request) async {
      final path = request.uri.path;
      if (path == '/auth/login') {
        await _readBody(request);
        _json(request, {'token': 'tok', 'mustSetPassword': false});
        return;
      }
      if (path == '/devices') {
        _json(request, [
          {'mac': 'aa:bb:cc:dd:ee:01'},
          {'mac': 'aa:bb:cc:dd:ee:02'},
        ]);
        return;
      }
      request.response.statusCode = 404;
    });
    addTearDown(() => server.close(force: true));

    await expectLater(
      const HttpCosmosExUploader().send(
        config: _config(
          host: 'http://127.0.0.1:${server.port}',
          mode: 'cosmo2ex',
          password: 'secret',
        ),
        zipPath: zip.path,
      ),
      throwsA(
        isA<CosmosExException>().having(
          (e) => e.message,
          'message',
          contains('Share directory'),
        ),
      ),
    );

    final share = Directory(p.join(dir.path, 'floppyImages'))..createSync();
    await expectLater(
      const HttpCosmosExUploader().send(
        config: _config(
          host: 'http://127.0.0.1:${server.port}',
          mode: 'cosmo2ex',
          password: 'secret',
          share: share.path,
        ),
        zipPath: zip.path,
      ),
      throwsA(
        isA<CosmosExException>().having(
          (e) => e.message,
          'message',
          contains('Multiple CosmosEx devices'),
        ),
      ),
    );
  });
}
