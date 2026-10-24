// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';

/// One Atari ST record from the generic PirateFinder catalogue JSON
/// (`piratefinder-catalog-atari-st.json.gz`, schema 1).
class PirateFinderDisk {
  const PirateFinderDisk({
    required this.id,
    required this.seriesId,
    required this.number,
    required this.part,
    required this.version,
    required this.label,
    required this.title,
    required this.date,
    required this.platform,
    required this.kind,
    required this.publisher,
    required this.cracker,
    required this.condition,
    required this.notes,
    required this.credits,
    required this.menuText,
    required this.category,
    required this.crew,
    required this.crewId,
    required this.year,
    required this.month,
    required this.day,
    required this.sortTitle,
  });

  factory PirateFinderDisk.fromJson(Map<String, dynamic> json) =>
      PirateFinderDisk(
        id: (json['id'] as num).toInt(),
        seriesId: json['series_id']?.toString(),
        number: (json['number'] as num?)?.toInt(),
        part: (json['part'] as String?) ?? '',
        version: (json['version'] as String?) ?? '',
        label: (json['label'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        date: (json['date'] as String?) ?? '',
        platform: (json['platform'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? '',
        publisher: (json['publisher'] as String?) ?? '',
        cracker: (json['cracker'] as String?) ?? '',
        condition: (json['condition'] as String?) ?? '',
        notes: (json['notes'] as String?) ?? '',
        credits: (json['credits'] as String?) ?? '',
        menuText: (json['menu_text'] as String?) ?? '',
        category: (json['category'] as String?) ?? '',
        crew: (json['crew'] as String?) ?? '',
        crewId: (json['crew_id'] as num?)?.toInt(),
        year: (json['year'] as num?)?.toInt(),
        month: (json['month'] as num?)?.toInt(),
        day: (json['day'] as num?)?.toInt(),
        sortTitle: (json['sort_title'] as String?) ?? '',
      );

  final int id;
  final String? seriesId;
  final int? number;
  final String part;
  final String version;
  final String label;
  final String title;
  final String date;
  final String platform;
  final String kind;
  final String publisher;
  final String cracker;
  final String condition;
  final String notes;
  final String credits;
  final String menuText;
  final String category;
  final String crew;
  final int? crewId;
  final int? year;
  final int? month;
  final int? day;
  final String sortTitle;

  bool get isSingle => kind == 'single';

  String get titleOrLabel => title.isNotEmpty ? title : label;
}

class PirateFinderContent {
  const PirateFinderContent({
    required this.id,
    required this.diskId,
    required this.position,
    required this.title,
    required this.kind,
    required this.publisher,
    required this.cracker,
    required this.version,
    required this.extra,
    required this.source,
  });

  factory PirateFinderContent.fromJson(Map<String, dynamic> json) =>
      PirateFinderContent(
        id: (json['id'] as num).toInt(),
        diskId: (json['disk_id'] as num).toInt(),
        position: (json['position'] as num?)?.toInt() ?? 0,
        title: (json['title'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? '',
        publisher: (json['publisher'] as String?) ?? '',
        cracker: (json['cracker'] as String?) ?? '',
        version: (json['version'] as String?) ?? '',
        extra: (json['extra'] as String?) ?? '',
        source: (json['source'] as String?) ?? '',
      );

  final int id;
  final int diskId;
  final int position;
  final String title;
  final String kind;
  final String publisher;
  final String cracker;
  final String version;
  final String extra;
  final String source;
}

class PirateFinderImage {
  const PirateFinderImage({
    required this.id,
    required this.diskId,
    required this.name,
    required this.format,
    required this.flags,
    required this.size,
    required this.crc32,
    required this.md5,
    required this.sha1,
    required this.sha512,
    required this.bad,
    required this.rank,
    required this.virus,
    required this.virusDamage,
    required this.antivirus,
  });

  factory PirateFinderImage.fromJson(Map<String, dynamic> json) =>
      PirateFinderImage(
        id: (json['id'] as num).toInt(),
        diskId: (json['disk_id'] as num).toInt(),
        name: (json['name'] as String?) ?? '',
        format: (json['format'] as String?) ?? '',
        flags: (json['flags'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt(),
        crc32: ((json['crc32'] as String?) ?? '').toLowerCase(),
        md5: ((json['md5'] as String?) ?? '').toLowerCase(),
        sha1: ((json['sha1'] as String?) ?? '').toLowerCase(),
        sha512: ((json['sha512'] as String?) ?? '').toLowerCase(),
        bad: json['bad'] == true,
        rank: (json['rank'] as num?)?.toInt() ?? 0,
        virus: (json['virus'] as String?) ?? '',
        virusDamage: json['virus_damage'] == true,
        antivirus: (json['antivirus'] as String?) ?? '',
      );

  final int id;
  final int diskId;
  final String name;
  final String format;
  final String flags;
  final int? size;
  final String crc32;
  final String md5;
  final String sha1;
  final String sha512;
  final bool bad;
  final int rank;
  final String virus;
  final bool virusDamage;
  final String antivirus;
}

class PirateFinderCrew {
  const PirateFinderCrew({
    required this.id,
    required this.name,
    required this.platform,
    required this.notes,
    required this.members,
    required this.founded,
    required this.source,
    required this.url,
    required this.wikipedia,
    required this.diskCount,
  });

  factory PirateFinderCrew.fromJson(Map<String, dynamic> json) =>
      PirateFinderCrew(
        id: (json['id'] as num).toInt(),
        name: (json['name'] as String?) ?? '',
        platform: (json['platform'] as String?) ?? '',
        notes: (json['notes'] as String?) ?? '',
        members: (json['members'] as String?) ?? '',
        founded: (json['founded'] as String?) ?? '',
        source: (json['source'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        wikipedia: (json['wikipedia'] as String?) ?? '',
        diskCount: (json['disk_count'] as num?)?.toInt() ?? 0,
      );

  final int id;
  final String name;
  final String platform;
  final String notes;
  final String members;
  final String founded;
  final String source;
  final String url;
  final String wikipedia;
  final int diskCount;
}

class PirateFinderTrivia {
  const PirateFinderTrivia({
    required this.id,
    required this.diskId,
    required this.contentId,
    required this.kind,
    required this.text,
    required this.source,
    required this.url,
    required this.licence,
  });

  factory PirateFinderTrivia.fromJson(Map<String, dynamic> json) =>
      PirateFinderTrivia(
        id: (json['id'] as num).toInt(),
        diskId: (json['disk_id'] as num?)?.toInt(),
        contentId: (json['content_id'] as num?)?.toInt(),
        kind: (json['kind'] as String?) ?? '',
        text: (json['text'] as String?) ?? '',
        source: (json['source'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        licence: (json['licence'] as String?) ?? '',
      );

  final int id;
  final int? diskId;
  final int? contentId;
  final String kind;
  final String text;
  final String source;
  final String url;
  final String licence;
}

class PirateFinderLink {
  const PirateFinderLink({
    required this.diskId,
    required this.label,
    required this.url,
  });

  factory PirateFinderLink.fromJson(Map<String, dynamic> json) =>
      PirateFinderLink(
        diskId: (json['disk_id'] as num).toInt(),
        label: (json['label'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
      );

  final int diskId;
  final String label;
  final String url;
}

class PirateFinderSeries {
  const PirateFinderSeries({
    required this.id,
    required this.name,
    required this.platform,
    required this.kind,
    required this.groupName,
    required this.description,
    required this.aliases,
  });

  factory PirateFinderSeries.fromJson(Map<String, dynamic> json) =>
      PirateFinderSeries(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        platform: (json['platform'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? '',
        groupName: (json['group_name'] as String?) ?? '',
        description: (json['description'] as String?) ?? '',
        aliases: ((json['aliases'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  final String id;
  final String name;
  final String platform;
  final String kind;
  final String groupName;
  final String description;
  final List<String> aliases;
}

class PirateFinderSource {
  const PirateFinderSource({
    required this.id,
    required this.name,
    required this.url,
    required this.licence,
    required this.retrieved,
    required this.records,
  });

  factory PirateFinderSource.fromJson(Map<String, dynamic> json) =>
      PirateFinderSource(
        id: (json['id'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        licence: (json['licence'] as String?) ?? '',
        retrieved: (json['retrieved'] as String?) ?? '',
        records: (json['records'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String name;
  final String url;
  final String licence;
  final String retrieved;
  final int records;
}

/// One matched PF record and how it was found.
class PirateFinderMatch {
  const PirateFinderMatch({
    required this.disk,
    required this.candidates,
    required this.method,
    required this.confidence,
  });

  final PirateFinderDisk disk;
  final List<PirateFinderDisk> candidates;

  /// `hash` or `title`.
  final String method;

  /// `exact` (hash) or `likely` (title/cracker).
  final String confidence;
}

/// Parsed PirateFinder Atari ST catalogue with lookup indexes.
class PirateFinderIndex {
  PirateFinderIndex._({
    required this.generatedAt,
    required this.sourceTag,
    required this.sources,
    required Map<int, PirateFinderDisk> disks,
    required Map<int, PirateFinderCrew> crews,
    required Map<String, PirateFinderSeries> series,
    required Map<int, List<PirateFinderContent>> contents,
    required Map<int, List<PirateFinderTrivia>> trivia,
    required Map<int, List<PirateFinderLink>> links,
    required Map<String, List<int>> singleByTitle,
    required Map<String, List<int>> menuByTitle,
    required Map<String, List<int>> sha1,
    required Map<String, List<int>> md5,
    required Map<String, List<int>> sha512,
    required Map<String, List<int>> crc,
    required Map<int, PirateFinderImage> images,
  })  : _disks = disks,
        _crews = crews,
        _series = series,
        _contents = contents,
        _trivia = trivia,
        _links = links,
        _singleByTitle = singleByTitle,
        _menuByTitle = menuByTitle,
        _sha1 = sha1,
        _md5 = md5,
        _sha512 = sha512,
        _crc = crc,
        _images = images;

  final String generatedAt;
  final String sourceTag;
  final List<PirateFinderSource> sources;
  final Map<int, PirateFinderDisk> _disks;
  final Map<int, PirateFinderCrew> _crews;
  final Map<String, PirateFinderSeries> _series;
  final Map<int, List<PirateFinderContent>> _contents;
  final Map<int, List<PirateFinderTrivia>> _trivia;
  final Map<int, List<PirateFinderLink>> _links;
  final Map<String, List<int>> _singleByTitle;
  final Map<String, List<int>> _menuByTitle;
  final Map<String, List<int>> _sha1;
  final Map<String, List<int>> _md5;
  final Map<String, List<int>> _sha512;
  final Map<String, List<int>> _crc;
  final Map<int, PirateFinderImage> _images;

  int get length => _disks.length;

  /// Loads the gzipped PF-only JSON (run this in an isolate).
  static PirateFinderIndex fromGzipFile(String path) {
    final bytes = gzip.decode(File(path).readAsBytesSync());
    final map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return fromJson(map);
  }

  static PirateFinderIndex fromJson(Map<String, dynamic> map) {
    final disks = <int, PirateFinderDisk>{};
    for (final raw in (map['disks'] as List<dynamic>?) ?? const []) {
      final disk = PirateFinderDisk.fromJson(Map<String, dynamic>.from(raw as Map));
      disks[disk.id] = disk;
    }
    final crews = <int, PirateFinderCrew>{};
    for (final raw in (map['crews'] as List<dynamic>?) ?? const []) {
      final crew = PirateFinderCrew.fromJson(Map<String, dynamic>.from(raw as Map));
      crews[crew.id] = crew;
    }
    final series = <String, PirateFinderSeries>{};
    for (final raw in (map['series'] as List<dynamic>?) ?? const []) {
      final item = PirateFinderSeries.fromJson(Map<String, dynamic>.from(raw as Map));
      if (item.id.isNotEmpty) series[item.id] = item;
    }
    final contents = <int, List<PirateFinderContent>>{};
    for (final raw in (map['contents'] as List<dynamic>?) ?? const []) {
      final item = PirateFinderContent.fromJson(Map<String, dynamic>.from(raw as Map));
      (contents[item.diskId] ??= []).add(item);
    }
    for (final list in contents.values) {
      list.sort((a, b) => a.position.compareTo(b.position));
    }
    final trivia = <int, List<PirateFinderTrivia>>{};
    for (final raw in (map['trivia'] as List<dynamic>?) ?? const []) {
      final item = PirateFinderTrivia.fromJson(Map<String, dynamic>.from(raw as Map));
      final diskId = item.diskId;
      if (diskId != null) (trivia[diskId] ??= []).add(item);
    }
    final links = <int, List<PirateFinderLink>>{};
    for (final raw in (map['links'] as List<dynamic>?) ?? const []) {
      final item = PirateFinderLink.fromJson(Map<String, dynamic>.from(raw as Map));
      (links[item.diskId] ??= []).add(item);
    }
    final sources = [
      for (final raw in (map['sources'] as List<dynamic>?) ?? const [])
        PirateFinderSource.fromJson(Map<String, dynamic>.from(raw as Map)),
    ];
    final source = map['source'] is Map
        ? Map<String, dynamic>.from(map['source'] as Map)
        : const <String, dynamic>{};

    final singleByTitle = <String, List<int>>{};
    final menuByTitle = <String, List<int>>{};
    for (final disk in disks.values) {
      if (disk.kind == 'single') {
        final key = _titleKeyOfDisk(disk, contents[disk.id]);
        if (key.isNotEmpty) (singleByTitle[key] ??= []).add(disk.id);
      }
      if (disk.kind == 'menu' ||
          disk.kind == 'pack' ||
          disk.kind == 'compilation') {
        for (final item in contents[disk.id] ?? const <PirateFinderContent>[]) {
          final key = titleKey(item.title);
          if (key.isNotEmpty) (menuByTitle[key] ??= []).add(disk.id);
        }
      }
    }

    final sha1 = <String, List<int>>{};
    final md5 = <String, List<int>>{};
    final sha512 = <String, List<int>>{};
    final crc = <String, List<int>>{};
    final images = <int, PirateFinderImage>{};
    for (final raw in (map['images'] as List<dynamic>?) ?? const []) {
      final image = PirateFinderImage.fromJson(Map<String, dynamic>.from(raw as Map));
      images[image.id] = image;
      if (image.sha1.isNotEmpty) (sha1[image.sha1] ??= []).add(image.id);
      if (image.md5.isNotEmpty) (md5[image.md5] ??= []).add(image.id);
      if (image.sha512.isNotEmpty) (sha512[image.sha512] ??= []).add(image.id);
      if (image.crc32.isNotEmpty && image.size != null) {
        (crc['${image.crc32}:${image.size}'] ??= []).add(image.id);
      }
    }

    return PirateFinderIndex._(
      generatedAt: (map['generated_at'] as String?) ?? '',
      sourceTag: (source['tag'] as String?) ?? '',
      sources: sources,
      disks: disks,
      crews: crews,
      series: series,
      contents: contents,
      trivia: trivia,
      links: links,
      singleByTitle: singleByTitle,
      menuByTitle: menuByTitle,
      sha1: sha1,
      md5: md5,
      sha512: sha512,
      crc: crc,
      images: images,
    );
  }

  PirateFinderDisk? disk(int id) => _disks[id];
  PirateFinderCrew? crewForDisk(PirateFinderDisk disk) {
    final byId = disk.crewId == null ? null : _crews[disk.crewId];
    if (byId != null) return byId;
    final key = normalizeLabel(disk.crew);
    if (key.isEmpty) return null;
    for (final crew in _crews.values) {
      if (normalizeLabel(crew.name) == key) return crew;
    }
    return null;
  }

  PirateFinderSeries? seriesForDisk(PirateFinderDisk disk) =>
      disk.seriesId == null ? null : _series[disk.seriesId];

  List<PirateFinderContent> contentsForDisk(int diskId) =>
      _contents[diskId] ?? const [];

  List<PirateFinderTrivia> triviaForDisk(int diskId) =>
      _trivia[diskId] ?? const [];

  List<PirateFinderLink> linksForDisk(int diskId) =>
      _links[diskId] ?? const [];

  /// Other menu/pack/compilation disks that list one of [disk]'s titles.
  List<PirateFinderDisk> appearancesForDisk(PirateFinderDisk disk) {
    final result = <PirateFinderDisk>[];
    final seen = <int>{disk.id};
    for (final content in contentsForDisk(disk.id)) {
      for (final id in _menuByTitle[titleKey(content.title)] ?? const <int>[]) {
        if (!seen.add(id)) continue;
        final other = _disks[id];
        if (other != null) result.add(other);
      }
    }
    result.sort((a, b) => (a.label).compareTo(b.label));
    return result;
  }

  PirateFinderMatch? matchByHashes(List<Map<String, dynamic>> hashes) {
    final found = <int>{};
    for (final hash in hashes) {
      final sha1 = (hash['sha1'] as String?)?.toLowerCase();
      final md5 = (hash['md5'] as String?)?.toLowerCase();
      final sha512 = (hash['sha512'] as String?)?.toLowerCase();
      final crc32 = (hash['crc32'] as String?)?.toLowerCase();
      final size = (hash['size'] as num?)?.toInt();
      for (final value in [sha1, md5, sha512]) {
        if (value == null || value.isEmpty) continue;
        found.addAll(_sha1[value] ?? const []);
        found.addAll(_md5[value] ?? const []);
        found.addAll(_sha512[value] ?? const []);
      }
      if (crc32 != null && crc32.isNotEmpty && size != null) {
        found.addAll(_crc['$crc32:$size'] ?? const []);
      }
    }
    if (found.isEmpty) return null;
    final images = found
        .map((id) => _images[id])
        .whereType<PirateFinderImage>()
        .toList()
      ..sort(_imageQuality);
    for (final image in images) {
      final disk = _disks[image.diskId];
      if (disk == null) continue;
      return PirateFinderMatch(
        disk: disk,
        candidates: [disk],
        method: 'hash',
        confidence: 'exact',
      );
    }
    return null;
  }

  PirateFinderMatch? matchByTitles(
    Iterable<String> titles, {
    Set<String> labels = const {},
    Set<int> years = const {},
    Set<String> publishers = const {},
  }) {
    final ids = <int>{};
    for (final title in titles) {
      final key = titleKey(title);
      if (key.isEmpty) continue;
      ids.addAll(_singleByTitle[key] ?? const []);
    }
    if (ids.isEmpty) return null;
    var disks = ids.map((id) => _disks[id]).whereType<PirateFinderDisk>().toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (labels.isNotEmpty) {
      final filtered = disks.where((d) {
        final values = {
          normalizeLabel(d.crew),
          normalizeLabel(d.cracker),
        };
        return values.any(labels.contains);
      }).toList();
      if (filtered.isNotEmpty) disks = filtered;
    }
    if (disks.length > 1 && years.isNotEmpty) {
      final filtered = disks.where((d) => d.year != null && years.contains(d.year)).toList();
      if (filtered.isNotEmpty) disks = filtered;
    }
    if (disks.length > 1 && publishers.isNotEmpty) {
      final filtered = disks
          .where((d) => publishers.contains(normalizeLabel(d.publisher)))
          .toList();
      if (filtered.isNotEmpty) disks = filtered;
    }
    if (disks.isEmpty) return null;
    return PirateFinderMatch(
      disk: disks.first,
      candidates: disks,
      method: 'title',
      confidence: 'likely',
    );
  }

  static int _imageQuality(PirateFinderImage a, PirateFinderImage b) {
    final bad = (a.bad ? 1 : 0).compareTo(b.bad ? 1 : 0);
    if (bad != 0) return bad;
    final rank = a.rank.compareTo(b.rank);
    if (rank != 0) return rank;
    return a.id.compareTo(b.id);
  }

  static String _titleKeyOfDisk(PirateFinderDisk disk, List<PirateFinderContent>? contents) {
    if (disk.title.isNotEmpty) return titleKey(disk.title);
    for (final item in contents ?? const <PirateFinderContent>[]) {
      if (item.kind == 'game' && item.title.isNotEmpty) return titleKey(item.title);
    }
    return contents != null && contents.isNotEmpty ? titleKey(contents.first.title) : '';
  }

  /// Normalises a game title for title matching.
  static String titleKey(String value) {
    var text = value.toLowerCase();
    final bracket = text.indexOf(RegExp(r'[\(\[]'));
    if (bracket >= 0) text = text.substring(0, bracket);
    text = text.replaceFirst(RegExp(r'\s+v\d+(?:\.\d+)*\s*$'), '');
    text = text.replaceAll(RegExp(r'[,\s]+(the|a|an)\s*$'), '');
    if (text.startsWith('the ')) text = text.substring(4);
    text = text.replaceAll('&', ' and ').replaceAll('+', ' and ');
    text = text.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    text = text.replaceAllMapped(
      RegExp(r'\b(ii|iii|iv|vi|vii|viii|ix|x)\b'),
      (match) => const {
        'ii': '2',
        'iii': '3',
        'iv': '4',
        'vi': '6',
        'vii': '7',
        'viii': '8',
        'ix': '9',
        'x': '10',
      }[match.group(1)]!,
    );
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Normalises a crew/cracker label for matching.
  static String normalizeLabel(String value) {
    var text = value.toLowerCase().replaceAll('&', ' and ').replaceAll('+', ' and ');
    text = text.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    if (text.startsWith('the ')) text = text.substring(4);
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }
}
