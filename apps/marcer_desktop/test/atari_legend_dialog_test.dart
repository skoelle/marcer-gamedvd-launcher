// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/widgets/atari_legend_dialog.dart';

void main() {
  testWidgets('shows the cached metadata and opens the game page',
      (tester) async {
    Uri? opened;
    const game = AtariLegendGame(
      id: 22,
      name: 'Buggy Boy',
      slug: 'buggy-boy',
      year: 1987,
      publisher: 'Elite',
      genres: ['Simulation', 'Driving'],
      developers: ['Taito', 'Tatsumi'],
      authors: ['Jas C Brooke'],
    );

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showAtariLegendDialog(
                context,
                game: game,
                launcher: (uri) async {
                  opened = uri;
                  return true;
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('AtariLegend'), findsOneWidget);
    expect(find.text('Buggy Boy (1987)'), findsOneWidget);
    expect(find.text('Elite'), findsOneWidget);
    expect(find.text('Simulation, Driving'), findsOneWidget);
    expect(find.text('Taito, Tatsumi'), findsOneWidget);
    expect(find.text('Jas C Brooke'), findsOneWidget);

    await tester.tap(find.text('Open on atarilegend.com'));
    await tester.pumpAndSettle();
    expect(opened, Uri.parse('https://www.atarilegend.com/games/buggy-boy'));
  });

  testWidgets('hides the browser button when the slug is empty',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showAtariLegendDialog(
                context,
                game: const AtariLegendGame(id: 1, name: 'X', slug: ''),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('AtariLegend'), findsOneWidget);
    expect(find.text('Open on atarilegend.com'), findsNothing);
  });
}
