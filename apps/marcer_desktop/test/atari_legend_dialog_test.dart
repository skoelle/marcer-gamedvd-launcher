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
      reviewCount: 1,
      commentCount: 1,
      magazineCount: 1,
      score: 4.11,
      voteCount: 7,
      publisherCompanyId: 270,
      publisherImgext: 'png',
      developerCompanyId: 163,
      developerImgext: 'png',
    );

    const texts = AtariLegendTexts(
      generatedAt: 'now',
      games: {
        '22': AtariLegendGameTexts(
          reviews: [
            AtariLegendReview(
              id: 67,
              text: '[b]Great[/b] game',
              publishedAt: '2001-11-13 01:00:00',
              graphics: 8,
              sound: 7,
              gameplay: 9,
              overall: 8,
              comments: [
                AtariLegendComment(
                    text: 'Agreed', createdAt: '2020-01-02 00:00:00'),
              ],
            ),
          ],
          comments: [
            AtariLegendComment(
                text: 'Later', createdAt: '2021-01-01 00:00:00'),
          ],
          magazines: [
            AtariLegendMagazineRef(
              magazine: 'ST Magazine',
              issue: '21',
              published: '1988-07-01',
              page: '142',
              score: '6/10',
              type: 'Review',
              archiveUrl: 'https://archive.org/x',
            ),
          ],
        ),
      },
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
                textsLoader: () async => texts,
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

    // Community score far right + publisher/developer logos side by side.
    expect(find.text('4.11'), findsOneWidget);
    expect(find.text('/ 5'), findsOneWidget);
    expect(find.text('7 votes'), findsOneWidget);
    expect(
        find.text(
            'https://www.atarilegend.com/storage/images/company_logos/270.png'),
        findsOneWidget);
    expect(
        find.text(
            'https://www.atarilegend.com/storage/images/company_logos/163.png'),
        findsOneWidget);

    // Images live in the Info tab: both sections simultaneously (no hero).
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
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();
    expect(find.text('Screenshot   2 / 2'), findsNothing);

    // Reviews tab (lazy text cache): scores, BBCode body, external link.
    await tester.tap(find.text('Reviews (1)'));
    await tester.pumpAndSettle();
    expect(find.text('2001-11-13'), findsOneWidget);
    expect(find.text('Graphics 8  ·  Sound 7  ·  Gameplay 9  ·  Overall 8'),
        findsOneWidget);
    expect(
        tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .any((w) => w.textSpan?.toPlainText().contains('Great game') ??
                false),
        isTrue);
    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();
    expect(opened, Uri.parse('https://www.atarilegend.com/reviews/67'));
    opened = null;

    // Magazines tab: entry + archive.org link.
    await tester.tap(find.text('Magazines (1)'));
    await tester.pumpAndSettle();
    expect(find.text('ST Magazine #21 (Review)'), findsOneWidget);
    expect(find.text('1988-07-01  ·  p142  ·  6/10'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu_book_outlined));
    await tester.pumpAndSettle();
    expect(opened, Uri.parse('https://archive.org/x'));
    opened = null;

    // Comments tab.
    await tester.tap(find.text('Comments (1)'));
    await tester.pumpAndSettle();
    expect(find.text('2021-01-01'), findsOneWidget);
    expect(
        tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .any((w) => w.textSpan?.toPlainText() == 'Later'),
        isTrue);

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

  testWidgets('developers/authors use an aligned 3-column grid',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const game = AtariLegendGame(
      id: 1,
      name: 'Many Credits',
      slug: 'many-credits',
      developerCredits: [
        AtariLegendCredit(name: 'Dev 1', role: 'Arcade'),
        AtariLegendCredit(name: 'Dev 2', role: 'Game Conversion'),
        AtariLegendCredit(name: 'Dev 3'),
        AtariLegendCredit(name: 'Dev 4'),
      ],
      authorCredits: [
        AtariLegendCredit(name: 'Author 1', role: 'Music'),
        AtariLegendCredit(name: 'Author 2', role: 'Programming'),
        AtariLegendCredit(name: 'Author 3', role: 'Graphics'),
        AtariLegendCredit(name: 'Author 4', role: 'Game Design'),
        AtariLegendCredit(name: 'Author 5', role: 'Documentation'),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showAtariLegendDialog(context, game: game),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    for (var i = 1; i <= 4; i++) {
      expect(find.text('Dev $i'), findsOneWidget);
    }
    for (var i = 1; i <= 5; i++) {
      expect(find.text('Author $i'), findsOneWidget);
    }

    // Three per row: 1-3 and 4-5 wrap to the next row.
    final a1 = tester.getTopLeft(find.text('Author 1')).dy;
    final a2 = tester.getTopLeft(find.text('Author 2')).dy;
    final a3 = tester.getTopLeft(find.text('Author 3')).dy;
    final a4 = tester.getTopLeft(find.text('Author 4')).dy;
    expect(a1, a2);
    expect(a2, a3);
    expect(a4, greaterThan(a1));
  });
}
