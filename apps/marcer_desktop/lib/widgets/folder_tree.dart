// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';
import '../theme.dart';

class _Node {
  _Node({required this.rel, required this.entry});
  final String rel;
  final Entry entry;
}

/// Left panel: overlay folder tree (SPEC §7 merge, lazy expansion).
/// Mouse-driven; the tree auto-follows the current navigation path.
class FolderTree extends StatefulWidget {
  const FolderTree({super.key, required this.controller});

  final CatalogController controller;

  @override
  State<FolderTree> createState() => _FolderTreeState();
}

class _FolderTreeState extends State<FolderTree> {
  final Set<String> _expanded = {};
  String? _pendingFollow;

  @override
  void initState() {
    super.initState();
    _followCurrentPath();
  }

  @override
  void didUpdateWidget(FolderTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    _followCurrentPath();
  }

  void _followCurrentPath() {
    final rel = widget.controller.currentRel;
    if (rel.startsWith(kFavoritesRelPrefix) || rel.isEmpty) return;
    if (_pendingFollow == rel) return;
    _pendingFollow = rel;
    final parts = rel.split('/');
    var acc = '';
    _expanded.add('');
    for (final part in parts) {
      acc = acc.isEmpty ? part : '$acc/$part';
      _expanded.add(acc);
    }
  }

  void _flatten(String rel, int depth, List<Widget> out) {
    final c = widget.controller;
    final children = <_Node>[];
    if (rel.isEmpty && c.showFavoritesFolder) {
      for (final entry in c.virtualFavoritesEntries) {
        final favRel = c.favoritesRelForEntry(entry);
        if (favRel != null) {
          children.add(_Node(rel: favRel, entry: entry));
        }
      }
    }
    children.addAll(c.childrenOf(rel).map((e) => _Node(rel: rel.isEmpty ? e.name : '$rel/${e.name}', entry: e)));

    for (final node in children) {
      final isFav = node.entry.isVirtual;
      final selected = node.rel == c.currentRel;
      final expandable = node.entry.kind == EntryKind.directory && !isFav;
      final isExpanded = _expanded.contains(node.rel);
      out.add(
        InkWell(
          onTap: () => c.setPath(node.rel),
          child: Container(
            height: 24,
            color: selected ? kSelectedBackground : Colors.transparent,
            padding: EdgeInsets.only(left: 4.0 + depth * 14),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: expandable
                      ? InkWell(
                          onTap: () => setState(() {
                            isExpanded
                                ? _expanded.remove(node.rel)
                                : _expanded.add(node.rel);
                          }),
                          child: Icon(
                            isExpanded
                                ? Icons.arrow_drop_down
                                : Icons.arrow_right,
                            size: 18,
                          ),
                        )
                      : null,
                ),
                Icon(
                  isFav ? Icons.star
                      : Icons.folder,
                  size: 14,
                  color: colorForEntry(node.entry),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    node.entry.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected
                          ? kSelectedForeground
                          : colorForEntry(node.entry),
                    ),
                  ),
                ),
                Text(
                  node.entry.isVirtual ? '' : _shortLayer(node.entry),
                  style: TextStyle(
                    fontSize: 9,
                    color: selected
                        ? kSelectedForeground.withValues(alpha: 0.8)
                        : Colors.grey.shade600,
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      );
      if (expandable && isExpanded) {
        _flatten(node.rel, depth + 1, out);
      }
    }
  }

  static String _shortLayer(Entry e) {
    switch (e.layerStatus) {
      case LayerStatus.both:
        return 'BOTH';
      case LayerStatus.root:
        return 'ROOT';
      case LayerStatus.patch:
        return 'PTCH';
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    _flatten('', 0, rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: Text('Folders',
              style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                  fontWeight: FontWeight.bold)),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: rows.isEmpty
                ? [
                    const Padding(
                      padding: EdgeInsets.all(10),
                      child: Text('No folders',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    )
                  ]
                : rows,
          ),
        ),
      ],
    );
  }
}
