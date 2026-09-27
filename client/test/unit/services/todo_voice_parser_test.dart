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
}
