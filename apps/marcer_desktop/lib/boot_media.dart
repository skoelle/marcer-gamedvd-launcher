// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// Floppy disk images Hatari can read from inside a ZIP (`--disk-a`).
const Set<String> _floppyExts = {
  '.st',
  '.msa',
  '.stx',
  '.ipf',
  '.ctr',
  '.raw',
};

/// GEMDOS programs that can be autostarted with `--auto`.
const Set<String> _bootExts = {'.prg', '.tos', '.ttp', '.app', '.gtp'};

/// GEMDOS boots disable both floppy drives: Falcon TOS 4.04 otherwise raises
/// a modal "Drive A: is not responding" dialog that blocks the autostart
/// (harmless on ST, where it also avoids probing an empty drive).
const List<String> _noFloppy = ['--drive-a', 'off', '--drive-b', 'off'];

/// Session temp root for extracted GEMDOS titles.
String _bootTempRoot() =>
    p.join(Directory.systemTemp.path, 'marcer_boot_$pid');

String _norm(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Sort key that prefers disk 1 / A over 2 / B (`..._a.st`, `disk1`).
int _diskIndex(String name) {
  final base = _norm(p.basenameWithoutExtension(name));
  final m = RegExp(r'(\d+)$').firstMatch(base);
  if (m != null) return int.parse(m.group(1)!);
  if (base.endsWith('a')) return 1;
  if (base.endsWith('b')) return 2;
  return 99;
}

/// True for Atari STZip self-extracting archives (they only unpack files).
bool _isStzip(ArchiveFile f) {
  final c = f.content;
  if (c.length < 5) return false;
  return String.fromCharCodes(c.take(5)).toLowerCase() == 'stzip';
}

/// Returns `(part, prefix)` for a disk-like boot name, else `(null, base)`.
(int?, String) _partNumber(String name) {
  final base = _norm(p.basenameWithoutExtension(name));
  final m = RegExp(r'(\d+)$').firstMatch(base);
  if (m != null) {
    return (int.parse(m.group(1)!), base.substring(0, m.start));
  }
  if (base.endsWith('a')) return (1, base.substring(0, base.length - 1));
  if (base.endsWith('b')) return (2, base.substring(0, base.length - 1));
  return (null, base);
}

/// Picks the program to autostart from the ZIP's boot files (mirrors
/// `tools/screenshot-gen/shotgen.py`): stem match, stem containment (skipping
/// STZip self-extractors), the only boot file, a numbered multi-part set's
/// lowest part, else the largest.
ArchiveFile _pickBoot(List<ArchiveFile> boots, String stem) {
  final target = _norm(stem);
  final contain = <ArchiveFile>[];
  for (final f in boots) {
    if (_isStzip(f)) continue;
    final ns = _norm(p.basenameWithoutExtension(f.name));
    if (ns == target) return f;
    if (target.isNotEmpty && (target.contains(ns) || ns.contains(target))) {
      contain.add(f);
    }
  }
  if (contain.length == 1) return contain.first;
  final real = boots.where((f) => !_isStzip(f)).toList();
  final pool =
      contain.isNotEmpty ? contain : (real.isNotEmpty ? real : boots);
  if (pool.length == 1) return pool.first;
  final groups = <String, List<(int?, ArchiveFile)>>{};
  for (final f in pool) {
    final (part, prefix) = _partNumber(f.name);
    groups.putIfAbsent(prefix, () => []).add((part, f));
  }
  ArchiveFile? numbered;
  int? numberedPart;
  for (final items in groups.values) {
    // A numbered set needs at least two numbered members (so `FPATCH` +
    // `FPATCH2` is not a set); then the lowest part wins.
    final parts = items.where((t) => t.$1 != null).toList()
      ..sort((a, b) => a.$1!.compareTo(b.$1!));
    if (parts.length >= 2) {
      final part = parts.first.$1!;
      if (numberedPart == null || part < numberedPart) {
        numbered = parts.first.$2;
        numberedPart = part;
      }
    }
  }
  if (numbered != null) return numbered;
  pool.sort((a, b) => b.size.compareTo(a.size));
  return pool.first;
}

/// One prepared boot medium: extra Hatari args and the mode
/// (`floppy` | `gemdos`).
class BootMedia {
  const BootMedia(this.mode, this.args);

  final String mode;
  final List<String> args;
}

/// Inspects [zipPath] and prepares the boot medium (extracting GEMDOS titles
/// into a session temp directory). Throws on unreadable archives.
BootMedia prepareBoot(String zipPath) {
  final stem = p.basenameWithoutExtension(zipPath);
  final archive = ZipDecoder().decodeStream(InputFileStream(zipPath));
  final files = archive.files.where((f) => f.isFile).toList();
  final images = files
      .where((f) => _floppyExts.contains(p.extension(f.name).toLowerCase()))
      .toList();
  final boots = files
      .where((f) => _bootExts.contains(p.extension(f.name).toLowerCase()))
      .toList();

  final dir = Directory(p.join(_bootTempRoot(), stem));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  if (images.isNotEmpty && boots.isEmpty) {
    // Disk image(s) inside the ZIP: Hatari reads them directly.
    return BootMedia('floppy', _floppyArgs(dir.path, zipPath, images));
  }

  _extract(archive, dir.path);
  final args = <String>[..._noFloppy, '-d', dir.path];
  if (boots.isNotEmpty) {
    final boot = _pickBoot(boots, stem);
    args
      ..add('--auto')
      ..add('C:\\${boot.name.replaceAll('/', '\\')}');
  }
  return BootMedia('gemdos', args);
}

/// Mounts the floppy image(s): one image → Hatari reads the ZIP; several
/// (disk A/B) → extract the first two and mount them as drive A and B.
List<String> _floppyArgs(
    String dir, String zipPath, List<ArchiveFile> images) {
  final ordered = [...images]
    ..sort((a, b) {
      final d = _diskIndex(a.name).compareTo(_diskIndex(b.name));
      return d != 0 ? d : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  if (ordered.length == 1) return ['--disk-a', zipPath];
  final out = <String>[];
  for (final (label, f) in [('a', ordered[0]), ('b', ordered[1])]) {
    final ext = p.extension(f.name);
    final dest = p.join(dir, 'disk_$label$ext');
    final stream = OutputFileStream(dest);
    f.writeContent(stream);
    stream.closeSync();
    out
      ..add('--disk-$label')
      ..add(dest);
  }
  return out;
}

/// Extracts [archive] into [dest], rejecting absolute/traversal member paths.
void _extract(Archive archive, String dest) {
  final root = p.normalize(Directory(dest).absolute.path);
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final outPath = p.normalize(p.join(root, f.name));
    if (outPath != root && !p.isWithin(root, outPath)) continue;
    Directory(p.dirname(outPath)).createSync(recursive: true);
    final out = OutputFileStream(outPath);
    f.writeContent(out);
    out.closeSync();
  }
}
