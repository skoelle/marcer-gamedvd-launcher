// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:url_launcher/url_launcher.dart';

import '../catalog_controller.dart';
import '../piratefinder_names.dart';
import 'piratefinder_link.dart';

/// Opens the PirateFinder details dialog for a catalog card or browse entry.
/// Data is loaded lazily; [rel] is the selected ZIP (exact-hash match).
Future<void> showPirateFinderDialog(
  BuildContext context, {
  required CatalogController controller,
  GameCard? card,
  Entry? entry,
  String? rel,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => PirateFinderDialog(
      controller: controller,
      card: card,
      entry: entry,
      rel: rel,
    ),
  );
}

class PirateFinderDialog extends StatefulWidget {
  const PirateFinderDialog({
    super.key,
    required this.controller,
    this.card,
    this.entry,
    this.rel,
  });

  final CatalogController controller;
  final GameCard? card;
  final Entry? entry;
  final String? rel;

  @override
  State<PirateFinderDialog> createState() => _PirateFinderDialogState();
}

class _PirateFinderDialogState extends State<PirateFinderDialog> {
  late final Future<_PfLookup?> _future;
  PirateFinderDisk? _selected;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_PfLookup?> _load() async {
    final data = widget.controller.pirateFinderData;
    final index = await data?.ensureIndex();
    final match = widget.card != null
        ? await widget.controller.pirateFinderMatchForCard(
            widget.card!,
            rel: widget.rel,
          )
        : await widget.controller.pirateFinderMatchForEntry(
            widget.entry!,
            rel: widget.rel,
          );
    if (index == null) {
      return _PfLookup(index: null, match: match, error: data?.indexError);
    }
    return _PfLookup(index: index, match: match);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF111111),
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 920,
          maxHeight: MediaQuery.sizeOf(context).height - 80,
        ),
        child: FutureBuilder<_PfLookup?>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 220,
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
            final match = lookup.match;
            if (match == null || match.candidates.isEmpty) {
              return _message(
                'No $kPirateFinderCatalogShortName match',
                'No catalogue record matched this title, crew or ZIP hash.',
              );
            }
            final selected = _selected ?? match.disk;
            return _content(lookup.index!, match, selected);
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
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
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
    PirateFinderMatch match,
    PirateFinderDisk disk,
  ) {
    final candidates = match.candidates;
    final series = index.seriesForDisk(disk);
    final crew = index.crewForDisk(disk);
    final appearances = index.appearancesForDisk(disk);
    final trivia = index.triviaForDisk(disk.id);
    return DefaultTabController(
      length: 5,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(match, disk, candidates),
          const Divider(height: 1),
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Release'),
              Tab(text: 'Crew'),
              Tab(text: 'Menus'),
              Tab(text: 'Trivia'),
              Tab(text: 'Sources'),
            ],
          ),
          Flexible(
            child: TabBarView(
              children: [
                _scroll(_releaseTab(index, disk, series)),
                _scroll(_crewTab(crew)),
                _scroll(_menusTab(appearances)),
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

  Widget _header(
    PirateFinderMatch match,
    PirateFinderDisk disk,
    List<PirateFinderDisk> candidates,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      kPirateFinderCatalogName,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _badge(
                      match.confidence == 'exact' ? 'EXACT' : 'LIKELY',
                      match.confidence == 'exact'
                          ? Colors.greenAccent
                          : Colors.orangeAccent,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  disk.label,
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
                if (candidates.length > 1) ...[
                  const SizedBox(height: 6),
                  DropdownButton<int>(
                    value: disk.id,
                    isDense: true,
                    items: [
                      for (final candidate in candidates)
                        DropdownMenuItem(
                          value: candidate.id,
                          child: Text(
                            candidate.label,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                    onChanged: (id) {
                      final next = candidates
                          .where((c) => c.id == id)
                          .firstOrNull;
                      if (next != null) setState(() => _selected = next);
                    },
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _scroll(Widget child) =>
      SingleChildScrollView(padding: const EdgeInsets.all(16), child: child);

  Widget _releaseTab(
    PirateFinderIndex index,
    PirateFinderDisk disk,
    PirateFinderSeries? series,
  ) {
    final contents = index.contentsForDisk(disk.id);
    final links = index.linksForDisk(disk.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kv('Label', disk.label),
        _kv('Title', disk.title),
        if (series != null) ...[
          _kv('Series', series.name),
          if (series.groupName.isNotEmpty) _kv('Group', series.groupName),
        ],
        _kv(
          'Number',
          [
            if (disk.number != null) '${disk.number}',
            if (disk.part.isNotEmpty) 'part ${disk.part}',
            if (disk.version.isNotEmpty) 'version ${disk.version}',
          ].join(' · '),
        ),
        _kv('Kind', disk.kind),
        _kv('Category', disk.category),
        _kv('Date', _date(disk)),
        _kv('Publisher', disk.publisher),
        _kv('Cracker', disk.cracker),
        _kv('Crew', disk.crew),
        _kv('Condition', disk.condition),
        if (contents.isNotEmpty) ...[
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
        if (disk.notes.isNotEmpty) ...[
          _section('Notes'),
          SelectableText(disk.notes, style: const TextStyle(fontSize: 12)),
        ],
        if (disk.credits.isNotEmpty) ...[
          _section('Credits'),
          SelectableText(disk.credits, style: const TextStyle(fontSize: 12)),
        ],
        if (disk.menuText.isNotEmpty) ...[
          _section('Menu text'),
          SelectableText(
            disk.menuText,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ],
        if (links.isNotEmpty) ...[
          _section('Links'),
          for (final link in links) _link(link.label, link.url),
        ],
      ],
    );
  }

  Widget _crewTab(PirateFinderCrew? crew) {
    if (crew == null) {
      return const Text(
        'No crew history in the $kPirateFinderCatalogName.',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kv('Name', crew.name),
        _kv('Founded', crew.founded),
        _kv('Source', crew.source),
        if (crew.members.isNotEmpty) ...[
          _section('Members'),
          SelectableText(crew.members, style: const TextStyle(fontSize: 12)),
        ],
        if (crew.notes.isNotEmpty) ...[
          _section('History'),
          SelectableText(crew.notes, style: const TextStyle(fontSize: 12)),
        ],
        if (crew.url.isNotEmpty) _link('Open crew page', crew.url),
        if (crew.wikipedia.isNotEmpty) ...[
          _link(
            'Wikipedia: ${crew.wikipedia}',
            'https://en.wikipedia.org/wiki/${Uri.encodeComponent(crew.wikipedia.replaceAll(' ', '_'))}',
          ),
        ],
      ],
    );
  }

  Widget _menusTab(List<PirateFinderDisk> appearances) {
    if (appearances.isEmpty) {
      return const Text(
        'No other menu-disk appearances found.',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final disk in appearances)
          _bullet(
            disk.label,
            [
              if (disk.year != null) '${disk.year}',
              if (disk.crew.isNotEmpty) disk.crew,
              if (disk.kind.isNotEmpty) disk.kind,
            ].join(' · '),
          ),
      ],
    );
  }

  Widget _triviaTab(List<PirateFinderTrivia> trivia) {
    if (trivia.isEmpty) {
      return const Text(
        'No trivia in the $kPirateFinderCatalogName.',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in trivia) ...[
          Row(
            children: [
              _badge(item.kind.toUpperCase(), Colors.blueGrey),
              const SizedBox(width: 6),
              if (item.source.isNotEmpty)
                Text(
                  item.source,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
            ],
          ),
          const SizedBox(height: 3),
          SelectableText(item.text, style: const TextStyle(fontSize: 12)),
          if (item.url.isNotEmpty) _link('Source', item.url),
          if (item.licence.isNotEmpty)
            Text(
              item.licence,
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
            width: 100,
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

class _PfLookup {
  const _PfLookup({required this.index, required this.match, this.error});

  final PirateFinderIndex? index;
  final PirateFinderMatch? match;
  final String? error;
}
