// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../piratefinder_data.dart';
import '../piratefinder_names.dart';

/// Opens the original PirateFinder project page in the external browser.
Future<void> openPirateFinderProject(BuildContext context) async {
  final opened = await launchUrl(
    Uri.parse(kPirateFinderProjectUrl),
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'Could not open the $kPirateFinderCatalogShortName GitHub page.',
        ),
      ),
    );
  }
}

/// Small "PirateFinder-Catalog on GitHub" text button for the data rows/dialogs.
class PirateFinderGithubLink extends StatelessWidget {
  const PirateFinderGithubLink({super.key, this.fontSize = 10});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => openPirateFinderProject(context),
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: Colors.lightBlueAccent,
      ),
      child: Text(
        '$kPirateFinderCatalogShortName on GitHub',
        style: TextStyle(fontSize: fontSize),
      ),
    );
  }
}
