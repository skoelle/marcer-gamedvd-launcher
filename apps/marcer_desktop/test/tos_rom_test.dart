// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/tos_rom.dart';

List<int> _zipWith(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

void main() {
  test('offers the TOS options in the agreed order', () {
    expect(kTosRomOptions, hasLength(9));
    expect(kTosRomOptions.map((o) => o.label).toList(), [
      'English (UK) — TOS 1.04',
      'English (UK) — TOS 1.02',
      'English (UK) — TOS 1.00',
      'Deutsch — TOS 1.04',
      'Deutsch — TOS 1.02',
      'Deutsch — TOS 1.00',
      'English (UK) — TOS 1.62',
      'Deutsch — TOS 1.62',
      'Multilanguage — TOS 4.04',
    ]);
    expect(kTosRomOptions.map((o) => o.url).toList(), [
      'https://www.atariworld.org/files/images/tos104uk.zip',
      'https://www.atariworld.org/files/images/tos102uk.zip',
      'https://www.atariworld.org/files/images/tos100uk.zip',
      'https://www.atariworld.org/files/images/tos104de.zip',
      'https://www.atariworld.org/files/images/tos102de.zip',
      'https://www.atariworld.org/files/images/tos100de.zip',
      'https://www.atariworld.org/files/images/tos162uk.zip',
      'https://www.atariworld.org/files/images/tos162de.zip',
      'https://www.atariworld.org/files/images/tos404.zip',
    ]);
    expect(kDefaultTosRomOption.label, 'English (UK) — TOS 1.04');
    expect(kDefaultTosVersions, ['1.04']);
  });

  test('resolves the TOS image next to the app directory', () {
    final cfg = DesktopConfig(rootDirectory: '/r', appDir: '/apps/launcher');
    expect(tosTargetDirectory(cfg), '/apps/launcher');
    expect(tosImagePath(cfg), '/apps/launcher/TOS.IMG');
    expect(tosImagePath(cfg, fileName: 'TOS162.IMG'),
        '/apps/launcher/TOS162.IMG');
  });

  test('pickTosRomEntry prefers a ROM extension over a larger text file', () {
    final archive = Archive();
    archive.addFile(
        ArchiveFile('readme.txt', 500, List<int>.filled(500, 0x20)));
    archive.addFile(ArchiveFile('tos104uk.img', 10, List<int>.filled(10, 1)));
    final picked = pickTosRomEntry(archive);
    expect(picked, isNotNull);
    expect(picked!.name, 'tos104uk.img');
    expect(picked.bytes, hasLength(10));
  });

  test('writeTosImageFromZip extracts the ROM as TOS.IMG', () {
    final dir = Directory.systemTemp.createTempSync('tos_rom_test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final rom = List<int>.filled(192 * 1024, 0xAB);
    final zip = _zipWith({
      'readme.txt': utf8.encode('TOS image'),
      'tos104uk.img': rom,
    });

    final source = writeTosImageFromZip(zip, dir.path);

    expect(source, 'tos104uk.img');
    final out = File('${dir.path}/TOS.IMG');
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync(), rom.length);
  });

  test('writeTosImageFromZip throws on an invalid ZIP', () {
    expect(() => writeTosImageFromZip(utf8.encode('not a zip'), '/tmp'),
        throwsA(isA<TosRomException>()));
  });

  test('writeTosImageFromZip throws when no file entry exists', () {
    final emptyZip = _zipWith({});
    expect(() => writeTosImageFromZip(emptyZip, '/tmp'),
        throwsA(isA<TosRomException>()));
  });
}
