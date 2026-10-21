// Copyright (c) 2026 Stefan Koelle (https://stefankoelle.de)
// Licensed under the MIT License. See LICENSE file in project root for details.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marcer_desktop/theme.dart';

void main() {
  test('desktop scrollbars remain visible while the content is scrollable', () {
    final theme = buildAppTheme();
    expect(
      theme.scrollbarTheme.thumbVisibility?.resolve(<WidgetState>{}),
      isTrue,
    );
  });
}
