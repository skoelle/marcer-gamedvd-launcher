// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/app_paths.dart';
import 'package:marcer_desktop/hatari_installer.dart';
import 'package:path/path.dart' as p;

List<int> _zipWith(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

void main() {
  test('offers a build for Windows and macOS, but none for Linux', () {
    expect(hatariBuildFor(os: 'windows')?.label, contains('Windows'));
    expect(hatariBuildFor(os: 'macos')?.label, contains('macOS'));
    expect(hatariBuildFor(os: 'linux'), isNull);
  });

  test('build URLs point at the pinned SourceForge release', () {
    final win = hatariBuildFor(os: 'windows')!;
    final mac = hatariBuildFor(os: 'macos')!;
    expect(win.url, contains('hatari/$kHatariVersion/'));
    expect(win.url, contains('hatari-${kHatariVersion}_windows64.zip'));
    expect(mac.url, contains('hatari-${kHatariVersion}_macos.zip'));
  });

  test('resolves the install directory next to the app', () {
    final cfg = DesktopConfig(rootDirectory: '/r', appDir: '/apps/launcher');
    expect(hatariBaseDir(cfg), '/apps/launcher');
    expect(hatariInstallDir(cfg), p.join('/apps/launcher', 'hatari'));
  });

  test('downloadedDataDir keeps the app dir on non-macOS', () {
    final cfg = DesktopConfig(rootDirectory: '/r', appDir: '/apps/launcher');
    if (Platform.isMacOS) {
      // macOS installs outside the .app bundle, in the per-user data dir.
      expect(downloadedDataDir(cfg), contains('MarcerGameDVDLauncher'));
      expect(downloadedDataDir(cfg), contains('Application Support'));
    } else {
      expect(downloadedDataDir(cfg), '/apps/launcher');
    }
  });

  test('hatariInstalled reflects the configured executable', () {
    final dir = Directory.systemTemp.createTempSync('hatari_installed');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final exe = File(p.join(dir.path, 'hatari.exe'))..writeAsBytesSync([0]);
    final cfg = DesktopConfig(
        rootDirectory: '/r', appDir: dir.path, hatariExecutable: 'hatari.exe');
    expect(hatariInstalled(cfg), isTrue);
    expect(hatariInstalled(cfg.copyWith(hatariExecutable: 'missing')), isFalse);
    expect(hatariInstalled(DesktopConfig(rootDirectory: '/r')), isFalse);
    expect(exe.existsSync(), isTrue);
  });

  test('hatariConfigExecutable is relative to the app dir when known', () {
    expect(
        hatariConfigExecutable(
            appDir: '/apps/launcher',
            exePath: p.join('/apps/launcher', 'hatari', 'hatari.exe')),
        p.join('hatari', 'hatari.exe'));
    expect(
        hatariConfigExecutable(appDir: '', exePath: '/opt/hatari/hatari'),
        '/opt/hatari/hatari');
  });

  test('hatariConfigExecutable stays absolute outside the app dir (macOS)', () {
    const exe = '/Users/x/Library/Application Support/MarcerGameDVDLauncher/'
        'hatari/Hatari.app/Contents/MacOS/Hatari';
    expect(hatariConfigExecutable(appDir: '/Applications/App.app/Contents/MacOS',
        exePath: exe), exe);
  });

  test('findHatariExecutable finds hatari.exe (Windows layout)', () {
    final dir = Directory.systemTemp.createTempSync('hatari_find_win');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File(p.join(dir.path, 'hatari-2.6.1_windows64', 'hatari.exe'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);
    File(p.join(dir.path, 'hatari-2.6.1_windows64', 'SDL2.dll'))
        .writeAsBytesSync([0]);

    final exe = findHatariExecutable(dir.path);
    expect(exe, isNotNull);
    expect(p.basename(exe!), 'hatari.exe');
  });

  test('findHatariExecutable finds the macOS bundle executable', () {
    final dir = Directory.systemTemp.createTempSync('hatari_find_mac');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File(p.join(dir.path, 'Hatari.app', 'Contents', 'MacOS', 'hatari'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([0]);
    File(p.join(dir.path, 'Hatari.app', 'Contents', 'Info.plist'))
        .writeAsBytesSync([0]);
    File(p.join(dir.path, 'readme.txt')).writeAsBytesSync([0]);

    final exe = findHatariExecutable(dir.path);
    expect(exe, isNotNull);
    expect(p.basename(exe!), 'hatari');
    expect(exe, contains('Contents'));
  });

  test('findHatariExecutable returns null for an unrelated tree', () {
    final dir = Directory.systemTemp.createTempSync('hatari_find_none');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File(p.join(dir.path, 'readme.txt')).writeAsBytesSync([0]);
    expect(findHatariExecutable(dir.path), isNull);
  });

  test('findHatariExecutable ignores empty placeholder files', () {
    final dir = Directory.systemTemp.createTempSync('hatari_find_empty');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File(p.join(dir.path, 'hatari')).createSync(); // 0 bytes
    expect(findHatariExecutable(dir.path), isNull);
  });

  test('installHatariFromZip extracts and returns the executable', () {
    final dir = Directory.systemTemp.createTempSync('hatari_install');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final zip = _zipWith({
      'hatari-2.6.1_windows64/hatari.exe': List<int>.filled(16, 0x7F),
      'hatari-2.6.1_windows64/SDL2.dll': List<int>.filled(8, 0x00),
    });

    final exe = installHatariFromZip(zip, dir.path);

    expect(p.basename(exe), 'hatari.exe');
    expect(File(exe).existsSync(), isTrue);
    expect(
        File(p.join(dir.path, 'hatari-2.6.1_windows64', 'SDL2.dll'))
            .existsSync(),
        isTrue);
  });

  test('installHatariFromZip throws on an invalid ZIP', () {
    expect(() => installHatariFromZip([1, 2, 3], '/tmp'),
        throwsA(isA<HatariInstallException>()));
  });

  test('installHatariFromZip throws when no executable exists', () {
    final dir = Directory.systemTemp.createTempSync('hatari_no_exe');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final zip = _zipWith({'readme.txt': [1, 2, 3]});
    expect(() => installHatariFromZip(zip, dir.path),
        throwsA(isA<HatariInstallException>()));
  });
}
