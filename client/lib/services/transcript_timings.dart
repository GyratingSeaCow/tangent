// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Word-level transcript timings: the data behind "tap a word, hear that
// moment" (docs/design/2026-09-25-tap-to-hear.md).
//
// The server promotes the winning job's segments+words onto the dump as
// `transcript_timings` and sync carries it like `transcript`. This file
// owns the client model, the tolerant parser, and the pure lookups the
// Listen UI needs (current word for a playback position, seek target for
// a tap, default mode, confidence buckets). No Flutter imports: all of it
// is unit-testable without a widget tree.
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

/// One timed word. `confidence` is faster-whisper's word probability
/// (0–1); missing on the wire means 1.0 (nothing to flag).
final class TimedWord {
  const TimedWord({
    required this.text,
    required this.start,
    required this.end,
    this.confidence = 1.0,
  });

  final String text;

  /// Seconds from the start of the recording.
  final double start;
  final double end;
  final double confidence;

  Map<String, Object?> toJson() =>
      {'w': text, 's': start, 'e': end, 'p': confidence};
}

/// One segment (sentence-ish slice) with its words. `words` is empty for
/// segment-only data (older recordings, backfilled server-side).
final class TimedSegment {
  const TimedSegment({
    required this.start,
    required this.end,
    required this.text,
    required this.words,
    this.speaker,
  });

  final double start;
  final double end;
  final String? speaker;
  final String text;
  final List<TimedWord> words;

  Map<String, Object?> toJson() => {
        'start': start,
        'end': end,
        'speaker': speaker,
        'text': text,
        'words': [for (final w in words) w.toJson()],
      };
}

/// A recording's complete timing data.
final class TranscriptTimings {
  TranscriptTimings._(this.segments, this.peaks)
      : allWords = List.unmodifiable(
          [for (final s in segments) ...s.words],
        );

  final List<TimedSegment> segments;

  /// Server-computed RMS buckets (0–1, spec §3.6) for the waveform strip.
  /// Empty on backfilled legacy rows: the strip draws flat.
  final List<double> peaks;
  bool get hasPeaks => peaks.isNotEmpty;

  /// Every word in order, flattened — the unit the karaoke highlight and
  /// tap-to-seek work on.
  final List<TimedWord> allWords;

  /// True when at least one segment carries word timings. False means
  /// Listen mode degrades to sentence-level tap/highlight.
  bool get hasWords => allWords.isNotEmpty;

  /// The transcript text the timings describe: what the engine emitted,
  /// before any user edit. Re-alignment diffs the user's text against it.
  String get sourceText => segments.map((s) => s.text).join(' ');

  /// Parses the wire/DB form. Accepts either `{"segments": [...]}` or a
  /// bare list (the job's `result_segments`). Returns null for anything
  /// that is not usable timing data — never throws: a bad payload must
  /// not take the detail screen down.
  static TranscriptTimings? parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      debugPrint('tangent.timings: unparsable payload ignored');
      return null;
    }
    final Object? list = switch (decoded) {
      List<Object?> l => l,
      Map<Object?, Object?> m => m['segments'],
      _ => null,
    };
    if (list is! List) return null;
    final segments = <TimedSegment>[];
    for (final entry in list) {
      final seg = _segment(entry);
      if (seg != null) segments.add(seg);
    }
    if (segments.isEmpty) return null;
    final peaks = <double>[];
    final rawPeaks = decoded is Map ? decoded['peaks'] : null;
    if (rawPeaks is List) {
      for (final p in rawPeaks) {
        if (p is num) peaks.add(p.toDouble().clamp(0.0, 1.0));
      }
    }
    return TranscriptTimings._(
      List.unmodifiable(segments),
      List.unmodifiable(peaks),
    );
  }

  static TimedSegment? _segment(Object? entry) {
    if (entry is! Map) return null;
    final text = entry['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final start = _num(entry['start']);
    final end = _num(entry['end']);
    if (start == null || end == null || end < start) return null;
    final words = <TimedWord>[];
    final rawWords = entry['words'];
    if (rawWords is List) {
      for (final w in rawWords) {
        final word = _word(w);
        if (word != null) words.add(word);
      }
    }
    final speaker = entry['speaker'];
    return TimedSegment(
      start: start,
      end: end,
      speaker: speaker is String && speaker.trim().isNotEmpty
          ? speaker.trim()
          : null,
      text: text.trim(),
      words: List.unmodifiable(words),
    );
  }

  static TimedWord? _word(Object? entry) {
    if (entry is! Map) return null;
    final text = entry['w'];
    if (text is! String || text.trim().isEmpty) return null;
    final s = _num(entry['s']);
    final e = _num(entry['e']);
    if (s == null || e == null || e < s) return null;
    final p = _num(entry['p']);
    return TimedWord(
      text: text.trim(),
      start: s,
      end: e,
      confidence: p == null ? 1.0 : p.clamp(0.0, 1.0),
    );
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    return null;
  }

  String toJson() => jsonEncode({
        'segments': [for (final s in segments) s.toJson()],
        'peaks': peaks,
      });

  /// Index into [allWords] for playback [position] (seconds), or null
  /// when the position falls in a gap, before the first word, or after
  /// the last. Start inclusive, end exclusive. Binary search: the
  /// karaoke highlight calls this on every position tick.
  int? currentWordIndex(double position) => _find(
        allWords.length,
        position,
        (i) => allWords[i].start,
        (i) => allWords[i].end,
      );

  /// Same as [currentWordIndex] but over segments — the fallback for
  /// segment-only recordings.
  int? currentSegmentIndex(double position) => _find(
        segments.length,
        position,
        (i) => segments[i].start,
        (i) => segments[i].end,
      );

  static int? _find(
    int n,
    double position,
    double Function(int) startOf,
    double Function(int) endOf,
  ) {
    if (n == 0) return null;
    var lo = 0;
    var hi = n - 1;
    // Last item whose start <= position.
    var candidate = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (startOf(mid) <= position) {
        candidate = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (candidate < 0) return null;
    return position < endOf(candidate) ? candidate : null;
  }
}

/// Lead-in for a tap: play from a little before the word so its onset is
/// not clipped. Standard in transcript players.
const Duration tapLeadIn = Duration(milliseconds: 300);

/// Where to seek when the user taps something that starts at
/// [startSeconds]. Clamped at zero.
Duration seekTargetFor(double startSeconds) {
  final target =
      Duration(milliseconds: (startSeconds * 1000).round()) - tapLeadIn;
  return target.isNegative ? Duration.zero : target;
}

/// Default mode for the detail screen: Listen whenever there is anything
/// to listen along to (even sentence-level, even before the audio is
/// downloaded — the Listen view carries the download affordance);
/// otherwise the editor.
bool defaultListenMode({
  required TranscriptTimings? timings,
  required bool audioLocal,
}) =>
    timings != null;

/// How strongly a word should be flagged as worth a second listen.
enum ConfidenceBucket { confident, uncertain, low }

/// Buckets per spec §3.5: below 0.3 strong tint, below 0.5 subtle tint.
ConfidenceBucket confidenceBucket(double confidence) {
  if (confidence < 0.3) return ConfidenceBucket.low;
  if (confidence < 0.5) return ConfidenceBucket.uncertain;
  return ConfidenceBucket.confident;
}
