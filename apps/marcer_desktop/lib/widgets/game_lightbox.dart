// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';

/// Gallery-style lightbox over the current center list: header with badges,
/// large preview, variant filmstrip, candidate strip and a 330px info
/// panel. `←/→` move through cards/entries, `↑/↓` through variants,
/// `PgUp/PgDn` through the images of the active variant, `Esc` closes.
class GameLightbox extends StatefulWidget {
  const GameLightbox({super.key, required this.controller});

  final CatalogController controller;

  static Future<void> show(BuildContext context, CatalogController c) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black87,
      builder: (_) => GameLightbox(controller: c),
    );
  }

  @override
  State<GameLightbox> createState() => _GameLightboxState();
}

class _GameLightboxState extends State<GameLightbox> {
  final FocusNode _focus = FocusNode(debugLabel: 'lightbox');

  List<Object> _items = const [];
  int _itemIdx = 0;
  int _variantIdx = 0;
  int _imageIdx = -1; // -1 = card/entry preview, else candidate index

  @override
  void initState() {
    super.initState();
    _rebuildItems();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _rebuildItems() {
    final c = widget.controller;
    if (c.catalogMode) {
      _items = List<Object>.of(c.catalogCards);
      _itemIdx = c.selectedIndex.clamp(0, _items.length - 1);
    } else {
      _items = c.visibleEntries
          .where((e) => e.kind == EntryKind.zip)
          .toList();
      final sel = c.selectedEntry;
      final idx = sel == null ? -1 : _items.indexOf(sel);
      _itemIdx = idx >= 0 ? idx : 0;
    }
    _variantIdx = 0;
    _imageIdx = -1;
  }

  Object? get _item =>
      _items.isEmpty ? null : _items[_itemIdx.clamp(0, _items.length - 1)];

  List<_Variant> get _variants {
    final item = _item;
    if (item is GameCard) {
      return [
        for (final v in item.variants)
          _Variant(
            title: v.name,
            status: v.status,
            layer: v.layer,
            preview: v.previewPath,
            candidates: v.candidatePaths,
          ),
      ];
    }
    if (item is Entry) {
      final c = widget.controller;
      final shots = c.screenshotFor(item);
      return [
        _Variant(
          title: item.name,
          status: shots?.status ?? '',
          layer: item.layerStatus.name.toUpperCase(),
          preview: c.previewPathFor(item),
          candidates: c.candidatePathsFor(item),
        ),
      ];
    }
    return const [];
  }

  InfoSummary? get _info {
    final item = _item;
    if (item is GameCard) return item.info;
    if (item is Entry) {
      final g = widget.controller.infoFor(item);
      return g == null ? null : InfoSummary.fromGame(g);
    }
    return null;
  }

  String get _title {
    final item = _item;
    if (item is GameCard) return item.name;
    if (item is Entry) return widget.controller.titleFor(item);
    return '';
  }

  String? get _layer {
    final item = _item;
    if (item is GameCard) return item.layer;
    if (item is Entry) return item.layerStatus.name.toUpperCase();
    return null;
  }

  Map<String, int> get _statusCounts {
    final item = _item;
    return item is GameCard ? item.statusCounts : const {};
  }

  String get _year {
    final item = _item;
    if (item is GameCard) return item.year == 'unknown' ? '' : item.year;
    if (item is Entry) {
      final info = widget.controller.infoFor(item);
      if (info == null || info.variants.isEmpty) return '';
      return extractYear(info.variants.first['release'] as String?);
    }
    return '';
  }

  void _goItem(int delta) {
    if (_items.isEmpty) return;
    final next = (_itemIdx + delta).clamp(0, _items.length - 1);
    if (next == _itemIdx) return;
    setState(() {
      _itemIdx = next;
      _variantIdx = 0;
      _imageIdx = -1;
    });
    widget.controller.moveSelectionTo(next);
  }

  void _goVariant(int delta) {
    final vs = _variants;
    if (vs.length <= 1) return;
    setState(() {
      _variantIdx = (_variantIdx + delta) % vs.length;
      _imageIdx = -1;
    });
  }

  void _goImage(int delta) {
    final vs = _variants;
    if (_variantIdx >= vs.length) return;
    final v = vs[_variantIdx];
    // Image list: [-1 = preview, 0..candidates.length-1]
    final max = v.candidates.length - 1;
    setState(() {
      var next = (_imageIdx + delta).clamp(-1, max < 0 ? -1 : max);
      if (max < 0) next = -1;
      _imageIdx = next;
    });
  }

  void _setImage(int idx) => setState(() => _imageIdx = idx);

  void _setVariant(int idx) => setState(() {
        _variantIdx = idx;
        _imageIdx = -1;
      });

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _goItem(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _goItem(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _goVariant(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _goVariant(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _goImage(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _goImage(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final vs = _variants;
    if (_variantIdx >= vs.length) _variantIdx = 0;
    final v = vs.isEmpty ? null : vs[_variantIdx];
    final images = <String?>[
      if (v != null && v.preview != null) v.preview,
      if (v != null) ...v.candidates,
    ];
    final imgIdx = _imageIdx.clamp(-1, images.isEmpty ? -1 : images.length - 1);
    final imagePath = images.isEmpty || imgIdx < 0 ? null : images[imgIdx];

    final height = MediaQuery.of(context).size.height * 0.86;

    return Material(
      color: Colors.transparent,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: GestureDetector(
          onTap: () => _focus.requestFocus(),
          child: Center(
            child: Container(
              width: 1200,
              height: height,
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D0D),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2A2A2A)),
              ),
              clipBehavior: Clip.antiAlias,
              child: vs.isEmpty && _item == null
                  ? const Center(
                      child: Text('No selection',
                          style: TextStyle(color: Colors.grey)))
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _header(),
                              Expanded(
                                child: Container(
                                  color: Colors.black,
                                  child: imagePath == null
                                      ? const Center(
                                          child: Text('No screenshot',
                                              style: TextStyle(
                                                  color: Colors.grey)))
                                      : Image.file(
                                          io.File(imagePath),
                                          fit: BoxFit.contain,
                                          errorBuilder: (_, _, _) =>
                                              const Center(
                                                  child: Text('Failed to load',
                                                      style: TextStyle(
                                                          color: Colors.grey))),
                                        ),
                                ),
                              ),
                              if (vs.length > 1) _filmstrip(vs),
                              if (v != null && v.candidates.isNotEmpty)
                                _candidateStrip(v),
                              _hints(),
                            ],
                          ),
                        ),
                        Container(
                          width: 330,
                          color: const Color(0xFF161616),
                          child: _infoPanel(),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final counts = _statusCounts.entries
        .map((e) => '${e.value}× ${e.key}')
        .join('  ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: const Color(0xFF141414),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                ),
              ),
              IconButton(
                tooltip: 'Close (Esc)',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 20, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 4),
            Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (_layer != null && _layer!.isNotEmpty)
                _badge(_layer!, Colors.green),
              if (counts.isNotEmpty) _badge(counts, Colors.blueGrey),
              if (_year.isNotEmpty) _badge(_year, Colors.teal),
            ],
          ),
        ],
      ),
    );
  }

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

  Widget _filmstrip(List<_Variant> vs) {
    return Container(
      height: 92,
      color: const Color(0xFF111111),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: vs.length,
        itemBuilder: (context, i) {
          final v = vs[i];
          final active = i == _variantIdx;
          return GestureDetector(
            onTap: () => _setVariant(i),
            child: Container(
              width: 150,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                border: Border.all(
                    color: active ? Colors.cyan : const Color(0xFF2A2A2A),
                    width: active ? 2 : 1),
                borderRadius: BorderRadius.circular(4),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Container(
                      color: Colors.black,
                      child: v.preview == null
                          ? const Center(
                              child: Icon(Icons.videogame_asset,
                                  size: 20, color: Colors.white24))
                          : Image.file(io.File(v.preview!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const SizedBox.shrink()),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    color: const Color(0xFF1B1B1B),
                    child: Text(
                      v.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 9, color: active ? Colors.cyan : Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _candidateStrip(_Variant v) {
    return Container(
      height: 60,
      color: const Color(0xFF111111),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: v.candidates.length,
        itemBuilder: (context, i) {
          final active = i == _imageIdx;
          return GestureDetector(
            onTap: () => _setImage(i),
            child: Container(
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                border: Border.all(
                    color: active ? Colors.cyan : const Color(0xFF2A2A2A)),
                borderRadius: BorderRadius.circular(3),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.file(
                io.File(v.candidates[i]),
                height: 48,
                errorBuilder: (_, _, _) => const SizedBox(width: 48),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _hints() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: const Color(0xFF141414),
      child: const Text(
        '←/→ card   ↑/↓ variant   PgUp/PgDn image   Esc close',
        style: TextStyle(fontSize: 10, color: Colors.grey),
      ),
    );
  }

  Widget _infoPanel() {
    final info = _info;
    final vs = _variants;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Text(_title,
            style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        if (info == null)
          const Text('No metadata',
              style: TextStyle(color: Colors.grey, fontSize: 12))
        else
          ..._infoRows(info, vs),
      ],
    );
  }

  List<Widget> _infoRows(InfoSummary info, List<_Variant> vs) {
    final rows = <Widget>[];
    const fields = <String, String>{
      'publisher': 'Publisher',
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
      'tos_bad': 'TOS/BAD',
    };
    if (info.title.isNotEmpty) rows.add(_kv('Title', info.title));
    fields.forEach((key, label) {
      String val = '';
      if (key == 'publisher') val = info.publisher;
      if (key == 'cracked_by') val = info.crackedBy;
      if (key == 'crew') val = info.crew;
      if (key == 'language') val = info.language;
      if (key == 'disks') val = info.disks?.toString() ?? '';
      if (key == 'release') val = info.release;
      if (key == 'version') val = info.version;
      if (key == 'licence') val = info.licence;
      if (key == 'screen_format') val = info.screenFormat;
      if (key == 'intro_code') val = info.introCode;
      if (key == 'cracktro') val = info.cracktro;
      if (key == 'add_info') val = info.addInfo;
      if (key == 'special_note') val = info.specialNote;
      if (key == 'tos_bad') val = info.tosBad;
      if (val.isEmpty) return;
      rows.add(_kv(label, val));
    });
    final flags = <String>[
      if (info.rawDump) 'RAW dump',
      if (info.pastiDump) 'Pasti dump',
      if (info.boxscan) 'Boxscan',
      if (info.specialFlag.isNotEmpty) 'Special',
    ];
    if (flags.isNotEmpty) rows.add(_kv('Flags', flags.join(', ')));
    if (info.variants.length > 1) {
      rows.add(_kv('Gameinfo variants', '${info.variants.length}'));
    }
    if (vs.isNotEmpty) rows.add(_kv('ZIP variants', '${vs.length}'));
    return rows;
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}

class _Variant {
  const _Variant({
    required this.title,
    required this.status,
    required this.layer,
    required this.preview,
    required this.candidates,
  });

  final String title;
  final String status;
  final String layer;
  final String? preview;
  final List<String> candidates;
}
