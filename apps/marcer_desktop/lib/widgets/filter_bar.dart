// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';

import '../catalog_controller.dart';

/// Top filter bar: quick search + dropdowns (desktop-only feature per plan).
class FilterBar extends StatelessWidget {
  const FilterBar({super.key, required this.controller});

  final CatalogController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Material(
      color: const Color(0xFF1B1B1B),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 260,
              child: TextField(
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search name / title / publisher…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: c.setQuery,
              ),
            ),
            const SizedBox(width: 12),
            _dropdown('Layer', c.layerFilter, const ['ALL', 'BOTH', 'ROOT', 'PTCH'],
                c.setLayerFilter),
            const SizedBox(width: 12),
            _dropdown('Screenshots', c.shotsFilter,
                const ['ALL', 'WITH', 'WITHOUT'], c.setShotsFilter),
            const SizedBox(width: 12),
            if (c.publisherOptions.isNotEmpty)
              _dropdown('Publisher', c.publisherFilter,
                  ['ALL', ...c.publisherOptions], c.setPublisherFilter,
                  width: 190),
            if (c.yearOptions.isNotEmpty) ...[
              const SizedBox(width: 12),
              _dropdown('Year', c.yearFilter, ['ALL', ...c.yearOptions],
                  c.setYearFilter,
                  width: 110),
            ],
            const Spacer(),
            Text(
              '${c.entryCount} entries',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dropdown(
    String label,
    String value,
    List<String> items,
    ValueChanged<String> onChanged, {
    double width = 140,
  }) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        key: ValueKey('$label:$value'),
        initialValue: items.contains(value) ? value : items.first,
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontSize: 11),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
        style: const TextStyle(fontSize: 13, color: Colors.white),
        items: items
            .map((e) => DropdownMenuItem(
                value: e,
                child: Text(e, overflow: TextOverflow.ellipsis)))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}
