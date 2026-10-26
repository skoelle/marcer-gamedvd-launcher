// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:path/path.dart' as p;

/// The app's per-user data directory on macOS
/// (`~/Library/Application Support/MarcerGameDVDLauncher`), or `''` on the
/// other platforms (which use the portable layout next to the app).
///
/// Used for downloaded artifacts and as the last-resort config location: a
/// quarantined, unsigned app runs from a randomized read-only **App
/// Translocation** path where nothing next to the app is writable, so this is
/// the only stable, writable place.
String marcerAppDataDir() {
  if (!Platform.isMacOS) return '';
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return '';
  return p.join(
      home, 'Library', 'Application Support', 'MarcerGameDVDLauncher');
}

/// Stable per-user directory for downloaded artifacts (the prebuilt Hatari and
/// the TOS ROM images).
///
/// On macOS this is [marcerAppDataDir]: writing inside the `.app` bundle is
/// unreliable there — a quarantined, unsigned app runs from a randomized
/// read-only **App Translocation** path, the bundle is replaced on self-update
/// and may live on a read-only volume. On the other platforms the portable
/// layout is kept unchanged: the app directory (falling back to the current
/// working directory when unset).
String downloadedDataDir(DesktopConfig config) {
  final appData = marcerAppDataDir();
  if (appData.isNotEmpty) return appData;
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

/// User-facing recovery steps for App Translocation (used by the startup hint
/// and the blocked self-update).
///
/// The decisive part is the **individual Finder move of the `.app`**: moving
/// the enclosing folder or `mv` in Terminal does not end translocation.
const String kAppTranslocatedHint =
    'macOS runs this app from a temporary read-only copy (App Translocation). '
    'Quit it, create ~/MarcerGameDVDLauncher, move MarcerGameDVDLauncher.app '
    'into it INDIVIDUALLY in Finder (not the whole folder, not `mv` in '
    'Terminal), then move MarcerGameDvd-Hatari.cfg and '
    'desktop.config.example.json next to it, and reopen the app from there. '
    'If the app is already in that folder, move it individually out (e.g. to '
    'Downloads) and individually back. Alternatively remove the quarantine: '
    'xattr -dr com.apple.quarantine <path to .app>.';

/// Self-update error shown while the app runs translocated (read-only).
const String kAppTranslocatedUpdateError =
    'Self-update is not possible while macOS runs the app from a temporary '
    'read-only copy (App Translocation).\n\n$kAppTranslocatedHint';
