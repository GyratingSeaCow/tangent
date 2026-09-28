// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One-time back-fill of the v1.15.0 rewrite-in-place (spec §2).
//
// v1.15.0 wrote speaker names INTO the transcript (`## Speaker 1` became
// `## Jeff`). v1.17.0 keeps names in `dumps.speaker_names` and the text
// raw. This module plans the conversion for one transcript; the v20
// database migration applies it to every row and records what it did.

import '../models/speaker_names.dart';
import 'render_speaker_names.dart';
import 'speaker_naming.dart';

/// What the back-fill would do to one transcript.
class SpeakerNamesBackfillPlan {
  const SpeakerNamesBackfillPlan({
    required this.names,
    required this.transcript,
    required this.rewrittenHeadings,
  });

  /// The recovered map (`Speaker k` → heading k).
  final SpeakerNames names;

  /// The transcript with raw labels restored.
  final String transcript;

  /// The user headings that were turned back into raw labels, in document
  /// order — the undo record.
  final List<String> rewrittenHeadings;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'names': names.toJson(),
        'rewrittenHeadings': rewrittenHeadings,
      };
}

final RegExp _rawLabel = RegExp(r'^Speaker (\d+)$');

/// Null when [transcript] carries no user speaker heading
/// ([hasUserSpeakerNames] is false — raw `Speaker N`, `[unattributed]` and
/// known section headings such as `## Summary` are never speakers), or
/// when the pairing is not safe (see below).
///
/// Pairing: the non-section `## ` headings in document order are
/// `Speaker 1..k` (heading k ⇔ `Speaker k`, the rule the export's
/// `resolveSpeakerNames` uses). The plan is refused — nothing rewritten —
/// when a raw heading sits at the wrong position or a label we would
/// assign already heads a different section: rewriting there would merge
/// two speakers, and leaving the text as it was is the safe failure.
/// True when [transcript] carries user speaker headings the back-fill
/// REFUSED to convert ([planSpeakerNamesBackfill] returned null for an
/// ambiguous pairing, not for lack of anything to do). The migration
/// records these dump ids so Home can surface them once (leftovers
/// sweep L5); a raw or never-renamed transcript is not a skip.
bool speakerNamesBackfillRefused(String transcript) =>
    hasUserSpeakerNames(transcript) &&
    planSpeakerNamesBackfill(transcript) == null;

SpeakerNamesBackfillPlan? planSpeakerNamesBackfill(String transcript) {
  if (!hasUserSpeakerNames(transcript)) return null;
  final List<String> headings = speakerHeadings(transcript);
  final Set<String> present = headings.toSet();
  final Map<String, String> map = <String, String>{};
  final List<String> rewritten = <String>[];
  for (int i = 0; i < headings.length; i++) {
    final String heading = headings[i];
    final String label = 'Speaker ${i + 1}';
    final RegExpMatch? raw = _rawLabel.firstMatch(heading);
    if (raw != null) {
      if (heading != label) return null; // raw label out of position
      continue;
    }
    if (present.contains(label)) return null; // would merge two speakers
    map[label] = heading;
    rewritten.add(heading);
  }
  if (map.isEmpty) return null;
  final SpeakerNames names = SpeakerNames(map);
  return SpeakerNamesBackfillPlan(
    names: names,
    transcript: unrenderSpeakerNames(transcript, names),
    rewrittenHeadings: rewritten,
  );
}
