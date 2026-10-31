// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';
import 'close_button.dart';
import 'cluster_detail_panel.dart';

/// Full cluster browser: nested subgroup tree with previews on the left, the
/// cluster summary on the right. Local crews open the crew release browser.
class ClusterLightbox extends StatefulWidget {
  const ClusterLightbox({
    super.key,
    required this.controller,
    required this.cluster,
    this.onOpenCrew,
  });

  final CatalogController controller;
  final CrewCluster cluster;

  /// Opens the crew release browser for a local tree node/member.
  final void Function(CrewGroup crew)? onOpenCrew;

  static Future<void> show(
    BuildContext context,
    CatalogController controller,
    CrewCluster cluster, {
    void Function(CrewGroup crew)? onOpenCrew,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black87,
      builder: (_) => ClusterLightbox(
        controller: controller,
        cluster: cluster,
        onOpenCrew: onOpenCrew,
      ),
    );
  }

  @override
  State<ClusterLightbox> createState() => _ClusterLightboxState();
}

class _ClusterLightboxState extends State<ClusterLightbox> {
  static const double _sidebarWidth = 360;
  final FocusNode _focus = FocusNode(debugLabel: 'cluster-lightbox');
  bool _showExternal = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  int get _hiddenExternalCount {
    final tree = widget.cluster.tree;
    if (tree == null) return 0;
    return _countHidden(tree, parentVisible: true);
  }

  int _countHidden(CrewClusterNode node, {required bool parentVisible}) {
    final visible = parentVisible && _nodeVisible(node);
    var hidden = visible ? 0 : 1;
    for (final child in node.children) {
      hidden += _countHidden(child, parentVisible: visible);
    }
    return hidden;
  }

  bool _hasLocalDescendant(CrewClusterNode node) => node.children.any(
        (child) => child.isLocal || _hasLocalDescendant(child),
      );

