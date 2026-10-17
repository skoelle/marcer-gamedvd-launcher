// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/tos_rom.dart';
import 'package:marcer_desktop/widgets/tos_rom_dialog.dart';
import 'package:path/path.dart' as p;

class _FakeTosRomDownloader implements TosRomDownloader {
  @override
  Future<void> download(
    TosRomOption option,
    String targetDir, {
    TosRomProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    onProgress?.call('Downloading…', 0, 0);
    Directory(targetDir).createSync(recursive: true);
    File(p.join(targetDir, kTosImageFileName))
        .writeAsBytesSync(List<int>.filled(8, 0xAB));
  }
}

Future<bool?> _openDialog(
  WidgetTester tester,
  DesktopConfig config, {
  TosRomDownloader? downloader,
}) async {
  bool? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              result = await showTosRomDialog(context,
                  config: config,
                  downloader: downloader ?? const HttpTosRomDownloader());
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
  testWidgets('shows the default option and all four choices', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final cfg = DesktopConfig(rootDirectory: '/r', appDir: '/tmp/app');
    await _openDialog(tester, cfg);

    expect(find.text('TOS ROM not found'), findsOneWidget);
    // Selected value shown in the dropdown.
    expect(find.text('English (UK) — TOS 1.04'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<TosRomOption>));
    await tester.pumpAndSettle();
    expect(find.text('English (UK) — TOS 1.02'), findsOneWidget);
    expect(find.text('Deutsch — TOS 1.04'), findsOneWidget);
    expect(find.text('Deutsch — TOS 1.02'), findsOneWidget);
  });

  testWidgets('download installs TOS.IMG and closes with true', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('tos_dialog_test');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final cfg = DesktopConfig(rootDirectory: '/r', appDir: dir.path);

    // Kick off the dialog and capture its result.
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showTosRomDialog(context,
                    config: cfg, downloader: _FakeTosRomDownloader());
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(File(p.join(dir.path, 'TOS.IMG')).existsSync(), isTrue);
  });
}
