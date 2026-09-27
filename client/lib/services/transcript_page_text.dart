// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Rendered transcript block (v1.20.0,
// docs/design/2026-09-27-transcript-to-notebook.md §B).
//
// ONE pure renderer that turns a dump into the text a notebook text block
// carries, plus the character ranges inside it that are live timestamps.
// Mirrors the v1.16 Markdown export and REUSES its helpers
// (`resolveSpeakerNames`, `needsHourStamps`, `formatSegmentStamp`) so the
// page and the export can never disagree about a name or a stamp width.

import '../data/local_db.dart';
import '../models/speaker_names.dart';
import '../models/text_stamp.dart';
import 'render_speaker_names.dart';
import 'transcript_markdown.dart';
import 'transcript_timings.dart';

export '../models/text_stamp.dart' show TextStamp;

/// The rendered transcript: block [text] and the [stamps] inside it.
class TranscriptPageText {
  const TranscriptPageText({required this.text, required this.stamps});

  final String text;
  final List<TextStamp> stamps;

  bool get isEmpty => text.trim().isEmpty;
}

final RegExp _headingLine = RegExp(r'^## (.*?)\s*$');

/// The transcript as page text.
///
/// Rules (spec §B):
///  - With [timings]: one paragraph per speaker TURN (a run of consecutive
///    segments by the same speaker), `[mm:ss] Name: text…`, blank line
///    between turns; `[h:mm:ss]` for the whole block once any segment is
///    ≥ 1 h. Names resolve exactly as the Markdown export does — the
///    speaker-name map first, heading pairing second, raw label last.
///    Segments without a speaker (mono transcript) are their own paragraphs,
///    stamped per segment: `[mm:ss] text`.
///  - Without timings: turns come from the transcript's `## <label>`
///    sections rendered through the name map — `Name: text` — with NO
///    stamps (never fake a time). A transcript with no headings is returned
///    as-is.
///  - No `##` headings, no frontmatter, blank text → empty result.
///
/// Every stamp's [TextStamp.offset] is the index of its `[` and
/// [TextStamp.length] runs through the `]`.
TranscriptPageText transcriptPageText({
  required DumpRow dump,
  required TranscriptTimings? timings,
  required SpeakerNames speakerNames,
}) {
  final String? transcript = dump.transcript;
  if (timings != null) {
    final TranscriptPageText stamped = _fromTimings(
      dump: dump,
      transcript: transcript,
      timings: timings,
      speakerNames: speakerNames,
    );
    if (!stamped.isEmpty) return stamped;
  }
  return TranscriptPageText(
    text: _fromText(transcript, speakerNames),
    stamps: const <TextStamp>[],
  );
}

TranscriptPageText _fromTimings({
  required DumpRow dump,
  required String? transcript,
  required TranscriptTimings timings,
  required SpeakerNames speakerNames,
}) {
  final bool hours = needsHourStamps(timings);
  final Map<String, String> names = resolveSpeakerNames(
    transcript: transcript,
    timings: timings,
    names: speakerNames,
  );
  final StringBuffer out = StringBuffer();
  final List<TextStamp> stamps = <TextStamp>[];

  // A turn under construction: who, when it started, and its sentences.
  String? turnSpeaker;
  double? turnStart;
  final List<String> turnText = <String>[];

  void flush() {
    if (turnText.isEmpty) return;
    if (out.isNotEmpty) out.write('\n\n');
    final String stamp = formatSegmentStamp(turnStart!, hours: hours);
    stamps.add(
      TextStamp(
        offset: out.length,
        length: stamp.length,
        seconds: turnStart!,
        dumpId: dump.id,
      ),
    );
    out.write(stamp);
    out.write(' ');
    final String? speaker = turnSpeaker;
    if (speaker != null) out.write('${names[speaker] ?? speaker}: ');
    out.write(turnText.join(' '));
    turnText.clear();
    turnSpeaker = null;
    turnStart = null;
  }

  for (final TimedSegment segment in timings.segments) {
    final String text = segment.text.trim();
    if (text.isEmpty) continue;
    final String? speaker = segment.speaker;
    // Mono segments never merge: each is its own stamped paragraph.
    final bool continues =
        turnText.isNotEmpty && speaker != null && speaker == turnSpeaker;
    if (!continues) {
      flush();
      turnSpeaker = speaker;
      turnStart = segment.start;
    }
    turnText.add(text);
  }
  flush();
  return TranscriptPageText(
    text: out.toString(),
    stamps: List<TextStamp>.unmodifiable(stamps),
  );
}

/// No timings: `## <label>` sections become `Name: body` paragraphs with the
/// map applied; headingless text passes through trimmed.
String _fromText(String? transcript, SpeakerNames speakerNames) {
  if (transcript == null || transcript.trim().isEmpty) return '';
  final String rendered = renderSpeakerNames(transcript, speakerNames);
  final List<String> lines = rendered.replaceAll('\r\n', '\n').split('\n');
  if (!lines.any((String l) => _headingLine.hasMatch(l))) {
    return rendered.trim();
  }
  final List<String> paragraphs = <String>[];
  String? heading;
  final List<String> body = <String>[];

  void flush() {
    final String text = body.join('\n').trim();
    body.clear();
    if (text.isEmpty) return;
    paragraphs.add(heading == null ? text : '$heading: $text');
  }

  for (final String line in lines) {
    final RegExpMatch? match = _headingLine.firstMatch(line);
    if (match != null) {
      flush();
      heading = match.group(1);
      continue;
    }
    body.add(line);
  }
  flush();
  return paragraphs.join('\n\n');
}
