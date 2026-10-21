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
import 'dart:io';

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
    this.aliases = const [],
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
      aliases: strings('aliases'),
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

  /// Alternative titles (AtariLegend `game_akas`), also used for matching.
  final List<String> aliases;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'slug': slug,
        if (year != null) 'year': year,
        if (publisher.isNotEmpty) 'publisher': publisher,
        if (genres.isNotEmpty) 'genres': genres,
        if (developers.isNotEmpty) 'developers': developers,
        if (authors.isNotEmpty) 'authors': authors,
        if (aliases.isNotEmpty) 'aliases': aliases,
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
  final gameAkas = <String, List<String>>{};
  for (final r in _rows(sql, 'game_akas')) {
    final gid = r['game_id'];
    final name = r['name'];
    if (gid != null && name != null && name.isNotEmpty) {
      (gameAkas[gid] ??= <String>[]).add(name);
    }
  }

  final releasesByGame = <String, List<Map<String, String?>>>{};
  final releaseToGame = <String, String?>{};
  for (final r in releases) {
    final gid = r['game_id'];
    final rid = r['id'];
    if (rid != null) releaseToGame[rid] = gid;
    if (gid != null) (releasesByGame[gid] ??= []).add(r);
  }
  final releaseAkas = <String, List<String>>{};
  for (final r in _rows(sql, 'game_release_akas')) {
    final gid = releaseToGame[r['game_release_id']];
    final name = r['aka_name'];
    if (gid != null && name != null && name.isNotEmpty) {
      (releaseAkas[gid] ??= <String>[]).add(name);
    }
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
      aliases: _uniqStrings([
        ...(gameAkas[gid] ?? const []),
        for (final r in releasesByGame[gid] ?? const []) r['name'] ?? '',
        ...(releaseAkas[gid] ?? const []),
      ]),
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

// --------------------------------------------------------------------------
// matching: archive folder -> AtariLegend game
// --------------------------------------------------------------------------

/// Single-character diacritic fold (Dart has no Unicode NFKD). Covers the
/// Latin-1/Latin-Extended characters common in Atari ST titles.
const Map<String, String> _foldMap = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
  'ă': 'a', 'ą': 'a', 'æ': 'ae',
  'ç': 'c', 'ć': 'c', 'č': 'c', 'ĉ': 'c', 'ċ': 'c',
  'ď': 'd', 'đ': 'd', 'ð': 'd',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e',
  'ę': 'e', 'ě': 'e', '€': 'e',
  'ĝ': 'g', 'ğ': 'g', 'ġ': 'g', 'ģ': 'g',
  'ĥ': 'h', 'ħ': 'h',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i',
  'į': 'i', 'ı': 'i',
  'ĵ': 'j',
  'ķ': 'k',
  'ĺ': 'l', 'ļ': 'l', 'ľ': 'l', 'ł': 'l',
  'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
  'ŏ': 'o', 'ő': 'o', 'œ': 'oe',
  'ŕ': 'r', 'ř': 'r',
  'ś': 's', 'š': 's', 'ş': 's', 'ș': 's', 'ŝ': 's',
  'ß': 'ss',
  'ţ': 't', 'ť': 't', 'ț': 't', 'ŧ': 't',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u',
  'ů': 'u', 'ű': 'u', 'ų': 'u',
  'ŵ': 'w',
  'ý': 'y', 'ÿ': 'y', 'ŷ': 'y',
  'ź': 'z', 'ž': 'z', 'ż': 'z',
};

/// Normalizes a title for matching (casefold, diacritics, punctuation,
/// `&` → `and`, article inversion `Tale, A` → `tale`, articles stripped).
String atariLegendNormKey(String? s) {
  if (s == null) return '';
  final lower = s.toLowerCase();
  final buf = StringBuffer();
  for (final ch in lower.split('')) {
    buf.write(_foldMap[ch] ?? ch);
  }
  var t = buf.toString().replaceAll('&', ' and ');
  t = t.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  final m = RegExp(r'^(.*?), (a|an|the)$').firstMatch(t);
  if (m != null) t = '${m.group(2)} ${m.group(1)}';
  return t
      .split(' ')
      .where((x) => x.isNotEmpty && !const {'a', 'an', 'the'}.contains(x))
      .join(' ');
}

int _levenshtein(String a, String b) {
  final n = a.length;
  final m = b.length;
  if (n == 0) return m;
  if (m == 0) return n;
  var prev = List<int>.generate(m + 1, (i) => i);
  var cur = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    cur[0] = i;
    for (var j = 1; j <= m; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final deletion = prev[j] + 1;
      final insertion = cur[j - 1] + 1;
      final substitution = prev[j - 1] + cost;
      var v = deletion < insertion ? deletion : insertion;
      if (substitution < v) v = substitution;
      cur[j] = v;
    }
    final tmp = prev;
    prev = cur;
    cur = tmp;
  }
  return prev[m];
}

