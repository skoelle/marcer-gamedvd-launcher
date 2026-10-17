// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';
import 'game_info_panel.dart';
import 'status_kind_dialog.dart';

/// Right panel: preview screenshot + game metadata (Playnite-style detail).
class DetailPanel extends StatelessWidget {
  const DetailPanel({
    super.key,
    required this.controller,
    this.onOpenLightbox,
  });

  final CatalogController controller;

  /// Opens the lightbox on a catalog card's variant index (same contract as
  /// `CenterGrid.onOpenLightbox`); used by crew/cracker group clicks.
  final void Function(int variant, int image)? onOpenLightbox;

  @override
  Widget build(BuildContext context) {
    // `*` toggles the favorite of the shown ZIP (card "This ZIP" variant /
    // browse entry), `C` opens the status/kind dialog for the same ZIP —
    // also after clicks inside the panel moved the keyboard focus away
    // from the grid.
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.character == '*' ||
            event.logicalKey == LogicalKeyboardKey.asterisk) {
          controller.toggleFavoriteSelected();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyC) {
          _changeStatusShown(context);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: _content(),
    );
  }

  /// `C`: status/kind dialog for the ZIP shown in "This ZIP" (the focused /
  /// primary card variant or the browse-mode entry). The change stays
  /// in-memory in the controller's pending map until the filter bar's
  /// Save (n) button writes it.
  Future<void> _changeStatusShown(BuildContext context) async {
    final c = controller;
    final String rel;
    final String title;
    final String? status;
    final String? kind;
    if (c.catalogMode) {
      final card = c.selectedCard;
      if (card == null) return;
      final view = _primaryVariant(card);
      if (view == null) return;
      rel = view.rel;
      title = view.name;
      status = view.status;
      kind = view.kind;
    } else {
      final e = c.selectedEntry;
      if (e == null || e.kind != EntryKind.zip) return;
      rel = c.relOf(e);
      title = e.name;
      status = c.screenshotFor(e)?.status;
      kind = c.screenshotFor(e)?.kind;
    }
    // pd/utils ZIPs (and favorites of ZIPs outside the screenshot archive)
    // have no index.json entry — the change could never be saved.
    if (c.screenshots[rel] == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text('No index.json entry for this ZIP — '
            'status editing is unavailable.'),
        duration: const Duration(seconds: 3),
      ));
      return;
    }
    final choice = await showStatusKindDialog(context,
        title: title, currentStatus: status, currentKind: kind);
    if (choice == null) return;
    c.applyStatusChange(rel, choice.status, choice.kind);
  }

  Widget _content() {
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
    final variants = c.variantsOfCard(card);
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
                  if (c.isFavoriteCard(card))
                    _badge('FAVORITE', Colors.amber),
                  if (card.layer.isNotEmpty)
                    _badge(card.layer, _layerColorName(card.layer)),
                  if (c.cardMissing(card)) _badge('MISSING', Colors.redAccent),
                  if (card.displayStatus.isNotEmpty)
                    _badge(card.displayStatus, Colors.blueGrey),
                  if (card.year != 'unknown') _badge(card.year, Colors.teal),
                  if (variants.length > 1)
                    _badge('${variants.length} variants', Colors.indigo),
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
            // Group click: open the lightbox on that crew's/cracker's ZIP;
            // no matching ZIP ("not found") opens variant 0, which shows the
            // "… ZIP not found —" prefix in the lightbox header.
            onSelectGroup: (value, kind) {
              final open = onOpenLightbox;
              if (open == null) return;
              final idx = focusVariant(card, value, kind);
              open(idx >= 0 ? idx : 0, 0);
            },
          ),
        ),
      ],
    );
  }

  /// The ZIP shown in the "This ZIP" table: the crew/cracker-focused variant
  /// when a focus filter is active, else the variant that produced the card's
  /// primary preview, else the first (indexes [CatalogController.variantsOfCard],
  /// so pd/utils cards resolve their folder ZIPs on demand).
  ZipVariantView? _primaryVariant(GameCard card) {
    final variants = controller.variantsOfCard(card);
    if (variants.isEmpty) return null;
    var idx = (card.focusVariant ?? -1) >= 0 ? card.focusVariant! : -1;
    if (idx < 0 && card.previewPath != null) {
      final match =
          variants.indexWhere((v) => v.previewPath == card.previewPath);
      if (match >= 0) idx = match;
    }
    if (idx < 0 || idx >= variants.length) idx = 0;
    final v = variants[idx];
    return ZipVariantView(
      name: v.name,
      status: v.status,
      kind: v.kind,
      layer: v.layer,
      rel: v.rel,
      size: v.size,
      missing: controller.variantMissing(v),
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
                    key: ValueKey('$preview#${c.imageVersionOf(preview)}'),
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
                            key: ValueKey(
                                '$path#${c.imageVersionOf(path)}'),
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
