// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

/// Filename-derived card grouping for the magazine cover disks section.
///
/// The magazine scope (`Bonus/Magazine Cover Disks`) has no metadata at
/// all; every bit of information lives in the file name. One card = one
/// magazine issue: multiple disks and ` (2)` copies become variants. The
/// parser is mirrored in `tools/gallery/gallery.py` (`_magazine_key`).
library;

/// One magazine card group derived from a ZIP file name.
class MagazineGroup {
  const MagazineGroup({
    required this.folder,
    required this.display,
    required this.year,
  });

  /// Group key below the magazine folder (issue number / `YYYY-MM`).
  final String folder;

  /// Human-readable card title (e.g. `ST Action 41`).
  final String display;

  /// Four-digit year parsed from the file name, or `''`.
  final String year;
}

const List<String> _suffixes = [
  ' - 2 missings',
  ' - 4 missings',
  ' - Complete',
];

/// Cleans a magazine folder name (`ST Action - 2 missings` -> `ST Action`).
String magazineName(String folder) {
  var name = folder;
  for (final suffix in _suffixes) {
    if (name.endsWith(suffix)) {
      name = name.substring(0, name.length - suffix.length);
    }
  }
  return name;
}

final RegExp _duplicateSuffix = RegExp(r'\s*\(\d+\)\s*$');
final RegExp _yearRe = RegExp(r'\b(19|20)\d{2}\b');
final RegExp _stActionRe = RegExp(r'st action\s+(\d+)', caseSensitive: false);
final RegExp _startMicroRe =
    RegExp(r'start\s*micro\s*(\d+)', caseSensitive: false);
final RegExp _startMicroDateRe = RegExp(r'\((\d{4})-(\d{2})\)');
final RegExp _stComputerRe = RegExp(
    r'(\d{4})[_-](\d{2}(?:-\d{2})?|s\d|p\d)',
    caseSensitive: false);
final RegExp _issueRe = RegExp(r'issue\s*(\d+)', caseSensitive: false);

/// Groups one magazine ZIP (file name without `.zip`) into an issue card.
MagazineGroup magazineGroup(String magazineFolder, String stem) {
  final mag = magazineName(magazineFolder);
  final s = stem.replaceAll(_duplicateSuffix, '');
  final year = _yearRe.firstMatch(s)?.group(0) ?? '';
  if (mag == 'ST Action') {
    final m = _stActionRe.firstMatch(s);
    if (m != null) {
      return MagazineGroup(
        folder: m.group(1)!,
        display: 'ST Action ${m.group(1)}',
        year: '',
      );
    }
  } else if (mag == 'Start Micro') {
    final m = _startMicroRe.firstMatch(s);
    if (m != null) {
      final date = _startMicroDateRe.firstMatch(s);
      return MagazineGroup(
        folder: m.group(1)!,
        display: 'Start Micro ${m.group(1)}',
        year: date?.group(1) ?? '',
      );
    }
  } else if (mag == 'ST Computer') {
    final m = _stComputerRe.firstMatch(s);
    if (m != null) {
      final label = '${m.group(1)}-${m.group(2)!.toUpperCase()}';
      return MagazineGroup(
        folder: m.group(0)!.toLowerCase(),
        display: 'ST Computer $label',
        year: m.group(1)!,
      );
    }
  } else if (mag == 'The One' || mag == 'Zero') {
    final m = _issueRe.firstMatch(s);
    if (m != null) {
      return MagazineGroup(
        folder: m.group(1)!,
        display: '$mag Issue ${m.group(1)}',
        year: year,
      );
    }
  }
  return MagazineGroup(folder: s.toLowerCase(), display: s, year: year);
}
