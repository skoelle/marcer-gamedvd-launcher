// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/falcon_launcher.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('falcon_launcher_test');
    File('${tmp.path}/hatari').writeAsStringSync('');
    File('${tmp.path}/TOS404.IMG').writeAsBytesSync(List<int>.filled(8, 0));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DesktopConfig config() => DesktopConfig(
        rootDirectory: tmp.path,
        appDir: tmp.path,
        hatariExecutable: 'hatari',
      );

  String writeZip(String name, Map<String, String> files) {
    final archive = Archive();
    files.forEach((path, content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    });
    final data = ZipEncoder().encode(archive)!;
    final file = File('${tmp.path}/$name')..writeAsBytesSync(data);
    return file.path;
  }

  test('GEMDOS title extracts and autostarts the boot program', () {
    final zip = writeZip('Another World.zip', {
      'Another World.PRG': 'x',
      'DATA/1.dat': 'y',
    });
    final res = buildFalconCommand(config(), zip);
    expect(res.error, isNull, reason: res.error);
    final args = res.command!.arguments;
    expect(args, contains('--machine'));
    expect(args, contains('falcon'));
    expect(args, contains('--tos'));
    expect(args, contains('${tmp.path}/TOS404.IMG'));
    expect(args, contains('--dsp'));
    expect(args, contains('emu'));
    expect(args, contains('--monitor'));
    expect(args, contains('rgb'));
    // never the ST config
    expect(args, isNot(contains('-c')));
    expect(args, isNot(contains('--disk-a')));
    // floppy drives are disabled so the Falcon TOS drive-A dialog cannot block
    expect(args, contains('--drive-a'));
    expect(args, contains('--drive-b'));
    expect(args, contains('-d'));
    expect(args, contains('--auto'));
    expect(args, contains(r'C:\Another World.PRG'));
  });

  test('floppy-only ZIP is passed to --disk-a', () {
    final zip = writeZip('Ishar F030 - Disk 1.zip', {'ishar1.msa': 'x'});
    final res = buildFalconCommand(config(), zip);
    expect(res.error, isNull, reason: res.error);
    final args = res.command!.arguments;
    expect(args, contains('--disk-a'));
    expect(args, contains(zip));
    expect(args, isNot(contains('--auto')));
    expect(args, isNot(contains('--drive-a')));
  });

  test('multi-image floppy ZIP mounts disk A and B', () {
    final zip = writeZip('Road Riot.zip', {
      'road_riot_a.st': 'a',
      'road_riot_b.st': 'b',
    });
    final res = buildFalconCommand(config(), zip);
    expect(res.error, isNull, reason: res.error);
    final args = res.command!.arguments;
    expect(args, contains('--disk-a'));
    expect(args, contains('--disk-b'));
    expect(args.where((a) => a.endsWith('disk_a.st')), hasLength(1));
    expect(args.where((a) => a.endsWith('disk_b.st')), hasLength(1));
  });

  test('boot pick prefers the program matching the ZIP stem', () {
    final zip = writeZip('Bad Mood.zip', {
      'SETUP.PRG': 'x',
      'Bad Mood.PRG': 'y',
    });
    final res = buildFalconCommand(config(), zip);
    final args = res.command!.arguments;
    expect(args, contains(r'C:\Bad Mood.PRG'));
  });

  test('boot pick skips STZip self-extractors and numbered disks win', () {
    final zip = writeZip('AAZOHM.zip', {
      'AAZOHM2.TOS': 'STZip self extracting file v2.2',
      'AAZOHM1.TOS': 'STZip self extracting file v2.2',
      'GAME.PRG': 'x',
    });
    final res = buildFalconCommand(config(), zip);
    final args = res.command!.arguments;
    expect(args, contains(r'C:\GAME.PRG'));
  });

  test('boot pick prefers the lowest part of a numbered set', () {
    final zip = writeZip('AAZOHM.zip', {
      'AAZOHM3.TOS': '333',
      'AAZOHM2.TOS': '22',
      'AAZOHM1.TOS': '1',
    });
    final res = buildFalconCommand(config(), zip);
    final args = res.command!.arguments;
    expect(args, contains(r'C:\AAZOHM1.TOS'));
  });

  test('variant extra args are appended after the Falcon defaults', () {
    final zip = writeZip('Game.zip', {'GAME.PRG': 'x'});
    final res = buildFalconCommand(config(), zip,
        variant: kFalconVariants.firstWhere((v) => v.name == 'VGA'));
    final args = res.command!.arguments;
    expect(args, contains('vga'));
  });

  test('missing Falcon TOS aborts with a clear error', () {
    File('${tmp.path}/TOS404.IMG').deleteSync();
    final zip = writeZip('Game.zip', {'GAME.PRG': 'x'});
    final res = buildFalconCommand(config(), zip);
    expect(res.command, isNull);
    expect(res.error, contains('TOS404.IMG'));
  });
}
