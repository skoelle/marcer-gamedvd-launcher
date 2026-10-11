// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'config.dart';

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
({HatariCommand? command, String? error}) buildHatariCommand(
    DesktopConfig config, String zipPath) {
  final validation = validateHatariConfig(config);
  if (validation != null) return (command: null, error: validation);
  if (zipPath.trim().isEmpty || !File(zipPath).existsSync()) {
    return (command: null, error: 'ZIP file not found: $zipPath');
  }
  final args = hatariArguments(
      config.hatariArgsTemplate, config.resolveHatariConfigFile(), zipPath);
  return (
    command: HatariCommand(config.resolveHatariExecutable(), args,
        config.appDir.isEmpty ? Directory.current.path : config.appDir),
    error: null,
  );
}
