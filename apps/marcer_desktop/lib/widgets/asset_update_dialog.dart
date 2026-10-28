// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';

import '../asset_updater.dart';
import '../atarilegend_data.dart';
import '../catalog_assets.dart';
import '../piratefinder_data.dart';
import '../piratefinder_names.dart';
import 'piratefinder_link.dart';

/// Shows the catalog-data update dialog (GameInfo first, then Screenshots).
/// [onApplied] is called after a successful update so the caller can reload the
/// catalog.
Future<void> showAssetUpdateDialog(
  BuildContext context, {
  required AssetUpdateController controller,
  AtariLegendUpdateController? atariLegend,
  PirateFinderDataController? pirateFinder,
  required void Function() onApplied,
}) {
  // Refresh the remote stands whenever the dialog opens. AtariLegend is
  // deliberately excluded: its remote dump is only checked on demand.
  controller.check(force: true);
  pirateFinder?.check(force: true);
  atariLegend?.refreshLocal();
  return showDialog<void>(
    context: context,
    builder: (_) => AssetUpdateDialog(
      controller: controller,
      atariLegend: atariLegend,
      pirateFinder: pirateFinder,
      onApplied: onApplied,
    ),
  );
}

/// Dialog listing the catalog-data assets with local vs. remote version and
/// per-asset Update / Skip this version actions (gameinfo first).
class AssetUpdateDialog extends StatefulWidget {
  const AssetUpdateDialog({
    super.key,
    required this.controller,
    this.atariLegend,
    this.pirateFinder,
    required this.onApplied,
  });

  final AssetUpdateController controller;
  final AtariLegendUpdateController? atariLegend;
  final PirateFinderDataController? pirateFinder;
  final void Function() onApplied;

  @override
  State<AssetUpdateDialog> createState() => _AssetUpdateDialogState();
}

class _AssetUpdateDialogState extends State<AssetUpdateDialog> {
  bool _cancelRequested = false;
  late final Listenable _listenable;

  static const _order = [CatalogAsset.gameinfo, CatalogAsset.screenshots];

  @override
  void initState() {
    super.initState();
    final listenables = <Listenable>[
      widget.controller,
      if (widget.atariLegend != null) widget.atariLegend!,
      if (widget.pirateFinder != null) widget.pirateFinder!,
    ];
    _listenable = listenables.length == 1
        ? listenables.first
        : Listenable.merge(listenables);
  }

  Future<void> _update(CatalogAsset asset) async {
    _cancelRequested = false;
    final ok = await widget.controller.update(
      asset,
      isCancelled: () => _cancelRequested,
    );
    if (!mounted) return;
    if (ok) widget.onApplied();
  }

  Future<void> _updatePirateFinder() async {
    final pf = widget.pirateFinder;
    if (pf == null || pf.busy) return;
    _cancelRequested = false;
    final ok = await pf.update(isCancelled: () => _cancelRequested);
    if (!mounted) return;
    if (ok) widget.onApplied();
  }

