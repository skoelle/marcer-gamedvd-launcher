// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/catalog_assets.dart';

void main() {
  test('picks the newest screenshots archive by name timestamp', () {
    final names = [
      'screenshots-20260101-101010.zip',
      'screenshots-20261017-080230.zip',
      'screenshots-20260505-000000.zip',
      'gameinfo-20261017-080230.zip',
      'readme.txt',
    ];
    expect(newestAssetArchiveName(names, CatalogAsset.screenshots),
        'screenshots-20261017-080230.zip');
    expect(newestAssetArchiveName(names, CatalogAsset.gameinfo),
        'gameinfo-20261017-080230.zip');
  });

  test('ignores non-matching names and is case-insensitive on the prefix', () {
    final names = [
      'Screenshots-20261017-080230.ZIP',
      'screenshots-2026.zip',
      'screenshots-20261017-080230.7z',
      'gameinfos-20261017-080230.zip',
    ];
    expect(newestAssetArchiveName(names, CatalogAsset.screenshots),
        'Screenshots-20261017-080230.ZIP');
    expect(newestAssetArchiveName(names, CatalogAsset.gameinfo), isNull);
  });

  test('returns null when no archive matches', () {
    expect(newestAssetArchiveName(const [], CatalogAsset.screenshots), isNull);
    expect(
        newestAssetArchiveName(const ['other-20261017-080230.zip'],
            CatalogAsset.gameinfo),
        isNull);
  });
}
