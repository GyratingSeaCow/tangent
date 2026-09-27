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

    test('4. a weekday ending an item is THAT item\'s date (v1.27.0 lifts D3/D1)', () {
      // v1.26.0 kept 'call the dentist on Friday' whole; the relative-dates
      // arc turns the trailing weekday into a per-item date (R2).
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'Add to my to-do list, pick up milk and call the dentist on Friday',
        recordedOn: sep27,
      );
      expect(p.items, ['pick up milk', 'call the dentist']);
      expect(p.dueDate, isNull);
      expect(p.entries.map((e) => e.dueDate), [null, '2026-10-02']);
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

    test('relative words at the head ARE dates since v1.27.0 (D3 lifted)', () {
      // Sep 27, 2026 is a Sunday.
      const Map<String, String> phrases = <String, String>{
        'tomorrow': '2026-09-28',
        'on Friday': '2026-10-02',
        'next week': '2026-09-28',
        'in 3 days': '2026-09-30',
        'today': '2026-09-27',
      };
      for (final MapEntry<String, String> e in phrases.entries) {
        final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
          'add to my to do list ${e.key} buy nails',
          recordedOn: sep27,
        );
        expect(p.dueDate, e.value, reason: e.key);
        expect(p.items, ['buy nails'], reason: e.key);
      }
    });

    test('an absolute date at the START of a later item is that item\'s date', () {
      // v1.26.0 kept 'on September 30th call Dana' whole (D1); the
      // relative-dates arc recognises item-start phrases (R2).
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'add to my to do list buy nails and on September 30th call Dana',
        recordedOn: sep27,
      );
      expect(p.items, ['buy nails', 'call Dana']);
      expect(p.dueDate, isNull);
      expect(p.entries.last.dueDate, '2026-09-30');
    });

    test('a middle-of-item absolute date stays text', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'add to my to do list buy nails and call Dana on September 30th about rent',
        recordedOn: sep27,
      );
      expect(p.items, ['buy nails', 'call Dana on September 30th about rent']);
      expect(p.entries.last.dueDate, isNull);
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

  group('TodoVoiceParser.parseWithDate — relative + per-item fixtures (v1.27.0)', () {
    // docs/design/2026-09-27-voice-todo-relative-dates.md §"Real-data-shaped
    // fixtures", verbatim. recordedOn 2026-09-27 is a SUNDAY.
    final DateTime sunday = DateTime(2026, 9, 27);

    VoiceTodoParse parse(String t) =>
        TodoVoiceParser.parseWithDate(t, recordedOn: sunday);

    test('1. "call the dentist on Friday" — per-item weekday', () {
      final VoiceTodoParse p = parse('Add to my to-do list, call the dentist on Friday.');
      expect(p.items, ['call the dentist']);
      expect(p.dueDate, isNull);
      expect(p.entries, [const VoiceTodoItem('call the dentist', dueDate: '2026-10-02')]);
    });

    test('2. sentence Friday, mom on Sunday — item beats sentence (R2)', () {
      final VoiceTodoParse p = parse(
        'Add to my to-do list for Friday, buy milk and call mom on Sunday.',
      );
      expect(p.dueDate, '2026-10-02');
      expect(p.entries, [
        const VoiceTodoItem('buy milk'),
        const VoiceTodoItem('call mom', dueDate: '2026-10-04'),
      ]);
      // What the capture layer will write per row:
      expect(
        p.entries.map((e) => e.dueDate ?? p.dueDate),
        ['2026-10-02', '2026-10-04'],
      );
    });

    test('3. "take the bins out tomorrow"', () {
      final VoiceTodoParse p = parse('Remind me to take the bins out tomorrow.');
      expect(p.entries, [const VoiceTodoItem('take the bins out', dueDate: '2026-09-28')]);
    });

    test('4. "next month" = the 1st, "next week" = next Monday (R3)', () {
      final VoiceTodoParse p = parse(
        'Add to my to-do list, pay rent next month and renew the plates next week.',
      );
      expect(p.dueDate, isNull);
      expect(p.entries, [
        const VoiceTodoItem('pay rent', dueDate: '2026-10-01'),
        // Sep 27 is a Sunday, so "next week" is the very next day.
        const VoiceTodoItem('renew the plates', dueDate: '2026-09-28'),
      ]);
    });

    test('5. "for Sunday" said ON a Sunday is next week\'s Sunday (R1)', () {
      final VoiceTodoParse p = parse('Add to my to-do list for Sunday, wash the car.');
      expect(p.items, ['wash the car']);
      expect(p.dueDate, '2026-10-04');
    });

    test('6. "sun screen" and "mon ami" are text (short-form guards)', () {
      final VoiceTodoParse p = parse('Add to my to-do list, buy sun screen and call mon ami.');
      expect(p.dueDate, isNull);
      expect(p.entries, [
        const VoiceTodoItem('buy sun screen'),
        const VoiceTodoItem('call mon ami'),
      ]);
    });

    test('7. "in three days" as the sentence date, number word', () {
      final VoiceTodoParse p = parse('Add to my to-do list, in three days call the vet.');
      expect(p.items, ['call the vet']);
      expect(p.dueDate, '2026-09-30');
    });

    test('8. a weekday in the MIDDLE of an item is not a date', () {
      final VoiceTodoParse p = parse('Add to my to-do list, call mom on Sunday about the trip.');
      expect(p.dueDate, isNull);
      expect(p.entries, [const VoiceTodoItem('call mom on Sunday about the trip')]);
    });

    test('9. the phrase was the whole item — text kept, no date', () {
      final VoiceTodoParse p = parse('Add to my to-do list, today.');
      expect(p.dueDate, isNull);
      expect(p.entries, [const VoiceTodoItem('today')]);
    });

    test('10. v1.26.0 fixture 1 is unchanged', () {
      final VoiceTodoParse p = parse(
        'Add to my to-do list for September 30th to go to the store.',
      );
      expect(p.items, ['go to the store']);
      expect(p.dueDate, '2026-09-30');
      expect(p.entries.single.dueDate, isNull);
    });
  });

  group('TodoVoiceParser.parseWithDate — relative phrase table', () {
    // 2026-09-27 is a Sunday; the week after runs Mon 28 … Sun Oct 4.
    final DateTime sunday = DateTime(2026, 9, 27);

    String? due(String phrase, {DateTime? on}) => TodoVoiceParser
        .parseWithDate('add to my to do list $phrase buy nails', recordedOn: on ?? sunday)
        .dueDate;

    List<String> items(String phrase, {DateTime? on}) => TodoVoiceParser
        .parseWithDate('add to my to do list $phrase buy nails', recordedOn: on ?? sunday)
        .items;

    test('today / tomorrow / the day after tomorrow', () {
      expect(due('today'), '2026-09-27');
      expect(due('for today'), '2026-09-27');
      expect(due('tomorrow'), '2026-09-28');
      expect(due('by tomorrow'), '2026-09-28');
      expect(due('the day after tomorrow'), '2026-09-29');
      expect(due('day after tomorrow'), '2026-09-29');
      expect(items('the day after tomorrow'), ['buy nails']);
    });

    test('every weekday name and short form, strictly after a Sunday (R1)', () {
      const Map<String, String> table = <String, String>{
        'Monday': '2026-09-28', 'mon': '2026-09-28',
        'Tuesday': '2026-09-29', 'tue': '2026-09-29', 'tues': '2026-09-29',
        'Wednesday': '2026-09-30', 'wed': '2026-09-30', 'weds': '2026-09-30',
        'Thursday': '2026-10-01', 'thu': '2026-10-01', 'thur': '2026-10-01',
        'thurs': '2026-10-01',
        'Friday': '2026-10-02', 'fri': '2026-10-02',
        'Saturday': '2026-10-03', 'sat': '2026-10-03',
        'Sunday': '2026-10-04', 'sun': '2026-10-04',
      };
      for (final MapEntry<String, String> e in table.entries) {
        // Short forms need end-of-item / `.` / `,` after them, so they are
        // exercised at the item END; full names also at the sentence head.
        final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
          'add to my to do list buy nails on ${e.key}',
          recordedOn: sunday,
        );
        expect(p.entries.single.dueDate, e.value, reason: e.key);
        expect(p.items, ['buy nails'], reason: e.key);
        if (e.key.length > 5) {
          expect(due(e.key), e.value, reason: e.key);
          expect(due('this ${e.key}'), e.value, reason: 'this ${e.key}');
          expect(due('next ${e.key}'), e.value, reason: 'next ${e.key}');
          expect(due('on ${e.key.toUpperCase()}'), e.value, reason: e.key);
        }
      }
    });

    test('short forms with a trailing period or comma', () {
      final VoiceTodoParse p = TodoVoiceParser.parseWithDate(
        'add to my to do list buy nails fri., call Dana sat.',
        recordedOn: sunday,
      );
      expect(p.entries, [
        const VoiceTodoItem('buy nails', dueDate: '2026-10-02'),
        const VoiceTodoItem('call Dana', dueDate: '2026-10-03'),
      ]);
    });

    test('R1 across every anchor weekday: same name = +7, never today', () {
      // Anchor Mon Sep 28 … Sun Oct 4; ask for each weekday from each.
      const List<String> names = <String>[
        'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
      ];
      for (int a = 0; a < 7; a++) {
        final DateTime anchor = DateTime(2026, 9, 28 + a);
        for (int t = 0; t < 7; t++) {
          final int delta = ((t - a) % 7 + 7) % 7 == 0 ? 7 : ((t - a) % 7 + 7) % 7;
          final DateTime expected = DateTime(2026, 9, 28 + a + delta);
          final String iso = '${expected.year}-${expected.month.toString().padLeft(2, '0')}-'
              '${expected.day.toString().padLeft(2, '0')}';
          expect(due('on ${names[t]}', on: anchor), iso, reason: '${names[a]} → ${names[t]}');
        }
      }
    });

    test('in N days / weeks with digits, number words, and "a"', () {
      expect(due('in 3 days'), '2026-09-30');
      expect(due('in 1 day'), '2026-09-28');
      expect(due('in a day'), '2026-09-28');
      expect(due('in a week'), '2026-10-04');
      expect(due('in 2 weeks'), '2026-10-11');
      expect(due('in two weeks'), '2026-10-11');
      expect(due('in ten days'), '2026-10-07');
      expect(due('in twenty-one days'), '2026-10-18');
      expect(due('in twenty one days'), '2026-10-18');
      expect(due('in thirty days'), '2026-10-27');
      expect(due('in 30 days'), '2026-10-27');
      expect(items('in three days'), ['buy nails']);
    });

    test('number words one through thirty', () {
      const List<String> words = <String>[
        'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
        'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen',
        'seventeen', 'eighteen', 'nineteen', 'twenty', 'twenty-one', 'twenty-two',
        'twenty-three', 'twenty-four', 'twenty-five', 'twenty-six',
        'twenty-seven', 'twenty-eight', 'twenty-nine', 'thirty',
      ];
      for (int i = 0; i < words.length; i++) {
        final DateTime expected = DateTime(2026, 9, 27 + i + 1);
        final String iso = '${expected.year}-${expected.month.toString().padLeft(2, '0')}-'
            '${expected.day.toString().padLeft(2, '0')}';
        expect(due('in ${words[i]} days'), iso, reason: words[i]);
      }
    });

    test('next week = next Monday, next month = the 1st (R3)', () {
      expect(due('next week'), '2026-09-28'); // Sunday → tomorrow
      expect(due('next week', on: DateTime(2026, 9, 28)), '2026-10-05'); // Monday → +7
      expect(due('next week', on: DateTime(2026, 9, 30)), '2026-10-05'); // Wednesday
      expect(due('next month'), '2026-10-01');
      expect(due('next month', on: DateTime(2026, 12, 15)), '2027-01-01');
      expect(items('by next week'), ['buy nails']);
    });

    test('end of the week = coming Sunday (or today), end of the month', () {
      expect(due('end of the week'), '2026-09-27'); // recorded on a Sunday
      expect(due('the end of the week', on: DateTime(2026, 9, 28)), '2026-10-04');
      expect(due('by the end of the week', on: DateTime(2026, 10, 3)), '2026-10-04');
      expect(due('end of week', on: DateTime(2026, 9, 30)), '2026-10-04');
      expect(due('end of the month'), '2026-09-30');
      expect(due('by the end of the month', on: DateTime(2026, 2, 3)), '2026-02-28');
      expect(due('end of the month', on: DateTime(2028, 2, 3)), '2028-02-29');
      expect(due('end of the month', on: DateTime(2026, 12, 3)), '2026-12-31');
    });

    test('no Duration arithmetic: crossing the November DST change is exact', () {
      // US DST ends Sun 2026-11-01; a 23-hour-day bug would land on Oct 31.
      expect(due('in 7 days', on: DateTime(2026, 10, 27)), '2026-11-03');
      expect(due('in a week', on: DateTime(2026, 10, 31)), '2026-11-07');
      expect(due('on Sunday', on: DateTime(2026, 10, 31)), '2026-11-01');
    });

    test('NOT parsed: times of day, this weekend, soon, in a few days', () {
      const List<String> phrases = <String>[
        'at 3', 'this weekend', 'soon', 'later', 'someday', 'in a few days',
        'a week from Friday',
      ];
      for (final String phrase in phrases) {
        expect(due(phrase), isNull, reason: phrase);
        expect(items(phrase), ['$phrase buy nails'], reason: phrase);
      }
    });
  });

  group('TodoVoiceParser.parseWithDate — per-item positions (R2)', () {
    final DateTime sunday = DateTime(2026, 9, 27);

    VoiceTodoParse parse(String t) =>
        TodoVoiceParser.parseWithDate(t, recordedOn: sunday);

    test('a phrase at the START of an item', () {
      // The FIRST item's leading phrase is the sentence date (position 1);
      // later items' leading phrases are their own (position 2).
      final VoiceTodoParse p = parse(
        'add to my to do list buy nails, Sunday call mom and tomorrow buy milk',
      );
      expect(p.dueDate, isNull);
      expect(p.entries, [
        const VoiceTodoItem('buy nails'),
        const VoiceTodoItem('call mom', dueDate: '2026-10-04'),
        const VoiceTodoItem('buy milk', dueDate: '2026-09-28'),
      ]);
    });

    test('the first item\'s leading phrase is the SENTENCE date, not its own', () {
      final VoiceTodoParse p = parse('add to my to do list Sunday call mom and buy milk');
      expect(p.dueDate, '2026-10-04');
      expect(p.entries, [const VoiceTodoItem('call mom'), const VoiceTodoItem('buy milk')]);
    });

    test('end wins when both the start and the end carry a phrase', () {
      final VoiceTodoParse p = parse(
        'add to my to do list buy nails, tomorrow call mom on Friday',
      );
      expect(p.entries.last, const VoiceTodoItem('tomorrow call mom', dueDate: '2026-10-02'));
    });

    test('an absolute date at the item END', () {
      final VoiceTodoParse p = parse(
        'add to my to do list pay rent by the 30th of September, buy milk 10/2',
      );
      expect(p.entries, [
        const VoiceTodoItem('pay rent', dueDate: '2026-09-30'),
        const VoiceTodoItem('buy milk', dueDate: '2026-10-02'),
      ]);
    });

    test('items without their own date inherit nothing at the entry level', () {
      final VoiceTodoParse p = parse(
        'add to my to do list for Friday buy milk, call mom tomorrow, and mow',
      );
      expect(p.dueDate, '2026-10-02');
      expect(p.entries.map((e) => e.dueDate), [null, '2026-09-28', null]);
      expect(p.items, ['buy milk', 'call mom', 'mow']);
    });

    test('an unresolvable per-item date stays text', () {
      final VoiceTodoParse p = parse('add to my to do list pay rent on February 30th');
      expect(p.entries, [const VoiceTodoItem('pay rent on February 30th')]);
    });

    test('a phrase that IS the item keeps its text, no date (every form)', () {
      for (final String phrase in <String>['today', 'on Friday', 'next week', 'tomorrow']) {
        final VoiceTodoParse p = parse('add to my to do list buy nails, $phrase');
        expect(p.entries.last, VoiceTodoItem(phrase), reason: phrase);
      }
    });

    test('parse() strips per-item phrases too', () {
      expect(
        TodoVoiceParser.parse('Add to my to-do list, call the dentist on Friday.'),
        ['call the dentist'],
      );
    });

    test('VoiceTodoItem equality and toString', () {
      expect(const VoiceTodoItem('a', dueDate: 'x'), const VoiceTodoItem('a', dueDate: 'x'));
      expect(const VoiceTodoItem('a'), isNot(const VoiceTodoItem('a', dueDate: 'x')));
      expect(const VoiceTodoItem('a').hashCode, const VoiceTodoItem('a').hashCode);
      expect(const VoiceTodoItem('a', dueDate: 'x').toString(), contains('x'));
    });
  });

  group('TodoVoiceParser.parseWithDate — ambiguity guards', () {
    final DateTime sunday = DateTime(2026, 9, 27);

    VoiceTodoParse parse(String t) =>
        TodoVoiceParser.parseWithDate(t, recordedOn: sunday);

    test('"may" is a month only with a day number', () {
      expect(parse('add to my to do list may call mom').entries, [
        const VoiceTodoItem('may call mom'),
      ]);
      expect(
        parse('add to my to do list buy nails, may call mom').entries.last,
        const VoiceTodoItem('may call mom'),
      );
      expect(parse('add to my to do list may 30 call mom').dueDate, '2027-05-30');
    });

    test('short weekday forms inside words are text', () {
      for (final String t in <String>[
        'buy sun screen', 'call mon ami', 'fix the sat nav', 'the wed ding cake',
        'thu mbs up', 'fri es', 'tue sday',
      ]) {
        final VoiceTodoParse p = parse('add to my to do list $t');
        expect(p.entries, [VoiceTodoItem(t)], reason: t);
      }
      // ...and a short form glued to a following word at the item end.
      expect(parse('add to my to do list buy sunscreen').entries, [
        const VoiceTodoItem('buy sunscreen'),
      ]);
      expect(parse('add to my to do list buy nails friday_night').entries, [
        const VoiceTodoItem('buy nails friday_night'),
      ]);
    });

    test('full weekday names need a word boundary', () {
      expect(parse('add to my to do list read Mondays paper').entries, [
        const VoiceTodoItem('read Mondays paper'),
      ]);
      expect(parse('add to my to do list fridays are busy').entries, [
        const VoiceTodoItem('fridays are busy'),
      ]);
    });

    test('"in days" needs a number', () {
      expect(parse('add to my to do list in days like these buy nails').entries, [
        const VoiceTodoItem('in days like these buy nails'),
      ]);
      expect(parse('add to my to do list in a few days buy nails').dueDate, isNull);
      expect(parse('add to my to do list check in days').entries, [
        const VoiceTodoItem('check in days'),
      ]);
    });

    test('"todays" is text', () {
      expect(parse('add to my to do list todays paper').entries, [
        const VoiceTodoItem('todays paper'),
      ]);
      expect(parse('add to my to do list read todays paper').entries, [
        const VoiceTodoItem('read todays paper'),
      ]);
      expect(parse('add to my to do list buy nails todays').entries, [
        const VoiceTodoItem('buy nails todays'),
      ]);
      expect(parse('add to my to do list tomorrows meeting').dueDate, isNull);
    });
  });
}
