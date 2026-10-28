// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

/// Crew metadata block shared by the Crews-tab detail sidebar and the crew
/// release browser sidebar (name, ZIP/release counts, aliases, PirateFinder
/// info).
class CrewOverview extends StatelessWidget {
  const CrewOverview({
    super.key,
    required this.crew,
    this.pirateFinderCrew,
    this.onOpenPirateFinder,
    this.showHints = false,
  });

  final CrewGroup crew;

  /// Optional PirateFinder crew info of the same group (members, history,
  /// release count, source); shown below the aliases when present.
  final PirateFinderCrew? pirateFinderCrew;

  /// Opens the full PirateFinder-Catalog crew lightbox (the `More` action).
  final VoidCallback? onOpenPirateFinder;

  /// Shows the crew-tab usage hints (release click / double-click).
  final bool showHints;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
          if (showHints) ...[
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
        ],
      ),
    );
  }

  /// PirateFinder crew block (members, history, release count, source). No
  /// link, no `founded`, no Wikipedia.
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
          Row(
            children: [
              const Expanded(
                child: Text(
                  'PirateFinder-Catalog',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF9E9E9E),
                  ),
                ),
              ),
              if (onOpenPirateFinder != null)
                TextButton(
                  onPressed: onOpenPirateFinder,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: Colors.lightBlueAccent,
                  ),
                  child: const Text('More', style: TextStyle(fontSize: 10)),
                ),
            ],
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
