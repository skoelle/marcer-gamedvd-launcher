// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:convert';
import 'dart:io';

/// Aggregate counters of one crew cluster (`crew-cluster.json`).
class CrewClusterCounts {
  const CrewClusterCounts({
    this.groups = 0,
    this.top = 0,
    this.excluded = 0,
    this.ambiguous = 0,
    this.external = 0,
    this.members = 0,
    this.groupZips = 0,
    this.zips = 0,
    this.memberZips = 0,
  });

  factory CrewClusterCounts.fromJson(Map<String, dynamic> json) {
    int integer(String key) => (json[key] as num?)?.toInt() ?? 0;
    return CrewClusterCounts(
      groups: integer('groups'),
      top: integer('top'),
      excluded: integer('excluded'),
      ambiguous: integer('ambiguous'),
      external: integer('external'),
      members: integer('members'),
      groupZips: integer('group_zips'),
      zips: integer('zips'),
      memberZips: integer('member_zips'),
    );
  }

  final int groups;
  final int top;
  final int excluded;
  final int ambiguous;
  final int external;
  final int members;
  final int groupZips;
  final int zips;
  final int memberZips;
}

/// One group entry of a cluster (the flat list used for cards/overlaps).
class CrewClusterGroup {
  const CrewClusterGroup({
    required this.name,
    required this.status,
    required this.zips,
    required this.clusters,
    this.localId,
  });

