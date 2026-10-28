// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:url_launcher/url_launcher.dart';

import '../catalog_controller.dart';
import '../piratefinder_names.dart';
import 'close_button.dart';
import 'piratefinder_link.dart';

/// Opens the PirateFinder-Catalog crew lightbox for a Crews-tab group.
Future<void> showPirateFinderCrewDialog(
  BuildContext context, {
  required CatalogController controller,
  required CrewGroup crew,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => PirateFinderCrewDialog(controller: controller, crew: crew),
  );
}

class PirateFinderCrewDialog extends StatefulWidget {
  const PirateFinderCrewDialog({
    super.key,
    required this.controller,
    required this.crew,
  });

  final CatalogController controller;
  final CrewGroup crew;

  @override
  State<PirateFinderCrewDialog> createState() => _PirateFinderCrewDialogState();
}

class _PirateFinderCrewDialogState extends State<PirateFinderCrewDialog> {
  late final Future<_CrewLookup?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_CrewLookup?> _load() async {
    final data = widget.controller.pirateFinderData;
    var index = data?.index;
    index ??= await data?.ensureIndex();
    if (index == null) return _CrewLookup(error: data?.indexError);
    final crew = widget.controller.pirateFinderCrewForGroup(widget.crew);
    if (crew == null) return _CrewLookup(index: index);
    return _CrewLookup(
      index: index,
      crew: crew,
      disks: index.disksForCrew(crew),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF111111),
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 980,
          maxHeight: MediaQuery.sizeOf(context).height - 80,
        ),
        child: FutureBuilder<_CrewLookup?>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 240,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final lookup = snapshot.data;
            if (lookup == null || lookup.index == null) {
              return _message(
                '$kPirateFinderCatalogName is not available.',
                lookup?.error ??
                    'Download it in Settings → '
                        '$kPirateFinderCatalogShortName.',
              );
            }
            final crew = lookup.crew;
            if (crew == null) {
              return _message(
                'No $kPirateFinderCatalogShortName crew match',
                'No catalogue crew matched ${widget.crew.name} by name or alias.',
              );
            }
            return _content(lookup.index!, crew, lookup.disks);
          },
        ),
      ),
    );
  }

  Widget _message(String title, String text) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  kPirateFinderCatalogName,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
              DialogCloseButton(onPressed: () => Navigator.of(context).pop()),
            ],
          ),
          const SizedBox(height: 8),
          Text(title, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 4),
          Text(text, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 16),
          const Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.end,
              children: [
                PirateFinderGithubLink(),
                Text(
                  ' · $kPirateFinderCatalogName · CC BY-NC-SA 4.0 · '
                  'not part of the Marcer catalog',
                  style: TextStyle(fontSize: 10, color: Color(0xFF7A7A7A)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(
    PirateFinderIndex index,
    PirateFinderCrew crew,
    List<PirateFinderDisk> disks,
  ) {
    final singles = disks.where((disk) => disk.kind == 'single').toList();
    final menus = disks.where((disk) => disk.kind != 'single').toList();
    final trivia = _collectTrivia(index, disks);
    return DefaultTabController(
      length: 5,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(crew, singles.length, menus.length),
          const Divider(height: 1),
          TabBar(
            isScrollable: true,
            tabs: [
              const Tab(text: 'Overview'),
              Tab(text: 'Releases (${singles.length})'),
              Tab(text: 'Menus (${menus.length})'),
              Tab(text: 'Trivia (${trivia.length})'),
              const Tab(text: 'Sources'),
            ],
          ),
          Flexible(
            child: TabBarView(
              children: [
                _scroll(_overviewTab(crew, singles, menus)),
                _scroll(_disksTab(index, singles, 'No single releases found.')),
                _scroll(_disksTab(index, menus, 'No menus or packs found.')),
                _scroll(_triviaTab(trivia)),
                _scroll(_sourcesTab(index)),
              ],
            ),
          ),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PirateFinderGithubLink(),
                Text(
                  ' · Data from the $kPirateFinderCatalogName '
                  '(CC BY-NC-SA 4.0). Includes Atari Legend, Demozoo, '
                  'libretro and other sources. '
                  'Not part of the Marcer catalog.',
                  style: TextStyle(fontSize: 10, color: Color(0xFF7A7A7A)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(PirateFinderCrew crew, int singles, int menus) {
    final meta = <String>[
      'PirateFinder-Catalog',
      if (crew.platform.isNotEmpty) crew.platform,
      '$singles single releases',
      '$menus menus / packs',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  crew.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          DialogCloseButton(onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }

  Widget _scroll(Widget child) =>
      SingleChildScrollView(padding: const EdgeInsets.all(16), child: child);

  Widget _overviewTab(
    PirateFinderCrew crew,
    List<PirateFinderDisk> singles,
    List<PirateFinderDisk> menus,
  ) {
    final links = <Widget>[
      if (crew.url.isNotEmpty) _link('Demozoo / profile', crew.url),
      if (crew.wikipedia.isNotEmpty) _link('Wikipedia', crew.wikipedia),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (crew.members.isNotEmpty) _kv('Members', crew.members),
        if (crew.founded.isNotEmpty) _kv('Founded', crew.founded),
        if (crew.platform.isNotEmpty) _kv('Platform', crew.platform),
        if (crew.source.isNotEmpty) _kv('Source', crew.source),
        _kv('Catalogue releases', '${crew.diskCount}'),
        _kv('Single releases', '${singles.length}'),
        _kv('Menus / packs', '${menus.length}'),
        if (crew.notes.isNotEmpty) ...[
          _section('History'),
          SelectableText(crew.notes, style: const TextStyle(fontSize: 12)),
        ],
        if (links.isNotEmpty) ...[_section('Links'), ...links],
      ],
    );
  }

  Widget _disksTab(
    PirateFinderIndex index,
    List<PirateFinderDisk> disks,
    String emptyText,
  ) {
    if (disks.isEmpty) {
      return Text(
        emptyText,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final disk in disks) _diskEntry(index, disk)],
    );
  }

  Widget _diskEntry(PirateFinderIndex index, PirateFinderDisk disk) {
    final date = _date(disk);
    final series = index.seriesForDisk(disk);
    final contents = index.contentsForDisk(disk.id);
    final links = index.linksForDisk(disk.id);
    final showContents =
        contents.isNotEmpty && (contents.length > 1 || disk.kind != 'single');
    final kind = [
      if (disk.kind.isNotEmpty) disk.kind,
      if (disk.category.isNotEmpty) disk.category,
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _kv('Release Name', disk.label),
          if (date.isNotEmpty) _kv('Release date', date),
          if (disk.publisher.isNotEmpty) _kv('Publisher', disk.publisher),
          if (kind.isNotEmpty) _kv('Kind', kind),
          if (series != null) _kv('Series', series.name),
          if (disk.version.isNotEmpty) _kv('Version', disk.version),
          if (disk.notes.isNotEmpty) _kv('Notes', disk.notes),
          if (disk.credits.isNotEmpty) _kv('Credits', disk.credits),
          if (disk.menuText.isNotEmpty) ...[
            _section('Menu text'),
            SelectableText(
              disk.menuText,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ],
          if (showContents) ...[
            _section('Contents (${contents.length})'),
            for (final item in contents)
              _bullet(
                item.title,
                [
                  if (item.kind.isNotEmpty) item.kind,
                  if (item.publisher.isNotEmpty) item.publisher,
                  if (item.cracker.isNotEmpty) 'cr ${item.cracker}',
                ].join(' · '),
              ),
          ],
          if (links.isNotEmpty) ...[
            _section('Links'),
            for (final link in links) _link(link.label, link.url),
          ],
        ],
      ),
    );
  }

  List<({PirateFinderTrivia trivia, String menu})> _collectTrivia(
    PirateFinderIndex index,
    List<PirateFinderDisk> disks,
  ) {
    final result = <({PirateFinderTrivia trivia, String menu})>[];
    final seen = <String>{};
    for (final disk in disks) {
      for (final fact in index.factsForDisk(disk)) {
        final key = '${fact.trivia.text}\u0000${fact.trivia.url}';
        if (seen.add(key)) {
          result.add((trivia: fact.trivia, menu: fact.menu.label));
        }
      }
      for (final trivia in index.triviaForDisk(disk.id)) {
        if (trivia.kind != 'fact' && trivia.kind != 'note') continue;
        final key = '${trivia.text}\u0000${trivia.url}';
        if (seen.add(key)) {
          result.add((trivia: trivia, menu: disk.label));
        }
      }
    }
    return result;
  }

  Widget _triviaTab(List<({PirateFinderTrivia trivia, String menu})> trivia) {
    if (trivia.isEmpty) {
      return const Text(
        'No trivia in the $kPirateFinderCatalogName.',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in trivia) ...[
          Row(
            children: [
              _badge(entry.trivia.kind.toUpperCase(), Colors.blueGrey),
              const SizedBox(width: 6),
              if (entry.trivia.source.isNotEmpty)
                Text(
                  entry.trivia.source,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
            ],
          ),
          const SizedBox(height: 3),
          SelectableText(
            entry.trivia.text,
            style: const TextStyle(fontSize: 12),
          ),
          if (entry.menu.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'via menu: ${entry.menu}',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
          if (entry.trivia.url.isNotEmpty) _link('Source', entry.trivia.url),
          if (entry.trivia.licence.isNotEmpty)
            Text(
              entry.trivia.licence,
              style: const TextStyle(fontSize: 10, color: Color(0xFF7A7A7A)),
            ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _sourcesTab(PirateFinderIndex index) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kv('Catalogue', index.sourceTag),
        _kv('Generated', index.generatedAt),
        _kv(
          'Licence',
          'CC BY-NC-SA 4.0 — non-commercial, attribution, share-alike',
        ),
        const SizedBox(height: 4),
        const Text(
          'Derived from the public $kPirateFinderCatalogName. '
          'Not part of the Marcer catalog.',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
        _section('Sources'),
        for (final source in index.sources)
          _bullet(
            source.name,
            [
              source.licence,
              if (source.records > 0) '${source.records} records',
            ].where((value) => value.isNotEmpty).join(' · '),
          ),
      ],
    );
  }

  Widget _kv(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 5),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: Colors.cyan,
      ),
    ),
  );

  Widget _bullet(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12)),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            style: const TextStyle(fontSize: 10, color: Colors.grey),
          ),
      ],
    ),
  );

  Widget _link(String label, String url) => Padding(
    padding: const EdgeInsets.only(top: 3, bottom: 3),
    child: InkWell(
      onTap: () =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          color: Colors.lightBlueAccent,
          decoration: TextDecoration.underline,
        ),
      ),
    ),
  );

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.bold),
    ),
  );

  String _date(PirateFinderDisk disk) {
    if (disk.day != null && disk.month != null && disk.year != null) {
      return '${disk.year}-${disk.month!.toString().padLeft(2, '0')}-'
          '${disk.day!.toString().padLeft(2, '0')}';
    }
    if (disk.month != null && disk.year != null) {
      return '${disk.year}-${disk.month!.toString().padLeft(2, '0')}';
    }
    return disk.year?.toString() ?? disk.date;
  }
}

class _CrewLookup {
  const _CrewLookup({this.index, this.crew, this.disks = const [], this.error});

  final PirateFinderIndex? index;
  final PirateFinderCrew? crew;
  final List<PirateFinderDisk> disks;
  final String? error;
}
