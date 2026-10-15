// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';

/// Status bar counts (user decision 2026-10-15): every status segment shows
/// games (cards) plus their ZIP entries — `done 2 (2 zips)` — so the games
/// number equals the dropdown result count for that status.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CatalogController c;

  const crackedTree = 'Title Sorted/Cracked Games - Title Sorted';
  const relAlpha = '$crackedTree/A/Alpha/a.zip';
  const relAlphaV2 = '$crackedTree/A/Alpha/a_v2.zip';
  const relBeta = '$crackedTree/B/Beta/beta.zip';
  const relGamma = '$crackedTree/C/Gamma/gamma.zip';
  const relGamma2 = '$crackedTree/C/Gamma/gamma2.zip';
  const relDelta = '$crackedTree/D/Delta/delta.zip';
  const relEpsilon = '$crackedTree/E/Epsilon/epsilon.zip';

  Map<String, dynamic> entry(String rel, String status,
          {String? preview}) =>
      {
        'rel': rel,
        'name': rel.split('/').last,
        'status': status,
        'kind': status == 'error' ? null : (status == 'done' ? 'game' : null),
        'layer': 'ROOT',
        'preview': preview,
        'candidates': <String>[],
      };

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('status_line_test');
    for (final rel in [
      relAlpha,
      relAlphaV2,
      relBeta,
      relGamma,
      relGamma2,
      relDelta,
      relEpsilon,
    ]) {
      final file = File('${tmp.path}/root/$rel');
      file.parent.createSync(recursive: true);
      file.createSync();
    }
    Directory('${tmp.path}/patch/Title Sorted').createSync(recursive: true);
    Directory('${tmp.path}/data').createSync(recursive: true);
    Directory('${tmp.path}/out').createSync(recursive: true);
    File('${tmp.path}/out/index.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'entries': {
        relAlpha: entry(relAlpha, 'done', preview: 'a.png'),
        relAlphaV2: entry(relAlphaV2, 'pending'),
        relBeta: entry(relBeta, 'desktop', preview: 'beta.png'),
        relGamma: entry(relGamma, 'pending'),
        relGamma2: entry(relGamma2, 'pending'),
        relDelta: entry(relDelta, 'done', preview: 'delta.png'),
        relEpsilon: entry(relEpsilon, 'error'),
      },
    }));
    File('${tmp.path}/data/games-pd.json').writeAsStringSync(jsonEncode({
      'games': [
        {
          'letter': 'P',
          'folder': 'PacMan',
          'layers': ['ROOT'],
          'matched_via': 'folder',
          'matched_title': 'Pac-Man',
          'variants': [
            {'title': 'Pac-Man'}
          ],
        },
      ],
    }));
    File('${tmp.path}/data/manifest.json').writeAsStringSync(jsonEncode({
      'generated_at': '2026-10-15',
      'sources': [
        {'kind': 'cracked', 'matched_folders': 4},
      ],
    }));
    c = CatalogController(DesktopConfig(
      rootDirectory: '${tmp.path}/root',
      patchDirectory: '${tmp.path}/patch',
      outDirectory: '${tmp.path}/out',
      dataDirectory: '${tmp.path}/data',
    ));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test(
      'status segments show games plus ZIPs; coverage counts games only',
      () async {
    await c.init();
    // Cards: Alpha (done+pending → done, preview), Beta (desktop, preview),
    // Gamma (pending×2), Delta (done, preview), Epsilon (error → aggregate
    // pending, no pending ZIP).
    expect(c.statusLine, contains('3 / 5 with screenshot'));
    expect(c.statusLine, contains('done 2 (2 zips)'));
    expect(c.statusLine, contains('desktop 1 (1 zips)'));
    expect(c.statusLine, contains('pending 2 (3 zips)'),
        reason: 'games = any-pending-ZIP cards (Alpha, Gamma); '
            'zips = index pending entries (a_v2, gamma, gamma2)');
    expect(c.statusLine, contains('info 4 folders'));
    expect(c.statusLine, isNot(contains(contains('skipped_disk_n'))));
    expect(c.statusLine, isNot(contains(contains('no_usable_shots'))));
    expect(c.statusLine, isNot(contains(contains('interrupted'))));
  });

  test('status segment games equal the dropdown result counts', () async {
    await c.init();

    c.setStatus('done');
    expect(c.countText, '2 results');
    expect(c.statusLine, contains('done 2 (2 zips)'));

    // App pending rule: a pending ZIP inside a mostly-done folder counts.
    c.setStatus('pending');
    expect(c.countText, '2 results');
    expect(c.statusLine, contains('pending 2 (3 zips)'));

    c.setStatus('desktop');
    expect(c.countText, '1 results');
    expect(c.statusLine, contains('desktop 1 (1 zips)'));

    // Default status: screenshot cards == coverage numerator.
    c.resetFilters();
    expect(c.countText, '3 results');
    expect(c.statusLine, contains('3 / 5 with screenshot'));
  });
}