  factory CrewClusterGroup.fromJson(Map<String, dynamic> json) {
    String str(String key) => (json[key] ?? '').toString().trim();
    return CrewClusterGroup(
      name: str('name'),
      localId: str('local_id').isEmpty ? null : str('local_id'),
      status: str('status'),
      zips: (json['zips'] as num?)?.toInt() ?? 0,
      clusters: ((json['clusters'] as List<dynamic>?) ?? const [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(),
    );
  }

  final String name;
  final String? localId;
  final String status;
  final int zips;
  final List<String> clusters;

  bool get isLocal => localId != null && localId!.isNotEmpty;

  /// Gallery status label (`TOP`, `Non-TOP`, …).
  String get statusLabel => switch (status) {
        'top' => 'TOP',
        'excluded' => 'Non-TOP',
        'external' => 'external',
        'ambiguous' => 'ambiguous',
        _ => status,
      };
}

/// A person label attached to a crew node (not a subgroup edge).
class CrewClusterMember {
  const CrewClusterMember({
    required this.name,
    required this.zips,
    required this.current,
    this.localId,
  });

  factory CrewClusterMember.fromJson(Map<String, dynamic> json) => CrewClusterMember(
        name: (json['name'] ?? '').toString(),
        localId: (json['local_id'] ?? '').toString().trim().isEmpty
            ? null
            : (json['local_id'] ?? '').toString().trim(),
        zips: (json['zips'] as num?)?.toInt() ?? 0,
        current: json['current'] == true,
      );

  final String name;
  final String? localId;
  final int zips;
  final bool current;
}

/// Nested spanning-tree node of one cluster.
class CrewClusterNode {
  const CrewClusterNode({
    required this.name,
    required this.status,
    required this.zips,
    required this.children,
    required this.members,
    this.localId,
    this.manual = false,
    this.kind = '',
  });

  factory CrewClusterNode.fromJson(Map<String, dynamic> json) {
    String str(String key) => (json[key] ?? '').toString().trim();
    return CrewClusterNode(
      name: str('name'),
      localId: str('local_id').isEmpty ? null : str('local_id'),
      status: str('status'),
      zips: (json['zips'] as num?)?.toInt() ?? 0,
      manual: json['manual'] == true,
      kind: str('kind'),
      children: ((json['children'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CrewClusterNode.fromJson)
          .toList(),
      members: ((json['members'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CrewClusterMember.fromJson)
          .toList(),
    );
  }

  final String name;
  final String? localId;
  final String status;
  final int zips;
  final bool manual;
  final String kind;
  final List<CrewClusterNode> children;
  final List<CrewClusterMember> members;

  bool get isLocal => localId != null && localId!.isNotEmpty;

  String get statusLabel => switch (status) {
        'top' => 'TOP',
        'excluded' => 'Non-TOP',
        'external' => 'external',
        'ambiguous' => 'ambiguous',
        _ => status,
      };
}

/// Global subgroup edge (`from` is the child, `to` the parent).
class CrewClusterEdge {
  const CrewClusterEdge({
    required this.from,
    required this.to,
    required this.type,
    required this.current,
    required this.clusters,
    required this.crossCluster,
  });

  factory CrewClusterEdge.fromJson(Map<String, dynamic> json) => CrewClusterEdge(
        from: (json['from'] ?? '').toString(),
        to: (json['to'] ?? '').toString(),
        type: (json['type'] ?? '').toString(),
        current: json['current'] == true,
        clusters: ((json['clusters'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        crossCluster: json['cross_cluster'] == true,
      );

  final String from;
  final String to;
  final String type;
  final bool current;
  final List<String> clusters;
  final bool crossCluster;
}

/// One crew/group cluster.
class CrewCluster {
  const CrewCluster({
    required this.id,
    required this.name,
    required this.kind,
    required this.roots,
    required this.counts,
    required this.groups,
    required this.edges,
    required this.tree,
    this.previewLocalId,
  });

  factory CrewCluster.fromJson(
    Map<String, dynamic> json, {
    List<CrewClusterEdge> globalEdges = const [],
    CrewClusterNode? tree,
  }) {
    String str(String key) => (json[key] ?? '').toString().trim();
    final id = str('id');
    final clusterEdges = ((json['edges'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(CrewClusterEdge.fromJson)
        .toList();
    return CrewCluster(
      id: id,
      name: str('name'),
      kind: str('kind'),
      roots: ((json['roots'] as List<dynamic>?) ?? const [])
          .map((e) => e is Map<String, dynamic>
              ? (e['name'] ?? '').toString()
              : e.toString())
          .where((e) => e.isNotEmpty)
          .toList(),
      counts: CrewClusterCounts.fromJson(
        (json['counts'] as Map<String, dynamic>?) ?? const {},
      ),
      groups: ((json['groups'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CrewClusterGroup.fromJson)
          .toList(),
      edges: clusterEdges.isNotEmpty
          ? clusterEdges
          : globalEdges
              .where((edge) => edge.clusters.contains(id))
              .toList(),
      tree: tree,
      previewLocalId: str('preview_local_id').isEmpty
          ? null
          : str('preview_local_id'),
    );
  }

  final String id;
  final String name;

  /// `umbrella` (contains a local group descendant) or `independent`.
  final String kind;
  final List<String> roots;
  final CrewClusterCounts counts;
  final List<CrewClusterGroup> groups;
  final List<CrewClusterEdge> edges;
  final CrewClusterNode? tree;
  final String? previewLocalId;

  bool get isIndependent => kind == 'independent';

  /// Groups in more than one cluster (overlap list).
  List<CrewClusterGroup> get overlaps =>
      groups.where((g) => g.clusters.length > 1).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// One membership/parent relation of a [CrewEntity].
class CrewEntityLink {
  const CrewEntityLink({required this.name, required this.current});

  factory CrewEntityLink.fromJson(Map<String, dynamic> json) => CrewEntityLink(
        name: (json['name'] ?? '').toString(),
        current: json['current'] == true,
      );

  final String name;
  final bool current;
}

/// Cracker/group membership data from `crew-cluster.json` `entities{}`.
class CrewEntity {
  const CrewEntity({
    required this.name,
    required this.kind,
    required this.status,
    required this.memberships,
    required this.parents,
    required this.subgroupCount,
    required this.descendantCount,
    required this.candidateCount,
  });

  factory CrewEntity.fromJson(Map<String, dynamic> json) {
    String str(String key) => (json[key] ?? '').toString().trim();
    List<CrewEntityLink> links(String key) =>
        ((json[key] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(CrewEntityLink.fromJson)
            .toList();
    return CrewEntity(
      name: str('name'),
      kind: str('kind'),
      status: str('status'),
      memberships: links('memberships'),
      parents: links('parents'),
      subgroupCount: (json['subgroup_count'] as num?)?.toInt() ?? 0,
      descendantCount: (json['descendant_count'] as num?)?.toInt() ?? 0,
      candidateCount: (json['candidate_count'] as num?)?.toInt() ?? 0,
    );
  }

  final String name;
  final String kind;
  final String status;
  final List<CrewEntityLink> memberships;
  final List<CrewEntityLink> parents;
  final int subgroupCount;
  final int descendantCount;
  final int candidateCount;

  /// Gallery `entitySummary`: parent groups / subgroups for resolved group
  /// entities, memberships for resolved persons, match hints otherwise.
  String get summary {
    if (status == 'resolved' && kind == 'group') {
      final parts = <String>[];
      if (parents.isNotEmpty) {
        parts.add(
          'Parent groups: ${parents.map((p) => '${p.name}${p.current ? ' (current)' : ''}').join(' · ')}',
        );
      }
      if (subgroupCount > 0) parts.add('Subgroups: $subgroupCount');
      return parts.isEmpty ? 'Parent groups / subgroups: none' : parts.join(' · ');
    }
    if (status == 'resolved') {
      if (memberships.isEmpty) return 'Memberships: none known';
      return 'Memberships: ${memberships.map((m) => '${m.name}${m.current ? ' (current)' : ''}').join(' · ')}';
    }
    if (status == 'ambiguous') {
      return 'Matching: ambiguous ($candidateCount matches)';
    }
    if (status == 'joint') return 'Matching: joint label';
    return 'Matching: none known';
  }
}

/// `crew-cluster.json` loader. Missing/unreadable data degrades to an empty
/// index with [loadError] set (the Clusters tab is hidden then).
class CrewClusterIndex {
  CrewClusterIndex._(
    this.clusters,
    this.entities,
    this._byId,
    this._byCrewId,
    this.loadError,
    this.generatedAt,
  );

  factory CrewClusterIndex.load(String gameinfoDir) {
    if (gameinfoDir.trim().isEmpty) {
      return CrewClusterIndex._(
        const [],
        const {},
        const {},
        const {},
        'GameinfoDirectory not configured',
        '',
      );
    }
    final file = File('$gameinfoDir/crew-cluster.json');
    if (!file.existsSync()) {
      return CrewClusterIndex._(
        const [],
        const {},
        const {},
        const {},
        'crew-cluster.json not found',
        '',
      );
    }
    try {
      final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final globalEdges = ((map['edges'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CrewClusterEdge.fromJson)
          .toList();
      final trees = (map['trees'] as Map<String, dynamic>?) ?? const {};
      final clusters = ((map['clusters'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((json) {
            final id = (json['id'] ?? '').toString();
            final rawTree = trees[id];
            return CrewCluster.fromJson(
              json,
              globalEdges: globalEdges,
              tree: rawTree is Map<String, dynamic>
                  ? CrewClusterNode.fromJson(rawTree)
                  : null,
            );
          })
          .where((c) => c.id.isNotEmpty && c.name.isNotEmpty)
          .toList();
      final entitiesJson =
          (map['entities'] as Map<String, dynamic>?) ?? const {};
      final entities = <String, CrewEntity>{};
      entitiesJson.forEach((key, value) {
        if (value is! Map<String, dynamic>) return;
        entities[key.trim().toLowerCase()] = CrewEntity.fromJson(value);
      });
      final byId = {for (final cluster in clusters) cluster.id: cluster};
      final byCrewId = <String, List<CrewCluster>>{};
      for (final cluster in clusters) {
        for (final group in cluster.groups) {
          final id = group.localId;
          if (id == null || id.isEmpty) continue;
          _appendCluster(byCrewId, id, cluster);
        }
        final tree = cluster.tree;
        if (tree != null) _collectTreeClusters(tree, cluster, byCrewId);
      }
      return CrewClusterIndex._(
        clusters,
        entities,
        byId,
        byCrewId,
        clusters.isEmpty ? 'no clusters in file' : null,
        (map['generated_at'] ?? '').toString(),
      );
    } catch (e) {
      return CrewClusterIndex._(
        const [],
        const {},
        const {},
        const {},
        'parse error: $e',
        '',
      );
    }
  }

  static void _collectTreeClusters(
    CrewClusterNode node,
    CrewCluster cluster,
    Map<String, List<CrewCluster>> out,
  ) {
    if (node.localId != null && node.localId!.isNotEmpty) {
      _appendCluster(out, node.localId!, cluster);
    }
    for (final member in node.members) {
      if (member.localId != null && member.localId!.isNotEmpty) {
        _appendCluster(out, member.localId!, cluster);
      }
    }
    for (final child in node.children) {
      _collectTreeClusters(child, cluster, out);
    }
  }

  static void _appendCluster(
    Map<String, List<CrewCluster>> out,
    String crewId,
    CrewCluster cluster,
  ) {
    final list = out.putIfAbsent(crewId, () => <CrewCluster>[]);
    if (!list.any((c) => c.id == cluster.id)) list.add(cluster);
  }

  static CrewClusterIndex empty(String reason) =>
      CrewClusterIndex._(const [], const {}, const {}, const {}, reason, '');

  final List<CrewCluster> clusters;
  final Map<String, CrewEntity> entities;
  final Map<String, CrewCluster> _byId;
  final Map<String, List<CrewCluster>> _byCrewId;
  final String? loadError;
  final String generatedAt;

  int get length => clusters.length;
  bool get hasData => clusters.isNotEmpty;

  CrewCluster? clusterFor(String id) => _byId[id];

  /// Every cluster containing [crewId] (direct group, tree node or member).
  List<CrewCluster> clustersForCrew(String crewId) =>
      _byCrewId[crewId] ?? const [];

  CrewEntity? entityFor(String crewId) =>
      entities[crewId.trim().toLowerCase()];
}
