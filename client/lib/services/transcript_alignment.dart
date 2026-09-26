// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Re-aligns a user-edited transcript to the engine's word timings
// (spec §3.4). The timings describe what Whisper heard; the transcript
// is what the user made of it. A token-level diff (LCS on normalized
// tokens) decides which words still carry their original time:
//
//   matched  → keeps its timing
//   inserted → rendered, untimed, never highlighted
//   deleted  → vanishes; playback passes through its audio
//   replaced → a deleted run adjacent to an inserted run: the inserted
//              words share the deleted run's [start, end] as one block,
//              so a corrected "roomy" → "Rumi" still plays the moment
//
// Pure Dart, no Flutter: unit-tested directly. Called once per
// (transcript, timings) pair and cached by the caller.
import 'transcript_timings.dart';

/// One renderable token of the edited transcript.
final class AlignedToken {
  const AlignedToken({
    required this.text,
    required this.trailing,
    this.start,
    this.end,
    this.confidence = 1.0,
  });

  /// The user's text, verbatim (case, punctuation intact).
  final String text;

  /// Whitespace that followed the token in the source, so the renderer
  /// reproduces the user's line breaks and spacing.
  final String trailing;

  /// Seconds; null when the token carries no time (pure insertion).
  final double? start;
  final double? end;
  final double confidence;

  bool get isTimed => start != null;
}

final class TranscriptAlignment {
  TranscriptAlignment._(this.tokens)
      : hasInsertions = tokens.any((t) => !t.isTimed);

  final List<AlignedToken> tokens;

  /// True when the user added words the engine never heard — the UI
  /// shows the "timings follow your edits where words match" caption.
  final bool hasInsertions;

  /// Token index for playback [position] (seconds), or null in a gap or
  /// on an untimed token. Linear over timed tokens is fine: replaced
  /// runs share spans so a binary search cannot be relied on to find
  /// the first of a block.
  int? currentTokenIndex(double position) {
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i];
      if (t.start == null) continue;
      if (position >= t.start! && position < t.end!) return i;
    }
    return null;
  }
}

/// Splits the transcript into tokens with their trailing whitespace.
List<(String, String)> _tokenize(String text) {
  final out = <(String, String)>[];
  final re = RegExp(r'(\S+)(\s*)');
  for (final m in re.allMatches(text)) {
    out.add((m.group(1)!, m.group(2)!));
  }
  return out;
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r"[^\p{L}\p{N}']", unicode: true), '');

/// Aligns [transcript] to [timings]. See the file comment for the rules.
TranscriptAlignment alignTranscript(
  String transcript,
  TranscriptTimings timings,
) {
  final user = _tokenize(transcript);
  final engine = timings.allWords;
  if (user.isEmpty) return TranscriptAlignment._(const []);

  final a = [for (final (t, _) in user) _norm(t)];
  final b = [for (final w in engine) _norm(w.text)];

  // LCS table (n*m ints). Transcripts are thousands of words at most;
  // a 20k x 20k table would be too much, so cap the engine side per
  // segment window... but in practice recordings are minutes, not
  // hours, and the caller caches. Keep it simple and correct.
  final n = a.length, m = b.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j] && a[i].isNotEmpty
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }

  // Walk the table emitting ops; buffer deletes and inserts so an
  // adjacent delete-run + insert-run becomes a replacement block.
  final tokens = <AlignedToken>[];
  var i = 0, j = 0;
  final pendingDeleted = <TimedWord>[];
  final pendingInserted = <int>[]; // user token indexes

  void flush() {
    if (pendingInserted.isEmpty) {
      pendingDeleted.clear();
      return;
    }
    double? s, e;
    if (pendingDeleted.isNotEmpty) {
      s = pendingDeleted.first.start;
      e = pendingDeleted.last.end;
    }
    final conf = pendingDeleted.isEmpty
        ? 1.0
        : pendingDeleted
            .map((w) => w.confidence)
            .reduce((x, y) => x < y ? x : y);
    for (final ui in pendingInserted) {
      final (text, trailing) = user[ui];
      tokens.add(AlignedToken(
        text: text,
        trailing: trailing,
        start: s,
        end: e,
        confidence: conf,
      ),);
    }
    pendingDeleted.clear();
    pendingInserted.clear();
  }

  while (i < n || j < m) {
    if (i < n && j < m && a[i] == b[j] && a[i].isNotEmpty) {
      flush();
      final (text, trailing) = user[i];
      final w = engine[j];
      tokens.add(AlignedToken(
        text: text,
        trailing: trailing,
        start: w.start,
        end: w.end,
        confidence: w.confidence,
      ),);
      i++;
      j++;
    } else if (j < m && (i >= n || dp[i][j + 1] >= dp[i + 1][j])) {
      pendingDeleted.add(engine[j]);
      j++;
    } else {
      pendingInserted.add(i);
      i++;
    }
  }
  flush();
  return TranscriptAlignment._(List.unmodifiable(tokens));
}
