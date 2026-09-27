// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/todo_voice_parser.dart';

/// Parsing rules + every edge case named in
/// docs/design/2026-09-27-todo-voice-capture.md §"Parsing rules".
void main() {
  group('TodoVoiceParser trigger family', () {
    test('add to my to do list (two words)', () {
      expect(
        TodoVoiceParser.parse(
          'customer board is toast, add to my to do list pick up thermal '
          'paste and email the Zionsville customer back',
        ),
        ['pick up thermal paste', 'email the Zionsville customer back'],
      );
    });

    test('Whisper closes the trigger with a period — first item is not ". Go…"', () {
      // Real recording, v1.23.0 first-day data: the server stored
      // '. Go to the store' and '. Go out for a drive'.
      expect(
        TodoVoiceParser.parse('Add to my to do list. Go to the store and go get Advil.'),
        ['Go to the store', 'go get Advil'],
      );
      expect(
        TodoVoiceParser.parse('add to my to do list… go out for a drive'),
        ['go out for a drive'],
      );
    });
    test('add to my todo list (one word)', () {
      expect(
        TodoVoiceParser.parse('add to my todo list call the bank'),
        ['call the bank'],
      );
    });

    test('to-do hyphenated', () {
      expect(
        TodoVoiceParser.parse('add to my to-do list order filters'),
        ['order filters'],
      );
    });

    test('put on my to do list', () {
      expect(
        TodoVoiceParser.parse('put on my to do list sweep the bench'),
        ['sweep the bench'],
      );
    });

    test('add that to my list', () {
      expect(
        TodoVoiceParser.parse('add that to my list ship the Fold'),
        ['ship the Fold'],
      );
    });

    test('remind me to keeps its own semantics', () {
      expect(
        TodoVoiceParser.parse('remind me to buy milk and to call Dana'),
        ['buy milk', 'call Dana'],
      );
    });

    test('mixed case matches', () {
      expect(
        TodoVoiceParser.parse('Blah blah. ADD To My To Do List: pay rent'),
        ['pay rent'],
      );
    });

    test('optional trailing colon is swallowed', () {
      expect(
        TodoVoiceParser.parse('add to my to do list: pay rent'),
        ['pay rent'],
      );
    });

    test('no trigger yields nothing', () {
      expect(
        TodoVoiceParser.parse('just thinking out loud about the shop'),
        isEmpty,
      );
      expect(TodoVoiceParser.hasTrigger('no phrase here'), isFalse);
      expect(TodoVoiceParser.hasTrigger('remind me to stretch'), isTrue);
    });

    test('null and empty input are safe', () {
      expect(TodoVoiceParser.parse(null), isEmpty);
      expect(TodoVoiceParser.parse(''), isEmpty);
    });
  });

  group('TodoVoiceParser span and splitting', () {
    test('span runs to the END of the transcript', () {
      // Periods are NOT separators (spec rule 3 names only ',' and ' and '),
      // so trailing chatter after the trigger lands in the item verbatim —
      // minus the sentence-final period rule 4 strips.
      expect(
        TodoVoiceParser.parse(
          'add to my to do list mow the lawn and rake, then quit.',
        ),
        ['mow the lawn', 'rake', 'then quit'],
      );
    });

    test('trigger at the very end with nothing after produces no items', () {
      expect(TodoVoiceParser.parse('okay add to my to do list'), isEmpty);
      expect(TodoVoiceParser.parse('okay add to my to do list:   '), isEmpty);
    });

    test('trigger appearing twice: the first wins, the second is item text',
        () {
      expect(
        TodoVoiceParser.parse(
          'add to my to do list buy nails, add to my to do list buy screws',
        ),
        ['buy nails', 'add to my to do list buy screws'],
      );
    });

    test('"and" inside a word never splits', () {
      expect(
        TodoVoiceParser.parse('remind me to pick up a brand new sander'),
        ['pick up a brand new sander'],
      );
      expect(
        TodoVoiceParser.parse('add to my to do list flash the android tablet'),
        ['flash the android tablet'],
      );
    });

    test('a comma-less single item stays one item', () {
      expect(
        TodoVoiceParser.parse('add to my to do list replace the front bearing'),
        ['replace the front bearing'],
      );
    });

    test('an item that is only punctuation is dropped', () {
      expect(
        TodoVoiceParser.parse('add to my to do list buy nails, ., and ...'),
        ['buy nails'],
      );
    });

    test('whitespace is collapsed and trailing periods stripped', () {
      expect(
        TodoVoiceParser.parse('add to my to do list   buy   nails...'),
        ['buy nails'],
      );
    });

    test('empty fragments between separators are dropped', () {
      expect(
        TodoVoiceParser.parse('add to my to do list a,, , and b'),
        ['a', 'b'],
      );
    });
  });

  group('TodoVoiceParser caps', () {
    test('at most 20 items', () {
      final String span = List<String>.generate(30, (i) => 'item $i').join(', ');
      final List<String> items =
          TodoVoiceParser.parse('add to my to do list $span');
      expect(items.length, 20);
      expect(items.first, 'item 0');
      expect(items.last, 'item 19');
    });

    test('each item truncated to 200 chars', () {
      final String long = 'x' * 260;
      final List<String> items =
          TodoVoiceParser.parse('remind me to $long');
      expect(items.single.length, 200);
    });
  });
  group('TodoVoiceParser.parseWithDate — real-data fixtures (v1.26.0)', () {
    // docs/design/2026-09-27-voice-todo-due-dates.md §"Real-data fixtures",
    // verbatim. Anchor days are the dump's created_at, never today.
    final DateTime sep27 = DateTime(2026, 9, 27, 14, 3);
    final DateTime oct5 = DateTime(2026, 10, 5, 9);

    test('1. leading "for September 30th to" recorded 2026-09-27', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'Add to my to-do list for September 30th to go to the store.',
        recordedOn: sep27,
      );
      expect(p.items, ['go to the store']);
      expect(p.dueDate, '2026-09-30');
    });

    test('2. same transcript recorded 2026-10-05 rolls to next year (D2)', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'Add to my to-do list for September 30th to go to the store.',
        recordedOn: oct5,
      );
      expect(p.items, ['go to the store']);
      expect(p.dueDate, '2027-09-30');
    });

    test('3. the v1.23.1 fixture is unchanged and undated', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'Add to my to do list. Go to the store and go get Advil.',
        recordedOn: sep27,
      );
      expect(p.items, ['Go to the store', 'go get Advil']);
      expect(p.dueDate, isNull);
    });

    test('4. a weekday inside an item stays text (D3, D1)', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'Add to my to-do list, pick up milk and call the dentist on Friday',
        recordedOn: sep27,
      );
      expect(p.items, ['pick up milk', 'call the dentist on Friday']);
      expect(p.dueDate, isNull);
    });

    test('5. "on the 30th of September" after remind me to', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'Remind me to on the 30th of September renew the plates',
        recordedOn: sep27,
      );
      expect(p.items, ['renew the plates']);
      expect(p.dueDate, '2026-09-30');
    });

    test('6. numeric 9/30', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'Add to my to-do list for 9/30 get the oil changed',
        recordedOn: sep27,
      );
      expect(p.items, ['get the oil changed']);
      expect(p.dueDate, '2026-09-30');
    });

    test('7. February 30th is not a date — the phrase stays TEXT', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'Add to my to-do list for February 30th call the bank',
        recordedOn: sep27,
      );
      expect(p.items, ['for February 30th call the bank']);
      expect(p.dueDate, isNull);
    });

    test('8. an explicit year is used as spoken', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'Add to my to-do list for September 30th 2027 buy tickets',
        recordedOn: sep27,
      );
      expect(p.items, ['buy tickets']);
      expect(p.dueDate, '2027-09-30');
    });

    test('the date applies to EVERY item in the sentence (D1)', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'add to my to do list for September 30th buy milk and call Dana',
        recordedOn: sep27,
      );
      expect(p.items, ['buy milk', 'call Dana']);
      expect(p.dueDate, '2026-09-30');
    });

    test('parse() returns the same items with the phrase stripped', () {
      expect(
        TodoVoiceParser.parse(
          'Add to my to-do list for September 30th to go to the store.',
        ),
        ['go to the store'],
      );
    });
  });

  group('TodoVoiceParser.parseWithDate — spellings and forms', () {
    final DateTime sep27 = DateTime(2026, 9, 27);

    String? due(String transcript, {DateTime? on}) => TodoVoiceParser
        .parseWithDate(transcript, recordedOn: on ?? sep27)
        .dueDate;

    List<String> items(String transcript) =>
        TodoVoiceParser.parseWithDate(transcript, recordedOn: sep27).items;

    test('month spellings', () {
      const Map<String, String> table = <String, String>{
        'September 30th': '2026-09-30',
        'september 30': '2026-09-30',
        'Sept 30': '2026-09-30',
        'Sept. 30': '2026-09-30',
        'Sep. 30': '2026-09-30',
        'SEP 30': '2026-09-30',
        'Oct 1': '2026-10-01',
        'October 1st': '2026-10-01',
        'Jan 2': '2027-01-02',
        'Feb. 28': '2027-02-28',
        'March 3': '2027-03-03',
        'Apr 4': '2027-04-04',
        'May 5': '2027-05-05',
        'June 6': '2027-06-06',
        'Jul 7': '2027-07-07',
        'August 8': '2027-08-08',
        'Nov 11': '2026-11-11',
        'Dec 25th': '2026-12-25',
      };
      for (final MapEntry<String, String> e in table.entries) {
        expect(
          due('add to my to do list ${e.key} buy nails'),
          e.value,
          reason: e.key,
        );
        expect(
          items('add to my to do list ${e.key} buy nails'),
          ['buy nails'],
          reason: e.key,
        );
      }
    });

    test('ordinal suffixes', () {
      const List<String> days = <String>[
        '1st', '2nd', '3rd', '4th', '21st', '22nd', '23rd', '30th', '30',
      ];
      for (final String d in days) {
        final String digits = d.replaceAll(RegExp('[a-z]'), '');
        expect(
          due('remind me to on October $d rotate the tires'),
          '2026-10-${digits.padLeft(2, '0')}',
          reason: d,
        );
      }
    });

    test('prepositions: for / on / by / due / due on / none', () {
      const List<String> preps = <String>[
        'for ', 'on ', 'by ', 'due ', 'due on ', '',
      ];
      for (final String prep in preps) {
        final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
          'add to my to do list ${prep}October 3rd pick up the dry cleaning',
          recordedOn: sep27,
        );
        expect(p.dueDate, '2026-10-03', reason: '"$prep"');
        expect(p.items, ['pick up the dry cleaning'], reason: '"$prep"');
      }
    });

    test('"the Nth of Month" with and without a year', () {
      expect(
        due('add to my to do list the 30th of September buy nails'),
        '2026-09-30',
      );
      expect(
        due('add to my to do list for the 3rd of October, 2027 buy nails'),
        '2027-10-03',
      );
      expect(
        items('add to my to do list for the 3rd of October, 2027 buy nails'),
        ['buy nails'],
      );
    });

    test('numeric forms with slash, dash, and year', () {
      expect(due('add to my to do list 9/30 buy nails'), '2026-09-30');
      expect(due('add to my to do list 09/30/2027 buy nails'), '2027-09-30');
      expect(due('add to my to do list on 9-30 buy nails'), '2026-09-30');
      expect(due('add to my to do list 1/2 buy nails'), '2027-01-02');
      expect(items('add to my to do list 09/30/2027 buy nails'), ['buy nails']);
    });

    test('"Sep 30, 2027" with a comma before the year', () {
      expect(due('add to my to do list Sep 30, 2027 buy nails'), '2027-09-30');
    });

    test('Whisper punctuation between trigger and date is tolerated', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'Add to my to do list. For September 30th, go to the store.',
        recordedOn: sep27,
      );
      expect(p.items, ['go to the store']);
      expect(p.dueDate, '2026-09-30');
    });

    test('the phrase alone with nothing after it yields no items', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'add to my to do list for September 30th',
        recordedOn: sep27,
      );
      expect(p.items, isEmpty);
    });

    test('an invalid numeric date stays text', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'add to my to do list 13/45 buy nails',
        recordedOn: sep27,
      );
      expect(p.items, ['13/45 buy nails']);
      expect(p.dueDate, isNull);
    });

    test('an explicit-year invalid date stays text (never guess)', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'add to my to do list for February 30th 2027 buy nails',
        recordedOn: sep27,
      );
      expect(p.items, ['for February 30th 2027 buy nails']);
      expect(p.dueDate, isNull);
    });

    test('relative words are NOT dates (D3)', () {
      const List<String> phrases = <String>[
        'tomorrow', 'on Friday', 'next week', 'in 3 days', 'today',
      ];
      for (final String phrase in phrases) {
        final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
          'add to my to do list $phrase buy nails',
          recordedOn: sep27,
        );
        expect(p.dueDate, isNull, reason: phrase);
        expect(p.items, ['$phrase buy nails'], reason: phrase);
      }
    });

    test('a date NOT at the front stays item text (D1)', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'add to my to do list buy nails and on September 30th call Dana',
        recordedOn: sep27,
      );
      expect(p.items, ['buy nails', 'on September 30th call Dana']);
      expect(p.dueDate, isNull);
    });

    test('a bare number that is not a date form is item text', () {
      expect(items('add to my to do list 30 bags of mulch'), ['30 bags of mulch']);
      expect(due('add to my to do list 30 bags of mulch'), isNull);
      expect(
        items('add to my to do list may the fourth be with you'),
        ['may the fourth be with you'],
      );
    });
  });

  group('TodoVoiceParser.parseWithDate — D2 resolution', () {
    String? due(String transcript, DateTime on) =>
        TodoVoiceParser.parseWithDate(transcript, recordedOn: on).dueDate;

    test('recorded ON the date itself resolves to that date, not next year',
        () {
      expect(
        due(
          'add to my to do list for September 30th pay rent',
          DateTime(2026, 9, 30, 23, 59),
        ),
        '2026-09-30',
      );
      expect(
        due('add to my to do list for 9/30 pay rent', DateTime(2026, 9, 30)),
        '2026-09-30',
      );
    });

    test('the day after rolls to next year', () {
      expect(
        due(
          'add to my to do list for September 30th pay rent',
          DateTime(2026, 10, 1, 0, 0, 1),
        ),
        '2027-09-30',
      );
    });

    test('a later month this year stays this year', () {
      expect(
        due('add to my to do list December 31st pay rent', DateTime(2026, 9, 27)),
        '2026-12-31',
      );
    });

    test('an explicit year in the past is used as spoken', () {
      expect(
        due(
          'add to my to do list September 30th 2025 pay rent',
          DateTime(2026, 9, 27),
        ),
        '2025-09-30',
      );
    });

    test('Feb 29 without a year goes to the next leap occurrence', () {
      expect(
        due('add to my to do list February 29th pay rent', DateTime(2026, 9, 27)),
        '2028-02-29',
      );
      expect(
        due('add to my to do list February 29th pay rent', DateTime(2028, 2, 29)),
        '2028-02-29',
      );
      expect(
        due('add to my to do list February 29th pay rent', DateTime(2028, 3, 1)),
        '2032-02-29',
      );
    });

    test('Feb 29 with a non-leap year stays text', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'add to my to do list February 29th 2027 pay rent',
        recordedOn: DateTime(2026, 9, 27),
      );
      expect(p.dueDate, isNull);
      expect(p.items, ['February 29th 2027 pay rent']);
    });

    test('null and empty input are safe', () {
      expect(
        TodoVoiceParser.parseWithDate(null, recordedOn: DateTime(2026)).items,
        isEmpty,
      );
      expect(
        TodoVoiceParser.parseWithDate('', recordedOn: DateTime(2026)).dueDate,
        isNull,
      );
    });
  });
}
