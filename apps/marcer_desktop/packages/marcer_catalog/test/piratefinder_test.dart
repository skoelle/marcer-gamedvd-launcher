// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

PirateFinderIndex _index() => PirateFinderIndex.fromJson({
  'generated_at': '2026-10-24T12:34:16Z',
  'source': {'tag': 'catalogue-2026-10-19'},
  'sources': [
    {
      'id': 'atari-legend',
      'name': 'Atari Legend',
      'url': 'https://atarilegend.com',
      'licence': 'CC BY-NC-SA 4.0',
      'records': 10,
    },
  ],
  'series': [
    {
      'id': 'automation',
      'name': 'Automation',
      'platform': 'atari-st',
      'kind': 'menu',
      'group_name': 'Automation',
      'aliases': ['auto'],
    },
  ],
  'crews': [
    {
      'id': 1,
      'name': 'Replicants',
      'platform': 'atari-st',
      'members': 'Orion, Snake',
      'founded': '1988',
      'notes': 'A crew',
      'disk_count': 1,
    },
  ],
  'disks': [
    {
      'id': 1,
      'series_id': null,
      'kind': 'single',
      'title': 'Arkanoid (1987)(Imagine)[cr Cobra]',
      'label': 'Arkanoid [cr Cobra]',
      'publisher': 'Imagine',
      'cracker': 'Cobra',
      'crew': 'Replicants',
      'crew_id': 1,
      'year': 1987,
    },
    {
      'id': 2,
      'series_id': null,
      'kind': 'single',
      'title': 'Arkanoid (1987)(Imagine)[cr Klapauzius]',
      'label': 'Arkanoid [cr Klapauzius]',
      'publisher': 'Imagine',
      'cracker': 'Klapauzius',
      'crew': 'Klapauzius',
      'year': 1987,
    },
    {
      'id': 3,
      'series_id': 'automation',
      'kind': 'menu',
      'number': 250,
      'label': 'Automation 250',
      'title': 'Automation 250',
      'crew': 'Automation',
      'year': 1990,
    },
    {
      'id': 4,
      'kind': 'menu',
      'label': 'Replicants Menu 1',
      'title': 'Replicants Menu 1',
      'crew': 'Replicants',
      'crew_id': 1,
      'year': 1991,
    },
    {
      'id': 5,
      'kind': 'single',
      'label': 'Arkanoid [cr Replicants]',
      'crew': 'Replicants',
      'year': 1986,
    },
  ],
  'contents': [
    {
      'id': 10,
      'disk_id': 1,
      'position': 1,
      'title': 'Arkanoid',
      'kind': 'game',
    },
    {
      'id': 11,
      'disk_id': 3,
      'position': 1,
      'title': 'Arkanoid',
      'kind': 'game',
    },
  ],
  'images': [
    {
      'id': 100,
      'disk_id': 1,
      'name': 'Arkanoid.st',
      'format': 'st',
      'size': 737280,
      'sha1': 'abc',
      'md5': 'def',
      'sha512': 'ghi',
      'crc32': '12345678',
      'bad': false,
      'rank': 1,
    },
  ],
  'trivia': [
    {
      'id': 900,
      'disk_id': 1,
      'kind': 'fact',
      'text': 'A fact',
      'source': 'atari-legend',
      'licence': 'CC BY-NC-SA 4.0',
    },
    {
      'id': 901,
      'disk_id': 3,
      'content_id': 11,
      'kind': 'fact',
      'text': 'Cheat: type XYZ',
      'source': 'atari-legend',
      'url': 'https://atarilegend.com/games/arkanoid',
      'licence': 'CC BY-NC-SA 4.0',
    },
    {
      'id': 902,
      'disk_id': 3,
      'content_id': 11,
      'kind': 'fact',
      'text': 'Cheat: type XYZ',
      'source': 'atari-legend',
      'url': 'https://atarilegend.com/games/arkanoid',
      'licence': 'CC BY-NC-SA 4.0',
    },
    {
      'id': 903,
      'disk_id': 3,
      'kind': 'wikipedia',
      'content_id': 11,
      'text': 'Arkanoid',
      'source': 'wikipedia',
      'url': 'https://en.wikipedia.org/wiki/Arkanoid',
      'licence': 'CC BY-SA 4.0',
    },
  ],
  'links': [
    {
      'disk_id': 1,
      'label': 'Atari Legend',
      'url': 'https://atarilegend.com/games/x',
    },
  ],
});

void main() {
  test('hash match returns the exact disk', () {
    final match = _index().matchByHashes([
      {'sha1': 'abc', 'size': 737280, 'crc32': '12345678'},
    ]);
    expect(match, isNotNull);
    expect(match!.disk.id, 1);
    expect(match.confidence, 'exact');
    expect(match.method, 'hash');
  });

  test('title match uses cracker labels and candidates', () {
    final index = _index();
    final ambiguous = index.matchByTitles(['Arkanoid']);
    expect(ambiguous!.candidates.length, 2);

    final cobra = index.matchByTitles(['Arkanoid'], labels: {'cobra'});
    expect(cobra!.disk.id, 1);
    expect(cobra.confidence, 'likely');
  });

  test('crew, contents, appearances, trivia and links', () {
    final index = _index();
    final disk = index.disk(1)!;
    expect(index.crewForDisk(disk)!.name, 'Replicants');
    expect(index.contentsForDisk(1).single.title, 'Arkanoid');
    expect(index.appearancesForDisk(disk).single.label, 'Automation 250');
    expect(index.triviaForDisk(1).single.text, 'A fact');
    expect(index.linksForDisk(1).single.label, 'Atari Legend');
    expect(index.seriesForDisk(index.disk(3)!)!.name, 'Automation');
    expect(index.sourceTag, 'catalogue-2026-10-19');
  });

  test('factsForDisk finds menu facts for the disk titles only', () {
    final index = _index();
    final facts = index.factsForDisk(index.disk(1)!);
    // The menu fact for content 11 (Arkanoid) is found once (duplicate merged);
    // the Wikipedia stub is excluded.
    expect(facts.length, 1);
    expect(facts.single.trivia.text, 'Cheat: type XYZ');
    expect(facts.single.menu.label, 'Automation 250');
    // A disk without menu appearances has no facts.
    expect(index.factsForDisk(index.disk(3)!), isEmpty);
  });

  test('crewByName matches names case/punct-insensitively', () {
    final index = _index();
    expect(index.crewByName('replicants')!.name, 'Replicants');
    expect(index.crewByName('REPLICANTS')!.id, 1);
    expect(index.crewByName('nonexistent'), isNull);
    expect(index.crewByName(''), isNull);
  });

  test('disksForCrew collects credited singles and menus', () {
    final index = _index();
    final crew = index.crewByName('Replicants')!;
    final disks = index.disksForCrew(crew);
    expect(disks.map((disk) => disk.id), [5, 1, 4]);
    expect(disks.where((disk) => disk.kind == 'single').length, 2);
    expect(disks.where((disk) => disk.kind != 'single').length, 1);
  });

  test('title key and label normalization', () {
    expect(
      PirateFinderIndex.titleKey('The Chaos Engine, The (Europe)'),
      'chaos engine',
    );
    expect(PirateFinderIndex.titleKey('Xenon II v1.2'), 'xenon 2');
    expect(PirateFinderIndex.normalizeLabel('The Medway Boys'), 'medway boys');
    expect(
      PirateFinderIndex.normalizeLabel('MCA & Hotline'),
      'mca and hotline',
    );
  });
}
