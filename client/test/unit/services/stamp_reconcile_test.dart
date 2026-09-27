// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Stamp reconciliation (v1.20.0, spec §C): a stamp survives an edit ONLY if
// the new text still has the identical `[…]` slice at the identical offset.
// No shifting, no diffing.

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/stamp_reconcile.dart';
import 'package:tangent/services/transcript_page_text.dart';

const String text = '[00:00] Jeff: Morning\n\n[00:05] Dana: Hi';
const List<TextStamp> stamps = <TextStamp>[
  TextStamp(offset: 0, length: 7, seconds: 0, dumpId: 'd'),
  TextStamp(offset: 23, length: 7, seconds: 5, dumpId: 'd'),
];

void main() {
  test('fixture stamps really point at their brackets', () {
    for (final stamp in stamps) {
      expect(
        text.substring(stamp.offset, stamp.offset + stamp.length),
        matches(RegExp(r'^\[\d\d:\d\d\]$')),
      );
    }
  });

  test('unchanged text keeps every stamp (same list)', () {
    expect(identical(reconcileStamps(text, text, stamps), stamps), isTrue);
  });

  test('an edit after the last stamp keeps all', () {
    expect(reconcileStamps(text, '$text there!', stamps), stamps);
    expect(reconcileStamps(text, '$text\n\nmy own note', stamps), stamps);
  });

  test('an insertion before a stamp drops it — stamps are never shifted', () {
    final kept = reconcileStamps(
      text,
      '[00:00] Jeff: Good morning\n\n[00:05] Dana: Hi',
      stamps,
    );
    expect(kept, [stamps.first]);
  });

  test('an insertion at the very top drops every stamp', () {
    expect(reconcileStamps(text, 'Note: $text', stamps), isEmpty);
  });

  test('a deletion inside a stamp drops it', () {
    // "[00:5] " — one digit gone from the second stamp; the first is intact.
    final edited = text.replaceFirst('[00:05]', '[00:5]');
    expect(reconcileStamps(text, edited, stamps), [stamps.first]);
  });

  test('a stamp whose slice is now a different time is dropped', () {
    final edited = text.replaceFirst('[00:05]', '[00:06]');
    expect(reconcileStamps(text, edited, stamps), [stamps.first]);
  });

  test('text truncated before a stamp drops it', () {
    expect(reconcileStamps(text, '[00:00] Jeff', stamps), [stamps.first]);
    expect(reconcileStamps(text, '', stamps), isEmpty);
  });

  test('an empty stamp list stays empty', () {
    expect(reconcileStamps(text, 'x', const <TextStamp>[]), isEmpty);
  });

  test('a corrupt stamp (out of range) is dropped rather than throwing', () {
    const bad = TextStamp(offset: 500, length: 7, seconds: 1, dumpId: 'd');
    expect(reconcileStamps(text, '$text!', [bad, ...stamps]), stamps);
  });
}
