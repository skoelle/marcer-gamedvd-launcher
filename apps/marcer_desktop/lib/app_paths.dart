// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

/// Stable per-user directory for downloaded artifacts (the prebuilt Hatari and
/// the TOS ROM images).
///
/// On macOS this is `~/Library/Application Support/MarcerGameDVDLauncher`:
/// writing inside the `.app` bundle is unreliable there — a quarantined,
/// unsigned app runs from a randomized read-only **App Translocation** path,
/// the bundle is replaced on self-update and may live on a read-only volume.
/// On the other platforms the portable layout is kept unchanged: the app
/// directory (falling back to the current working directory when unset).
String downloadedDataDir(DesktopConfig config) {
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return p.join(
          home, 'Library', 'Application Support', 'MarcerGameDVDLauncher');
    }
  }
  return config.appDir.isNotEmpty ? config.appDir : Directory.current.path;
}

/// True when macOS is running the app from a randomized, read-only
/// App-Translocation path (a quarantined, unsigned/not-notarized app launched
/// e.g. straight from `~/Downloads`). Config writes, favorites, downloaded
/// artifacts and relative paths are unstable there — the user should move the
/// app to a normal folder and/or clear the quarantine.
bool isAppTranslocated() =>
    Platform.isMacOS &&
    Platform.resolvedExecutable.contains('/AppTranslocation/');
