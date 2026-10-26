// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/foundation.dart';
import 'package:marcer_catalog/marcer_catalog.dart';

import 'atarilegend_fetcher.dart';

/// Manual check/update state for the AtariLegend metadata cache.
///
/// The remote dump is **never** checked automatically (no startup check, no
/// check when the Catalog data dialog opens); the user presses Check. This
/// controller only reads the local cache header on [refreshLocal].
class AtariLegendUpdateController extends ChangeNotifier {
  AtariLegendUpdateController({AtariLegendFetcher? fetcher})
    : _fetcher = fetcher ?? const HttpAtariLegendFetcher();

  final AtariLegendFetcher _fetcher;

  DesktopConfig config = DesktopConfig(rootDirectory: '');

  /// Applied local cache header (`null` when not installed).
  AtariLegendCacheInfo? local;

  /// Newest remote dump file (`null` until the user pressed Check).
  String? remoteDumpFile;

  String? error;
  bool checking = false;
  bool downloading = false;
  String message = '';
  int done = 0;
  int total = 0;

  bool _disposed = false;

  String get dataDir => config.resolveAtariLegendDirectory();

  bool get busy => checking || downloading;

  String? get remoteDate => _dateOf(remoteDumpFile);

  String? get localDate {
    final date = local?.assetDate ?? '';
    return date.isEmpty ? null : date;
  }

  /// Label for the local row: `dump 2026-10-18`, `installed · date unknown`
  /// or `not installed`.
  String get localLabel {
    final info = local;
    if (info == null) return 'not installed';
    final date = info.assetDate;
    return date.isEmpty ? 'installed · date unknown' : 'dump $date';
  }

  /// True when the checked remote dump is newer than the applied one (or no
  /// local cache/date is known).
  bool get hasPending {
    final remote = remoteDate;
    if (remote == null) return false;
    final current = localDate;
    if (current == null) return true;
    return remote.compareTo(current) > 0;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Reads the local cache header (cheap; no network request).
  void refreshLocal() {
    local = AtariLegendCacheInfo.load(dataDir);
    _notify();
  }

  /// Fetches the remote dump listing and resolves the newest dump file.
  /// Only called from the Check button.
  Future<void> check() async {
    if (busy) return;
    if (dataDir.isEmpty) {
      error = 'Set a data directory first.';
      _notify();
      return;
    }
    checking = true;
    error = null;
    message = 'Checking…';
    _notify();
    try {
      final dump = await _fetcher.latestDump();
      if (dump == null || dump.trim().isEmpty) {
        throw const AtariLegendFetchException(
          'No YYYY-MM-DD.sql.gz found in the AtariLegend listing.',
        );
      }
      remoteDumpFile = dump.trim();
    } catch (e) {
      error = 'AtariLegend check failed: $e';
    } finally {
      checking = false;
      message = '';
      local = AtariLegendCacheInfo.load(dataDir);
      _notify();
    }
  }

  /// Downloads the newest dump and rewrites the compact cache. Progress and
  /// cancellation are forwarded to the existing fetcher.
  Future<bool> update({bool Function()? isCancelled}) async {
    if (busy) return false;
    final dir = dataDir;
    if (dir.isEmpty) {
      error = 'Set a data directory first.';
      _notify();
      return false;
    }
    downloading = true;
    error = null;
    message = 'Starting…';
    done = 0;
    total = 0;
    _notify();
    try {
      final result = await _fetcher.fetch(
        targetDir: dir,
        onProgress: (nextMessage, nextDone, nextTotal) {
          message = nextMessage;
          done = nextDone;
          total = nextTotal;
          _notify();
        },
        isCancelled: isCancelled,
      );
      remoteDumpFile = result.dumpFile;
      downloading = false;
      message = '';
      // The successful fetch result is authoritative (it just rewrote the
      // cache); do not keep a stale old header from disk.
      local = AtariLegendCacheInfo(
        generatedAt: DateTime.now().toUtc().toIso8601String(),
        sourceFile: result.dumpFile,
        dumpDate: _dateOf(result.dumpFile) ?? '',
        gameCount: result.games,
      );
      _notify();
      return true;
    } on AtariLegendFetchCancelled {
      error = 'AtariLegend download cancelled.';
    } catch (e) {
      error = 'AtariLegend download failed: $e';
    }
    downloading = false;
    message = '';
    _notify();
    return false;
  }

  static String? _dateOf(String? dumpFile) {
    if (dumpFile == null) return null;
    final match = RegExp(r'^(\d{4}-\d{2}-\d{2})').firstMatch(dumpFile.trim());
    return match?.group(1);
  }
}
