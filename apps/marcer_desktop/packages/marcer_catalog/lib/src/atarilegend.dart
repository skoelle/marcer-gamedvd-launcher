// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

/// AtariLegend runtime cache.
///
/// The desktop app must not ship AtariLegend data (CC BY-NC-SA 4.0). The
/// settings "Download AtariLegend data" action fetches the weekly
/// `YYYY-MM-DD.sql.gz` dump, decompresses it and parses only the tables needed
/// for the first feature step (games + release year/publisher + the
/// developer/author/genre facets), writing a compact `atarilegend.json`.
///
/// See `docs/ANALYSIS-atarilegend.md`.
library;

import 'dart:convert';
import 'dart:io' show gzip;

/// Default cache file name inside the `AtariLegendDirectory`.
const String kAtariLegendFileName = 'atarilegend.json';

/// Cache schema version (bump on incompatible layout changes).
const int kAtariLegendSchemaVersion = 1;

/// One cached AtariLegend game.
class AtariLegendGame {
  const AtariLegendGame({
    required this.id,
    required this.name,
    required this.slug,
    this.year,
    this.publisher = '',
    this.genres = const [],
    this.developers = const [],
    this.authors = const [],
  });

  factory AtariLegendGame.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) =>
        ((json[key] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
    return AtariLegendGame(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      slug: (json['slug'] ?? '').toString(),
      year: (json['year'] as num?)?.toInt(),
      publisher: (json['publisher'] ?? '').toString(),
      genres: strings('genres'),
      developers: strings('developers'),
      authors: strings('authors'),
    );
  }

  final int id;
  final String name;
  final String slug;
  final int? year;
  final String publisher;
  final List<String> genres;
  final List<String> developers;
  final List<String> authors;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'slug': slug,
        if (year != null) 'year': year,
        if (publisher.isNotEmpty) 'publisher': publisher,
        if (genres.isNotEmpty) 'genres': genres,
        if (developers.isNotEmpty) 'developers': developers,
        if (authors.isNotEmpty) 'authors': authors,
      };
}

/// The cached AtariLegend dataset (`atarilegend.json`).
class AtariLegendCache {
  const AtariLegendCache({
    this.schemaVersion = kAtariLegendSchemaVersion,
    required this.generatedAt,
    this.sourceFile = '',
    this.dumpDate = '',
    required this.games,
  });

