// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';
import 'game_info_panel.dart';

/// Right panel: preview screenshot + game metadata (Playnite-style detail).
class DetailPanel extends StatelessWidget {
  const DetailPanel({super.key, required this.controller});

  final CatalogController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.catalogMode) {
      final card = c.selectedCard;
      return Container(
        color: const Color(0xFF161616),
        child: card == null
            ? const Center(
                child: Text('No selection',
                    style: TextStyle(color: Colors.grey, fontSize: 13)))
            : _cardInfo(c, card),
      );
    }
    final entry = c.selectedEntry;
    return Container(
      color: const Color(0xFF161616),
      child: entry == null
          ? const Center(
              child: Text('No selection',
                  style: TextStyle(color: Colors.grey, fontSize: 13)))
          : entry.kind == EntryKind.directory
              ? _directoryInfo(c, entry)
              : _zipInfo(c, entry),
    );
  }

  Widget _cardInfo(CatalogController c, GameCard card) {
    // Gallery-style detail (no large preview — the lightbox shows the image).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(card.name,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (card.layer.isNotEmpty)
                    _badge(card.layer, _layerColorName(card.layer)),
                  if (card.displayStatus.isNotEmpty)
                    _badge(card.displayStatus, Colors.blueGrey),
                  if (card.year != 'unknown') _badge(card.year, Colors.teal),
                  if (card.variants.length > 1)
                    _badge('${card.variants.length} variants', Colors.indigo),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: GameInfoPanel(
            info: card.info,
            variant: _primaryVariant(card),
            filter: c.filter,
            onPlay: () => c.launchSelected(),
          ),
        ),
      ],
    );
  }

  /// The ZIP shown in the "This ZIP" table: the crew/cracker-focused variant
  /// when a focus filter is active, else the variant that produced the card's
  /// primary preview, else the first variant.
  ZipVariantView? _primaryVariant(GameCard card) {
    if (card.variants.isEmpty) return null;
    var idx = (card.focusVariant ?? -1) >= 0 ? card.focusVariant! : -1;
    if (idx < 0 && card.previewPath != null) {
      final match = card.variants
          .indexWhere((v) => v.previewPath == card.previewPath);
      if (match >= 0) idx = match;
    }
    if (idx < 0) idx = 0;
    final v = card.variants[idx];
    return ZipVariantView(
      name: v.name,
      status: v.status,
      layer: v.layer,
      rel: v.rel,
      size: v.size,
    );
  }

  Color _layerColorName(String layer) => switch (layer) {
        'BOTH' => Colors.green,
        'PTCH' => Colors.pink,
        _ => Colors.lightGreen,
      };

  Widget _directoryInfo(CatalogController c, Entry e) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Row(children: [
          const Icon(Icons.folder, size: 36, color: Colors.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(e.name,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
        ]),
        const SizedBox(height: 12),
        _badges(c, e),
        const SizedBox(height: 12),
        _kv('Type', e.isVirtual ? 'Virtual folder' : 'Directory'),
        _kv('Layer', e.layerStatus.name.toUpperCase()),
        if (!e.isVirtual) _kv('Path', e.effectivePath ?? ''),
      ],
    );
  }

  Widget _zipInfo(CatalogController c, Entry e) {
    final preview = c.previewPathFor(e);
    final candidates = c.candidatePathsFor(e);
    final info = c.infoFor(e);
    final shots = c.screenshotFor(e);

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            height: 220,
            color: Colors.black,
            child: preview != null
                ? Image.file(
                    File(preview),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        _noPreview('Failed to load $preview'),
                  )
                : _noPreview('No screenshot'),
          ),
        ),
        if (candidates.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: candidates
                  .map((path) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Image.file(File(path),
                            height: 56,
                            errorBuilder: (_, _, _) =>
                                const SizedBox(width: 56)),
                      ))
                  .toList(),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(c.titleFor(e),
            style:
                const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        _badges(c, e),
        const SizedBox(height: 12),
        if (info == null)
          const Text('No metadata for this entry',
              style: TextStyle(color: Colors.grey, fontSize: 12))
        else
          ..._metadataRows(c, info, shots),
        const SizedBox(height: 12),
        _kv('Layer', e.layerStatus.name.toUpperCase()),
        _kv('Path', e.effectivePath ?? ''),
        if (e.inPatch && e.inRoot)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('Launching would use the patch copy (SPEC R14)',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ),
      ],
    );
  }

  Widget _noPreview(String text) {
    return Center(
        child: Text(text,
            style: const TextStyle(color: Colors.grey, fontSize: 13)));
  }

  Widget _badges(CatalogController c, Entry e) {
    final badges = <Widget>[];
    badges.add(_badge(e.layerStatus.name.toUpperCase(), _layerColor(e)));
    final shots = c.screenshotFor(e);
    if (shots != null) {
      badges.add(_badge(shots.status, Colors.blueGrey));
    }
    final section = c.sectionOf(e);
    if (section.isNotEmpty) badges.add(_badge(section, Colors.teal));
    if (c.isFavorite(e)) badges.add(_badge('FAVORITE', Colors.amber));
    return Wrap(spacing: 6, runSpacing: 6, children: badges);
  }

  Color _layerColor(Entry e) => switch (e.layerStatus) {
        LayerStatus.both => Colors.green,
        LayerStatus.root => Colors.lightGreen,
        LayerStatus.patch => Colors.pink,
      };

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.25),
          border: Border.all(color: color.withValues(alpha: 0.7)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 10, color: color.withValues(alpha: 1))),
      );

  List<Widget> _metadataRows(
      CatalogController c, GameInfo info, ScreenshotEntry? shots) {
    final rows = <Widget>[
      _kv('Matched via', info.matchedVia),
      if (info.variants.length > 1) _kv('Variants', '${info.variants.length}'),
      ..._metadataRowsFromVariants(info.variants, skipVariantsCount: true),
    ];
    if (shots != null && shots.zipContents.isNotEmpty) {
      rows.add(_kv('ZIP contents', '${shots.zipContents.length} files'));
    }
    return rows;
  }

  List<Widget> _metadataRowsFromVariants(List<Map<String, dynamic>> variants,
      {bool skipVariantsCount = false}) {
    final v = variants.isEmpty ? const <String, dynamic>{} : variants.first;
    final rows = <Widget>[];
    if (!skipVariantsCount && variants.length > 1) {
      rows.add(_kv('Variants', '${variants.length}'));
    }
    const fields = <String, String>{
      'title': 'Title',
      'publisher': 'Publisher',
      'company': 'Company',
      'cracked_by': 'Cracked by',
      'crew': 'Crew',
      'language': 'Language',
      'disks': 'Disks',
      'release': 'Release',
      'version': 'Version',
      'licence': 'Licence',
      'screen_format': 'Screen format',
      'intro_code': 'Intro code',
      'cracktro': 'Cracktro',
      'add_info': 'Add. info',
      'special_note': 'Special note',
    };
    fields.forEach((key, label) {
      final value = v[key];
      if (value == null) return;
      final text = value is bool ? (value ? 'yes' : 'no') : '$value';
      if (text.isEmpty || text == 'false') return;
      rows.add(_kv(label, text, flagYes: value == true));
    });
    final flags = <String>[
      if (v['raw_dump'] == true) 'RAW dump',
      if (v['pasti_dump'] == true) 'Pasti dump',
      if (v['boxscan'] == true) 'Boxscan',
      if (v['tos_bad'] == true) 'TOS/BAD',
      if (v['special_flag'] == true) 'Special',
    ];
    if (flags.isNotEmpty) rows.add(_kv('Flags', flags.join(', ')));
    return rows;
  }

  Widget _kv(String label, String value, {bool flagYes = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: flagYes ? Colors.greenAccent : Colors.white70,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
