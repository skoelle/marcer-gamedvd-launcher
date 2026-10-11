import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/hatari_launcher.dart';

void main() {
  test('launchHatari runs a real (fake) executable', () async {
    final tmp = Directory.systemTemp.createTempSync('launch_e2e');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final fake = File('${tmp.path}/hatari')
      ..writeAsStringSync(
          '#!/bin/sh\nprintf "%s\\n" "\$@" > "${tmp.path}/args.txt"\n');
    Process.runSync('chmod', ['+x', fake.path]);
    final zip = File('${tmp.path}/Game.zip')..writeAsStringSync('z');
    File('${tmp.path}/MarcerGameDvd-Hatari.cfg').writeAsStringSync('cfg');

    final cfg = DesktopConfig(
      rootDirectory: tmp.path,
      appDir: tmp.path,
      hatariExecutable: 'hatari',
    );
    final res = await launchHatari(cfg, zip.path);
    expect(res.error, isNull, reason: res.error);
    final code = await res.process!.exitCode;
    expect(code, 0);
    final args = File('${tmp.path}/args.txt').readAsStringSync().split('\n');
    expect(args, contains('-c'));
    expect(args, contains('${tmp.path}/MarcerGameDvd-Hatari.cfg'));
    expect(args, contains('--disk-a'));
    expect(args, contains(zip.path));
  });
}