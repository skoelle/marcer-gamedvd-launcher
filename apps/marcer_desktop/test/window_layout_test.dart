// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/window_layout.dart';
import 'package:screen_retriever/screen_retriever.dart';

void main() {
  test('displayWorkArea uses the visible work area and position', () {
    const display = Display(
      id: '1',
      size: Size(1920, 1080),
      visiblePosition: Offset(0, 0),
      visibleSize: Size(1920, 1040),
      scaleFactor: 1,
    );
    final area = displayWorkArea(display)!;
    expect(area.size, const Size(1920, 1040));
    expect(area.position, Offset.zero);
  });

  test('displayWorkArea falls back to the full size', () {
    const display = Display(id: '1', size: Size(1280, 720));
    final area = displayWorkArea(display)!;
    expect(area.size, const Size(1280, 720));
    expect(area.position, Offset.zero);
  });

  test('displayWorkArea ignores an empty display', () {
    const display = Display(id: '1', size: Size.zero);
    expect(displayWorkArea(display), isNull);
  });

  test('clampWindowSize keeps a fitting size', () {
    expect(
      clampWindowSize(const Size(1280, 800), const Size(1920, 1040)),
      const Size(1280, 800),
    );
  });

  test('clampWindowSize shrinks a too-large requested size', () {
    expect(
      clampWindowSize(const Size(2560, 1440), const Size(1920, 1040)),
      const Size(1904, 1024),
    );
  });

  test('clampWindowSize honours the minimum only when it fits', () {
    expect(
      clampWindowSize(const Size(320, 240), const Size(1920, 1040)),
      const Size(640, 480),
    );
    expect(
      clampWindowSize(const Size(320, 240), const Size(500, 400)),
      const Size(484, 384),
    );
  });
}
