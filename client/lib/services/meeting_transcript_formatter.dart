// SPDX-License-Identifier: AGPL-3.0-or-later

/// Meeting-mode transcript presentation.
///
/// The server may return a diarised `segments` array alongside the plain
/// transcript text. Meeting dumps render those segments as a per-speaker
/// digest; every other mode keeps the plain text untouched. Nothing here
/// touches storage — the formatted string is simply what the caller persists
/// into the existing transcript column.
library;

/// One diarised slice of a transcription result.
final class TranscriptSegment {
  const TranscriptSegment({
    required this.start,
    required this.text,
    this.end,
    this.speaker,
  });

  /// Elapsed seconds from the start of the recording.
  final double start;

  /// Elapsed seconds at which this slice ends, when the server reports it.
  final double? end;

  /// Diarised speaker label, or null when the server could not attribute it.
  final String? speaker;

  /// Spoken text for this slice.
  final String text;
}

/// Reads a raw `segments` payload into typed segments.
///
/// Every shape the server has not promised is discarded rather than trusted:
/// non-list payloads, non-map entries, and entries without usable text all
/// drop out. A missing, unparsable, or negative `start` becomes 0 so a block
/// still renders at a legal timestamp.
List<TranscriptSegment> parseTranscriptSegments(Object? raw) {
  if (raw is! Iterable) return const [];
  final segments = <TranscriptSegment>[];
  for (final entry in raw) {
    if (entry is TranscriptSegment) {
      if (entry.text.trim().isEmpty) continue;
      segments.add(
        TranscriptSegment(
          start: _seconds(entry.start),
          end: entry.end == null ? null : _seconds(entry.end),
          speaker: _label(entry.speaker),
          text: entry.text.trim(),
        ),
      );
      continue;
    }
    if (entry is! Map) continue;
    final text = entry['text'];
    if (text is! String || text.trim().isEmpty) continue;
    final end = entry['end'];
    segments.add(
      TranscriptSegment(
        start: _seconds(entry['start']),
        end: end == null ? null : _seconds(end),
        speaker: _label(entry['speaker']),
        text: text.trim(),
      ),
    );
  }
  return segments;
}

/// Renders [segments] as a per-speaker digest (Option A).
///
/// Mirror of the server's `format_meeting_transcript` — keep the two in
/// lockstep, byte for byte. One `## Speaker N` section per speaker, ordered
/// by that speaker's FIRST APPEARANCE in the recording (the diarization
/// backend's raw labels are arbitrary, so they are renumbered: whoever
/// speaks first is Speaker 1). Within a section each segment is its own
/// line, in chronological order. Text diarization could not attribute lands
/// in a final `## [unattributed]` section, always last.
///
/// When diarization produced no speakers at all, falls back to the
/// timestamped-paragraph rendering — better than one giant unattributed
/// section. Returns null when nothing is renderable, which leaves the
/// caller on its existing plain-text path.
String? formatMeetingTranscript(List<TranscriptSegment> segments) {
  final entries = <_Entry>[];
  for (final segment in segments) {
    final text = segment.text.trim();
    if (text.isEmpty) continue;
    entries.add(
      _Entry(_seconds(segment.start), _label(segment.speaker), text),
    );
  }
  if (entries.isEmpty) return null;
  if (entries.every((entry) => entry.speaker == null)) {
    return _formatTimestampedParagraphs(entries);
  }
  // Stable chronological order: ties keep payload order (List.sort is not
  // stable, so the original index breaks ties — matching Python's sorted).
  final indexed = entries.asMap().entries.toList()
    ..sort((a, b) {
      final byStart = a.value.start.compareTo(b.value.start);
      return byStart != 0 ? byStart : a.key.compareTo(b.key);
    });
  final attributed = <String, List<String>>{};
  final unattributed = <String>[];
  for (final entry in indexed.map((e) => e.value)) {
    final speaker = entry.speaker;
    if (speaker == null) {
      unattributed.add(entry.text);
    } else {
      attributed.putIfAbsent(speaker, () => []).add(entry.text);
    }
  }
  final sections = <String>[];
  var index = 1;
  for (final texts in attributed.values) {
    sections.add('## Speaker $index\n\n${texts.join('\n')}');
    index += 1;
  }
  if (unattributed.isNotEmpty) {
    sections.add('## [unattributed]\n\n${unattributed.join('\n')}');
  }
  return sections.join('\n\n');
}

/// Convenience over [parseTranscriptSegments] + [formatMeetingTranscript] for
/// callers holding an untyped server payload.
String? formatMeetingTranscriptFromResult(Object? raw) =>
    formatMeetingTranscript(parseTranscriptSegments(raw));

final class _Entry {
  const _Entry(this.start, this.speaker, this.text);
  final double start;
  final String? speaker;
  final String text;
}

/// The pre-digest rendering, kept as the zero-speaker fallback.
///
/// Consecutive segments merge into one paragraph while the speaker label is
/// unchanged (both-null counts as unchanged): named speakers merge for their
/// whole turn, and unattributed segments merge until a minute boundary passes
/// (the paragraph's first segment and the candidate segment fall in different
/// whole minutes), so a solo recording reads as prose with a `[MM:SS]` marker
/// roughly once a minute instead of a heading every few seconds. A speaker
/// label is never invented; attributed paragraphs render as
/// `[MM:SS] Name: text`.
String _formatTimestampedParagraphs(List<_Entry> entries) {
  final blocks = <_Block>[];
  for (final entry in entries) {
    final last = blocks.isEmpty ? null : blocks.last;
    if (last != null && last.speaker == entry.speaker) {
      final sameMinute = entry.start ~/ 60 == last.start ~/ 60;
      if (entry.speaker != null || sameMinute) {
        last.texts.add(entry.text);
        continue;
      }
    }
    blocks.add(_Block(entry.start, entry.speaker, [entry.text]));
  }
  return blocks.map((block) {
    final marker = '[${_timestamp(block.start)}]';
    final body = block.texts.join(' ');
    return block.speaker == null
        ? '$marker $body'
        : '$marker ${block.speaker}: $body';
  }).join('\n\n');
}

final class _Block {
  _Block(this.start, this.speaker, this.texts);
  final double start;
  final String? speaker;
  final List<String> texts;
}

/// Elapsed `MM:SS` below one hour, `H:MM:SS` (hours unpadded) at or above it.
/// Fractional seconds floor rather than round so a marker never points past
/// the audio it introduces.
String _timestamp(double start) {
  final total = _seconds(start).floor();
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String pad(int value) => value.toString().padLeft(2, '0');
  if (hours == 0) return '${pad(minutes)}:${pad(seconds)}';
  return '$hours:${pad(minutes)}:${pad(seconds)}';
}

double _seconds(Object? value) {
  final parsed = switch (value) {
    final num number => number.toDouble(),
    final String text => double.tryParse(text.trim()) ?? 0,
    _ => 0.0,
  };
  if (!parsed.isFinite || parsed < 0) return 0;
  return parsed;
}

String? _label(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
