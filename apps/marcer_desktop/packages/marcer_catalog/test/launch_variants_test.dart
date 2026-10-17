// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String exe;
  late String cfgFile;
  late String zip;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('launch_variants_test');
    exe = '${tmp.path}/hatari';
    cfgFile = '${tmp.path}/hatari.cfg';
    zip = '${tmp.path}/game.zip';
    File(exe).createSync();
    File(cfgFile).createSync();
    File(zip).createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  DesktopConfig config() => DesktopConfig(
        rootDirectory: '${tmp.path}/root',
        hatariExecutable: exe,
        hatariConfigFile: cfgFile,
        appDir: tmp.path,
      );

  HatariVariant variant(String name) =>
      kHatariVariants.firstWhere((v) => v.name == name);

  test('standard variant appends no extra args', () {
    final r = buildHatariCommand(config(), zip, variant: variant('Standard'));
    expect(r.error, isNull);
    expect(r.command!.arguments, isNot(contains('--machine')));
    expect(r.command!.arguments, isNot(contains('--mono')));
    expect(r.command!.arguments, isNot(contains('--tos')));
  });

  test('mono variant adds --mono --tos-res high', () {
    final r = buildHatariCommand(config(), zip, variant: variant('Mono'));
    expect(r.command!.arguments,
        containsAllInOrder(['--mono', '--tos-res', 'high']));
  });

  test('STE variant adds --machine ste and --tos TOS162.IMG', () {
    File('${tmp.path}/TOS162.IMG').createSync();
    final r = buildHatariCommand(config(), zip, variant: variant('STE'));
    expect(r.error, isNull);
    expect(r.command!.arguments, containsAllInOrder(['--machine', 'ste']));
    final i = r.command!.arguments.indexOf('--tos');
    expect(i, greaterThanOrEqualTo(0));
    expect(r.command!.arguments[i + 1], '${tmp.path}/TOS162.IMG');
  });

  test('STE variant without the TOS 1.62 ROM reports an error', () {
    final r = buildHatariCommand(config(), zip, variant: variant('STE'));
    expect(r.command, isNull);
    expect(r.error, contains('TOS162.IMG'));
  });

  test('Low Res TOS 1.02 variant adds --tos TOS102.IMG', () {
    File('${tmp.path}/TOS102.IMG').createSync();
    final r = buildHatariCommand(
        config(), zip, variant: variant('Low Res TOS 1.02'));
    final i = r.command!.arguments.indexOf('--tos');
    expect(i, greaterThanOrEqualTo(0));
    expect(r.command!.arguments[i + 1], '${tmp.path}/TOS102.IMG');
  });

  test('built-in variants are Standard, Mono, STE, Low Res TOS 1.02', () {
    expect(kHatariVariants.map((v) => v.name).toList(), [
      'Standard',
      'Mono',
      'STE',
      'Low Res TOS 1.02',
    ]);
  });
}
