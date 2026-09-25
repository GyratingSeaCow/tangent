// SPDX-License-Identifier: AGPL-3.0-or-later

/// Normalises a markdown AI summary for a plain notebook text block.
///
/// Summaries arrive as markdown sections (`## Summary`, `## Action items`,
/// `- bullet`). A [NotebookTextBlock] is a plain editor with no heading
/// style, so `## Heading` becomes `Heading` on a line of its own — the
/// heading text is kept, only the pounds go. Bullets are already readable
/// as plain text and are left exactly as written.
///
/// Pure and idempotent: plain text passes through unchanged, and running
/// the output through again yields the same output. Surrounding blank
/// lines are trimmed so blank input stays blank rather than becoming a box
/// of whitespace.
String summaryToPageText(String summary) {
  final List<String> lines = _normaliseNewlines(summary).split('\n');
  final List<String> out = <String>[
    for (final String line in lines) _stripHeading(line),
  ];
  return out.join('\n').trim();
}

/// The first line of actual content in a summary — what an audio bubble
/// shows beneath its title so the page tells you what the meeting was
/// about at a glance.
///
/// Headings (`## Summary`) and blank lines are skipped, and a leading
/// bullet marker is dropped so the line reads as a sentence. `null` when
/// there is nothing to show (no summary, blank, or headings only), so the
/// caller can render exactly as it did before summaries existed.
String? summaryFirstLine(String? summary) {
  if (summary == null) return null;
  for (final String raw in _normaliseNewlines(summary).split('\n')) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    if (_atxHeading.hasMatch(line) || _bareHeading.hasMatch(line)) continue;
    final String body = line.replaceFirst(_bulletMarker, '').trim();
    if (body.isEmpty) continue;
    return body;
  }
  return null;
}

/// Summaries are LF on the wire, but a summary edited or pasted on Windows
/// may carry CRLF; normalise so no `\r` leaks into a text block.
String _normaliseNewlines(String s) => s.replaceAll('\r\n', '\n');

/// `## ` with nothing after it — a heading with no text; not content.
final RegExp _bareHeading = RegExp(r'^\s{0,3}#{1,6}\s*$');

/// A bullet marker, or a bare marker with nothing after it (an empty bullet).
final RegExp _bulletMarker = RegExp(r'^[-*+](\s+|$)');

/// `#`, `##`, ... followed by at least one space at the start of the line is
/// an ATX heading; anything else (a `#42` ticket reference, `C#`) is body
/// text and is returned untouched.
final RegExp _atxHeading = RegExp(r'^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$');

String _stripHeading(String line) {
  final RegExpMatch? match = _atxHeading.firstMatch(line);
  if (match == null) return line;
  return match.group(1)!;
}
