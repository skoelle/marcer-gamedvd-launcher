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
      authors: ['Jas C Brooke', 'Martin W. Ward'],
      conversion: 'Arcade',
      developerCredits: [
        AtariLegendCredit(name: 'Taito', role: 'Arcade'),
        AtariLegendCredit(name: 'Tatsumi', role: 'Game Conversion'),
      ],
      authorCredits: [
        AtariLegendCredit(name: 'Jas C Brooke', role: 'Music'),
        AtariLegendCredit(name: 'Martin W. Ward', role: 'Programming'),
      ],
      screenshots: [
        AtariLegendImage(id: 24, imgext: 'png'),
        AtariLegendImage(id: 25, imgext: 'png'),
      ],
      boxscans: [
        AtariLegendBoxscan(
            id: 34, releaseId: 22, type: 'Box front', imgext: 'jpg'),
        AtariLegendBoxscan(
            id: 35, releaseId: 22, type: 'Box back', imgext: 'jpg'),
      ],
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
                imageBuilder: (context, url,
                        {int? cacheWidth, BoxFit? fit}) =>
                    Text(url),
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
    expect(find.text('Conversion'), findsOneWidget);
    // Arcade appears twice: the conversion value and Taito's role.
    expect(find.text('Arcade'), findsNWidgets(2));
    expect(find.text('Taito'), findsOneWidget);
    expect(find.text('Tatsumi'), findsOneWidget);
    expect(find.text('Game Conversion'), findsOneWidget);
    expect(find.text('Jas C Brooke'), findsOneWidget);
    expect(find.text('Martin W. Ward'), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Programming'), findsOneWidget);

    // Both image sections are visible simultaneously (no hero image).
    expect(find.text('Boxscans (2)'), findsOneWidget);
    expect(find.text('Screenshots (2)'), findsOneWidget);
    final shotUrl =
        atariLegendScreenshotUrl('buggy-boy', game.screenshots.first);
    expect(find.text(shotUrl), findsOneWidget);

    // Thumbnail click opens the viewer; arrows navigate.
    await tester.ensureVisible(find.text(shotUrl));
    await tester.tap(find.text(shotUrl));
    await tester.pumpAndSettle();
    expect(find.text('Screenshot   1 / 2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('Screenshot   2 / 2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Screenshot   2 / 2'), findsNothing);

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
