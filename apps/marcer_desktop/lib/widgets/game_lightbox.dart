// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';
import 'game_info_panel.dart';

/// Gallery-style lightbox over the current center list: header with badges
/// and position, integer-scaled main image (pixel-art safe), variant
/// filmstrip (short labels, status underline, `+N` candidate badges),
/// candidate strip and a 330px info panel with the release-variants table
/// (selected ZIP highlighted) and a "This ZIP" table.
/// `←/→` move through cards/entries, `↑/↓` through variants, `PgUp/PgDn`
/// through the images of the active variant, `Esc` closes.
class GameLightbox extends StatefulWidget {
  const GameLightbox({
    super.key,
    required this.controller,
    this.initialVariant = 0,
    this.initialImage = 0,
  });

  final CatalogController controller;

  /// Initial variant index (crew focus) and image index (0 = preview,
  /// gallery `openLightbox(idx, variant, img)` semantics).
  final int initialVariant;
  final int initialImage;

  static Future<void> show(
    BuildContext context,
    CatalogController c, {
    int variant = 0,
    int image = 0,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black87,
      builder: (_) => GameLightbox(
        controller: c,
        initialVariant: variant,
        initialImage: image,
      ),
    );
  }

  @override
  State<GameLightbox> createState() => _GameLightboxState();
}

class _GameLightboxState extends State<GameLightbox> {
  static const double _filmWidth = 96;
  static const double _filmGap = 6;

  final FocusNode _focus = FocusNode(debugLabel: 'lightbox');
  final ScrollController _filmScroll = ScrollController();

