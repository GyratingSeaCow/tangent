// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/summary_page_text.dart';

/// Summaries are markdown (`## Summary`, `- bullet`). A notebook text block
/// is a plain editor with no heading style, so the import normalises the
/// summary for the page: headings keep their text as a line of their own
/// with the pounds dropped; bullets are already readable and stay as-is.
void main() {
  group('summaryToPageText', () {
    test('strips heading markers but keeps the heading text on its own line',
        () {
      const String summary = '## Summary\n'
          'We agreed to ship on Friday.\n'
          '\n'
          '## Action items\n'
          '- Jeff: write the release notes\n'
          '- Sam: tag the build';

      expect(
        summaryToPageText(summary),
        'Summary\n'
        'We agreed to ship on Friday.\n'
        '\n'
        'Action items\n'
        '- Jeff: write the release notes\n'
        '- Sam: tag the build',
      );
    });

    test('keeps bullets exactly as written', () {
      const String bullets = '- first point\n- second point\n  - nested';
      expect(summaryToPageText(bullets), bullets);
    });

    test('is idempotent on plain text', () {
      const String plain = 'just a sentence\nand another one';
      expect(summaryToPageText(plain), plain);
      expect(summaryToPageText(summaryToPageText(plain)), plain);
    });

    test('is idempotent on its own output', () {
      const String summary = '## Summary\n- one\n\n### Details\ntext';
      final String once = summaryToPageText(summary);
      expect(summaryToPageText(once), once);
    });

    test('blank input stays blank', () {
      expect(summaryToPageText(''), '');
      expect(summaryToPageText('   \n\n  '), '');
    });

    test('a heading with no body still keeps its heading line', () {
      // Blank sections: the server strips "- None" placeholders, so a
      // heading can arrive with nothing under it. The heading text is still
      // real content and must not vanish.
      const String summary = '## Summary\n\n## Decisions\n';
      expect(summaryToPageText(summary), 'Summary\n\nDecisions');
    });

    test('a pound sign inside a line is not a heading', () {
      const String line = 'ticket #42 is blocked\nC# rewrite';
      expect(summaryToPageText(line), line);
    });
  });

  group('summaryFirstLine', () {
    test('returns the first content line under the heading, bullet stripped',
        () {
      const String summary = '## Summary\n'
          '- We agreed to ship on Friday.\n'
          '- Sam owns the tag.\n'
          '\n'
          '## Action items\n'
          '- Jeff: release notes';
      expect(summaryFirstLine(summary), 'We agreed to ship on Friday.');
    });

    test('skips blank lines and heading-only lines', () {
      expect(
        summaryFirstLine('## Summary\n\n\n## Decisions\nShip it.'),
        'Ship it.',
      );
    });

    test('plain prose without a heading yields its first line', () {
      expect(summaryFirstLine('first sentence\nsecond'), 'first sentence');
    });

    test('null, blank, and heading-only summaries yield null', () {
      expect(summaryFirstLine(null), isNull);
      expect(summaryFirstLine(''), isNull);
      expect(summaryFirstLine('  \n \n'), isNull);
      expect(summaryFirstLine('## Summary\n## Action items'), isNull);
    });
  });
}
