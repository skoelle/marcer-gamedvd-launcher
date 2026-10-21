// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:test/test.dart';

const String _sql = r'''
CREATE TABLE `games` (
  `id` int(11) NOT NULL,
  `name` varchar(255) DEFAULT NULL,
  `slug` varchar(255) NOT NULL
) ENGINE=InnoDB;

INSERT INTO `games` VALUES
(22,'Buggy Boy','buggy-boy'),
(1,'Gods','gods'),
(3,'O''Brien\'s Quest','obrien');

CREATE TABLE `game_releases` (
  `id` int(11) NOT NULL,
  `game_id` int(11) NOT NULL,
  `date` date DEFAULT NULL,
  `company_id` int(11) DEFAULT NULL
) ENGINE=InnoDB;

INSERT INTO `game_releases` VALUES
(1,22,'1987-01-01',270),
(2,22,'1988-05-01',1367),
(3,1,'1991-01-01',5),
(4,1,'1990-01-01',6),
(5,1,NULL,NULL);

CREATE TABLE `companies` (
  `id` int(11) NOT NULL,
  `name` varchar(255) DEFAULT NULL
) ENGINE=InnoDB;

INSERT INTO `companies` VALUES
(270,'Elite'),(1367,'Encore'),(1070,'Tatsumi'),(5,'X'),(6,'Y');

CREATE TABLE `genres` (
  `id` int(11) NOT NULL,
  `name` varchar(255) DEFAULT NULL
) ENGINE=InnoDB;

INSERT INTO `genres` VALUES
(11,'Simulation'),(14,'Driving');

CREATE TABLE `game_genre` (
  `game_id` int(11) NOT NULL,
  `genre_id` int(11) NOT NULL
) ENGINE=InnoDB;

INSERT INTO `game_genre` VALUES
(22,11),(22,14),(1,11);

CREATE TABLE `game_developer` (
  `company_id` int(11) DEFAULT NULL,
  `game_id` int(11) DEFAULT NULL,
  `developer_role_id` int(11) DEFAULT NULL
) ENGINE=InnoDB;

INSERT INTO `game_developer` VALUES
(270,22,NULL),(1070,22,NULL);

CREATE TABLE `individuals` (
  `id` int(11) NOT NULL,
  `name` varchar(255) DEFAULT NULL
) ENGINE=InnoDB;

INSERT INTO `individuals` VALUES
(243,'Jas C Brooke'),(3280,'Martin W. Ward');

CREATE TABLE `game_individual` (
  `id` int(11) NOT NULL,
  `game_id` int(11) DEFAULT NULL,
  `individual_id` int(11) DEFAULT NULL,
  `individual_role_id` int(11) DEFAULT NULL
) ENGINE=InnoDB;

INSERT INTO `game_individual` VALUES
(1,22,243,2),(2,22,3280,1);
''';

void main() {
  group('iterInsertRows', () {
    test('unescapes quotes, backslashes, newlines and NULL', () {
      final rows = iterInsertRows(
              r"INSERT INTO `t` VALUES (1,'a''b','x\\y','line\nbreak',NULL);",
              't')
          .toList();
      expect(rows, hasLength(1));
      expect(rows.single, ['1', "a'b", r'x\y', 'line\nbreak', null]);
    });

    test('parses multiple rows and statements', () {
      const sql = "INSERT INTO `t` VALUES (1,'a'),(2,'b');\n"
          "INSERT INTO `t` VALUES (3,'c');";
      final rows = iterInsertRows(sql, 't').toList();
      expect(rows.map((r) => r[0]), ['1', '2', '3']);
    });
  });

  group('newestDumpName', () {
    test('picks the newest date from the listing', () {
      const html = '<a href="2026-09-27.sql.gz">x</a> '
          '<a href="2026-10-11.sql.gz">y</a> '
          '<a href="2026-10-04.sql.gz">z</a> '
          '<a href="2026-10-11-users-ddl.sql.gz">u</a>';
      expect(newestDumpName(html), '2026-10-11.sql.gz');
    });

    test('returns null when no dump is listed', () {
      expect(newestDumpName('<html>nothing</html>'), isNull);
    });
  });

  group('parseAtariLegendCache', () {
    final cache = parseAtariLegendCache(_sql,
        generatedAt: '2026-10-17T00:00:00Z',
        sourceFile: '2026-10-11.sql.gz',
        dumpDate: '2026-10-11');

    test('collects games and sorts them by name', () {
      expect(cache.games.map((g) => g.name),
          ['Buggy Boy', 'Gods', "O'Brien's Quest"]);
      expect(cache.dumpDate, '2026-10-11');
    });

    test('uses the earliest release year and primary publisher', () {
      final buggy = cache.games.firstWhere((g) => g.id == 22);
      expect(buggy.year, 1987);
      expect(buggy.publisher, 'Elite');
      expect(buggy.genres, ['Simulation', 'Driving']);
      expect(buggy.developers, ['Elite', 'Tatsumi']);
      expect(buggy.authors, ['Jas C Brooke', 'Martin W. Ward']);
    });

    test('ignores undated/null releases for year/publisher', () {
      final gods = cache.games.firstWhere((g) => g.id == 1);
      expect(gods.year, 1990);
      expect(gods.publisher, 'Y');
    });

    test('handles SQL-escaped titles', () {
      final obrien = cache.games.firstWhere((g) => g.slug == 'obrien');
      expect(obrien.name, "O'Brien's Quest");
    });

    test('round-trips through JSON', () {
      final restored = AtariLegendCache.fromJson(cache.toJson());
      expect(restored.games, hasLength(cache.games.length));
      final buggy = restored.games.firstWhere((g) => g.id == 22);
      expect(buggy.year, 1987);
      expect(buggy.genres, ['Simulation', 'Driving']);
    });
  });
}
