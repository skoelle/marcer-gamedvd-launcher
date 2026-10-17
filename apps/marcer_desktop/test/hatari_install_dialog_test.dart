// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/hatari_installer.dart';
import 'package:marcer_desktop/widgets/hatari_install_dialog.dart';
import 'package:path/path.dart' as p;

class _FakeHatariDownloader implements HatariDownloader {
  bool cancelled = false;

  @override
  Future<String> download(
    HatariBuild build,
    String installDir, {
    HatariInstallProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    onProgress?.call('Downloading…', 0, 0);
    Directory(installDir).createSync(recursive: true);
    final exe = File(p.join(installDir, 'hatari.exe'))
      ..writeAsBytesSync(List<int>.filled(8, 0x7F));
    return exe.path;
  }
}

const _testBuild =
    HatariBuild(os: 'test', label: 'Test (x64)', url: 'https://example.test/h.zip');

Future<String?> _openDialog(
  WidgetTester tester,
  DesktopConfig config, {
  required HatariDownloader downloader,
  HatariBuild? build,
}) async {
  String? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              result = await showHatariInstallDialog(context,
                  config: config, downloader: downloader, build: build);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('install downloads and closes with the executable path',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('hatari_dialog_test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final cfg = DesktopConfig(rootDirectory: '/r', appDir: dir.path);

    final downloader = _FakeHatariDownloader();
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showHatariInstallDialog(context,
                    config: cfg, downloader: downloader, build: _testBuild);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Hatari not found'), findsOneWidget);
    await tester.tap(find.text('Install Hatari'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(p.basename(result!), 'hatari.exe');
    expect(File(result!).existsSync(), isTrue);
  });

  testWidgets('unsupported platform shows a manual-install hint',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final cfg = DesktopConfig(rootDirectory: '/r', appDir: '/tmp/app');
    await _openDialog(tester, cfg,
        downloader: _FakeHatariDownloader(), build: null);

    // On Linux (test host) no build is offered → manual-install message and no
    // install button. On other hosts a build exists; only assert the title.
    expect(find.text('Hatari not found'), findsOneWidget);
    if (hatariBuildFor() == null) {
      expect(find.text('Install Hatari'), findsNothing);
      expect(find.textContaining('Install Hatari with your system'),
          findsOneWidget);
    }
  });
}
