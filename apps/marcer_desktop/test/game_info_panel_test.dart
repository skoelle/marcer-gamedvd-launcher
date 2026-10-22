// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/widgets/game_info_panel.dart';

void main() {
  _atariLegendTests();

  testWidgets('play split button lists variants and reports the selection',
      (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    HatariVariant? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: GameInfoPanel(
            info: null,
            variant: const ZipVariantView(
              name: 'a.zip',
              status: 'done',
              layer: 'ROOT',
              rel: 'x/a.zip',
            ),
            variants: kHatariVariants,
            onPlay: () {},
            onPlayVariant: (v) => selected = v,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('PLAY'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    for (final v in kHatariVariants) {
      expect(find.text(v.name), findsWidgets, reason: v.name);
    }

    await tester.tap(find.text('Mono').last);
    await tester.pumpAndSettle();
    expect(selected?.name, 'Mono');
  });
  testWidgets('shows This ZIP before Release variants', (tester) async {
    final info = InfoSummary.fromGame(GameInfo(
      folder: 'Alpha',
      letter: 'A',
      layers: const ['ROOT'],
      matchedVia: 'exact',
      matchedTitle: 'Alpha',
      variants: const [
        {'title': 'Alpha v1'},
        {'title': 'Alpha v2'},
      ],
      kind: 'cracked',
    ));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          height: 800,
          child: GameInfoPanel(
            info: info,
            variant: const ZipVariantView(
              name: 'a.zip',
              status: 'done',
              layer: 'ROOT',
              rel: 'x/a.zip',
            ),
            variants: kHatariVariants,
            onPlay: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final thisZip = tester.getTopLeft(find.text('This ZIP'));
    final release = tester.getTopLeft(find.text('Release variants (2)'));
    expect(thisZip.dy, lessThan(release.dy));
  });

  testWidgets('no game info leaves a gap between AtariLegend and PLAY',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: GameInfoPanel(
            info: null,
            atariLegend:
                const AtariLegendGame(id: 22, name: 'Omega', slug: 'omega'),
            onAtariLegend: () {},
            variant: const ZipVariantView(
              name: 'omega.zip',
              status: 'done',
              layer: 'ROOT',
              rel: 'x/omega.zip',
            ),
            variants: kHatariVariants,
            onPlay: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final atariLegend = tester.getRect(find.text('AtariLegend'));
    final play = tester.getRect(find.text('PLAY'));
    expect(play.top - atariLegend.bottom, greaterThanOrEqualTo(16));
  });
}

void _atariLegendTests() {
  testWidgets('AtariLegend button shown for a match (also without game info)',
      (tester) async {
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: GameInfoPanel(
            info: null,
            atariLegend: const AtariLegendGame(
                id: 22, name: 'Buggy Boy', slug: 'buggy-boy'),
            onAtariLegend: () => tapped++,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('No game info'), findsOneWidget);
    expect(find.text('AtariLegend'), findsOneWidget);
    await tester.tap(find.text('AtariLegend'));
    expect(tapped, 1);
  });

  testWidgets('no AtariLegend button without a match', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 420,
          child: GameInfoPanel(info: null),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('AtariLegend'), findsNothing);
  });
}
