// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import '../theme.dart';

/// One ZIP as shown in the gallery-style info panel ("This ZIP" table).
class ZipVariantView {
  const ZipVariantView({
    required this.name,
    required this.status,
    required this.layer,
    required this.rel,
    this.kind,
    this.size,
    this.missing = false,
    this.tos,
  });

  final String name;
  final String status;

  /// Preview classification (`game`/`desktop`/`textscreen`/`darkscreen`),
  /// shown as the "Kind" row directly under Status; null/empty → em dash.
  final String? kind;

  final String layer;
  final String rel;
  final int? size;

  /// Non-default TOS version that captured this ZIP (e.g. `1.02`); shown as a
  /// dedicated "TOS" row. Null means the default TOS (`SPEC-screenshot-generator.md` §7.5).
  final String? tos;

  /// True when this ZIP is not present locally (neither root nor patch);
  /// shown as a dedicated red "Missing" row in the "This ZIP" table.
  final bool missing;
}

/// Gallery-style detail panel (`SPEC-gallery-webapp.md` §6.5 `lb-side`):
/// **Game info** table, **Release variants** table (matching row highlighted)
/// and the **This ZIP** table. Shared by the lightbox side panel and the
/// right-hand detail panel.
class GameInfoPanel extends StatelessWidget {
  const GameInfoPanel({
    super.key,
    required this.info,
    this.variant,
    this.filter,
    this.onPlay,
    this.onPlayVariant,
    this.variants = const [],
    this.onSelectGroup,
    this.atariLegend,
    this.onAtariLegend,
  });

  final InfoSummary? info;

  /// The ZIP whose "This ZIP" row is shown; also drives the highlighted
  /// release-variant row.
  final ZipVariantView? variant;

  /// Active filter — used for the crew/cracker fallback highlight when no
  /// ZIP name matched a release variant.
  final CatalogFilter? filter;

  /// Launches the shown ZIP with Hatari using the default variant (the
  /// "(P)lay" button); hidden when null.
  final VoidCallback? onPlay;

  /// Launches the shown ZIP with a specific [HatariVariant] (the split
  /// button's dropdown).
  final void Function(HatariVariant variant)? onPlayVariant;

  /// Variants offered by the Play dropdown (hidden when empty).
  final List<HatariVariant> variants;

  /// Click on a crew/cracker group (release-variant row or the Game info
  /// Crew/Cracked-by values): selects that group's image. [kind] is
  /// `'crew'` or `'cracker'`; hidden/no-op when null.
  final void Function(String value, String kind)? onSelectGroup;

  /// Cached AtariLegend metadata for this card (`null` when unmatched); used
  /// only to decide whether the AtariLegend button is shown.
  final AtariLegendGame? atariLegend;

