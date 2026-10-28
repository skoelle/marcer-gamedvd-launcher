// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:marcer_desktop/catalog_controller.dart';
import 'package:marcer_desktop/piratefinder_data.dart';

class _FakePirateFinderData extends PirateFinderDataController {
  _FakePirateFinderData(this.value);

  PirateFinderIndex? value;

  @override
  PirateFinderIndex? get index => value;

  @override
  Future<PirateFinderIndex?> ensureIndex({bool force = false}) async => value;
}

PirateFinderIndex _index() => PirateFinderIndex.fromJson({
  'generated_at': '2026-10-24T12:34:16Z',
  'source': {'tag': 'catalogue-2026-10-19'},
  'disks': [
    {
      'id': 1,
      'kind': 'single',
      'title': 'Arkanoid (1987)(Imagine)[cr Cobra]',
      'label': 'Arkanoid [cr Cobra]',
      'publisher': 'Imagine',
      'cracker': 'Cobra',
      'crew': 'Replicants',
      'year': 1987,
    },
  ],
  'contents': [],
  'images': [],
});

GameCard _card({String name = 'Arkanoid', String folder = 'Arkanoid'}) =>
    GameCard(
      id: 'cracked:$folder',
      name: name,
      kind: 'cracked',
      letter: 'A',
      folder: folder,
      displayStatus: 'done',
      screenshots: false,
      statusCounts: const {},
      layer: 'ROOT',
      year: '1987',
      previewPath: null,
      variants: const [],
      info: null,
      yearNum: 1987,
      publishers: const ['Imagine'],
      crews: const ['Replicants'],
      crackers: const ['Cobra'],
      languages: const [],
      raw: null,
      pasti: null,
      boxscan: null,
      tos: false,
      publisherSort: 'Imagine',
      crewSort: 'Replicants',
      crackerSort: 'Cobra',
      languageSort: '',
      searchText: name.toLowerCase(),
      sortName: name.toLowerCase(),
    );

void main() {
  test('title match waits for the index and is cached', () {
    final data = _FakePirateFinderData(null);
    final controller = CatalogController(DesktopConfig(rootDirectory: ''));
    controller.pirateFinderData = data;
    final card = _card();

    expect(controller.pirateFinderTitleMatchForCard(card), isNull);

    data.value = _index();
    final match = controller.pirateFinderTitleMatchForCard(card);

    expect(match, isNotNull);
    expect(match!.method, 'title');
    expect(controller.pirateFinderTitleMatchForCard(card), same(match));
  });

  test('without the full index the async match stays title-only', () async {
    final data = _FakePirateFinderData(_index());
    final controller = CatalogController(DesktopConfig(rootDirectory: ''));
    controller.pirateFinderData = data;
    final card = _card();

    expect(controller.hasFullIndex, isFalse);
    final match = await controller.pirateFinderMatchForCard(
      card,
      rel: 'A/Arkanoid/Arkanoid.zip',
    );
    expect(match, isNotNull);
    expect(match!.method, 'title');
    expect(match.confidence, 'likely');
  });

  test('no title match yields no button data', () {
    final data = _FakePirateFinderData(_index());
    final controller = CatalogController(DesktopConfig(rootDirectory: ''));
    controller.pirateFinderData = data;

    final card = _card(name: 'Unknown Game', folder: 'Unknown Game');
    expect(controller.pirateFinderTitleMatchForCard(card), isNull);
  });
}