  factory AtariLegendCache.fromJson(Map<String, dynamic> json) {
    final source = (json['source'] as Map<String, dynamic>?) ?? const {};
    return AtariLegendCache(
      schemaVersion: (json['schema_version'] as num?)?.toInt() ??
          kAtariLegendSchemaVersion,
      generatedAt: (json['generated_at'] ?? '').toString(),
      sourceFile: (source['file'] ?? '').toString(),
      dumpDate: (source['dump_date'] ?? '').toString(),
      games: ((json['games'] as List<dynamic>?) ?? const [])
          .map((e) => AtariLegendGame.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  final int schemaVersion;
  final String generatedAt;
  final String sourceFile;
  final String dumpDate;
  final List<AtariLegendGame> games;

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'generated_at': generatedAt,
        'source': {'file': sourceFile, 'dump_date': dumpDate},
        'games': games.map((g) => g.toJson()).toList(),
      };

  String toJsonString() =>
      '${const JsonEncoder.withIndent(' ').convert(toJson())}\n';
}

// --------------------------------------------------------------------------
// SQL dump parsing (stdlib-free, pure Dart)
// --------------------------------------------------------------------------

const Map<String, String> _unescapeMap = {
  '0': '\u0000',
  'n': '\n',
  'r': '\r',
  't': '\t',
  'Z': '\u001a',
  'b': '\b',
};

bool _isWs(String c) =>
    c == ' ' || c == '\t' || c == '\r' || c == '\n';

(String, int) _parseQuoted(String s, int i) {
  i++; // opening quote
  final out = StringBuffer();
  while (i < s.length) {
    final c = s[i];
    if (c == '\\' && i + 1 < s.length) {
      final n = s[i + 1];
      out.write(_unescapeMap[n] ?? n);
      i += 2;
      continue;
    }
    if (c == "'") {
      if (i + 1 < s.length && s[i + 1] == "'") {
        out.write("'");
        i += 2;
        continue;
      }
      return (out.toString(), i + 1);
    }
    out.write(c);
    i++;
  }
  return (out.toString(), i);
}

(String, int) _parseUnquoted(String s, int i) {
  var depth = 0;
  final start = i;
  while (i < s.length) {
    final c = s[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      if (depth == 0) break;
      depth--;
    } else if (c == ',' && depth == 0) {
      break;
    }
    i++;
  }
  return (s.substring(start, i).trim(), i);
}

/// Yields the value rows of all `INSERT INTO \`table\` VALUES` statements.
///
/// Handles SQL string escaping (`''`, `\'`, `\\`, `\n`, …), `NULL` (returned
/// as `null`) and multi-row/multi-statement inserts.
Iterable<List<String?>> iterInsertRows(String sql, String table) sync* {
  final marker = 'INSERT INTO `$table` VALUES';
  var pos = 0;
  while (true) {
    final start = sql.indexOf(marker, pos);
    if (start < 0) return;
    var i = start + marker.length;
    while (i < sql.length) {
      final c = sql[i];
      if (c == ';') {
        i++;
        break;
      }
      if (_isWs(c) || c == ',') {
        i++;
        continue;
      }
      if (c != '(') {
        i++;
        continue;
      }
      i++;
      final row = <String?>[];
      while (true) {
        while (i < sql.length && _isWs(sql[i])) {
          i++;
        }
        String? value;
        if (i < sql.length && sql[i] == "'") {
          final r = _parseQuoted(sql, i);
          value = r.$1;
          i = r.$2;
        } else {
          final r = _parseUnquoted(sql, i);
          value = r.$1;
          i = r.$2;
          if (value.toUpperCase() == 'NULL') value = null;
        }
        row.add(value);
        while (i < sql.length && _isWs(sql[i])) {
          i++;
        }
        if (i < sql.length && sql[i] == ',') {
          i++;
          continue;
        }
        if (i < sql.length && sql[i] == ')') {
          i++;
          break;
        }
        break;
      }
      yield row;
    }
    pos = i;
  }
}

/// Column names of `table` from its line-start `CREATE TABLE` statement.
///
/// Anchoring on a leading newline ignores the historical DDL embedded as text
/// inside the `database_changes` table.
List<String> _columnsOf(String sql, String table) {
  final marker = 'CREATE TABLE `$table` (';
  var start = sql.indexOf('\n$marker');
  if (start < 0) {
    start = sql.startsWith(marker) ? 0 : -1;
  }
  if (start < 0) return const [];
  final end = sql.indexOf('\n) ENGINE=', start);
  if (end < 0) return const [];
  final body = sql.substring(start, end);
  final cols = <String>[];
  for (final line in body.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('`')) continue;
    final close = t.indexOf('`', 1);
    if (close > 0) cols.add(t.substring(1, close));
  }
  return cols;
}

List<Map<String, String?>> _rows(String sql, String table) {
  final cols = _columnsOf(sql, table);
  if (cols.isEmpty) return const [];
  final out = <Map<String, String?>>[];
  for (final r in iterInsertRows(sql, table)) {
    final m = <String, String?>{};
    for (var i = 0; i < cols.length; i++) {
      m[cols[i]] = i < r.length ? r[i] : null;
    }
    out.add(m);
  }
  return out;
}

int? _int(String? v) => v == null ? null : int.tryParse(v);

List<String> _uniqStrings(Iterable<String?> values) {
  final out = <String>[];
  for (final v in values) {
    if (v == null || v.isEmpty) continue;
    if (!out.contains(v)) out.add(v);
  }
  return out;
}

/// Decompresses the downloaded dump bytes (gzip) into the SQL text.
String decodeAtariLegendDump(List<int> gzBytes) =>
    utf8.decode(gzip.decode(gzBytes), allowMalformed: true);

/// Newest `YYYY-MM-DD.sql.gz` file name advertised by the directory listing,
/// or `null` when none is found.
String? newestDumpName(String listingHtml) {
  final re = RegExp(r'(\d{4}-\d{2}-\d{2})\.sql\.gz');
  String? newest;
  for (final m in re.allMatches(listingHtml)) {
    final date = m.group(1)!;
    if (newest == null || date.compareTo(newest) > 0) newest = date;
  }
  return newest == null ? null : '$newest.sql.gz';
}

/// Parses the needed tables and assembles the compact cache.
///
/// Games come from `games`; the year is the earliest release year, the
/// publisher the company of the primary (earliest dated) release. Genres,
/// developers and authors are the facet fields later used by the filters.
AtariLegendCache parseAtariLegendCache(
  String sql, {
  String generatedAt = '',
  String sourceFile = '',
  String dumpDate = '',
}) {
  final games = _rows(sql, 'games');
  final releases = _rows(sql, 'game_releases');
  final companies = {for (final r in _rows(sql, 'companies')) r['id']: r['name']};
  final genres = {for (final r in _rows(sql, 'genres')) r['id']: r['name']};
  final individuals = {
    for (final r in _rows(sql, 'individuals')) r['id']: r['name']
  };

  final gameGenres = <String, List<String>>{};
  for (final r in _rows(sql, 'game_genre')) {
    final gid = r['game_id'];
    final name = genres[r['genre_id']];
    if (gid != null && name != null) {
      (gameGenres[gid] ??= <String>[]).add(name);
    }
  }
  final gameDevelopers = <String, List<String>>{};
  for (final r in _rows(sql, 'game_developer')) {
    final gid = r['game_id'];
    final name = companies[r['company_id']];
    if (gid != null && name != null) {
      (gameDevelopers[gid] ??= <String>[]).add(name);
    }
  }
  final gameAuthors = <String, List<String>>{};
  for (final r in _rows(sql, 'game_individual')) {
    final gid = r['game_id'];
    final name = individuals[r['individual_id']];
    if (gid != null && name != null) {
      (gameAuthors[gid] ??= <String>[]).add(name);
    }
  }

  final releasesByGame = <String, List<Map<String, String?>>>{};
  for (final r in releases) {
    final gid = r['game_id'];
    if (gid != null) (releasesByGame[gid] ??= []).add(r);
  }

  int? yearOf(String gid) {
    final years = <int>[];
    for (final r in releasesByGame[gid] ?? const []) {
      final d = r['date'];
      if (d != null && d.length >= 4) {
        final y = int.tryParse(d.substring(0, 4));
        if (y != null) years.add(y);
      }
    }
    if (years.isEmpty) return null;
    years.sort();
    return years.first;
  }

  String publisherOf(String gid) {
    final rs = [...(releasesByGame[gid] ?? const [])];
    rs.sort((a, b) => (a['date'] ?? '9999').compareTo(b['date'] ?? '9999'));
    for (final r in rs) {
      final cid = r['company_id'];
      if (cid != null) {
        final name = companies[cid];
        if (name != null && name.isNotEmpty) return name;
      }
    }
    return '';
  }

  final out = <AtariLegendGame>[];
  for (final g in games) {
    final id = _int(g['id']);
    final name = (g['name'] ?? '').toString();
    final slug = (g['slug'] ?? '').toString();
    if (id == null || name.isEmpty) continue;
    final gid = g['id']!;
    out.add(AtariLegendGame(
      id: id,
      name: name,
      slug: slug,
      year: yearOf(gid),
      publisher: publisherOf(gid),
      genres: _uniqStrings(gameGenres[gid] ?? const []),
      developers: _uniqStrings(gameDevelopers[gid] ?? const []),
      authors: _uniqStrings(gameAuthors[gid] ?? const []),
    ));
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  return AtariLegendCache(
    generatedAt: generatedAt,
    sourceFile: sourceFile,
    dumpDate: dumpDate,
    games: out,
  );
}
