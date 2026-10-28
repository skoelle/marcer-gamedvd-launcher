// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// Hash maps of every decodable ST disk image in [zipPath], for matching
/// against the PirateFinder `images` table.
///
/// `.msa` members yield both their decoded raw-sector hashes (TOSEC-style) and
/// the container hashes (Atari Legend stores the SHA-512 of the `.msa` file).
/// `.st` members are raw images; `.stx` members are hashed as stored.
Future<List<Map<String, dynamic>>> pirateFinderHashesForZip(
  String zipPath,
) async {
  final bytes = await File(zipPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  final result = <Map<String, dynamic>>[];
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = file.name;
    final suffix = _suffix(name);
    if (suffix != '.msa' && suffix != '.st' && suffix != '.stx') continue;
    if (file.size > 64 * 1024 * 1024) continue;
    final data = List<int>.from(file.content as List<int>);
    if (suffix == '.msa') {
      try {
        result.add(_hashesOf(decodeMsa(data)));
      } catch (_) {
        // A damaged MSA is skipped; the container hash below may still match.
      }
      result.add(_hashesOf(data));
    } else {
      result.add(_hashesOf(data));
    }
  }
  return result;
}

/// Stable container fingerprint of the image members in [zipPath]:
/// sorted `crc32:size` pairs (`tools/full-index-gen` writes the same value).
///
/// Reads only the ZIP central directory — no member is decompressed or
/// decoded. Lets the full index resolve a renamed ZIP by content.
String pirateFinderZipFingerprint(String zipPath) {
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeBuffer(input);
    final values = <String>{};
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final suffix = _suffix(file.name);
      if (suffix != '.msa' && suffix != '.st' && suffix != '.stx') continue;
      final crc = file.crc32;
      final size = file.size;
      if (crc == null || size <= 0) continue;
      if (size > 64 * 1024 * 1024) continue;
      values.add('${crc.toRadixString(16).padLeft(8, '0')}:$size');
    }
    final sorted = values.toList()..sort();
    return sorted.join(',');
  } finally {
    input.closeSync();
  }
}

/// Decodes an MSA archive to the raw ST sector image.
Uint8List decodeMsa(List<int> data) {
  if (data.length < 10 || data[0] != 0x0E || data[1] != 0x0F) {
    throw const FormatException('not an MSA file');
  }
  final sectors = _word(data, 2);
  final sides = _word(data, 4) + 1;
  final start = _word(data, 6);
  final end = _word(data, 8);
  if (sectors < 1 || sectors > 36) {
    throw FormatException('invalid sectors per track: $sectors');
  }
  if (sides != 1 && sides != 2) {
    throw FormatException('invalid sides: $sides');
  }
  if (end < start || end > 255) {
    throw FormatException('invalid track range: $start-$end');
  }
  const sectorSize = 512;
  final trackSize = sectors * sectorSize;
  final raw = Uint8List((end + 1) * sides * trackSize);
  var index = 10;
  for (var track = start; track <= end; track++) {
    for (var side = 0; side < sides; side++) {
      if (index + 2 > data.length) {
        throw const FormatException('MSA ends before a track header');
      }
      final length = _word(data, index);
      index += 2;
      if (index + length > data.length) {
        throw const FormatException('MSA track is truncated');
      }
      final packed = data.sublist(index, index + length);
      index += length;
      if (length > trackSize) {
        throw const FormatException('MSA track is too long');
      }
      final unpacked = length == trackSize
          ? Uint8List.fromList(packed)
          : _unpackTrack(packed, trackSize);
      final offset = (track * sides + side) * trackSize;
      raw.setRange(offset, offset + trackSize, unpacked);
    }
  }
  return raw;
}

Uint8List _unpackTrack(List<int> packed, int expected) {
  final out = <int>[];
  var index = 0;
  while (index < packed.length) {
    final marker = packed.indexOf(0xE5, index);
    if (marker < 0) {
      out.addAll(packed.sublist(index));
      break;
    }
    out.addAll(packed.sublist(index, marker));
    index = marker + 1;
    if (index + 3 > packed.length) {
      throw const FormatException('MSA run record is cut off');
    }
    final fill = packed[index];
    final count = (packed[index + 1] << 8) | packed[index + 2];
    index += 3;
    out.addAll(List<int>.filled(count, fill));
    if (out.length > expected) {
      throw const FormatException('MSA track expands past its size');
    }
  }
  if (out.length != expected) {
    throw FormatException(
      'MSA track unpacked to ${out.length} bytes, expected $expected',
    );
  }
  return Uint8List.fromList(out);
}

int _word(List<int> data, int offset) => (data[offset] << 8) | data[offset + 1];

String _suffix(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

Map<String, dynamic> _hashesOf(List<int> data) {
  final bytes = data is Uint8List ? data : Uint8List.fromList(data);
  return {
    'sha1': sha1.convert(bytes).toString(),
    'md5': md5.convert(bytes).toString(),
    'sha512': sha512.convert(bytes).toString(),
    'crc32': getCrc32(bytes).toRadixString(16).padLeft(8, '0'),
    'size': bytes.length,
  };
}
