// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../catalog_controller.dart';
import 'atari_legend_dialog.dart';
import 'crew_detail_panel.dart';
import 'game_info_panel.dart';
import 'local_assets_chips.dart';
import 'piratefinder_crew_dialog.dart';
import 'piratefinder_dialog.dart';
import 'open_folder_button.dart';
import 'status_kind_dialog.dart';

/// Right panel: preview screenshot + game metadata (Playnite-style detail).
class DetailPanel extends StatelessWidget {
  const DetailPanel({
    super.key,
    required this.controller,
    this.onOpenLightbox,
    this.onOpenCrewRelease,
  });

  final CatalogController controller;

  /// Opens the lightbox on a catalog card's variant index (same contract as
  /// `CenterGrid.onOpenLightbox`); used by crew/cracker group clicks.
  final void Function(int variant, int image)? onOpenLightbox;

  /// Opens a crew release (ZIP rel path) in the existing game lightbox.
  final void Function(CrewGroup crew, String rel)? onOpenCrewRelease;

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
      child: _content(context),
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
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'No index.json entry for this ZIP — '
            'status editing is unavailable.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }
    final choice = await showStatusKindDialog(
      context,
      title: title,
      currentStatus: status,
      currentKind: kind,
    );
    if (choice == null) return;
    c.applyStatusChange(rel, choice.status, choice.kind);
  }

  Widget _content(BuildContext context) {
    final c = controller;
    if (c.catalogMode) {
      final card = c.selectedCard;
      return Container(
        color: const Color(0xFF161616),
        child: card == null
            ? const Center(
                child: Text(
                  'No selection',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
              )
            : card.crew != null
            ? CrewDetailPanel(
                crew: card.crew!,
                pirateFinderCrew: c.pirateFinderCrewForGroup(card.crew!),
                onOpenPirateFinder: () => showPirateFinderCrewDialog(
                  context,
                  controller: c,
                  crew: card.crew!,
                ),
                onOpenRelease: onOpenCrewRelease,
              )
            : _cardInfo(context, c, card),
      );
    }
    final entry = c.selectedEntry;
    return Container(
      color: const Color(0xFF161616),
      child: entry == null
          ? const Center(
              child: Text(
                'No selection',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            )
          : entry.kind == EntryKind.directory
          ? _directoryInfo(c, entry)
          : _zipInfo(c, entry),
    );
  }

  Widget _cardInfo(BuildContext context, CatalogController c, GameCard card) {
    // Cache-only lookups + a background scan: selection never blocks on the
    // (possibly network) filesystem. Badges/rows appear once the scan lands.
    c.ensureCardScanned(card);
    final variants = c.cachedVariantsOfCard(card) ?? const <CardVariant>[];
    final layer = c.cachedCardLayer(card);
    final missing = c.cachedCardMissing(card);
    final al = c.atariLegendForCard(card);
    final pfMatch = c.pirateFinderTitleMatchForCard(card);
    // Lazily discovered local Boxscan/Manual assets (cached per game folder).
    final localAssets = c.localAssetsForCard(card);
    // Gallery-style detail (no large preview — the lightbox shows the image).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      card.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  CardFolderButtons(
                    layers: c.cardFolderLayers(card),
                    pathFor: (layer) =>
                        c.cardFolderPath(card, patch: layer == 'PATCH'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (c.isFavoriteCard(card)) _badge('FAVORITE', Colors.amber),
                  if (layer != null && layer.isNotEmpty)
                    _badge(layer, _layerColorName(layer)),
                  if (missing == true) _badge('MISSING', Colors.redAccent),
                  if (card.tosVersion != null && card.tosVersion!.isNotEmpty)
                    _badge('TOS ${card.tosVersion}', Colors.deepOrange),
                  if (card.displayStatus.isNotEmpty)
                    _badge(card.displayStatus, Colors.blueGrey),
                  if (card.year != 'unknown') _badge(card.year, Colors.teal),
                  if (variants.length > 1)
                    _badge('${variants.length} variants', Colors.indigo),
                ],
              ),
              if (missing == true) ...[
                const SizedBox(height: 8),
                _downloadButton(c, card),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: GameInfoPanel(
            info: card.info,
            variant: _primaryVariant(card),
            filter: c.filter,
            variants: card.kind == 'falcon' ? kFalconVariants : kHatariVariants,
            atariLegend: al,
            pirateFinderMatch: pfMatch,
            onAtariLegend: al == null
                ? null
                : () => showAtariLegendDialog(
                    context,
                    game: al,
                    textsLoader: c.atariLegendTexts,
                  ),
            onPirateFinder: pfMatch == null
                ? null
                : () => showPirateFinderDialog(
                    context,
                    controller: c,
                    card: card,
                  ),
            extras: LocalAssetsChips(
              assets: localAssets,
              service: c.localAssetsService,
            ),
            onPlay: () => c.launchSelected(),
            onPlayVariant: (variant) => c.launchSelected(variant: variant),
            onSendToCosmosEx: c.cosmosExConfigured
                ? () => c.sendSelectedToCosmosEx()
                : null,
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

  /// Button (or live progress + Cancel) for downloading a MISSING card's whole
  /// folder from the configured FTP server into the patch/root layer. When FTP
  /// is not configured the click surfaces a hint instead of downloading.
  Widget _downloadButton(CatalogController c, GameCard card) {
    if (c.downloadingCard == card) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              c.downloadProgress,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          TextButton(
            onPressed: c.cancelDownload,
            child: const Text('Cancel', style: TextStyle(fontSize: 12)),
          ),
        ],
      );
    }
    final busy = c.downloading;
    return Align(
      alignment: Alignment.centerLeft,
      child: Builder(
        builder: (context) => OutlinedButton.icon(
          onPressed: busy ? null : () => _startDownload(context, c, card),
          icon: const Icon(Icons.download, size: 16),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.redAccent,
            side: const BorderSide(color: Colors.redAccent),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          label: Text(
            c.ftpConfigured
                ? 'Download folder'
                : 'Download folder (FTP not set)',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
  }

  void _startDownload(
    BuildContext context,
    CatalogController c,
    GameCard card,
  ) {
    if (!c.ftpConfigured) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'FTP not configured — set Host/User/Password in Settings (gear icon).',
          ),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }
    c.downloadMissing(card);
  }

  /// The ZIP shown in the "This ZIP" table: the crew/cracker-focused variant
  /// when a focus filter is active, else the active status filter's preview
  /// variant, else the card's canonical preview, else the first (cache-only,
  /// so selecting a card never blocks on the filesystem; a background scan
  /// fills the data in).
  ZipVariantView? _primaryVariant(GameCard card) {
    final variants =
        controller.cachedVariantsOfCard(card) ?? const <CardVariant>[];
    if (variants.isEmpty) return null;
    var idx = (card.focusVariant ?? -1) >= 0 ? card.focusVariant! : -1;
    final display = controller.displayVariantForCard(card);
    if (display != null) {
      final match = variants.indexWhere((v) => v.rel == display.rel);
      if (match >= 0) idx = match;
    }
    if (idx < 0 && card.previewPath != null) {
      final match = variants.indexWhere(
        (v) => v.previewPath == card.previewPath,
      );
      if (match >= 0) idx = match;
    }
    if (idx < 0 || idx >= variants.length) idx = 0;
    final v = variants[idx];
    final layer = controller.cachedZipLayer(v.rel);
    return ZipVariantView(
      name: v.name,
      status: v.status,
      kind: v.kind,
      layer: layer ?? '',
      rel: v.rel,
      size: v.size,
      missing: layer != null && layer.isEmpty,
      tos: v.tos,
    );
  }

  Color _layerColorName(String layer) => switch (layer) {
    'BOTH' => Colors.green,
    _ => Colors.lightGreen,
  };

  Widget _directoryInfo(CatalogController c, Entry e) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Row(
          children: [
            const Icon(Icons.folder, size: 36, color: Colors.amber),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                e.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
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
                  .map(
                    (path) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Image.file(
                        File(path),
                        key: ValueKey('$path#${c.imageVersionOf(path)}'),
                        height: 56,
                        errorBuilder: (_, _, _) => const SizedBox(width: 56),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          c.titleFor(e),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        _badges(c, e),
        const SizedBox(height: 12),
        if (info == null)
          const Text(
            'No metadata for this entry',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          )
        else
          ..._metadataRows(c, info, shots),
        const SizedBox(height: 12),
        _kv('Layer', e.layerStatus.name.toUpperCase()),
        _kv('Path', e.effectivePath ?? ''),
        if (e.inPatch && e.inRoot)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Launching would use the patch copy (SPEC R14)',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
      ],
    );
  }

  Widget _noPreview(String text) {
    return Center(
      child: Text(
        text,
        style: const TextStyle(color: Colors.grey, fontSize: 13),
      ),
    );
  }

  Widget _badges(CatalogController c, Entry e) {
    final badges = <Widget>[];
    badges.add(_badge(e.layerStatus.name.toUpperCase(), _layerColor(e)));
    final shots = c.screenshotFor(e);
    if (shots != null) {
      badges.add(_badge(shots.status, Colors.blueGrey));
      if (shots.tos != null && shots.tos!.isNotEmpty) {
        badges.add(_badge('TOS ${shots.tos}', Colors.deepOrange));
      }
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
    child: Text(
      text,
      style: TextStyle(fontSize: 10, color: color.withValues(alpha: 1)),
    ),
  );

  List<Widget> _metadataRows(
    CatalogController c,
    GameInfo info,
    ScreenshotEntry? shots,
  ) {
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

  List<Widget> _metadataRowsFromVariants(
    List<Map<String, dynamic>> variants, {
    bool skipVariantsCount = false,
  }) {
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
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
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
