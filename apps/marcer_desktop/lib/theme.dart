// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

/// The 16 standard console color names of `SPEC.md` R19 (case-insensitive
/// lookup via [consoleColor]).
const Map<String, Color> kConsoleColors = {
  'Black': Color(0xFF000000),
  'DarkBlue': Color(0xFF000080),
  'DarkGreen': Color(0xFF008000),
  'DarkCyan': Color(0xFF008080),
  'DarkRed': Color(0xFF800000),
  'DarkMagenta': Color(0xFF800080),
  'DarkYellow': Color(0xFF808000),
  'Gray': Color(0xFFC0C0C0),
  'DarkGray': Color(0xFF808080),
  'Blue': Color(0xFF0000FF),
  'Green': Color(0xFF00FF00),
  'Cyan': Color(0xFF00FFFF),
  'Red': Color(0xFFFF0000),
  'Magenta': Color(0xFFFF00FF),
  'Yellow': Color(0xFFFFFF00),
  'White': Color(0xFFFFFFFF),
};

Color consoleColor(String name, {Color fallback = const Color(0xFFFFFFFF)}) =>
    kConsoleColors[name] ?? kConsoleColors[
        kConsoleColors.keys.firstWhere(
            (k) => k.toLowerCase() == name.toLowerCase(),
            orElse: () => '')] ??
    fallback;

/// Selection colors of `SPEC.md` §9.2 (`SelectedForeground` / `SelectedBackground`).
const Color kSelectedForeground = Color(0xFF000000); // Black
const Color kSelectedBackground = Color(0xFF008080); // DarkCyan

/// Entry color per `SPEC.md` §9.3 defaults (layer + kind), virtual = White.
Color colorForEntry(Entry e) {
  if (e.isVirtual) return kConsoleColors['White']!;
  final layer = e.layerStatus;
  if (e.kind == EntryKind.directory) {
    switch (layer) {
      case LayerStatus.both:
        return kConsoleColors['Yellow']!;
      case LayerStatus.patch:
        return kConsoleColors['DarkYellow']!;
      case LayerStatus.root:
        return kConsoleColors['Gray']!;
    }
  }
  switch (layer) {
    case LayerStatus.both:
      return kConsoleColors['Green']!;
    case LayerStatus.root:
      return kConsoleColors['DarkGreen']!;
    case LayerStatus.patch:
      return kConsoleColors['Magenta']!;
  }
}

String layerLabel(Entry e) {
  switch (e.layerStatus) {
    case LayerStatus.both:
      return '[BOTH] ';
    case LayerStatus.root:
      return '[ROOT] ';
    case LayerStatus.patch:
      return '[PTCH] ';
  }
}

/// 13-char prefix per `SPEC.md` §9.1.
String linePrefix(Entry e, {required bool favorite}) {
  final layer = e.isVirtual ? '[ROOT] ' : layerLabel(e);
  final type = e.kind == EntryKind.directory
      ? '[DIR] '
      : (favorite ? '    * ' : '      ');
  return '$layer$type';
}

ThemeData buildAppTheme() {
  const seed = Color(0xFF006468);
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
    useMaterial3: true,
    scaffoldBackgroundColor: const Color(0xFF121212),
    canvasColor: const Color(0xFF121212),
    dividerColor: const Color(0xFF2A2A2A),
    visualDensity: VisualDensity.compact,
  );
}