  List<Object> _items = const [];
  int _itemIdx = 0;
  int _variantIdx = 0;
  int _imageIdx = 0; // index into images = [preview?, ...candidates]

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
    _filmScroll.dispose();
    super.dispose();
  }

  void _rebuildItems() {
    final c = widget.controller;
    if (c.catalogMode) {
      _items = List<Object>.of(c.catalogCards);
      _itemIdx = c.selectedIndex.clamp(0, math.max(0, _items.length - 1));
    } else {
      _items = c.visibleEntries
          .where((e) => e.kind == EntryKind.zip)
          .toList();
      final sel = c.selectedEntry;
      final idx = sel == null ? -1 : _items.indexOf(sel);
      _itemIdx = idx >= 0 ? idx : 0;
    }
    final item = _item;
    final maxVariant =
        item is GameCard ? item.variants.length - 1 : (item is Entry ? 0 : -1);
    _variantIdx = widget.initialVariant.clamp(0, math.max(0, maxVariant));
    if (maxVariant >= 0 && _variantIdx > maxVariant) _variantIdx = 0;
    _imageIdx = math.max(0, widget.initialImage);
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
            size: v.size,
            rel: v.rel,
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
          size: shots?.size,
          rel: c.relOf(item),
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

  /// Image list of the selected variant: preview first, then candidates
  /// (gallery `lightboxImages`).
  List<String> _imagesOf(_Variant? v) {
    if (v == null) return const [];
    return [
      if (v.preview != null) v.preview!,
      ...v.candidates,
    ];
  }

  void _goItem(int delta) {
    if (_items.isEmpty) return;
    final next = (_itemIdx + delta).clamp(0, _items.length - 1);
    if (next == _itemIdx) return;
    setState(() {
      _itemIdx = next;
      _variantIdx = 0;
      _imageIdx = 0;
    });
    widget.controller.moveSelectionTo(next);
  }

  void _goVariant(int delta) {
    final vs = _variants;
    if (vs.length <= 1) return;
    setState(() {
      _variantIdx = (_variantIdx + delta) % vs.length;
      _imageIdx = 0;
    });
  }

  void _goImage(int delta) {
    final images = _imagesOf(
        _variantIdx < _variants.length ? _variants[_variantIdx] : null);
    if (images.isEmpty) return;
    setState(() {
      // wraps like the gallery PageUp/PageDown handler
      _imageIdx = (_imageIdx + delta + images.length) % images.length;
    });
  }

  /// Candidate strip click: map candidate index to the images array index
  /// (preview shifts by one — gallery `data-img`).
  void _setCandidate(int candIdx) {
    final vs = _variants;
    if (_variantIdx >= vs.length) return;
    final hasPreview = vs[_variantIdx].preview != null;
    setState(() {
      _imageIdx = candIdx + (hasPreview ? 1 : 0);
    });
  }

  void _setVariant(int idx) => setState(() {
        _variantIdx = idx;
        _imageIdx = 0;
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
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.keyP) {
      _launchCurrent();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _scrollActiveFilmIntoView() {
    if (!_filmScroll.hasClients) return;
    final target = _variantIdx * (_filmWidth + _filmGap);
    final pos = _filmScroll.position;
    if (target < pos.pixels) {
      _filmScroll.jumpTo(target);
    } else if (target + _filmWidth + _filmGap > pos.pixels + pos.viewportDimension) {
      _filmScroll.jumpTo(math.max(
          0.0, target + _filmWidth + _filmGap - pos.viewportDimension));
    }
  }

  @override
  Widget build(BuildContext context) {
    final vs = _variants;
    if (_variantIdx >= vs.length && vs.isNotEmpty) _variantIdx = 0;
    final v = vs.isEmpty ? null : vs[_variantIdx];
    final images = _imagesOf(v);
    if (_imageIdx >= images.length) _imageIdx = math.max(0, images.length - 1);
    final imagePath = images.isEmpty ? null : images[_imageIdx];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollActiveFilmIntoView();
    });

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
                              _header(v, vs.length),
                              Expanded(
                                child: Container(
                                  color: Colors.black,
                                  child: imagePath == null
                                      ? const Center(
                                          child: Text('No screenshot',
                                              style: TextStyle(
                                                  color: Colors.grey)))
                                      : _IntegerScaledImage(path: imagePath),
                                ),
                              ),
                              if (vs.length > 1) _filmstrip(vs),
                              Container(
                                height: 60,
                                color: const Color(0xFF111111),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                child: v == null
                                    ? const SizedBox.shrink()
                                    : _candidateStrip(v),
                              ),
                              _hints(),
                            ],
                          ),
                        ),
                        Container(
                          width: 330,
                          color: const Color(0xFF161616),
                          child: _infoPanel(v),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(_Variant? v, int totalVariants) {
    final counts =
        _statusCounts.entries.map((e) => '${e.value}× ${e.key}').join('  ');
    // gallery `lb-sub` miss prefix: focus filter active but no ZIP matched.
    final item = _item;
    final focusMiss = item is GameCard && item.focusVariant == -1;
    final missPrefix = focusMiss
        ? (widget.controller.filter.cracker != 'any'
            ? 'cracker ZIP not found — '
            : 'crew ZIP not found — ')
        : '';
    final sub = v == null
        ? 'no ZIP variants'
        : [
            if (v.status.isNotEmpty) v.status,
            if (v.layer.isNotEmpty) v.layer,
            if (v.size != null) '${(v.size! / 1024).round()} KB',
          ].join('  ·  ');
    final subText = '$missPrefix$sub';
    // gallery `lb-pos`: `3 / 60 · variant 2 / 3` (variant part only when
    // the folder has more than one ZIP).
    var pos = '${_itemIdx + 1} / ${_items.length}';
    if (totalVariants > 1) {
      pos += '  ·  variant ${_variantIdx + 1} / $totalVariants';
    }
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
              Text(
                pos,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              IconButton(
                tooltip: 'Close (Esc)',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 20, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(subText,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
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

  /// Short film label (gallery: strip `.zip`, then leading `…- ` prefix).
  static String _shortName(String name) {
    var s = name.replaceFirst(RegExp(r'\.zip$', caseSensitive: false), '');
    s = s.replaceFirst(RegExp(r'^[^-]*-\s*'), '');
    return s;
  }

  Widget _filmstrip(List<_Variant> vs) {
    return Container(
      height: 96,
      color: const Color(0xFF111111),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Scrollbar(
        controller: _filmScroll,
        thumbVisibility: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        child: ListView.builder(
          controller: _filmScroll,
          scrollDirection: Axis.horizontal,
          itemCount: vs.length,
          padding: const EdgeInsets.only(bottom: 8),
          itemBuilder: (context, i) {
          final v = vs[i];
          final active = i == _variantIdx;
          final stColor = v.preview == null
              ? const Color(0xFF444444)
              : (v.status == 'done'
                  ? const Color(0xFF11AA55)
                  : const Color(0xFFAA8800));
          final nCand = v.candidates.length;
          return Tooltip(
            message: '${v.title} (${v.status})',
            child: GestureDetector(
              onTap: () => _setVariant(i),
              child: Container(
                width: _filmWidth,
                margin: const EdgeInsets.only(right: _filmGap),
                decoration: BoxDecoration(
                  color: const Color(0xFF0E1216),
                  border: Border.all(
                      color: active ? Colors.cyan : const Color(0xFF2A2A2A),
                      width: 2),
                  borderRadius: BorderRadius.circular(4),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          Container(
                            color: Colors.black,
                            child: v.preview == null
                                ? const Center(
                                    child: Text('–',
                                        style: TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF556677))))
                                : Image.file(io.File(v.preview!),
                                    fit: BoxFit.cover,
                                    filterQuality: FilterQuality.none,
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox.shrink()),
                          ),
                          if (nCand > 1)
                            Positioned(
                              right: 3,
                              bottom: 3,
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 3),
                                constraints: const BoxConstraints(
                                    minWidth: 14, minHeight: 14),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2456A0),
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Text('+$nCand',
                                    style: const TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        height: 1.2)),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Container(height: 2, color: stColor),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 3, vertical: 2),
                      child: Text(
                        _shortName(v.title),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 9,
                            color: active ? Colors.cyan : const Color(0xFF99AABB)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
        ),
      ),
    );
  }

  /// Fixed-height strip (gallery: layout must not jump) — preview is not
  /// repeated here, only the `_cNN` candidates of the selected variant.
  Widget _candidateStrip(_Variant v) {
    return Row(
      children: [
        for (var i = 0; i < v.candidates.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => _setCandidate(i),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                      color: i + (v.preview != null ? 1 : 0) == _imageIdx
                          ? Colors.cyan
                          : const Color(0xFF2A2A2A)),
                  borderRadius: BorderRadius.circular(3),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.file(
                  io.File(v.candidates[i]),
                  height: 48,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.none,
                  errorBuilder: (_, _, _) =>
                      Container(width: 48, height: 48, color: Colors.black),
                ),
              ),
            ),
          ),
      ],
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

  Widget _infoPanel(_Variant? v) {
    return GameInfoPanel(
      info: _info,
      variant: v == null
          ? null
          : ZipVariantView(
              name: v.title,
              status: v.status,
              layer: v.layer,
              rel: v.rel,
              size: v.size,
            ),
      filter: widget.controller.filter,
      onPlay: v == null ? null : _launchCurrent,
    );
  }

  /// Launches the currently shown ZIP with Hatari (the selected variant of a
  /// catalog card, or the browse-mode entry).
  void _launchCurrent() {
    final item = _item;
    if (item is GameCard) {
      widget.controller.launchCardVariant(item, _variantIdx);
    } else if (item is Entry) {
      final path = item.effectivePath;
      if (path != null) widget.controller.launchZip(path);
    }
  }
}

/// Main lightbox image: decoded once for its natural size, then shown at
/// the largest **integer** scale that fits (gallery `fitIntegerScale` —
/// pixel-art stays crisp, `image-rendering: pixelated` equivalent).
class _IntegerScaledImage extends StatefulWidget {
  const _IntegerScaledImage({required this.path});

  final String path;

  @override
  State<_IntegerScaledImage> createState() => _IntegerScaledImageState();
}

class _IntegerScaledImageState extends State<_IntegerScaledImage> {
  ui.Image? _decoded;
  bool _failed = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _IntegerScaledImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _decoded?.dispose();
      _decoded = null;
      _failed = false;
      _load();
    }
  }

  @override
  void dispose() {
    _decoded?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final bytes = await io.File(widget.path).readAsBytes();
      final img = await decodeImageFromList(bytes);
      _loading = false;
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _decoded?.dispose();
        _decoded = img;
      });
    } catch (_) {
      _loading = false;
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _decoded;
    if (_failed || img == null) {
      return Center(
        child: Text(
          _failed ? 'Failed to load ${widget.path}' : '…',
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final scale = math.max(
        1,
        math.min(
          (constraints.maxWidth / img.width).floor(),
          (constraints.maxHeight / img.height).floor(),
        ),
      );
      return Center(
        child: SizedBox(
          width: img.width * scale.toDouble(),
          height: img.height * scale.toDouble(),
          child: Image.file(
            io.File(widget.path),
            fit: BoxFit.fill,
            filterQuality: FilterQuality.none,
            gaplessPlayback: true,
          ),
        ),
      );
    });
  }
}

class _Variant {
  const _Variant({
    required this.title,
    required this.status,
    required this.layer,
    required this.preview,
    required this.candidates,
    required this.size,
    required this.rel,
  });

  final String title;
  final String status;
  final String layer;
  final String? preview;
  final List<String> candidates;
  final int? size;
  final String rel;
}
