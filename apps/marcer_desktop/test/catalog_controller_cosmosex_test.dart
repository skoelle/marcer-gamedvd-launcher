// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/cosmos_ex.dart';

class _FakeUploader implements CosmosExUploader {
  _FakeUploader({this.fail = false});

  final bool fail;
  String? lastZip;
  CosmosExProgress? progress;

  @override
  Future<CosmosExSendResult> send({
    required DesktopConfig config,
    required String zipPath,
    CosmosExProgress? onProgress,
  }) async {
    lastZip = zipPath;
    progress = onProgress;
    onProgress?.call('Uploading…');
    if (fail) throw const CosmosExException('boom');
    return const CosmosExSendResult(
      mode: 'legacy',
      message: 'Sent game.zip to CosmosEx (slot 1).',
    );
  }
}

void main() {
  test(
    'sendZipToCosmosEx sets progress, notice and resets the busy state',
    () async {
      final controller = CatalogController(
        DesktopConfig(rootDirectory: '/r', cosmosExHost: 'cosmosex.local'),
      );
      addTearDown(controller.dispose);
      final uploader = _FakeUploader();
      controller.cosmosExUploader = uploader;

      final future = controller.sendZipToCosmosEx('/games/a.zip');
      expect(controller.cosmosExSending, isTrue);
      await future;

      expect(uploader.lastZip, '/games/a.zip');
      expect(controller.cosmosExSending, isFalse);
      expect(controller.cosmosExProgress, '');
      expect(controller.cosmosExError, isNull);
      expect(controller.cosmosExNotice, contains('Sent game.zip'));

      controller.clearCosmosExNotice();
      expect(controller.cosmosExNotice, isNull);
    },
  );

  test('sendZipToCosmosEx surfaces a CosmosExException message', () async {
    final controller = CatalogController(
      DesktopConfig(rootDirectory: '/r', cosmosExHost: 'cosmosex.local'),
    );
    addTearDown(controller.dispose);
    controller.cosmosExUploader = _FakeUploader(fail: true);

    await controller.sendZipToCosmosEx('/games/a.zip');

    expect(controller.cosmosExSending, isFalse);
    expect(controller.cosmosExError, 'boom');
    expect(controller.cosmosExNotice, isNull);

    controller.clearCosmosExError();
    expect(controller.cosmosExError, isNull);
  });
}
