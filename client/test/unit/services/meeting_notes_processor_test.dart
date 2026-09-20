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

  test('does not repeat the transcript inside the notes', () {
    const transcript = 'Dr. Rivera reviewed https://example.com at version 1.5. '
        'Mr. Jones confirmed the page loaded. '
        'The styling still needs a pass. '
        'Nobody objected to the rollout window.';

    final notes = processor.process(title: 'Technical review', transcript: transcript);

    expect(notes, isNot(contains('## Raw Transcript')));
    expect(notes, isNot(contains('## Key Discussion Points')));
    expect(notes, isNot(contains(transcript)));
    // The summary quotes at most two sentences; later ones stay out.
    expect(notes, isNot(contains('Nobody objected to the rollout window.')));
  });

  test('does not split URLs decimals or common personal titles', () {
    const transcript = 'Dr. Rivera reviewed https://example.com at version 1.5. '
        'Mr. Jones confirmed the page loaded. '
        'We decided to publish https://example.com at version 1.5 tonight.';

    final notes = processor.process(title: 'Technical review', transcript: transcript);
    final decisions = _section(notes, 'Decisions');

    expect(
      decisions,
      contains(
        '- We decided to publish https://example.com at version 1.5 tonight.',
      ),
    );
    expect(notes, isNot(contains('- com at version')));
    expect(notes, isNot(contains('- 5.')));
  });

  test('strips paragraph timestamp markers before analysing sentences', () {
    const transcript = '[00:00] We decided to launch the beta on Friday. '
        'The rest of the hour was status updates.\n'
        '\n'
        '[01:07] alice will send the minutes by Thursday. Anything else?\n'
        '\n'
        '[1:02:07] Closing remarks ran long.';

    final notes = processor.process(title: 'Weekly sync', transcript: transcript);

    expect(notes, isNot(contains('[00:00]')));
    expect(notes, isNot(contains('[01:07]')));
    expect(notes, isNot(contains('[1:02:07]')));
    expect(
      _section(notes, 'Decisions'),
      contains('- We decided to launch the beta on Friday.'),
    );
    expect(
      _section(notes, 'Action Items'),
      contains(
        '- alice will send the minutes by Thursday. '
        '(Owner: Alice; Date: Thursday)',
      ),
    );
    expect(_section(notes, 'Open Questions'), contains('- Anything else?'));
  });

  test('strips legacy HH:MM:SS heading markers too', () {
    const transcript = '00:00:00\n'
        'We decided to keep the current logo.\n'
        '\n'
        '00:01:05\n'
        'Nothing else happened.';

    final notes = processor.process(title: 'Brand check', transcript: transcript);

    expect(notes, isNot(contains('00:00:00')));
    expect(
      _section(notes, 'Decisions'),
      contains('- We decided to keep the current logo.'),
    );
  });

  test('leaves clock times inside prose untouched', () {
    const transcript = 'We decided to meet at 10:30 tomorrow.';

    final notes = processor.process(title: 'Scheduling', transcript: transcript);

    expect(
      _section(notes, 'Decisions'),
      contains('- We decided to meet at 10:30 tomorrow.'),
    );
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

  test('sparse input omits empty sections instead of printing filler', () {
    const transcript = 'Quiet check-in with no commitments.';

    final notes = processor.process(title: 'Weekly check-in', transcript: transcript);

    expect(notes, startsWith('# Weekly check-in'));
    expect(notes, contains('## Summary'));
    expect(notes, isNot(contains('## Decisions')));
    expect(notes, isNot(contains('## Action Items')));
    expect(notes, isNot(contains('## Open Questions')));
    expect(notes, isNot(contains('None stated')));
    expect(notes, isNot(contains('Owner:')));
  });

  test('summary still falls back to the empty marker when nothing remains', () {
    const transcript = 'Anything else?';

    final notes = processor.process(title: 'Tiny', transcript: transcript);

    expect(notes, contains('## Summary\n\nNone stated'));
    expect(_section(notes, 'Open Questions'), contains('- Anything else?'));
  });
}

String _section(String notes, String heading) {
  final start = notes.indexOf('## $heading');
  expect(start, isNot(-1), reason: 'missing section $heading in:\n$notes');
  final next = notes.indexOf('\n\n## ', start + 3);
  return notes.substring(start, next < 0 ? notes.length : next);
}
