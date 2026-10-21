// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/local_assets.dart';
import 'package:marcer_desktop/widgets/local_assets_chips.dart';
import 'package:path/path.dart' as p;

List<int> _zipWith(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

void main() {
  late Directory tmp;
  late String root;
  late String patch;
  const gameRel =
      'Title Sorted/Cracked Games - Title Sorted/A/Alpha';

  String gameDir(String layer) => p.join(tmp.path, layer, gameRel);

  void write(String layer, String rel, List<int> bytes) {
    final f = File(p.join(gameDir(layer), rel));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('local_assets_test');
    root = p.join(tmp.path, 'root');
    patch = p.join(tmp.path, 'patch');

    // Boxscan: loose images + an edition subfolder + a ZIP with flat,
    // container and nested image entries, plus a non-image entry.
    write('root', 'Boxscan/front.png', [1]);
    write('root', 'Boxscan/back.jpg', [2]);
    write('root', 'Boxscan/Frenchbox/cover.png', [3]);
    write(
        'root',
        'Boxscan/set.zip',
        _zipWith({
          'container/a.jpg': [10],
          'container/b.png': [11],
          'container/readme.txt': [12],
          'container/sub/c.jpg': [13],
        }));
    // Case/space variant in the patch layer + an extra edition file.
    write('patch', 'box scan/spaced.png', [4]);

    // Manual: scan/text pair, image pages, disk image, loose documents and a
    // plain PDF.
    write(
        'root',
        'Manual/Alien Syndrome.zip',
        _zipWith({'Alien Syndrome.pdf': [20]}));
    write(
        'root',
        'Manual/Alien Syndrome_text.zip',
        _zipWith({'Alien Syndrome_text.pdf': [21]}));
    write(
        'root',
        'Manual/image_manual.zip',
        _zipWith({'p1.jpg': [30], 'p2.png': [31]}));
    write('root', 'Manual/disk.zip', _zipWith({'game.msa': [40]}));
    write('root', 'Manual/loose.pdf', [50]);
    write('root', 'Manual/guide.doc', [51]);
    write('root', 'Manual/readme.txt', [52]);
    // Patch manual (plural spelling).
    write('patch', 'Manuals/patch.pdf', [60]);

    // Hidden NAS metadata must be ignored.
    write('root', '@eaDir/ignored.png', [99]);
    write('root', 'Boxscan/@eaDir/ignored.png', [99]);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('discovers box scans from loose files, editions and ZIPs', () {
    final assets = discoverSync(root, patch, gameRel);
    final labels = assets.boxscans.map((e) => e.label).toList();
    expect(labels, containsAll(<String>['Boxscan', 'Frenchbox', 'set']));

    final all = {
      for (final e in assets.boxscans)
        for (final i in e.images) i.name,
    };
    expect(all, containsAll(<String>[
      'front.png',
      'back.jpg',
      'cover.png',
      'spaced.png',
      'a.jpg',
      'b.png',
      'c.jpg',
    ]));
    // Non-image ZIP entries and @eaDir images are ignored.
    expect(all, isNot(contains('readme.txt')));
    expect(all, isNot(contains('ignored.png')));
    expect(assets.boxscanImageCount, 7);
  });

  test('discovers manuals: scan/text pair, pages, disk image, documents', () {
    final assets = discoverSync(root, patch, gameRel);
    final byStem = <String, List<LocalManualDoc>>{};
    for (final doc in assets.manuals) {
      byStem.putIfAbsent(doc.stem.toLowerCase(), () => []).add(doc);
    }

    final alien = byStem['alien syndrome']!;
    expect(alien.length, 2);
    expect(alien.where((d) => d.kind == LocalManualKind.pdf).length, 2);
    expect(alien.where((d) => d.textVariant).length, 1);

    final images = byStem['image_manual']!.single;
    expect(images.kind, LocalManualKind.imagePages);
    expect(images.images.map((i) => i.name), ['p1.jpg', 'p2.png']);

    final disk = byStem['disk']!.single;
    expect(disk.kind, LocalManualKind.diskImage);

    final readme = byStem['readme']!.single;
    expect(readme.kind, LocalManualKind.document);
    final guide = byStem['guide']!.single;
    expect(guide.kind, LocalManualKind.document);
    final loose = byStem['loose']!.single;
    expect(loose.kind, LocalManualKind.pdf);

    // Patch layer (plural Manuals/) is merged.
    expect(byStem['patch']!.single.kind, LocalManualKind.pdf);
  });

  test('discover() runs in an isolate and returns the same assets', () async {
    final service = LocalAssetsService();
    final assets = await service.discover(
      rootDirectory: root,
      patchDirectory: patch,
      gameRel: gameRel,
    );
    expect(assets.isEmpty, isFalse);
    expect(assets.boxscanImageCount, 7);
    expect(assets.manuals, isNotEmpty);
  });

  test('materializes loose and in-ZIP images on demand', () async {
    final service = LocalAssetsService();
    final assets = await service.discover(
      rootDirectory: root,
      patchDirectory: patch,
      gameRel: gameRel,
    );
    final set = assets.boxscans.firstWhere((e) => e.label == 'set');
    final inZip = set.images.firstWhere((i) => i.name == 'a.jpg');
    final extracted = await service.materializeImage(inZip);
    expect(extracted, isNotNull);
    expect(File(extracted!).readAsBytesSync(), [10]);

    final loose = assets.boxscans
        .expand((e) => e.images)
        .firstWhere((i) => i.name == 'front.png');
    expect(await service.materializeImage(loose),
        loose.loosePath);
  });

  test('materializes all images of an edition in one call', () async {
    final service = LocalAssetsService();
    final assets = await service.discover(
      rootDirectory: root,
      patchDirectory: patch,
      gameRel: gameRel,
    );
    final set = assets.boxscans.firstWhere((e) => e.label == 'set');
    final paths = await service.materializeEdition(set);
    expect(paths, hasLength(3));
    for (final image in set.images) {
      final path = paths[image.cacheKey];
      expect(path, isNotNull, reason: image.name);
      expect(File(path!).existsSync(), isTrue);
      expect(File(path).lengthSync(), greaterThan(0));
    }
  });

  test('materializes a manual PDF from its ZIP', () async {
    final service = LocalAssetsService();
    final assets = await service.discover(
      rootDirectory: root,
      patchDirectory: patch,
      gameRel: gameRel,
    );
    final doc = assets.manuals.firstWhere(
        (d) => d.stem.toLowerCase() == 'alien syndrome' && !d.textVariant);
    final path = await service.materializeDoc(doc);
    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), [20]);
  });

  testWidgets('renders the boxscan/manual chips', (tester) async {
    const assets = LocalGameAssets(
      boxscans: [
        LocalBoxscanEdition('Boxscan', [
          LocalImageRef(name: 'a.png', edition: 'Boxscan', loosePath: '/a.png'),
          LocalImageRef(name: 'b.png', edition: 'Boxscan', loosePath: '/b.png'),
        ]),
      ],
      manuals: [
        LocalManualDoc(
          stem: 'Alone',
          label: 'Alone.pdf',
          kind: LocalManualKind.pdf,
          textVariant: false,
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LocalAssetsChips(
          assets: Future.value(assets),
          service: LocalAssetsService(),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Box scans (2)'), findsOneWidget);
    expect(find.text('Manuals (1)'), findsOneWidget);
  });

  testWidgets('clears the chips immediately when the card changes',
      (tester) async {
    final first = Completer<LocalGameAssets>()
      ..complete(const LocalGameAssets(boxscans: [
        LocalBoxscanEdition('Boxscan', [
          LocalImageRef(name: 'a.png', edition: 'Boxscan', loosePath: '/a.png'),
        ]),
      ]));
    final second = Completer<LocalGameAssets>();

    Widget build(Future<LocalGameAssets> assets) => MaterialApp(
          home: Scaffold(
            body: LocalAssetsChips(
              assets: assets,
              service: LocalAssetsService(),
            ),
          ),
        );

    await tester.pumpWidget(build(first.future));
    await tester.pump();
    expect(find.text('Box scans (1)'), findsOneWidget);

    await tester.pumpWidget(build(second.future));
    await tester.pump();
    expect(find.text('Box scans (1)'), findsNothing);
    expect(find.text('Manuals (1)'), findsNothing);

    second.complete(const LocalGameAssets(manuals: [
      LocalManualDoc(
        stem: 'Alone',
        label: 'Alone.pdf',
        kind: LocalManualKind.pdf,
        textVariant: false,
      ),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Box scans (1)'), findsNothing);
    expect(find.text('Manuals (1)'), findsOneWidget);
  });
}
