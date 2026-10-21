// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';

import '../local_assets.dart';
import 'local_assets_dialog.dart';

/// Clickable `Box scans (N)` / `Manuals (N)` chips for a catalog card.
///
/// Resolves the lazily discovered [assets] future; renders nothing until the
/// discovery finished (or when the game has neither folder).
class LocalAssetsChips extends StatelessWidget {
  const LocalAssetsChips({
    super.key,
    required this.assets,
    required this.service,
  });

  final Future<LocalGameAssets> assets;
  final LocalAssetsService service;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LocalGameAssets>(
      key: ObjectKey(assets),
      future: assets,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null || data.isEmpty) return const SizedBox.shrink();
        return Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            if (data.boxscans.isNotEmpty)
              _chip(
                context,
                icon: Icons.photo_library_outlined,
                label: 'Box scans (${data.boxscanImageCount})',
                color: const Color(0xFF2BE0E0),
                onTap: () =>
                    showBoxscanGallery(context, assets: data, service: service),
              ),
            if (data.manuals.isNotEmpty)
              _chip(
                context,
                icon: Icons.menu_book_outlined,
                label: 'Manuals (${data.manuals.length})',
                color: Colors.amber,
                onTap: () =>
                    showManualDialog(context, assets: data, service: service),
              ),
          ],
        );
      },
    );
  }

  Widget _chip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 28,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1B1B),
              border: Border.all(color: const Color(0xFF3A3A3A)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
