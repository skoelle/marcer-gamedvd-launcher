// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

/// Right-panel detail for a Crews-tab card: crew metadata + the full release
/// list (no screenshots). Clicking a release opens the existing game lightbox
/// at that ZIP.
class CrewDetailPanel extends StatelessWidget {
  const CrewDetailPanel({
    super.key,
    required this.crew,
    this.pirateFinderCrew,
    this.onOpenRelease,
  });

  final CrewGroup crew;

  /// Optional PirateFinder crew info of the same group (members, history,
  /// release count, source); shown above the release list when present.
  final PirateFinderCrew? pirateFinderCrew;

  /// Opens the cracked-game card + variant for a release `rel` path.
  final void Function(String rel)? onOpenRelease;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      crew.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  _badge('${crew.zips} ZIPs', Colors.indigo),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                crew.kind == 'cracker'
                    ? 'Individual cracker · ${crew.releases.length} releases'
                    : 'Crew · ${crew.releases.length} releases',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              if (crew.aliases.length > 1) ...[
                const SizedBox(height: 6),
                Text(
                  'Also known as: ${crew.aliases.where((a) => a != crew.name).join(', ')}',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
              if (pirateFinderCrew != null) ...[
                const SizedBox(height: 8),
                _pirateFinderInfo(pirateFinderCrew!),
              ],
              const SizedBox(height: 6),
              const Text(
                'Click a release to open it in the existing lightbox.',
                style: TextStyle(fontSize: 10, color: Color(0xFF7A7A7A)),
              ),
              const SizedBox(height: 2),
              const Text(
                'Double-click the crew card for the screenshot browser.',
                style: TextStyle(fontSize: 10, color: Color(0xFF7A7A7A)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Text(
            'Releases (${crew.releases.length})',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.cyan,
            ),
          ),
        ),
        Expanded(
          child: crew.releases.isEmpty
              ? const Center(
                  child: Text(
                    'No releases',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: crew.releases.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: Color(0xFF242424)),
                  itemBuilder: (context, index) =>
                      _releaseRow(context, crew.releases[index]),
                ),
        ),
      ],
    );
  }

  /// PirateFinder crew block (members, history, release count, source) shown
  /// above the release list. No link, no `founded`, no Wikipedia.
  Widget _pirateFinderInfo(PirateFinderCrew pf) {
    final meta = <String>[
      '${pf.diskCount} releases',
      if (pf.source.isNotEmpty) pf.source,
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'PirateFinder-Catalog',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Color(0xFF9E9E9E),
            ),
          ),
          if (pf.members.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Members: ${pf.members}',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
          if (pf.notes.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              pf.notes,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Color(0xFF7A7A7A)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _releaseRow(BuildContext context, CrewRelease release) {
    final meta = <String>[
      if (release.publisher.isNotEmpty) release.publisher,
      if (release.crackedBy.isNotEmpty) 'cracker: ${release.crackedBy}',
      if (release.crew.isNotEmpty) 'crew: ${release.crew}',
      if (release.language.isNotEmpty) release.language,
    ].join(' · ');
    final flags = <Widget>[
      if (release.rawDump) _flag('RAW', Colors.lightGreen),
      if (release.pastiDump) _flag('PASTI', Colors.cyan),
      if (release.boxscan) _flag('BOX', Colors.amber),
      if (release.tosBad.isNotEmpty) _flag('TOS/Bad', Colors.deepOrange),
      if (release.ambiguous) _flag('ambiguous', Colors.orangeAccent),
      if (release.specialFlag.isNotEmpty)
        _flag(release.specialFlag, Colors.blueGrey),
    ];
    return InkWell(
      onTap: onOpenRelease == null ? null : () => onOpenRelease!(release.rel),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    release.title.isEmpty ? release.folder : release.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (release.year.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _badge(release.year, Colors.teal),
                ],
              ],
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                meta,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
            const SizedBox(height: 3),
            Row(
              children: [
                Expanded(
                  child: Text(
                    release.zip.isEmpty ? release.rel : release.zip,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF8A8A8A),
                    ),
                  ),
                ),
                if (release.disks > 0)
                  Text(
                    '${release.disks} disk${release.disks == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF8A8A8A),
                    ),
                  ),
              ],
            ),
            if (flags.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: flags),
            ],
          ],
        ),
      ),
    );
  }

  Widget _flag(String label, Color color) => Text(
    label,
    style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.w600),
  );

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
    ),
  );
}
