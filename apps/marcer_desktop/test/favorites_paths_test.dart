// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/favorites_paths.dart';

void main() {
  late Directory tmp;
  late String root;
  late String patch;
  late FavoritesPathCodec codec;

  const crackedTree = 'Title Sorted/Cracked Games - Title Sorted';
  const pdTree = 'Title Sorted/PD Games - Title Sorted';
  const crackedRel = '$crackedTree/D/Dal X/Dal X.zip';
  const pdRel = '$pdTree/P/PacMan/pacman.zip';

  void write(String base, String rel) {
    final file = File('$base/$rel');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('zip');
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('favorites_paths_test');
    root = '${tmp.path}/root';
    patch = '${tmp.path}/patch';
    write(root, crackedRel);
    write(patch, pdRel);
    codec = FavoritesPathCodec(
      rootDirectory: root,
      patchDirectory: patch,
      sectionTrees: const {'cracked': crackedTree, 'pd': pdTree},
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('encodes paths below the roots as root-relative POSIX paths', () {
    expect(codec.encode('$root/$crackedRel'), crackedRel);
    expect(codec.encode('$patch/$pdRel'), pdRel);
  });

  test('decodes relative paths, preferring the patch layer', () {
    expect(codec.decode(crackedRel), '$root/$crackedRel');
    expect(codec.decode(pdRel), '$patch/$pdRel');
  });

  test('decodes legacy Windows root paths', () {
    final legacy =
        'Y:\\Downloads\\MarcersGameDVD\\${crackedRel.replaceAll('/', '\\')}';
    expect(codec.decode(legacy), '$root/$crackedRel');
  });

  test('decodes legacy Windows patch paths', () {
    final legacy =
        'Y:\\Dropbox\\GamesPack\\Patch\\${pdRel.replaceAll('/', '\\')}';
    expect(codec.decode(legacy), '$patch/$pdRel');
  });

  test('decodes legacy Linux absolute paths', () {
    expect(codec.decode('$root/$crackedRel'), '$root/$crackedRel');
  });

  test('maps legacy paths case-insensitively', () {
    final legacy =
        'Y:\\Downloads\\MarcersGameDVD\\${crackedRel.replaceAll('/', '\\').toLowerCase()}';
    expect(codec.decode(legacy), '$root/$crackedRel');
  });

  test('keeps unresolvable foreign paths absolute', () {
    const foreign = r'Z:\Other\missing.zip';
    expect(codec.decode(foreign), 'Z:/Other/missing.zip');
    expect(codec.encode('Z:/Other/missing.zip'), 'Z:/Other/missing.zip');
  });

  test('resolves relative paths with backslashes', () {
    expect(codec.decode(crackedRel.replaceAll('/', '\\')), '$root/$crackedRel');
  });

  test('keeps missing relative paths under the root for later display', () {
    expect(codec.decode('$crackedTree/M/Missing/missing.zip'),
        '$root/$crackedTree/M/Missing/missing.zip');
  });

  test('does not escape the roots with relative traversal', () {
    expect(codec.decode('../outside.zip'), '../outside.zip');
  });
}
