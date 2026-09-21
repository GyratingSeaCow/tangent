// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The lasso footprint helper's safety net: a block whose real rendered size
// cannot be measured (no key, key not attached to a laid-out element) falls
// back to the nominal 300x90 canonical box instead of crashing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/notebook/notebook_editor_screen.dart';

void main() {
  // GlobalKey.currentContext consults the widgets binding even when the key
  // was never mounted; the fallback path needs it initialized.
  TestWidgetsFlutterBinding.ensureInitialized();

  const NotebookTextBlock text =
      NotebookTextBlock(id: 't1', text: 'hello', x: 24, y: 40);

  test('a text row with no measure key falls back to the nominal 300x90', () {
    expect(lassoBlockFootprint(text, null), const Size(300, 90));
  });

  test('a text row whose key has no laid-out context falls back, no crash',
      () {
    // A key that was never attached to a widget: currentContext is null,
    // exactly the state of a block not currently laid out.
    expect(lassoBlockFootprint(text, GlobalKey()), const Size(300, 90));
  });

  test('an image block reports its real model size even unmeasured', () {
    const NotebookImageBlock image = NotebookImageBlock(
      id: 'i1',
      data: '',
      mime: 'image/png',
      x: 10,
      y: 10,
      width: 480,
      height: 260,
    );
    expect(lassoBlockFootprint(image, null), const Size(480, 260));
  });

  test('a dump card stays on the nominal box the 40% threshold was tuned on',
      () {
    const NotebookDumpCardBlock card =
        NotebookDumpCardBlock(id: 'c1', dumpId: 'd1', x: 24, y: 120);
    expect(lassoBlockFootprint(card, GlobalKey()), const Size(300, 90));
  });
}
