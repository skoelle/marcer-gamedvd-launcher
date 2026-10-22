// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'dart:math' as math;
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';

/// Logical window geometry (outer window rect).
class WindowPlacement {
  const WindowPlacement({required this.position, required this.size});

  final Offset position;
  final Size size;
}

/// The usable work area of [display] in logical pixels (excludes the taskbar),
/// or `null` when the display reports no usable size.
WindowPlacement? displayWorkArea(Display display) {
  final size = display.visibleSize ?? display.size;
  if (size.width <= 0 || size.height <= 0) return null;
  return WindowPlacement(
    position: display.visiblePosition ?? Offset.zero,
    size: size,
  );
}

/// Clamps [requested] into [visible] (logical pixels), keeping a small margin
/// and never exceeding the display. Used for the non-maximized restore size
/// so a configured size larger than the screen cannot be cut off.
Size clampWindowSize(
  Size requested,
  Size visible, {
  Size minimum = const Size(640, 480),
  double margin = 8,
}) {
  final maxWidth = visible.width - margin * 2;
  final maxHeight = visible.height - margin * 2;
  if (maxWidth <= 0 || maxHeight <= 0) return requested;
  final width = _clamp(
      requested.width, math.min(minimum.width, maxWidth), maxWidth);
  final height = _clamp(
      requested.height, math.min(minimum.height, maxHeight), maxHeight);
  return Size(width, height);
}

double _clamp(double value, double lower, double upper) {
  if (upper <= lower) return upper;
  if (value < lower) return lower;
  if (value > upper) return upper;
  return value;
}