  bool _nodeVisible(CrewClusterNode node) =>
      _showExternal || node.isLocal || _hasLocalDescendant(node);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openCrew(String localId) {
    final group = widget.controller.crewForLocalId(localId);
    if (group == null) return;
    Navigator.of(context).maybePop();
    widget.onOpenCrew?.call(group);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = math.min(size.width - 48, 1400.0);
    final height = math.max(360.0, size.height - 48);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF0D0D0D),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2A2A2A)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _onKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                const Divider(height: 1),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _tree(context)),
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: _sidebarWidth,
                        child: ClusterDetailPanel(cluster: widget.cluster),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  color: const Color(0xFF141414),
                  child: const Text(
                    'Click a local crew to open its releases   Esc close',
                    style: TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final cluster = widget.cluster;
    final counts = cluster.counts;
    final hidden = _hiddenExternalCount;
    final sub = <String>[
      cluster.isIndependent ? 'Independent' : 'Umbrella',
      '${counts.groups} groups',
      '${counts.zips} ZIPs',
      '${counts.top} TOP',
      '${cluster.edges.length} links',
      if (!_showExternal && hidden > 0) '$hidden external hidden',
    ].join(' · ');
    return Container(
      color: const Color(0xFF1B1B1B),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cluster.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  sub,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
          ),
          if (_hiddenExternalCount > 0)
            TextButton(
              onPressed: () =>
                  setState(() => _showExternal = !_showExternal),
              child: Text(
                _showExternal ? 'Hide external' : 'Show external',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          const SizedBox(width: 8),
          DialogCloseButton(onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }

  Widget _tree(BuildContext context) {
    final tree = widget.cluster.tree;
    if (tree == null) {
      return const Center(
        child: Text('No cluster tree', style: TextStyle(color: Colors.grey)),
      );
    }
    final otherParents = _otherParents();
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        if (_nodeVisible(tree))
          ..._nodeRows(tree, 0, parentName: null, otherParents: otherParents),
      ],
    );
  }

  Map<String, List<String>> _otherParents() {
    final out = <String, List<String>>{};
    for (final edge in widget.cluster.edges) {
      out.putIfAbsent(edge.from, () => <String>[]);
      if (!out[edge.from]!.contains(edge.to)) out[edge.from]!.add(edge.to);
    }
    return out;
  }

  List<Widget> _nodeRows(
    CrewClusterNode node,
    int depth, {
    required String? parentName,
    required Map<String, List<String>> otherParents,
  }) {
    final rows = <Widget>[
      _nodeRow(node, depth, parentName: parentName, otherParents: otherParents),
    ];
    for (final child in node.children) {
      if (!_nodeVisible(child)) continue;
      rows.addAll(
        _nodeRows(
          child,
          depth + 1,
          parentName: node.name,
          otherParents: otherParents,
        ),
      );
    }
    if (_showExternal || node.isLocal) {
      for (final member in node.members) {
        if (!_showExternal && member.localId == null) continue;
        rows.add(_memberRow(member, depth + 1));
      }
    }
    return rows;
  }

  Widget _nodeRow(
    CrewClusterNode node,
    int depth, {
    required String? parentName,
    required Map<String, List<String>> otherParents,
  }) {
    final other = (otherParents[node.name] ?? const [])
        .where((name) => name != parentName)
        .toList();
    final isLocal = node.isLocal;
    final title = isLocal
        ? InkWell(
            onTap: () => _openCrew(node.localId!),
            child: Text(
              node.name,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.lightBlueAccent,
                decoration: TextDecoration.underline,
              ),
            ),
          )
        : Text(node.name, style: const TextStyle(fontSize: 12));
    return Padding(
      padding: EdgeInsets.fromLTRB(10.0 + depth * 18, 4, 10, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _thumb(
            node.localId,
            onTap: isLocal ? () => _openCrew(node.localId!) : null,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _statusBadge(node.status),
                    const SizedBox(width: 6),
                    Flexible(child: title),
                    if (isLocal) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${node.zips} ZIPs',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ],
                ),
                if (other.isNotEmpty)
                  Text(
                    'also subgroup of ${other.join(' · ')}',
                    style: const TextStyle(
                      fontSize: 9,
                      color: Color(0xFF8A8A8A),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _memberRow(CrewClusterMember member, int depth) {
    final local = member.localId;
    final title = local == null
        ? Text(member.name, style: const TextStyle(fontSize: 11))
        : InkWell(
            onTap: () => _openCrew(local),
            child: Text(
              member.name,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.lightBlueAccent,
                decoration: TextDecoration.underline,
              ),
            ),
          );
    return Padding(
      padding: EdgeInsets.fromLTRB(10.0 + depth * 18, 3, 10, 3),
      child: Row(
        children: [
          _thumb(local, onTap: local == null ? null : () => _openCrew(local)),
          const SizedBox(width: 8),
          _statusBadge('member'),
          const SizedBox(width: 6),
          Flexible(child: title),
          const SizedBox(width: 6),
          if (member.zips > 0)
            Text(
              '${member.zips} ZIPs',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          if (member.current) ...[
            const SizedBox(width: 6),
            const Text(
              'current',
              style: TextStyle(fontSize: 9, color: Colors.tealAccent),
            ),
          ],
        ],
      ),
    );
  }

  Widget _thumb(String? localId, {VoidCallback? onTap}) {
    final path = localId == null
        ? null
        : widget.controller.previewForLocalCrewId(localId);
    final image = Container(
      width: 100,
      height: 62,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      clipBehavior: Clip.antiAlias,
      child: path != null
          ? Image.file(
              File(path),
              key: ValueKey(
                '$path#${widget.controller.imageVersionOf(path)}',
              ),
              fit: BoxFit.cover,
              cacheWidth: 200,
              errorBuilder: (_, _, _) => _extPlaceholder(),
            )
          : _extPlaceholder(),
    );
    if (onTap == null) return image;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: image),
    );
  }

  Widget _extPlaceholder() => const Center(
        child: Text(
          'EXT',
          style: TextStyle(fontSize: 10, color: Color(0xFF6E6E6E)),
        ),
      );

  Widget _statusBadge(String status) {
    final (label, color) = switch (status) {
      'top' => ('TOP', Colors.greenAccent),
      'excluded' => ('Non-TOP', Colors.orangeAccent),
      'external' => ('external', Colors.blueGrey),
      'ambiguous' => ('ambiguous', Colors.orange),
      'member' => ('member', Colors.cyanAccent),
      _ => (status, Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
