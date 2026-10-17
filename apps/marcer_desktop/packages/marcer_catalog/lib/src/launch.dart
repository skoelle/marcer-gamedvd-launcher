// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'config.dart';

/// A named Hatari launch variant (the split Play button's dropdown): extra
/// command-line arguments appended after the args template, plus an optional
/// TOS ROM file (resolved against the app directory) the variant requires.
class HatariVariant {
  const HatariVariant({
    required this.name,
    required this.description,
    this.extraArgs = const [],
    this.tosFileName,
    this.tosVersions = const [],
  });

  final String name;
  final String description;
  final List<String> extraArgs;

  /// TOS image file name next to the app (e.g. `TOS162.IMG`); `null` uses the
  /// bundled config's `TOS.IMG`.
  final String? tosFileName;

  /// TOS versions offered when this variant's [tosFileName] must be downloaded
  /// (e.g. `['1.62']`).
  final List<String> tosVersions;
}

/// The built-in Play variants (fixed in code, user decision 2026-10-17):
/// Standard (ST, TOS 1.04), Mono, STE (TOS 1.62) and Low Res TOS 1.02.
const List<HatariVariant> kHatariVariants = [
  HatariVariant(name: 'Standard', description: 'ST, TOS 1.04, color'),
  HatariVariant(
    name: 'Mono',
    description: 'ST, TOS 1.04, monochrome high-res',
    // `--mono`/`--monitor mono` forces the mono monitor (ST boots to high-res
    // 640x400). We use `--monitor mono` instead of `--mono --tos-res high`:
    // `--tos-res high` crashes Hatari on Windows (v2.6.1-devel) and is
    // redundant in mono mode.
    extraArgs: ['--monitor', 'mono'],
  ),
  HatariVariant(
    name: 'STE',
    description: 'STE, TOS 1.62',
    extraArgs: ['--machine', 'ste'],
    tosFileName: 'TOS162.IMG',
    tosVersions: ['1.62'],
  ),
  HatariVariant(
    name: 'Low Res TOS 1.02',
    description: 'ST, TOS 1.02, low-res',
    tosFileName: 'TOS102.IMG',
    tosVersions: ['1.02'],
  ),
];

/// Builds the Hatari command for one ZIP (SPEC.md §12.1).
///
/// `{cfg}` → the Hatari config file (`Hatari.ConfigFile`, or the bundled
/// fallback next to the executable) and `{zip}` → the effective ZIP path.
/// Plain literal replacement — no shell interpretation.
class HatariCommand {
  const HatariCommand(this.executable, this.arguments, this.workingDirectory);

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
}

/// Substitutes `{cfg}` / `{zip}` in [template] and splits it into arguments
/// (double/single quotes group a token; SPEC.md §12.1, E12).
List<String> hatariArguments(String template, String cfgPath, String zipPath) {
  final expanded = template.replaceAll('{cfg}', cfgPath).replaceAll('{zip}', zipPath);
  return splitCommandLine(expanded);
}

/// Splits a command line into arguments, honouring `"` and `'` quoting.
List<String> splitCommandLine(String line) {
  final args = <String>[];
  final buf = StringBuffer();
  String? quote;
  var hasToken = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        buf.write(c);
      }
      hasToken = true;
    } else if (c == '"' || c == "'") {
      quote = c;
      hasToken = true;
    } else if (c == ' ' || c == '\t') {
      if (hasToken) {
        args.add(buf.toString());
        buf.clear();
        hasToken = false;
      }
    } else {
      buf.write(c);
      hasToken = true;
    }
  }
  if (hasToken) args.add(buf.toString());
  return args;
}

/// Validates the Hatari launch configuration (SPEC.md §5.4, E3/E4).
/// Returns a clear error message, or null when every requirement holds.
///
/// - `Hatari.Executable` must be set and exist.
/// - `Hatari.ConfigFile`, if non-empty, must exist.
/// - `Hatari.ArgsTemplate` must contain `{zip}` and `{cfg}`.
String? validateHatariConfig(DesktopConfig config) {
  final exe = config.resolveHatariExecutable();
  if (config.hatariExecutable.trim().isEmpty) {
    return 'Hatari.Executable must be set in desktop.config.json.';
  }
  if (!File(exe).existsSync()) {
    return 'Hatari executable not found: $exe';
  }
  if (config.hatariConfigFile.trim().isNotEmpty &&
      !File(config.resolveHatariConfigFile()).existsSync()) {
    return 'Hatari configuration file not found: '
        '${config.resolveHatariConfigFile()}';
  }
  final tpl = config.hatariArgsTemplate;
  if (!tpl.contains('{zip}')) {
    return 'Hatari.ArgsTemplate must contain the {zip} placeholder.';
  }
  if (!tpl.contains('{cfg}')) {
    return 'Hatari.ArgsTemplate must contain the {cfg} placeholder.';
  }
  return null;
}

/// Builds the full Hatari command for [zipPath], or returns an error message.
///
/// [zipPath] must exist (SPEC.md E7 handles the vanished-ZIP case as a modal).
/// [variant] appends its extra arguments and, when it requires a TOS ROM,
/// `--tos <appDir/file>` (error when that file is missing).
({HatariCommand? command, String? error}) buildHatariCommand(
    DesktopConfig config, String zipPath,
    {HatariVariant? variant}) {
  final validation = validateHatariConfig(config);
  if (validation != null) return (command: null, error: validation);
  if (zipPath.trim().isEmpty || !File(zipPath).existsSync()) {
    return (command: null, error: 'ZIP file not found: $zipPath');
  }
  final args = hatariArguments(
      config.hatariArgsTemplate, config.resolveHatariConfigFile(), zipPath);
  if (variant != null) {
    args.addAll(variant.extraArgs);
    final tosFile = variant.tosFileName;
    if (tosFile != null && tosFile.isNotEmpty) {
      final tosPath =
          config.appDir.isEmpty ? tosFile : '${config.appDir}/$tosFile';
      if (!File(tosPath).existsSync()) {
        return (
          command: null,
          error: '${variant.name} needs the TOS ROM $tosFile '
              '(not found next to the app).'
        );
      }
      args
        ..add('--tos')
        ..add(tosPath);
    }
  }
  return (
    command: HatariCommand(config.resolveHatariExecutable(), args,
        config.appDir.isEmpty ? Directory.current.path : config.appDir),
    error: null,
  );
}
