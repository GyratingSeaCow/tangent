// SPDX-License-Identifier: AGPL-3.0-or-later

/// Meeting-mode transcript presentation.
///
/// The server may return a diarised `segments` array alongside the plain
/// transcript text. Meeting dumps render those segments as timestamped speaker
/// blocks; every other mode keeps the plain text untouched. Nothing here
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

/// Renders [segments] as timestamped speaker blocks.
///
/// Consecutive segments carrying the same speaker label merge into one block
/// headed by the first of them. Unattributed segments never merge, so their
/// timestamps stay navigable, and their heading is the timestamp alone — a
/// speaker label is never invented. Returns null when nothing is renderable,
/// which leaves the caller on its existing plain-text path.
String? formatMeetingTranscript(List<TranscriptSegment> segments) {
  final blocks = <_Block>[];
  for (final segment in segments) {
    final text = segment.text.trim();
    if (text.isEmpty) continue;
    final speaker = _label(segment.speaker);
    final last = blocks.isEmpty ? null : blocks.last;
    if (last != null && speaker != null && last.speaker == speaker) {
      last.texts.add(text);
      continue;
    }
    blocks.add(_Block(_timestamp(segment.start), speaker, [text]));
  }
  if (blocks.isEmpty) return null;
  return blocks.map((block) {
    final heading = block.speaker == null
        ? block.timestamp
        : '${block.timestamp} ${block.speaker}';
    return '$heading\n${block.texts.join(' ')}';
  }).join('\n\n');
}

/// Convenience over [parseTranscriptSegments] + [formatMeetingTranscript] for
/// callers holding an untyped server payload.
String? formatMeetingTranscriptFromResult(Object? raw) =>
    formatMeetingTranscript(parseTranscriptSegments(raw));

final class _Block {
  _Block(this.timestamp, this.speaker, this.texts);
  final String timestamp;
  final String? speaker;
  final List<String> texts;
}

/// Zero-padded elapsed `HH:MM:SS`. Fractional seconds floor rather than round
/// so a heading never points past the audio it introduces.
String _timestamp(double start) {
  final total = _seconds(start).floor();
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${pad(hours)}:${pad(minutes)}:${pad(seconds)}';
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
