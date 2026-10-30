// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/widgets/game_info_panel.dart';

void main() {
  _atariLegendTests();

  testWidgets('play split button lists variants and reports the selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    HatariVariant? selected;
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
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
  testWidgets('play dropdown offers Send to CosmosEx', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var sent = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
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
              onPlayVariant: (_) {},
              onSendToCosmosEx: () => sent++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    expect(find.text('Send to CosmosEx'), findsOneWidget);
    await tester.tap(find.text('Send to CosmosEx'));
    await tester.pumpAndSettle();
    expect(sent, 1);
  });

  testWidgets('no CosmosEx action without a configured host', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
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
              onPlayVariant: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    expect(find.text('Send to CosmosEx'), findsNothing);
  });

  testWidgets('shows This ZIP before Release variants', (tester) async {
    final info = InfoSummary.fromGame(
      GameInfo(
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
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.pumpAndSettle();

    final thisZip = tester.getTopLeft(find.text('This ZIP'));
    final release = tester.getTopLeft(find.text('Release variants (2)'));
    expect(thisZip.dy, lessThan(release.dy));
  });

  testWidgets('Cracked by/Crew are release-specific and live in This ZIP', (
    tester,
  ) async {
    final info = InfoSummary.fromGame(
      GameInfo(
        folder: 'F15 Strike Eagle 2',
        letter: 'F',
        layers: const ['ROOT'],
        matchedVia: 'exact',
        matchedTitle: 'F15 Strike Eagle 2',
        variants: const [
          {'title': 'F15 Strike Eagle 2', 'cracked_by': 'Original'},
          {
            'title': 'F15 Strike Eagle 2 v2.07.1991',
            'cracked_by': 'Dr Trap / Empire',
            'crew': 'Elite',
          },
        ],
        kind: 'cracked',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 900,
            child: GameInfoPanel(
              info: info,
              variant: const ZipVariantView(
                name:
                    'F15 Strike Eagle 2 v2.7.91 - Dr Trap - Empire - Elite '
                    '- Disk 1.zip',
                status: 'done',
                layer: 'ROOT',
                rel: 'F/F15/F15 - Dr Trap.zip',
              ),
              onPlay: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cracked by'), findsOneWidget);
    // This ZIP row + Release variants table.
    expect(find.text('Dr Trap / Empire'), findsNWidgets(2));
    expect(find.text('Elite'), findsNWidgets(2));
    // Placeholder labels never reach the UI, not even in the variants table.
    expect(find.text('Original'), findsNothing);
    final gameInfoY = tester.getTopLeft(find.text('Game info')).dy;
    final thisZipY = tester.getTopLeft(find.text('This ZIP')).dy;
    final crackedByY = tester.getTopLeft(find.text('Cracked by')).dy;
    expect(crackedByY, greaterThan(gameInfoY));
    expect(crackedByY, greaterThan(thisZipY));
  });

  testWidgets('ambiguous ZIP shows no Cracked by/Crew rows', (tester) async {
    final info = InfoSummary.fromGame(
      GameInfo(
        folder: 'Alpha',
        letter: 'A',
        layers: const ['ROOT'],
        matchedVia: 'exact',
        matchedTitle: 'Alpha',
        variants: const [
          {'title': 'Alpha', 'cracked_by': 'Original'},
          {'title': 'Alpha', 'cracked_by': 'Dr Trap / Empire', 'crew': 'Elite'},
        ],
        kind: 'cracked',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 900,
            child: GameInfoPanel(
              info: info,
              variant: const ZipVariantView(
                name: 'Alpha.zip',
                status: 'done',
                layer: 'ROOT',
                rel: 'A/Alpha/Alpha.zip',
              ),
              onPlay: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cracked by'), findsNothing);
  });

  testWidgets('release fallback fills missing labels and marks inferred', (
    tester,
  ) async {
    final info = InfoSummary.fromGame(
      GameInfo(
        folder: 'Alpha',
        letter: 'A',
        layers: const ['ROOT'],
        matchedVia: 'exact',
        matchedTitle: 'Alpha',
        variants: const [
          {'title': 'Alpha'},
        ],
        kind: 'cracked',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 800,
            child: GameInfoPanel(
              info: info,
              variant: const ZipVariantView(
                name: 'Alpha - Cameo - Replicants.zip',
                status: 'done',
                layer: 'ROOT',
                rel: 'A/Alpha/Alpha - Cameo - Replicants.zip',
              ),
              releaseFallback: const CrewRelease(
                rel: 'A/Alpha/Alpha - Cameo - Replicants.zip',
                letter: 'A',
                folder: 'Alpha',
                zip: 'Alpha - Cameo - Replicants.zip',
                title: 'Alpha',
                year: '1990',
                publisher: '',
                crackedBy: 'Cameo',
                crew: 'Replicants',
                language: '',
                source: 'alias',
                disks: 1,
                rawDump: false,
                pastiDump: false,
                boxscan: false,
                ambiguous: false,
                tosBad: '',
                specialFlag: '',
                specialNote: '',
                inferredFields: {'crew'},
              ),
              onPlay: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cameo', findRichText: true), findsOneWidget);
    expect(find.text('Crew'), findsOneWidget);
    expect(find.textContaining('inferred', findRichText: true), findsOneWidget);
  });

  testWidgets('no game info leaves a gap between AtariLegend and PLAY', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: GameInfoPanel(
              info: null,
              atariLegend: const AtariLegendGame(
                id: 22,
                name: 'Omega',
                slug: 'omega',
              ),
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
      ),
    );
    await tester.pumpAndSettle();

    final atariLegend = tester.getRect(find.text('AtariLegend'));
    final play = tester.getRect(find.text('PLAY'));
    expect(play.top - atariLegend.bottom, greaterThanOrEqualTo(16));
  });
}

void _atariLegendTests() {
  testWidgets('AtariLegend button shown for a match (also without game info)', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: GameInfoPanel(
              info: null,
              atariLegend: const AtariLegendGame(
                id: 22,
                name: 'Buggy Boy',
                slug: 'buggy-boy',
              ),
              onAtariLegend: () => tapped++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No game info'), findsOneWidget);
    expect(find.text('AtariLegend'), findsOneWidget);
    await tester.tap(find.text('AtariLegend'));
    expect(tapped, 1);
  });

  testWidgets('no AtariLegend button without a match', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 420, child: GameInfoPanel(info: null)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AtariLegend'), findsNothing);
  });
  testWidgets('PF release section shows the summary and opens crew infos', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: GameInfoPanel(
              info: null,
              pirateFinderMatch: _pirateFinderMatch(),
              onPirateFinder: () => tapped++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PirateFinder Crew Releases (2)'), findsOneWidget);
    expect(find.text('Crews'), findsOneWidget);
    expect(find.text('Access · 42-Crew'), findsOneWidget);
    await tester.tap(find.text('Crews'));
    expect(tapped, 1);
  });

  testWidgets('PF release section is hidden without a match', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: GameInfoPanel(info: null, onPirateFinder: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('PirateFinder Crew Releases'), findsNothing);
    expect(find.text('Crews'), findsNothing);
  });
}

PirateFinderMatch _pirateFinderMatch() {
  final index = PirateFinderIndex.fromJson({
    'generated_at': '2026-10-24T12:34:16Z',
    'source': {'tag': 'catalogue-2026-10-19'},
    'disks': [
      {
        'id': 1,
        'kind': 'single',
        'title': '10th Frame (1987)(Access)',
        'label': '10th Frame',
        'publisher': 'Access',
        'crew': 'Access',
        'year': 1987,
      },
      {
        'id': 2,
        'kind': 'single',
        'title': '10th Frame (1987)(Access)[cr 42-Crew]',
        'label': '10th Frame [cr 42-Crew]',
        'publisher': 'Access',
        'cracker': '42-Crew',
        'crew': '42-Crew',
        'year': 1987,
      },
    ],
  });
  return PirateFinderMatch(
    disk: index.disk(1)!,
    candidates: [index.disk(1)!, index.disk(2)!],
    method: 'title',
    confidence: 'likely',
  );
}
