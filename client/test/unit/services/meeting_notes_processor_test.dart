// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/meeting_notes_processor.dart';

void main() {
  const processor = MeetingNotesProcessor();

  test('uses the stored dump title as the subject', () {
    final notes = processor.process(
      title: 'Website launch',
      transcript: 'The opening sentence is not the subject. The team reviewed scope.',
    );

    expect(notes, startsWith('# Website launch'));
    expect(notes, isNot(startsWith('# The opening sentence')));
  });

  test('does not split URLs decimals or common personal titles', () {
    const transcript = 'Dr. Rivera reviewed https://example.com at version 1.5. '
        'Mr. Jones confirmed the page loaded.';

    final notes = processor.process(title: 'Technical review', transcript: transcript);

    expect(notes, contains('## Raw Transcript\n\n$transcript'));
    expect(notes, isNot(contains('- com at version')));
    expect(notes, isNot(contains('- 5.')));
  });

  test('extracts only explicit decisions and commitments', () {
    const transcript = 'We decided to launch the beta on Friday. '
        'Decision: keep the current logo. '
        'The approved supplier attended. '
        'We discussed an agreed framework. '
        'The team approved the final release.';

    final notes = processor.process(title: 'Launch', transcript: transcript);
    final decisions = _section(notes, 'Decisions');

    expect(decisions, contains('- We decided to launch the beta on Friday.'));
    expect(decisions, contains('- Decision: keep the current logo.'));
    expect(decisions, contains('- The team approved the final release.'));
    expect(decisions, isNot(contains('approved supplier')));
    expect(decisions, isNot(contains('agreed framework')));
  });

  test('extracts explicit assigned actions including lowercase names', () {
    const transcript = 'alice will send the minutes by Thursday. '
        'bob is going to call the vendor on 2026-09-20. '
        'Action item: update the checklist. '
        'It must be true. We will need more time. Tom will be late.';

    final notes = processor.process(title: 'Follow-up', transcript: transcript);
    final actions = _section(notes, 'Action Items');

    expect(
      actions,
      contains(
        '- alice will send the minutes by Thursday. '
        '(Owner: Alice; Date: Thursday)',
      ),
    );
    expect(
      actions,
      contains(
        '- bob is going to call the vendor on 2026-09-20. '
        '(Owner: Bob; Date: 2026-09-20)',
      ),
    );
    expect(
      actions,
      contains(
        'Action item: update the checklist. '
        '(Owner: Not stated; Date: Not stated)',
      ),
    );
    expect(actions, isNot(contains('It must be true')));
    expect(actions, isNot(contains('We will need more time')));
    expect(actions, isNot(contains('Tom will be late')));
  });

  test('sparse input uses explicit empty markers and invents nothing', () {
    const transcript = 'Quiet check-in with no commitments.';

    final notes = processor.process(title: 'Weekly check-in', transcript: transcript);

    expect(notes, startsWith('# Weekly check-in'));
    expect(notes, contains('## Decisions\n\nNone stated'));
    expect(notes, contains('## Action Items\n\nNone stated'));
    expect(notes, contains('## Open Questions\n\nNone stated'));
    expect(notes, isNot(contains('Owner:')));
    expect(notes, isNot(contains('tomorrow')));
    expect(notes, contains('## Raw Transcript\n\n$transcript'));
  });
}

String _section(String notes, String heading) {
  final start = notes.indexOf('## $heading');
  final next = notes.indexOf('\n\n## ', start + 3);
  return notes.substring(start, next < 0 ? notes.length : next);
}