  /// Opens the AtariLegend dialog; hidden when null (no match / no data).
  final VoidCallback? onAtariLegend;

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        if (info == null) ...[
          _headingRow('No game info', trailing: _atariLegendButtonOrNull()),
          if (variant != null) ...[
            _headingRow('This ZIP', trailing: _playButtonOrNull()),
            ..._zipTable(variant!),
          ],
        ] else ...[
          _headingRow('Game info', trailing: _atariLegendButtonOrNull()),
          ..._infoRows(info, onSelectGroup),
          if (info.variants.length > 1) ...[
            const SizedBox(height: 8),
            _heading('Release variants (${info.variants.length})'),
            const SizedBox(height: 4),
            _variantsTable(info, variant, filter, onSelectGroup),
          ],
          if (variant != null) ...[
            const SizedBox(height: 8),
            _headingRow('This ZIP', trailing: _playButtonOrNull()),
            ..._zipTable(variant!),
          ],
        ],
      ],
    );
  }

  /// Heading with an optional trailing action on the right (e.g. the PLAY
  /// split button or the AtariLegend button).
  Widget _headingRow(String text, {Widget? trailing}) => Row(
        children: [
          Expanded(child: _heading(text)),
          ?trailing,
        ],
      );

  Widget? _playButtonOrNull() => onPlay == null ? null : _playButton();

  Widget? _atariLegendButtonOrNull() =>
      onAtariLegend == null ? null : _atariLegendButton();

  /// Teal-gradient "AtariLegend" button (same shape/position as PLAY).
  Widget _atariLegendButton() {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF2BE0E0), kAtariLegendTeal],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: InkWell(
          onTap: onAtariLegend,
          borderRadius: BorderRadius.circular(4),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.open_in_new, size: 15, color: Colors.white),
                SizedBox(width: 4),
                Text(
                  'AtariLegend',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _playButton() {
    final showDropdown = onPlayVariant != null && variants.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF1E88E5), Color(0xFF1565C0)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: onPlay,
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.fromLTRB(14, 6, 10, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_arrow, size: 16, color: Colors.white),
                    SizedBox(width: 4),
                    Text(
                      'PLAY',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (showDropdown) ...[
              Container(
                  width: 1,
                  height: 18,
                  color: Colors.white.withValues(alpha: 0.3)),
              PopupMenuButton<HatariVariant>(
                tooltip: 'Play as…',
                onSelected: (v) => onPlayVariant!(v),
                itemBuilder: (context) => [
                  for (final v in variants)
                    PopupMenuItem<HatariVariant>(
                      value: v,
                      child: Tooltip(
                        message: v.description,
                        child: Text(v.name),
                      ),
                    ),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child:
                      Icon(Icons.arrow_drop_down, size: 18, color: Colors.white),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _heading(String text) => Text(
        text,
        style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.white70,
            decoration: TextDecoration.underline),
      );

  List<Widget> _infoRows(
      InfoSummary info, void Function(String value, String kind)? onSelectGroup) {
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
    final values = <String, String>{
      'publisher': info.publisher,
      'cracked_by': info.crackedBy,
      'crew': info.crew,
      'language': info.language,
      'disks': info.disks?.toString() ?? '',
      'release': info.release,
      'version': info.version,
      'licence': info.licence,
      'screen_format': info.screenFormat,
      'intro_code': info.introCode,
      'cracktro': info.cracktro,
      'add_info': info.addInfo,
      'special_note': info.specialNote,
      'tos_bad': info.tosBad,
    };
    fields.forEach((key, label) {
      final val = values[key] ?? '';
      if (val.isEmpty) return;
      final groupKind =
          key == 'crew' ? 'crew' : (key == 'cracked_by' ? 'cracker' : null);
      rows.add(_kv(label, val,
          onTap: (groupKind != null && onSelectGroup != null)
              ? () => onSelectGroup(val, groupKind)
              : null));
    });
    final flags = <String>[
      if (info.rawDump) 'RAW dump',
      if (info.pastiDump) 'Pasti dump',
      if (info.boxscan) 'Boxscan',
      if (info.specialFlag.isNotEmpty) 'Special',
    ];
    if (flags.isNotEmpty) rows.add(_kv('Flags', flags.join(', ')));
    return rows;
  }

  /// Release-variants table; the row matching the selected ZIP (cracker or
  /// crew name contained in the ZIP filename) is highlighted. With an active
  /// crew/cracker filter whose ZIP could not be identified, the group's row
  /// is highlighted instead (cracker first). Rows are clickable when
  /// [onSelectGroup] is set (crew first, else cracker).
  Widget _variantsTable(InfoSummary info, ZipVariantView? v, CatalogFilter? filter,
      void Function(String value, String kind)? onSelectGroup) {
    final f = filter;
    var selIdx = -1;
    if (v != null) {
      final zl = v.name.toLowerCase();
      for (var i = 0; i < info.variants.length; i++) {
        final rv = info.variants[i];
        final cr = ((rv['cracked_by'] ?? '') as String).trim().toLowerCase();
        final crw = ((rv['crew'] ?? '') as String).trim().toLowerCase();
        if ((cr.isNotEmpty && zl.contains(cr)) ||
            (crw.isNotEmpty && zl.contains(crw))) {
          selIdx = i;
          break;
        }
      }
    }
    if (selIdx == -1 && f != null && f.cracker != 'any') {
      final target = normCrew(f.cracker);
      final idx = info.variants.indexWhere(
          (rv) => normCrew(rv['cracked_by'] as String?) == target);
      if (idx >= 0) selIdx = idx;
    }
    if (selIdx == -1 && f != null && f.crew != 'any') {
      final target = normCrew(f.crew);
      final idx = info.variants.indexWhere(
          (rv) => normCrew(rv['crew'] as String?) == target);
      if (idx >= 0) selIdx = idx;
    }
    const header = TextStyle(
        fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey);
    const cell = TextStyle(fontSize: 10, color: Colors.white70);
    return Container(
      decoration:
          BoxDecoration(border: Border.all(color: const Color(0xFF2A2A2A))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: const Color(0xFF202020),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: const Row(
              children: [
                Expanded(flex: 4, child: Text('Title', style: header)),
                Expanded(flex: 3, child: Text('Cracker', style: header)),
                Expanded(flex: 3, child: Text('Crew', style: header)),
                SizedBox(
                    width: 44,
                    child: Text('Year',
                        style: header, textAlign: TextAlign.right)),
              ],
            ),
          ),
          for (var ri = 0; ri < info.variants.length; ri++)
            _variantRow(info.variants[ri], ri == selIdx, cell, onSelectGroup),
        ],
      ),
    );
  }

  Widget _variantRow(Map<String, dynamic> rv, bool selected,
      TextStyle cell, void Function(String value, String kind)? onSelectGroup) {
    final crew = (rv['crew'] ?? '').toString().trim();
    final cracker = (rv['cracked_by'] ?? '').toString().trim();
    VoidCallback? onTap;
    if (onSelectGroup != null) {
      if (crew.isNotEmpty) {
        onTap = () => onSelectGroup(crew, 'crew');
      } else if (cracker.isNotEmpty) {
        onTap = () => onSelectGroup(cracker, 'cracker');
      }
    }
    final rowStyle = selected
        ? cell.copyWith(color: Colors.white, fontWeight: FontWeight.w600)
        : cell;
    final row = Container(
      color: selected
          ? Colors.cyan.withValues(alpha: 0.15)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Row(
        children: [
          Expanded(
              flex: 4,
              child: Text(
                '${rv['title'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: rowStyle,
              )),
          Expanded(
              flex: 3,
              child: Text(
                cracker,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: rowStyle,
              )),
          Expanded(
              flex: 3,
              child: Text(
                crew,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: rowStyle,
              )),
          SizedBox(
            width: 44,
            child: Text(
              '${rv['release'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.clip,
              textAlign: TextAlign.right,
              style: rowStyle,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }

  List<Widget> _zipTable(ZipVariantView v) {
    final kind =
        (v.kind == null || v.kind!.isEmpty) ? '—' : v.kind!;
    return [
      _kv('File', v.name),
      _kv('Status', v.status),
      _kv('Kind', kind),
      if (v.tos != null && v.tos!.isNotEmpty) _kv('TOS', v.tos!),
      if (v.missing) _kv('Missing', 'yes — not present locally'),
      if (v.layer.isNotEmpty) _kv('Layer', v.layer),
      if (v.size != null) _kv('Size', '${(v.size! / 1024).toStringAsFixed(0)} KB'),
      _kv('Path', v.rel),
    ];
  }

  Widget _kv(String label, String value, {VoidCallback? onTap}) {
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ),
      ],
    );
    if (onTap == null) {
      return Padding(padding: const EdgeInsets.only(bottom: 6), child: row);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(3), child: row),
    );
  }
}