// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Transcript search depth (docs/design/2026-09-26-search-and-summary-
// templates.md §2): pure helpers shared by the result cards and the
// detail screen's open-at-match. No Flutter widgets here, so each rule is
// unit-testable and both surfaces cannot drift apart.
import 'package:flutter/painting.dart' show TextRange;

import 'transcript_alignment.dart';

/// One run of an FTS5 snippet: bold runs are the matched terms.
typedef SnippetRun = ({String text, bool bold});

/// Match evidence for one search result row, computed alongside the
/// ranked candidates: the FTS5 snippet (with `<b>` markers), how many
/// times the terms occur in the transcript, and whether the TITLE is
/// what matched (the card then highlights the title instead).
final class DumpSearchMatch {
  const DumpSearchMatch({
    required this.snippet,
    required this.matchCount,
    required this.titleMatched,
  });

  final String snippet;
  final int matchCount;
  final bool titleMatched;
}

/// The search term a query stands for, as the user would expect it to
/// highlight. The FTS query is always phrase-quoted (`watchSearchDumps`
/// wraps the whole query in double quotes), so every hit contains the
/// whole trimmed text as one phrase; that phrase is what gets painted
/// and counted. Stray quotes are stripped; null when nothing remains.
String? searchTerm(String query) {
  final unquoted = query.replaceAll('"', '').trim();
  return unquoted.isEmpty ? null : unquoted;
}

/// Every non-overlapping, case-insensitive occurrence of the query's
/// phrase in [text], in reading order.
List<TextRange> findTranscriptMatches(String text, String query) {
  if (text.isEmpty) return const [];
  final term = searchTerm(query);
  if (term == null) return const [];
  final lower = text.toLowerCase();
  final needle = term.toLowerCase();
  final out = <TextRange>[];
  var from = 0;
  while (true) {
    final at = lower.indexOf(needle, from);
    if (at < 0) break;
    out.add(TextRange(start: at, end: at + needle.length));
    from = at + needle.length;
  }
  return out;
}

/// Case-insensitive occurrence count of the query's terms in [text].
int countTranscriptMatches(String text, String query) =>
    findTranscriptMatches(text, query).length;

/// Splits an FTS5 `snippet(..., '<b>', '</b>', ...)` result into runs.
List<SnippetRun> parseSnippet(String snippet) {
  final out = <SnippetRun>[];
  final re = RegExp('<b>(.*?)</b>', dotAll: true);
  var last = 0;
  for (final m in re.allMatches(snippet)) {
    if (m.start > last) {
      out.add((text: snippet.substring(last, m.start), bold: false));
    }
    out.add((text: m.group(1)!, bold: true));
    last = m.end;
  }
  if (last < snippet.length || out.isEmpty) {
    out.add((text: snippet.substring(last), bold: false));
  }
  return out;
}

/// Index of the aligned token whose text covers character [offset] of
/// [transcript], or null when the offset falls outside every token.
///
/// The alignment tokenizes the transcript with the same `\S+\s*` walk,
/// so token i's text starts exactly where the i-th run of non-space
/// characters starts; this rewalks the transcript to recover those
/// offsets rather than asking the alignment to carry them.
int? alignedTokenAt(
  TranscriptAlignment alignment,
  String transcript,
  int offset,
) {
  final re = RegExp(r'\S+');
  var i = 0;
  for (final m in re.allMatches(transcript)) {
    if (i >= alignment.tokens.length) break;
    if (offset >= m.start && offset < m.end) return i;
    if (offset < m.start) return null;
    i++;
  }
  return null;
}

/// Where playback should start for a match: the start (seconds) of the
/// timed word the match begins on, or null when that word carries no
/// time (a user insertion) or the match sits outside every token.
double? matchSeekSeconds(
  TranscriptAlignment alignment,
  String transcript,
  TextRange match,
) {
  final i = alignedTokenAt(alignment, transcript, match.start);
  if (i == null) return null;
  return alignment.tokens[i].start;
}
