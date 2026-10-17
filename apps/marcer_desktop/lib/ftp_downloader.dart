// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;

/// Thrown when a download run is cancelled by the user.
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();
}

/// A download failure (login failed, remote directory missing, transfer error).
class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Progress callback: [done] files finished (or skipped because they already
/// exist locally) out of [total] files discovered in the remote directory.
typedef DownloadProgress = void Function(int done, int total);

/// Pluggable recursive directory downloader. The production implementation is
/// [FtpDownloader]; the controller accepts a fake for unit tests.
abstract class Downloader {
  /// Downloads the remote directory [remoteDir] (relative to the FTP login
  /// directory unless absolute) recursively into the local directory
  /// [localDir], creating it as needed. Existing local files are skipped.
  ///
  /// [onProgress] is called after the remote tree was discovered (with
  /// `done == 0`) and after every transferred/skipped file. [isCancelled] is
  /// polled between transfers; when it returns `true` a
  /// [DownloadCancelledException] is thrown.
  Future<void> downloadDirectory({
    required String host,
    required int port,
    required String user,
    required String password,
    required String remoteDir,
    required String localDir,
    DownloadProgress? onProgress,
    bool Function()? isCancelled,
  });
}

/// Plain-FTP implementation of [Downloader] (port 21 by default), built on the
/// `ftpconnect` package. It performs two passes over the remote tree: a
/// discovery pass (to know the total file count for progress) and a transfer
/// pass that skips files already present locally.
class FtpDownloader implements Downloader {
  const FtpDownloader();

  @override
  Future<void> downloadDirectory({
    required String host,
    required int port,
    required String user,
    required String password,
    required String remoteDir,
    required String localDir,
    DownloadProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = FTPConnect(
      host,
      port: port,
      user: user.trim().isEmpty ? 'anonymous' : user,
      pass: password,
      timeout: 60,
    );
    var connected = false;
    try {
      connected = await client.connect();
      if (!connected) throw const DownloadException('FTP login failed.');

      final loginDir = await client.currentDirectory();
      final absRemote = absoluteRemoteDir(loginDir, remoteDir);
      if (!await client.changeDirectory(absRemote)) {
        throw DownloadException('Remote directory not found: $remoteDir');
      }

      final files = <List<String>>[];
      await _collect(client, const [], files, isCancelled);
      onProgress?.call(0, files.length);

      var done = 0;
      for (final segments in files) {
        if (isCancelled?.call() ?? false) {
          throw const DownloadCancelledException();
        }
        final localFile = File(p.joinAll([localDir, ...segments]));
        if (localFile.existsSync()) {
          onProgress?.call(++done, files.length);
          continue;
        }
        if (!await client.changeDirectory(absRemote)) {
          throw DownloadException('Remote directory not found: $remoteDir');
        }
        for (final dir in segments.take(segments.length - 1)) {
          if (!await client.changeDirectory(dir)) {
            throw DownloadException(
                "Remote subdirectory not found: ${segments.join('/')}");
          }
        }
        await client.downloadFile(segments.last, localFile);
        onProgress?.call(++done, files.length);
      }
    } on DownloadCancelledException {
      rethrow;
    } on DownloadException {
      rethrow;
    } catch (e) {
      throw DownloadException('$e');
    } finally {
      if (connected) {
        try {
          await client.disconnect();
        } catch (_) {
          // Best effort — never mask the original result.
        }
      }
    }
  }

  /// Recursively collects the relative path segments of every remote file
  /// below the current directory (which must be the remote root), leaving the
  /// current directory unchanged.
  Future<void> _collect(FTPConnect client, List<String> prefix,
      List<List<String>> out, bool Function()? isCancelled) async {
    if (isCancelled?.call() ?? false) {
      throw const DownloadCancelledException();
    }
    final entries = await client.listDirectoryContent();
    for (final e in entries) {
      final name = e.name;
      if (name == '.' || name == '..') continue;
      if (e.type == FTPEntryType.dir) {
        if (await client.changeDirectory(name)) {
          await _collect(client, [...prefix, name], out, isCancelled);
          await client.changeDirectory('..');
        }
      } else if (e.type == FTPEntryType.file) {
        out.add([...prefix, name]);
      }
    }
  }
}

/// Joins the FTP login directory [loginDir] and a [remoteDir] into an absolute
/// remote path (used by both the recursive game-folder downloader and the
/// catalog asset fetcher).
String absoluteRemoteDir(String loginDir, String remoteDir) {
  var base = loginDir.trim();
  if (base.isEmpty) base = '/';
  if (base.length > 1) base = base.replaceAll(RegExp(r'/+$'), '');
  final rel = remoteDir.trim().replaceAll(RegExp(r'^/+'), '');
  if (rel.isEmpty) return base;
  return base == '/' ? '/$rel' : '$base/$rel';
}
