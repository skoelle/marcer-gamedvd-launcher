// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

/// One ZIP as shown in the gallery-style info panel ("This ZIP" table).
class ZipVariantView {
  const ZipVariantView({
    required this.name,
    required this.status,
    required this.layer,
    required this.rel,
    this.size,
  });

  final String name;
  final String status;
  final String layer;
  final String rel;
  final int? size;
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
  });

  final InfoSummary? info;

  /// The ZIP whose "This ZIP" row is shown; also drives the highlighted
  /// release-variant row.
  final ZipVariantView? variant;

  /// Active filter — used for the crew/cracker fallback highlight when no
  /// ZIP name matched a release variant.
  final CatalogFilter? filter;

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        if (info == null) ...[
          _heading('No game info'),
          if (variant != null) ..._zipTable(variant!),
        ] else ...[
          _heading('Game info'),
          ..._infoRows(info),
          if (info.variants.length > 1) ...[
            const SizedBox(height: 8),
            _heading('Release variants (${info.variants.length})'),
            const SizedBox(height: 4),
            _variantsTable(info, variant, filter),
          ],
          if (variant != null) ...[
            const SizedBox(height: 8),
            _heading('This ZIP'),
            ..._zipTable(variant!),
          ],
        ],
      ],
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

  List<Widget> _infoRows(InfoSummary info) {
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
      rows.add(_kv(label, val));
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
  /// is highlighted instead (cracker first).
  Widget _variantsTable(
      InfoSummary info, ZipVariantView? v, CatalogFilter? filter) {
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
            Container(
              color: ri == selIdx
                  ? Colors.cyan.withValues(alpha: 0.15)
                  : Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Row(
                children: [
                  Expanded(
                      flex: 4,
                      child: Text(
                        '${info.variants[ri]['title'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ri == selIdx
                            ? cell.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)
                            : cell,
                      )),
                  Expanded(
                      flex: 3,
                      child: Text(
                        '${info.variants[ri]['cracked_by'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ri == selIdx
                            ? cell.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)
                            : cell,
                      )),
                  Expanded(
                      flex: 3,
                      child: Text(
                        '${info.variants[ri]['crew'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ri == selIdx
                            ? cell.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)
                            : cell,
                      )),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${info.variants[ri]['release'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      textAlign: TextAlign.right,
                      style: ri == selIdx
                          ? cell.copyWith(
                              color: Colors.white, fontWeight: FontWeight.w600)
                          : cell,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _zipTable(ZipVariantView v) {
    return [
      _kv('File', v.name),
      _kv('Status', v.status),
      if (v.layer.isNotEmpty) _kv('Layer', v.layer),
      if (v.size != null) _kv('Size', '${(v.size! / 1024).toStringAsFixed(0)} KB'),
      _kv('Path', v.rel),
    ];
  }

  Widget _kv(String label, String value) {
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
            child: Text(value,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}