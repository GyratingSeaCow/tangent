// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Stamp reconciliation after a text edit (v1.20.0, spec §C; v1.32.0 L2).
//
// Stamps are character ranges, and a text block is a free editor: any edit
// can shift or destroy them. v1.20.0 kept a stamp only at its exact old
// offset, so typing anywhere ABOVE a stamp silently lost it. L2 adds the
// one diff that is cheap and unambiguous — common prefix / common suffix
// — so an edit shifts the stamps after it instead of dropping them:
//
//   * a stamp entirely inside the unchanged prefix keeps its offset;
//   * a stamp entirely inside the unchanged suffix shifts by
//     `new.length - old.length`;
//   * a stamp overlapping the changed middle is dropped (as before).
//
// Still no diffing heroics beyond that: a stamp that silently pointed at
// the wrong time would be worse than no stamp at all.

import 'transcript_page_text.dart';

/// The stamps from [oldText] that still hold in [newText], re-offset for
/// the edit between the two.
///
/// The edit is modelled as ONE changed region: the longest common prefix
/// and the longest common suffix of the two texts are unchanged, and
/// everything between them was replaced. Stamps before the region keep
/// their offset; stamps after it shift by the length delta; stamps that
/// touch it are dropped. Pure; returns [stamps] itself when the text is
/// unchanged.
List<TextStamp> reconcileStamps(
  String oldText,
  String newText,
  List<TextStamp> stamps,
) {
  if (stamps.isEmpty) return stamps;
  if (oldText == newText) return stamps;
  final int prefix = _commonPrefix(oldText, newText);
  final int suffix = _commonSuffix(oldText, newText, prefix);
  final int delta = newText.length - oldText.length;
  final int oldSuffixStart = oldText.length - suffix;
  return List<TextStamp>.unmodifiable(<TextStamp>[
    for (final TextStamp stamp in stamps)
      if (_inRange(stamp, oldText))
        if (stamp.offset + stamp.length <= prefix)
          stamp
        else if (stamp.offset >= oldSuffixStart)
          TextStamp(
            offset: stamp.offset + delta,
            length: stamp.length,
            seconds: stamp.seconds,
            dumpId: stamp.dumpId,
          ),
  ]);
}

/// A corrupt stamp (negative, empty, or past the end of the text it was
/// recorded against) is dropped rather than shifted or thrown on.
bool _inRange(TextStamp stamp, String oldText) =>
    stamp.offset >= 0 &&
    stamp.length > 0 &&
    stamp.offset + stamp.length <= oldText.length;

/// Length of the longest common prefix of [a] and [b].
int _commonPrefix(String a, String b) {
  final int limit = a.length < b.length ? a.length : b.length;
  int i = 0;
  while (i < limit && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return i;
}

/// Length of the longest common suffix of [a] and [b] that does not
/// overlap the [prefix] already matched — a pure insertion of `aa` into
/// `aa` must not count the same characters twice.
int _commonSuffix(String a, String b, int prefix) {
  final int limit = (a.length < b.length ? a.length : b.length) - prefix;
  int i = 0;
  while (i < limit &&
      a.codeUnitAt(a.length - 1 - i) == b.codeUnitAt(b.length - 1 - i)) {
    i++;
  }
  return i;
}
