// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/widgets/status_bar.dart';

/// Controller stub with a fixed status line (a real controller needs a loaded
/// catalog for [CatalogController.statusLine]).
class _StatusController extends CatalogController {
  _StatusController() : super(DesktopConfig(rootDirectory: ''));

  @override
  String get countText => '0 results';

  @override
  List<String> get statusLine => const [];
}

Widget _subject(CatalogController controller, {String? version}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: 160,
          child: StatusBar(controller: controller, version: version),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('keeps the version visible and truncates the status text', (
    tester,
  ) async {
    final controller = _StatusController();
    addTearDown(controller.dispose);
    final longNotice = 'favorites save failed: ${'x' * 300}';
    controller.notices.add(longNotice);

    await tester.pumpWidget(_subject(controller, version: '0.6.6'));

    expect(find.text('v0.6.6'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // The full (truncated) status line stays available as a tooltip.
    expect(find.byTooltip('0 results  |  $longNotice'), findsOneWidget);
  });

  testWidgets('status text is exposed as a tooltip without a version', (
    tester,
  ) async {
    final controller = _StatusController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_subject(controller));

    expect(find.byTooltip('0 results'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
