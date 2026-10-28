// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/index_editor.dart';

void main() {
  late Directory tmp;
  late String screenshotDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('index_editor_test');
    screenshotDir = tmp.path;
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('shotgen lock', () {
    test('missing lock: not active, acquire/release roundtrip', () {
      expect(isShotgenActive(screenshotDir), isFalse);
      expect(readShotgenLockPid(screenshotDir), isNull);
      acquireShotgenLock(screenshotDir);
      expect(isShotgenActive(screenshotDir), isTrue); // own pid is alive
      releaseShotgenLock(screenshotDir);
      expect(File(shotgenLockPath(screenshotDir)).existsSync(), isFalse);
    });

    test('live pid in the lock file blocks acquire', () {
      final me = selfPid;
      if (me == null) {
        markTestSkipped('FFI pid lookup unavailable on this platform');
        return;
      }
      File(shotgenLockPath(screenshotDir)).writeAsStringSync('$me');
      expect(
          () => acquireShotgenLock(screenshotDir),
          throwsA(isA<ShotgenLockedException>()));
    });

    test('invalid/unreadable lock content is treated as absent', () {
      // Invalid UTF-8 makes readAsStringSync throw; the reader must degrade to
      // "no lock" instead of failing the caller.
      File(shotgenLockPath(screenshotDir)).writeAsBytesSync([0xFF, 0xFE, 0x00]);
      expect(readShotgenLockPid(screenshotDir), isNull);
      expect(isShotgenActive(screenshotDir), isFalse);
    });

    test('stale lock (dead pid) is treated as free and overwritten',
        () async {
      final proc = await Process.start('true', []);
      final deadPid = proc.pid;
      await proc.exitCode;
      File(shotgenLockPath(screenshotDir)).writeAsStringSync('$deadPid');
      expect(isShotgenActive(screenshotDir), isFalse);
      acquireShotgenLock(screenshotDir);
      expect(readShotgenLockPid(screenshotDir), selfPid);
      releaseShotgenLock(screenshotDir);
    });
  });

  group('swapPreviewCandidate', () {
    test('trades contents, keeps the fixed names', () {
      final dir = Directory('$screenshotDir/mirror')..createSync();
      final preview = File('${dir.path}/a.png')..writeAsStringSync('MAIN');
      final cand = File('${dir.path}/a_c01.png')..writeAsStringSync('CAND');
      swapPreviewCandidate(
          previewPath: preview.path, candidatePath: cand.path);
      expect(preview.readAsStringSync(), 'CAND');
      expect(cand.readAsStringSync(), 'MAIN');
    });

    test('missing candidate throws', () {
      final dir = Directory('$screenshotDir/mirror')..createSync();
      final preview = File('${dir.path}/a.png')..writeAsStringSync('MAIN');
      expect(
          () => swapPreviewCandidate(
              previewPath: preview.path,
              candidatePath: '${dir.path}/a_c09.png'),
          throwsA(isA<FileSystemException>()));
    });

    test('preview and candidate must share the directory', () {
      final dirA = Directory('$screenshotDir/a')..createSync();
      final dirB = Directory('$screenshotDir/b')..createSync();
      final preview = File('${dirA.path}/a.png')..writeAsStringSync('MAIN');
      final cand = File('${dirB.path}/a_c01.png')..writeAsStringSync('CAND');
      expect(
          () => swapPreviewCandidate(
              previewPath: preview.path, candidatePath: cand.path),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('applyStatusChanges', () {
    setUp(() {
      Directory('$screenshotDir/A/Alpha').createSync(recursive: true);
      File('$screenshotDir/index.json').writeAsStringSync(jsonEncode({
        'version': 1,
        'entries': {
          'A/Alpha/a.zip': {
            'rel': 'A/Alpha/a.zip',
            'name': 'a.zip',
            'status': 'desktop',
            'kind': 'textscreen',
            'layer': 'ROOT',
            'preview': 'a.png',
            'candidates': <String>[],
          },
        },
      }));
      File('$screenshotDir/A/Alpha/a.json').writeAsStringSync(jsonEncode({
        'spec_version': '1',
        'entry': 'A/Alpha/a.zip',
        'status': 'desktop',
        'kind': 'textscreen',
        'preview_is_desktop': true,
      }));
    });

    Map<String, dynamic> indexEntry() {
      final idx = jsonDecode(File('$screenshotDir/index.json').readAsStringSync())
          as Map<String, dynamic>;
      return ((idx['entries'] as Map)['A/Alpha/a.zip'] as Map)
          .cast<String, dynamic>();
    }

    Map<String, dynamic> meta() =>
        (jsonDecode(File('$screenshotDir/A/Alpha/a.json').readAsStringSync())
            as Map<String, dynamic>);

    test('writes status/kind to index + mirror meta, releases the lock',
        () async {
      await applyStatusChanges(screenshotDir: screenshotDir, changes: {
        'A/Alpha/a.zip': (status: 'done', kind: 'game'),
      });
      expect(File(shotgenLockPath(screenshotDir)).existsSync(), isFalse);
      expect(indexEntry()['status'], 'done');
      expect(indexEntry()['kind'], 'game');
      expect(meta()['status'], 'done');
      expect(meta()['kind'], 'game');
      expect(meta()['preview_is_desktop'], isFalse);
    });

    test('darkscreen keeps preview_is_desktop true in the meta', () async {
      await applyStatusChanges(screenshotDir: screenshotDir, changes: {
        'A/Alpha/a.zip': (status: 'desktop', kind: 'darkscreen'),
      });
      expect(meta()['kind'], 'darkscreen');
      expect(meta()['preview_is_desktop'], isTrue);
    });

    test('refuses while a live lock is held, index stays unchanged', () async {
      final me = selfPid;
      if (me == null) {
        markTestSkipped('FFI pid lookup unavailable on this platform');
        return;
      }
      File(shotgenLockPath(screenshotDir)).writeAsStringSync('$me');
      await expectLater(
          applyStatusChanges(screenshotDir: screenshotDir, changes: {
            'A/Alpha/a.zip': (status: 'done', kind: 'game'),
          }),
          throwsA(isA<ShotgenLockedException>()));
      expect(indexEntry()['status'], 'desktop');
      expect(indexEntry()['kind'], 'textscreen');
    });

    test('unknown rel entries are skipped, existing ones updated', () async {
      await applyStatusChanges(screenshotDir: screenshotDir, changes: {
        'missing/none.zip': (status: 'done', kind: 'game'),
        'A/Alpha/a.zip': (status: 'done', kind: null),
      });
      expect(indexEntry()['status'], 'done');
      expect(indexEntry()['kind'], isNull);
      expect(meta()['kind'], isNull);
      expect(meta()['preview_is_desktop'], isFalse);
    });
  });
}
