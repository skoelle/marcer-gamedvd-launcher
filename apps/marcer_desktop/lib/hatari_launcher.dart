// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:marcer_catalog/marcer_catalog.dart';

/// Starts Hatari for one ZIP (SPEC-launcher.md §12). Non-blocking: the process runs in
/// the background and the caller is notified when it exits.
///
/// Stderr/stdout are drained from the start (a full pipe would otherwise block
/// the emulator) and kept as a bounded tail so a non-zero exit can be reported
/// with Hatari's own message instead of a bare exit code.
class HatariProcess {
  HatariProcess(this._process) {
    _stdoutDone = _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(_stdout.write);
    _stderrDone = _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(_stderr.write);
  }

  static const int _maxTailChars = 4096;

  final Process _process;
  final _TailBuffer _stdout = _TailBuffer(_maxTailChars);
  final _TailBuffer _stderr = _TailBuffer(_maxTailChars);
  late final Future<void> _stdoutDone;
  late final Future<void> _stderrDone;

  /// Completes when the emulator exits and its output has been drained.
  Future<int> get exitCode async {
    final code = await _process.exitCode;
    try {
      await Future.wait([_stdoutDone, _stderrDone])
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Output capture is best effort; the exit code is what matters.
    }
    return code;
  }

  /// Captured stderr (preferred) plus stdout tail, trimmed; empty when Hatari
  /// printed nothing.
  String get output {
    final err = _stderr.value;
    final out = _stdout.value;
    if (err.isEmpty) return out;
    if (out.isEmpty) return err;
    return '$err\n$out';
  }
}

/// Keeps only the last [maxChars] characters written to it.
class _TailBuffer {
  _TailBuffer(this.maxChars);

  final int maxChars;
  final StringBuffer _buffer = StringBuffer();

  void write(String text) {
    _buffer.write(text);
    if (_buffer.length > maxChars) {
      final all = _buffer.toString();
      _buffer
        ..clear()
        ..write(all.substring(all.length - maxChars));
    }
  }

  String get value => _buffer.toString().trim();
}

/// Launches Hatari for [zipPath]. Returns a [HatariProcess] on success or an
/// error message when the configuration/ZIP is invalid (SPEC-launcher.md §5.4, E3/E4,E7).
Future<({HatariProcess? process, String? error})> launchHatari(
  DesktopConfig config,
  String zipPath, {
  HatariVariant? variant,
}) async {
  final (:command, :error) = buildHatariCommand(
    config,
    zipPath,
    variant: variant,
  );
  if (command == null) return (process: null, error: error);
  try {
    final process = await Process.start(
      command.executable,
      command.arguments,
      workingDirectory: command.workingDirectory,
      runInShell: false,
    );
    return (process: HatariProcess(process), error: null);
  } catch (e) {
    return (process: null, error: 'Error starting Hatari: $e');
  }
}
