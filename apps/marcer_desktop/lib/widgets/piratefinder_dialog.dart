// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';
import 'package:url_launcher/url_launcher.dart';

import '../catalog_controller.dart';
import '../piratefinder_names.dart';
import 'piratefinder_link.dart';

/// Opens the PirateFinder details dialog for a catalog card or browse entry.
/// The catalogue is preloaded; matches use title/crew metadata.
Future<void> showPirateFinderDialog(
  BuildContext context, {
  required CatalogController controller,
  GameCard? card,
  Entry? entry,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        PirateFinderDialog(controller: controller, card: card, entry: entry),
  );
}

class PirateFinderDialog extends StatefulWidget {
  const PirateFinderDialog({
    super.key,
    required this.controller,
    this.card,
    this.entry,
  });

  final CatalogController controller;
  final GameCard? card;
  final Entry? entry;

  @override
  State<PirateFinderDialog> createState() => _PirateFinderDialogState();
}

class _PirateFinderDialogState extends State<PirateFinderDialog> {
  late final Future<_PfLookup?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_PfLookup?> _load() async {
    final data = widget.controller.pirateFinderData;
    var index = data?.index;
    index ??= await data?.ensureIndex();
    final match = widget.card != null
        ? widget.controller.pirateFinderTitleMatchForCard(widget.card!)
        : widget.controller.pirateFinderTitleMatchForEntry(widget.entry!);
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
            return _content(lookup.index!, match);
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

  Widget _content(PirateFinderIndex index, PirateFinderMatch match) {
    final candidates = match.candidates;
    final first = match.disk;
    final appearances = <int, PirateFinderDisk>{};
    final trivia = <String, ({PirateFinderTrivia trivia, String menu})>{};
    for (final candidate in candidates) {
      for (final menu in index.appearancesForDisk(candidate)) {
        appearances[menu.id] = menu;
      }
      for (final fact in index.factsForDisk(candidate)) {
        trivia['${fact.trivia.text}\u0000${fact.trivia.url}'] = (
          trivia: fact.trivia,
          menu: fact.menu.label,
        );
      }
    }
    final menus = appearances.values.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    final triviaItems = trivia.values.toList();
    return DefaultTabController(
      length: 4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(match),
          const Divider(height: 1),
          TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Release (${candidates.length})'),
              Tab(text: 'Menus (${menus.length})'),
              Tab(text: 'Trivia (${triviaItems.length})'),
              const Tab(text: 'Sources'),
            ],
          ),
          Flexible(
            child: TabBarView(
              children: [
                _scroll(_releaseTab(index, match, first)),
                _scroll(_menusTab(menus)),
                _scroll(_triviaTab(triviaItems)),
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

  Widget _header(PirateFinderMatch match) {
    final disk = match.disk;
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
                    const Flexible(
                      child: Text(
                        kPirateFinderCatalogName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
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
    PirateFinderMatch match,
    PirateFinderDisk first,
  ) {
    final series = index.seriesForDisk(first);
    final links = index.linksForDisk(first.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (first.publisher.isNotEmpty) _kv('Publisher', first.publisher),
        if (series != null) ...[
          _kv('Series', series.name),
          if (series.groupName.isNotEmpty) _kv('Group', series.groupName),
        ],
        _kv('Kind', first.kind),
        _kv('Category', first.category),
        if (first.notes.isNotEmpty) ...[
          _section('Notes'),
          SelectableText(first.notes, style: const TextStyle(fontSize: 12)),
        ],
        if (first.credits.isNotEmpty) ...[
          _section('Credits'),
          SelectableText(first.credits, style: const TextStyle(fontSize: 12)),
        ],
        if (first.menuText.isNotEmpty) ...[
          _section('Menu text'),
          SelectableText(
            first.menuText,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ],
        if (links.isNotEmpty) ...[
          _section('Links'),
          for (final link in links) _link(link.label, link.url),
        ],
        _section('Releases (${match.candidates.length})'),
        for (final candidate in match.candidates)
          _releaseEntry(index, candidate),
      ],
    );
  }

  Widget _releaseEntry(PirateFinderIndex index, PirateFinderDisk disk) {
    final crew = index.crewForDisk(disk);
    final contents = index.contentsForDisk(disk.id);
    final date = _date(disk);
    final crewName = disk.crew.isNotEmpty ? disk.crew : disk.cracker;
    final showContents =
        contents.isNotEmpty && (contents.length > 1 || disk.kind != 'single');
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
          if (crewName.isNotEmpty)
            _kv('Crew', date.isEmpty ? crewName : '$crewName ($date)')
          else if (date.isNotEmpty)
            _kv('Release date', date),
          if (crew != null) ...[
            _kv('Members', crew.members),
            _kv('History', crew.notes),
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
        ],
      ),
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
