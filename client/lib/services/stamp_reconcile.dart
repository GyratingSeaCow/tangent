// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Stamp reconciliation after a text edit (v1.20.0, spec §C).
//
// Stamps are character ranges, and a text block is a free editor: any edit
// can shift or destroy them. The rule is deliberately dumb — no diffing
// heroics: a stamp survives ONLY if the new text still has exactly the same
// `[…]` characters at exactly the same place. Everything else is dropped.
// A stamp that silently pointed at the wrong time would be worse than no
// stamp at all.

import 'transcript_page_text.dart';

/// The stamps from [oldText] that still hold in [newText].
///
/// A stamp is kept when [newText] has `[` at [TextStamp.offset] and the
/// [TextStamp.length]-character slice there is identical to the slice in
/// [oldText]. Stamps are NOT shifted: an insertion before a stamp drops it.
/// Pure; returns [stamps] itself when the text is unchanged.
List<TextStamp> reconcileStamps(
  String oldText,
  String newText,
  List<TextStamp> stamps,
) {
  if (stamps.isEmpty) return stamps;
  if (oldText == newText) return stamps;
  return List<TextStamp>.unmodifiable(<TextStamp>[
    for (final TextStamp stamp in stamps)
      if (_stillHolds(oldText, newText, stamp)) stamp,
  ]);
}

bool _stillHolds(String oldText, String newText, TextStamp stamp) {
  final int end = stamp.offset + stamp.length;
  if (stamp.offset < 0 || stamp.length <= 0) return false;
  if (end > oldText.length || end > newText.length) return false;
  if (newText.codeUnitAt(stamp.offset) != 0x5B /* [ */) return false;
  return oldText.substring(stamp.offset, end) ==
      newText.substring(stamp.offset, end);
}
