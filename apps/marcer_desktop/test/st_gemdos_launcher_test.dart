// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/boot_media.dart';
import 'package:marcer_desktop/st_gemdos_launcher.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('st_gemdos_launcher_test');
    File('${tmp.path}/hatari').writeAsStringSync('');
    File('${tmp.path}/MarcerGameDvd-Hatari.cfg').writeAsStringSync('cfg');
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
    final data = ZipEncoder().encode(archive);
    return (File('${tmp.path}/$name')..writeAsBytesSync(data)).path;
  }

  test('GEMDOS magazine disk uses the ST config + -d/--auto', () {
    final zip = writeZip('1990_01.zip', {
      '1990_01/PLANET/PLANET.PRG': 'x',
      '1990_01/READ.ME': 'y',
    });
    final boot = prepareBoot(zip);
    expect(boot.mode, 'gemdos');
    final res = buildStGemdosCommand(config(), zip, boot);
    expect(res.error, isNull, reason: res.error);
    final args = res.command!.arguments;
    expect(args, contains('-c'));
    expect(args, contains('${tmp.path}/MarcerGameDvd-Hatari.cfg'));
    expect(args, contains('--drive-a'));
    expect(args, contains('--drive-b'));
    expect(args, contains('-d'));
    expect(args, contains('--auto'));
    expect(args, contains(r'C:\1990_01\PLANET\PLANET.PRG'));
    expect(args, isNot(contains('--disk-a')));
  });

  test('floppy magazine disk stays a floppy boot', () {
    final zip = writeZip('Zero Issue 01.zip', {'recoil.msa': 'x'});
    final boot = prepareBoot(zip);
    expect(boot.mode, 'floppy');
  });

  test('GEMDOS launch only requires {cfg}, the ZIP launch still needs {zip}',
      () {
    final zip = writeZip('1990_01.zip', {
      '1990_01/PLANET/PLANET.PRG': 'x',
    });
    final boot = prepareBoot(zip);
    final cfg = DesktopConfig(
      rootDirectory: tmp.path,
      appDir: tmp.path,
      hatariExecutable: 'hatari',
      hatariArgsTemplate: '--configfile "{cfg}"',
    );

    final res = buildStGemdosCommand(cfg, zip, boot);
    expect(res.error, isNull, reason: res.error);
    expect(res.command!.arguments, contains('-c'));

    // The normal (floppy/ZIP) launch keeps the strict validation.
    expect(validateHatariConfig(cfg), contains('{zip}'));
  });
}