double _ratio(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 1;
  final maxLen = a.length > b.length ? a.length : b.length;
  return 1 - _levenshtein(a, b) / maxLen;
}

/// Folder → game matcher over the cached AtariLegend games.
///
/// The desktop app cannot ship AtariLegend data and the cache has no folder
/// mapping, so it matches the archive folder name at runtime with the same
/// staged strategy as `tools/atarilegend-gen`: exact → prefix → fuzzy.
class AtariLegendIndex {
  AtariLegendIndex._(this._games, this._keyIndex, this._blockIndex,
      this._shortKeys)
      : _byId = {for (final g in _games) g.id: g};

  factory AtariLegendIndex.empty() =>
      AtariLegendIndex._(const [], const {}, const {}, const []);

  factory AtariLegendIndex.fromGames(List<AtariLegendGame> games) {
    final keyIndex = <String, List<int>>{};
    for (final g in games) {
      void addKey(String? name) {
        final k = atariLegendNormKey(name);
        if (k.isEmpty) return;
        final ids = keyIndex[k] ??= <int>[];
        if (!ids.contains(g.id)) ids.add(g.id);
      }

      addKey(g.name);
      for (final alias in g.aliases) {
        addKey(alias);
      }
    }
    final blockIndex = <String, List<String>>{};
    final shortKeys = <String>[];
    for (final k in keyIndex.keys) {
      if (k.length < 3) {
        shortKeys.add(k);
      } else {
        (blockIndex[k.substring(0, 3)] ??= <String>[]).add(k);
      }
    }
    return AtariLegendIndex._(
        List<AtariLegendGame>.unmodifiable(games), keyIndex, blockIndex,
        shortKeys);
  }

  /// Loads `<dir>/atarilegend.json`; empty (with a [warnings] entry) when
  /// the directory/file is missing or unreadable — never throws.
  factory AtariLegendIndex.load(String dir, {List<String>? warnings}) {
    final d = dir.trim();
    if (d.isEmpty) return AtariLegendIndex.empty();
    final file = File('$d/$kAtariLegendFileName');
    if (!file.existsSync()) {
      warnings?.add('AtariLegend data: $kAtariLegendFileName not found in $d');
      return AtariLegendIndex.empty();
    }
    try {
      final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final cache = AtariLegendCache.fromJson(map);
      if (cache.games.isEmpty) {
        warnings?.add('AtariLegend data: no games in ${file.path}');
        return AtariLegendIndex.empty();
      }
      return AtariLegendIndex.fromGames(cache.games);
    } catch (e) {
      warnings?.add('AtariLegend data: could not read ${file.path}: $e');
      return AtariLegendIndex.empty();
    }
  }

  final List<AtariLegendGame> _games;
  final Map<String, List<int>> _keyIndex;
  final Map<String, List<String>> _blockIndex;
  final List<String> _shortKeys;
  final Map<int, AtariLegendGame> _byId;
  final Map<String, AtariLegendGame?> _matchCache = {};

  int get length => _games.length;

  AtariLegendGame? byId(int id) => _byId[id];

  /// Matches an archive folder name to a cached game (cached per folder).
  AtariLegendGame? matchFolder(String folder) {
    if (_matchCache.containsKey(folder)) return _matchCache[folder];
    final result = _match(folder);
    _matchCache[folder] = result;
    return result;
  }

  AtariLegendGame? _match(String folder) {
    final k = atariLegendNormKey(folder);
    if (k.isEmpty || _games.isEmpty) return null;

    final exact = _keyIndex[k];
    if (exact != null && exact.isNotEmpty) return _lowest(exact);

    final pool = <String>[];
    if (k.length >= 3) {
      pool.addAll(_blockIndex[k.substring(0, 3)] ?? const []);
    }
    pool.addAll(_shortKeys);

    String? best;
    for (final a in pool) {
      if (k.startsWith('$a ') || a.startsWith('$k ')) {
        if (best == null || a.length > best.length) best = a;
      }
    }
    if (best != null) return _lowest(_keyIndex[best]!);

    String? bestKey;
    var bestScore = 0.0;
    for (final a in pool) {
      final r = _ratio(k, a);
      if (r > bestScore) {
        bestScore = r;
        bestKey = a;
      }
    }
    if (bestKey != null && bestScore >= 0.90) {
      return _lowest(_keyIndex[bestKey]!);
    }
    return null;
  }

  AtariLegendGame? _lowest(List<int> ids) {
    var lowest = ids.first;
    for (final id in ids) {
      if (id < lowest) lowest = id;
    }
    return _byId[lowest];
  }
}
