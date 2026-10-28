// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

/// Pure-Dart data layer for the Marcer GameDVD desktop app.
///
/// Implements the technology-neutral contracts of the repo specs:
/// - overlay merge per `SPEC-launcher.md` section 7,
/// - gameinfo join per `ANALYSIS-game-data.md` section 4.2,
/// - screenshot index lookup per `SPEC-screenshot-generator.md`.
library;

export 'src/atarilegend.dart';
export 'src/card.dart';
export 'src/catalog_filter.dart';
export 'src/catalog_universe.dart';
export 'src/config.dart';
export 'src/crews.dart';
export 'src/entry.dart';
export 'src/full_index.dart';
export 'src/gameinfo.dart';
export 'src/launch.dart';
export 'src/magazine.dart';
export 'src/overlay.dart';
export 'src/piratefinder.dart';
export 'src/screenshot_index.dart';
export 'src/section_trees.dart';