  Future<void> _updateAtariLegend() async {
    final al = widget.atariLegend;
    if (al == null || al.busy) return;
    _cancelRequested = false;
    final ok = await al.update(isCancelled: () => _cancelRequested);
    if (!mounted) return;
    if (ok) widget.onApplied();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        final c = widget.controller;
        final rows = _order
            .where((a) => c.remoteFor(a) != null)
            .toList(growable: false);
        return AlertDialog(
          title: const Text('Catalog data'),
          content: SizedBox(
            width: 760,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Catalog data sources: GameInfo and Screenshots come from '
                    'the Marcer FTP; AtariLegend is external data '
                    '(CC BY-NC-SA 4.0) and is only checked manually; the '
                    '$kPirateFinderCatalogName comes from GitHub '
                    '(CC BY-NC-SA 4.0, not part of the Marcer catalog).',
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  if (c.checking)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text(
                            'checking…',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  if (c.checkError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        c.checkError!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                  if (c.latest == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No catalog-data info available.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  for (final asset in rows) ...[
                    _row(c, asset),
                    const SizedBox(height: 8),
                  ],
                  if (widget.atariLegend != null) ...[
                    const Divider(),
                    const SizedBox(height: 4),
                    _atariLegendRow(widget.atariLegend!),
                    const SizedBox(height: 8),
                  ],
                  if (widget.pirateFinder != null) ...[
                    const Divider(),
                    const SizedBox(height: 4),
                    _pirateFinderRow(widget.pirateFinder!),
                    const SizedBox(height: 8),
                  ],
                  if (c.error != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      c.error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.redAccent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: c.busy ? null : () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _atariLegendRow(AtariLegendUpdateController al) {
    final busy =
        al.busy ||
        widget.controller.busy ||
        (widget.pirateFinder?.busy ?? false);
    final remoteDate = al.remoteDate;
    final remoteLabel = al.dataDir.isEmpty
        ? 'set a data directory first'
        : al.checking
        ? 'checking…'
        : al.remoteDumpFile == null
        ? 'unknown — press Check'
        : 'dump ${remoteDate ?? al.remoteDumpFile}';
    final pending = al.hasPending;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                width: 150,
                child: Text(
                  'AtariLegend',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'local:  ${al.localLabel}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    Text(
                      'remote: $remoteLabel',
                      style: const TextStyle(fontSize: 11),
                    ),
                    const Text(
                      'manual check only — no auto-check',
                      style: TextStyle(fontSize: 10, color: Color(0xFF7A7A7A)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'CC BY-NC-SA 4.0 · not part of the Marcer catalog',
            style: TextStyle(fontSize: 10, color: Color(0xFF7A7A7A)),
          ),
          const SizedBox(height: 6),
          if (al.downloading)
            Row(
              children: [
                Expanded(
                  child: al.total > 0
                      ? LinearProgressIndicator(
                          value: al.done / al.total,
                          minHeight: 6,
                        )
                      : const LinearProgressIndicator(minHeight: 6),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    al.message,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => setState(() => _cancelRequested = true),
                  child: const Text('Cancel'),
                ),
              ],
            )
          else if (al.checking)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  al.message,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            )
          else
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (al.remoteDumpFile != null && !pending)
                  const Text(
                    'up to date',
                    style: TextStyle(fontSize: 12, color: Color(0xFF4CAF50)),
                  ),
                OutlinedButton(
                  onPressed: busy || al.dataDir.isEmpty ? null : al.check,
                  child: const Text('Check'),
                ),
                if (pending)
                  FilledButton(
                    onPressed: busy ? null : _updateAtariLegend,
                    child: Text(al.local == null ? 'Install' : 'Update'),
                  ),
              ],
            ),
          if (al.error != null) ...[
            const SizedBox(height: 4),
            Text(
              al.error!,
              style: const TextStyle(fontSize: 11, color: Colors.redAccent),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pirateFinderRow(PirateFinderDataController pf) {
    final remote = pf.remote;
    final local = pf.local;
    final pending = pf.hasPending;
    final busy = pf.busy || widget.controller.busy;
    final hasDataDir = pf.dataDir.isNotEmpty;
    final localLabel = local == null
        ? 'not installed'
        : 'catalogue ${local.sourceTag} · ${local.generatedAt}';
    final remoteLabel = !hasDataDir
        ? 'set a data directory first'
        : remote == null
        ? (pf.checking ? 'checking…' : 'not available')
        : 'catalogue ${pf.latest?.sourceTag ?? '?'} · '
              '${pf.latest?.generatedAt ?? '?'}';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(
                width: 150,
                child: Text(
                  kPirateFinderCatalogShortName,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'local:  $localLabel',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    Text(
                      'remote: $remoteLabel',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PirateFinderGithubLink(),
              Text(
                ' · CC BY-NC-SA 4.0 · not part of the Marcer catalog',
                style: TextStyle(fontSize: 10, color: Color(0xFF7A7A7A)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (pf.downloading)
            Row(
              children: [
                Expanded(
                  child: pf.total > 0
                      ? LinearProgressIndicator(
                          value: pf.done / pf.total,
                          minHeight: 6,
                        )
                      : const LinearProgressIndicator(minHeight: 6),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    pf.message,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => setState(() => _cancelRequested = true),
                  child: const Text('Cancel'),
                ),
              ],
            )
          else
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (remote != null && !pending)
                  const Text(
                    'up to date',
                    style: TextStyle(fontSize: 12, color: Color(0xFF4CAF50)),
                  ),
                OutlinedButton(
                  onPressed: busy || !hasDataDir
                      ? null
                      : () => pf.check(force: true),
                  child: const Text('Check'),
                ),
                if (pending)
                  FilledButton(
                    onPressed: busy || !hasDataDir ? null : _updatePirateFinder,
                    child: Text(local == null ? 'Install' : 'Update'),
                  ),
              ],
            ),
          if (pf.error != null && remote == null) ...[
            const SizedBox(height: 4),
            Text(
              pf.error!,
              style: const TextStyle(fontSize: 11, color: Colors.redAccent),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(AssetUpdateController c, CatalogAsset asset) {
    final remote = c.remoteFor(asset)!;
    final local = c.localFor(asset);
    final dataPresent = c.dataPresentFor(asset);
    final localLabel =
        local ??
        (dataPresent ? 'version unknown (data present)' : 'not installed');
    final pending = c.isPending(asset);
    final updating = c.updatingAsset == asset;
    final busy = c.busy || c.checking || (widget.pirateFinder?.busy ?? false);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF2A2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 150,
                child: Text(
                  asset == CatalogAsset.gameinfo ? 'GameInfo' : 'Screenshots',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'local:  $localLabel',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    Text(
                      'remote: ${remote.archive}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (updating)
            Row(
              children: [
                Expanded(
                  child: c.updateTotal > 0
                      ? LinearProgressIndicator(
                          value: c.updateDone / c.updateTotal,
                          minHeight: 6,
                        )
                      : const LinearProgressIndicator(minHeight: 6),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    c.updateMessage,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => setState(() => _cancelRequested = true),
                  child: const Text('Cancel'),
                ),
              ],
            )
          else
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                if (!pending)
                  const Text(
                    'up to date',
                    style: TextStyle(fontSize: 12, color: Color(0xFF4CAF50)),
                  ),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => c.check(force: true, manual: true),
                  child: const Text('Check'),
                ),
                if (pending) ...[
                  OutlinedButton(
                    onPressed: busy ? null : () => c.skip(asset),
                    child: const Text('Skip this version'),
                  ),
                  FilledButton(
                    onPressed: busy ? null : () => _update(asset),
                    child: Text(
                      local == null
                          ? (dataPresent ? 'Overwrite' : 'Install')
                          : 'Update',
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}
