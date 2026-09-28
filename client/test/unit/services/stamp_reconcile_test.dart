// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Stamp reconciliation (v1.20.0, spec §C; v1.32.0 L2): the edit between
// the old and new text is a common-prefix / common-suffix diff. Stamps
// before the changed middle keep their offset, stamps after it shift by
// the length delta, stamps overlapping it are dropped.

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/stamp_reconcile.dart';
import 'package:tangent/services/transcript_page_text.dart';

const String text = '[00:00] Jeff: Morning\n\n[00:05] Dana: Hi';
const List<TextStamp> stamps = <TextStamp>[
  TextStamp(offset: 0, length: 7, seconds: 0, dumpId: 'd'),
  TextStamp(offset: 23, length: 7, seconds: 5, dumpId: 'd'),
];

TextStamp shifted(TextStamp stamp, int by) => TextStamp(
      offset: stamp.offset + by,
      length: stamp.length,
      seconds: stamp.seconds,
      dumpId: stamp.dumpId,
    );

/// Every kept stamp must still sit on a `[mm:ss]` in the new text —
/// the whole point of shifting is that the range stays true.
void expectStampsPointAtBrackets(String newText, List<TextStamp> kept) {
  for (final stamp in kept) {
    expect(
      newText.substring(stamp.offset, stamp.offset + stamp.length),
      matches(RegExp(r'^\[\d\d:\d\d\]$')),
      reason: 'stamp $stamp does not sit on a bracket in "$newText"',
    );
  }
}

void main() {
  test('fixture stamps really point at their brackets', () {
    expectStampsPointAtBrackets(text, stamps);
  });

  test('idempotent: unchanged text keeps every stamp (same list)', () {
    expect(identical(reconcileStamps(text, text, stamps), stamps), isTrue);
  });

  test('an edit after the last stamp keeps all, unshifted', () {
    expect(reconcileStamps(text, '$text there!', stamps), stamps);
    expect(reconcileStamps(text, '$text\n\nmy own note', stamps), stamps);
  });

  test('an insertion before a stamp shifts it forward (L2)', () {
    const edited = '[00:00] Jeff: Good morning\n\n[00:05] Dana: Hi';
    final kept = reconcileStamps(text, edited, stamps);
    expect(kept, [stamps.first, shifted(stamps.last, 5)]);
    expectStampsPointAtBrackets(edited, kept);
  });

  test('an insertion at the very top shifts every stamp forward', () {
    const edited = 'Note: $text';
    final kept = reconcileStamps(text, edited, stamps);
    expect(kept, [shifted(stamps.first, 6), shifted(stamps.last, 6)]);
    expectStampsPointAtBrackets(edited, kept);
  });

  test('a deletion before a stamp shifts it back', () {
    // "Morning" → "Hi": 5 characters gone before the second stamp.
    const edited = '[00:00] Jeff: Hi\n\n[00:05] Dana: Hi';
    final kept = reconcileStamps(text, edited, stamps);
    expect(kept, [stamps.first, shifted(stamps.last, -5)]);
    expectStampsPointAtBrackets(edited, kept);
  });

  test('a replacement before a stamp shifts by the length delta only', () {
    // Same-length replacement: nothing moves.
    const same = '[00:00] Jeff: Evening\n\n[00:05] Dana: Hi';
    expect(reconcileStamps(text, same, stamps), stamps);
    // Longer replacement: +3.
    const longer = '[00:00] Jeff: Good night\n\n[00:05] Dana: Hi';
    expect(
      reconcileStamps(text, longer, stamps),
      [stamps.first, shifted(stamps.last, 3)],
    );
  });

  test('an edit through a stamp drops that stamp and keeps the rest', () {
    // "[00:5] " — one digit gone from the second stamp; the first is intact.
    final edited = text.replaceFirst('[00:05]', '[00:5]');
    expect(reconcileStamps(text, edited, stamps), [stamps.first]);
  });

  test('a stamp whose slice is now a different time is dropped', () {
    final edited = text.replaceFirst('[00:05]', '[00:06]');
    expect(reconcileStamps(text, edited, stamps), [stamps.first]);
  });

  test('an edit spanning both stamps drops both', () {
    final edited = text.replaceRange(3, 26, 'x');
    expect(reconcileStamps(text, edited, stamps), isEmpty);
  });

  test('replace-all drops every stamp', () {
    expect(reconcileStamps(text, 'Completely new text', stamps), isEmpty);
    expect(reconcileStamps(text, '', stamps), isEmpty);
  });

  test('text truncated before a stamp drops it', () {
    expect(reconcileStamps(text, '[00:00] Jeff', stamps), [stamps.first]);
  });

  test(
      'edits at BOTH ends in one step read as one changed region — '
      'every stamp inside it is dropped, never guessed', () {
    // A prefix/suffix diff has no unchanged prefix or suffix here, so the
    // whole text is the changed middle. Dropping is the honest answer.
    expect(reconcileStamps(text, 'Hi $text!', stamps), isEmpty);
  });

  test(
      'a pure insertion of repeated characters does not double-count '
      'the overlap of prefix and suffix', () {
    const old = '[00:00] aa';
    const stamp = TextStamp(offset: 0, length: 7, seconds: 0, dumpId: 'd');
    // "aa" → "aaa": prefix 9 covers the stamp; the suffix must not claim
    // the same characters and shift it.
    expect(reconcileStamps(old, '[00:00] aaa', [stamp]), [stamp]);
  });

  test('an empty stamp list stays empty', () {
    expect(reconcileStamps(text, 'x', const <TextStamp>[]), isEmpty);
  });

  test('a corrupt stamp (out of range) is dropped rather than throwing', () {
    const bad = TextStamp(offset: 500, length: 7, seconds: 1, dumpId: 'd');
    expect(reconcileStamps(text, '$text!', [bad, ...stamps]), stamps);
    // Even when the edit is a prepend that would otherwise shift it.
    expect(
      reconcileStamps(text, 'x$text', [bad]),
      isEmpty,
    );
  });
}
