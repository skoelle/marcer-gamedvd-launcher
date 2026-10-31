// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/piratefinder_zip.dart';

Uint8List _packTrack(List<int> raw) {
  final out = <int>[];
  var index = 0;
  while (index < raw.length) {
    final value = raw[index];
    var run = 1;
    while (index + run < raw.length &&
        raw[index + run] == value &&
        run < 0xFFFF) {
      run++;
    }
    if (run >= 4 || value == 0xE5) {
      out
        ..add(0xE5)
        ..add(value)
        ..add((run >> 8) & 0xFF)
        ..add(run & 0xFF);
    } else {
      out.addAll(List<int>.filled(run, value));
    }
    index += run;
  }
  return Uint8List.fromList(out);
}

Uint8List _buildMsa(Uint8List raw, int sectors, int sides, int tracks) {
  final trackSize = sectors * 512;
  final header = <int>[
    0x0E,
    0x0F,
    (sectors >> 8) & 0xFF,
    sectors & 0xFF,
    0,
    sides - 1,
    0,
    0,
    (tracks - 1) >> 8,
    (tracks - 1) & 0xFF,
  ];
  final body = <int>[];
  for (var track = 0; track < tracks; track++) {
    for (var side = 0; side < sides; side++) {
      final offset = (track * sides + side) * trackSize;
      final chunk = raw.sublist(offset, offset + trackSize);
      final packed = _packTrack(chunk);
      final chosen = packed.length < chunk.length ? packed : chunk;
      body
        ..add((chosen.length >> 8) & 0xFF)
        ..add(chosen.length & 0xFF)
        ..addAll(chosen);
    }
  }
  return Uint8List.fromList([...header, ...body]);
}

void main() {
  test('decodeMsa reproduces the raw image', () {
    const sectors = 9;
    const sides = 2;
    const tracks = 2;
    final raw = Uint8List(tracks * sides * sectors * 512);
    for (var i = 0; i < raw.length; i += 4096) {
      raw[i] = i & 0xFF;
    }
    final msa = _buildMsa(raw, sectors, sides, tracks);
    expect(decodeMsa(msa), raw);
  });

  test('hashesForZip includes raw MSA and .st hashes', () async {
    const sectors = 9;
    const sides = 1;
    const tracks = 1;
    final raw = Uint8List(tracks * sides * sectors * 512);
    raw[0] = 1;
    final msa = _buildMsa(raw, sectors, sides, tracks);
    final archive = Archive()
      ..addFile(ArchiveFile('game.msa', msa.length, msa))
      ..addFile(ArchiveFile('game.st', raw.length, raw));
    final zip = ZipEncoder().encode(archive);
    final tmp = Directory.systemTemp.createTempSync('pf_zip_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}/game.zip';
    File(path).writeAsBytesSync(zip);

    final hashes = await pirateFinderHashesForZip(path);
    expect(hashes, isNotEmpty);
    final rawSha1 = sha1.convert(raw).toString();
    expect(hashes.any((h) => h['sha1'] == rawSha1), isTrue);
    expect(hashes.any((h) => h['size'] == raw.length), isTrue);
  });

  test('zipFingerprint uses only the central directory crc/size pairs', () {
    const sectors = 9;
    const sides = 1;
    const tracks = 1;
    final raw = Uint8List(tracks * sides * sectors * 512);
    raw[0] = 7;
    final msa = _buildMsa(raw, sectors, sides, tracks);
    final archive = Archive()
      ..addFile(ArchiveFile('game.msa', msa.length, msa))
      ..addFile(ArchiveFile('game.st', raw.length, raw));
    final zip = ZipEncoder().encode(archive);
    final tmp = Directory.systemTemp.createTempSync('pf_zip_fp');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}/game.zip';
    File(path).writeAsBytesSync(zip);

    String pair(List<int> data) =>
        '${getCrc32(data).toRadixString(16).padLeft(8, '0')}:${data.length}';
    final expected = [pair(msa), pair(raw)]..sort();
    expect(pirateFinderZipFingerprint(path), expected.join(','));
  });
}
