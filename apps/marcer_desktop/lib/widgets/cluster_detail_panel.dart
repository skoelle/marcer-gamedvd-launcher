// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

/// Right-panel detail for a Clusters-tab card: type, counts, roots,
/// overlaps, cross-cluster links and the status legend.
class ClusterDetailPanel extends StatelessWidget {
  const ClusterDetailPanel({
    super.key,
    required this.cluster,
    this.onOpenCluster,
  });

  final CrewCluster cluster;

  /// Opens the full cluster browser (tree view).
  final VoidCallback? onOpenCluster;

  @override
  Widget build(BuildContext context) {
    final counts = cluster.counts;
    final crossEdges =
        cluster.edges.where((edge) => edge.crossCluster).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                cluster.name,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            _badge(
              cluster.isIndependent ? 'independent' : 'umbrella',
              cluster.isIndependent ? Colors.purpleAccent : Colors.green,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${counts.groups} groups · ${counts.zips} ZIPs · '
          '${counts.top} TOP',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        if (cluster.roots.isNotEmpty) ...[
          const SizedBox(height: 8),
          _row('Root', cluster.roots.join(' · ')),
        ],
        _row('Group ZIPs', '${counts.groupZips}'),
        _row('Member ZIPs', '${counts.memberZips}'),
        _row('TOP', '${counts.top}'),
        _row('Non-TOP', '${counts.excluded}'),
        _row('Ambiguous', '${counts.ambiguous}'),
        _row('External', '${counts.external}'),
        _row('Members', '${counts.members}'),
        _row('Links', '${cluster.edges.length}'),
        if (crossEdges.isNotEmpty)
          _row('Cross-cluster links', '${crossEdges.length}'),
        if (onOpenCluster != null) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onOpenCluster,
              child: const Text('Open cluster browser'),
            ),
          ),
        ],
        if (cluster.overlaps.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text(
            'Overlaps',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.cyan,
            ),
          ),
          const SizedBox(height: 4),
          for (final group in cluster.overlaps)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${group.name} · ${group.clusters.join(', ')}',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
        ],
        if (crossEdges.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text(
            'Cross-cluster links',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.cyan,
            ),
          ),
          const SizedBox(height: 4),
          for (final edge in crossEdges)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${edge.from} → ${edge.to}',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
        ],
        const SizedBox(height: 12),
        const Text(
          'TOP = curated local group · Non-TOP = local outside the TOP '
          'selection · external = no local ZIP data',
          style: TextStyle(fontSize: 10, color: Color(0xFF7A7A7A)),
        ),
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 112,
              child: Text(
                label,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      );

  Widget _badge(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}
