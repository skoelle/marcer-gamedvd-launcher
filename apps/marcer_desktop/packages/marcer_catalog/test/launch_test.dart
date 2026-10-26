// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String appDir;
  late String zipPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('launch_test');
    appDir = tmp.path;
    zipPath = '${tmp.path}/Game.zip';
    File(zipPath).writeAsStringSync('zip');
    File('${tmp.path}/hatari').writeAsStringSync('bin');
    File('${tmp.path}/$kBundledHatariConfig').writeAsStringSync('cfg');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('splitCommandLine', () {
    test('splits on whitespace and honours double quotes', () {
      expect(splitCommandLine('-c "{cfg}" --disk-a "{zip}"'), [
        '-c',
        '{cfg}',
        '--disk-a',
        '{zip}',
      ]);
    });

    test('handles single quotes and unquoted tokens', () {
      expect(splitCommandLine("--x 'a b' c"), ['--x', 'a b', 'c']);
    });

    test('keeps empty quoted argument', () {
      expect(splitCommandLine('a "" b'), ['a', '', 'b']);
    });
  });

  group('hatariArguments', () {
    test('substitutes {cfg} and {zip}', () {
      final args = hatariArguments(
        '-c "{cfg}" --disk-a "{zip}"',
        '/cfg/hatari.cfg',
        '/games/Game.zip',
      );
      expect(args, ['-c', '/cfg/hatari.cfg', '--disk-a', '/games/Game.zip']);
    });
  });

  group('DesktopConfig Hatari resolution', () {
    test('bundled config fallback next to the executable', () {
      final c = DesktopConfig(rootDirectory: '/r', appDir: appDir);
      expect(c.resolveHatariConfigFile(), '$appDir/$kBundledHatariConfig');
    });

    test('bundled config found in the first search dir that contains it', () {
      final other = Directory('${tmp.path}/other')..createSync();
      final c = DesktopConfig(
        rootDirectory: '/r',
        appDir: appDir,
        searchDirs: [other.path, appDir],
      );
      File('$appDir/$kBundledHatariConfig').writeAsStringSync('cfg');
      expect(c.resolveHatariConfigFile(), '$appDir/$kBundledHatariConfig');
    });

    test('explicit ConfigFile wins; relative resolves against appDir', () {
      final c = DesktopConfig(
        rootDirectory: '/r',
        appDir: appDir,
        hatariConfigFile: 'my.cfg',
      );
      expect(c.resolveHatariConfigFile(), '$appDir/my.cfg');
    });

    test('relative executable resolves against appDir', () {
      final c = DesktopConfig(
        rootDirectory: '/r',
        appDir: appDir,
        hatariExecutable: 'hatari',
      );
      expect(c.resolveHatariExecutable(), '$appDir/hatari');
    });
  });

  group('validateHatariConfig', () {
    test('accepts a complete, existing configuration', () {
      final c = DesktopConfig(
        rootDirectory: '/r',
        appDir: appDir,
        hatariExecutable: 'hatari',
      );
      expect(validateHatariConfig(c), isNull);
    });

    test('missing executable', () {
      final c = DesktopConfig(rootDirectory: '/r', appDir: appDir);
      expect(validateHatariConfig(c), contains('must be set'));
    });

    test('non-existent executable', () {
      final c = DesktopConfig(
        rootDirectory: '/r',
        appDir: appDir,
        hatariExecutable: 'nope',
      );
      expect(validateHatariConfig(c), contains('not found'));
    });

    test('template must contain {zip} and {cfg}', () {
      final c = DesktopConfig(
        rootDirectory: '/r',
        appDir: appDir,
        hatariExecutable: 'hatari',
        hatariArgsTemplate: '--disk-a "{zip}"',
      );
      expect(validateHatariConfig(c), contains('{cfg}'));
    });

    test('missing implicit bundled config is reported clearly', () {
      File('$appDir/$kBundledHatariConfig').deleteSync();
      final c = DesktopConfig(
        rootDirectory: '/r',
        appDir: appDir,
        hatariExecutable: 'hatari',
      );
      final error = validateHatariConfig(c);
      expect(error, contains('configuration file not found'));
      // Hatari aborts argument parsing (exit code 1) on a missing `-c` file,
      // so the error must point at the fix instead of the bare exit code.
      expect(error, contains(kBundledHatariConfig));
    });

    test('missing explicit config is reported clearly', () {
      final c = DesktopConfig(
        rootDirectory: '/r',
        appDir: appDir,
        hatariExecutable: 'hatari',
        hatariConfigFile: 'gone.cfg',
      );
      expect(validateHatariConfig(c), contains('configuration file not found'));
    });
  });

  group('buildHatariCommand', () {
    test('builds command with substituted args and appDir working dir', () {
      final c = DesktopConfig(
        rootDirectory: '/r',
        appDir: appDir,
        hatariExecutable: 'hatari',
      );
      final result = buildHatariCommand(c, zipPath);
      expect(result.error, isNull);
      expect(result.command!.executable, '$appDir/hatari');
      expect(result.command!.workingDirectory, appDir);
      expect(result.command!.arguments, [
        '-c',
        '$appDir/$kBundledHatariConfig',
        '--disk-a',
        zipPath,
      ]);
    });

    test('vanished ZIP yields an error (SPEC E7)', () {
      final c = DesktopConfig(
        rootDirectory: '/r',
        appDir: appDir,
        hatariExecutable: 'hatari',
      );
      final result = buildHatariCommand(c, '${tmp.path}/gone.zip');
      expect(result.command, isNull);
      expect(result.error, contains('ZIP file not found'));
    });
  });
}
