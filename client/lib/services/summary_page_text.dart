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
  final List<String> lines = summary.split('\n');
  final List<String> out = <String>[
    for (final String line in lines) _stripHeading(line),
  ];
  return out.join('\n').trim();
}

/// `#`, `##`, ... followed by at least one space at the start of the line is
/// an ATX heading; anything else (a `#42` ticket reference, `C#`) is body
/// text and is returned untouched.
final RegExp _atxHeading = RegExp(r'^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$');

String _stripHeading(String line) {
  final RegExpMatch? match = _atxHeading.firstMatch(line);
  if (match == null) return line;
  return match.group(1)!;
}
