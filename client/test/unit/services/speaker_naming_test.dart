// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Speaker naming pure functions (docs/design/2026-09-26-speaker-naming.md §2).
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/speaker_naming.dart';

const String twoSpeakers = '## Speaker 1\n'
    '\n'
    'Ended up getting fired and then moved to Austin.\n'
    'Second line for one.\n'
    '\n'
    '## Speaker 2\n'
    '\n'
    'I told Speaker 1 to wait.\n'
    '\n'
    '## [unattributed]\n'
    '\n'
    'mumble';

void main() {
  group('detectSpeakers', () {
    test('returns labels in document order', () {
      expect(
        detectSpeakers('## Speaker 3\n\na\n\n## Speaker 1\n\nb\n\n## Speaker 2\n\nc'),
        <String>['Speaker 3', 'Speaker 1', 'Speaker 2'],
      );
    });

    test('ignores [unattributed] and non-speaker headings', () {
      expect(
        detectSpeakers(
          '## Meeting Summary\n\nx\n\n$twoSpeakers\n\n## Alice\n\nhi',
        ),
        <String>['Speaker 1', 'Speaker 2'],
      );
    });

    test('empty on a plain transcript', () {
      expect(detectSpeakers('just some words\nSpeaker 1 said hi'), isEmpty);
      expect(detectSpeakers(''), isEmpty);
    });

    test('tolerates CRLF line endings', () {
      expect(
        detectSpeakers('## Speaker 1\r\n\r\nhi\r\n## Speaker 2\r\nyo'),
        <String>['Speaker 1', 'Speaker 2'],
      );
    });
  });

  group('firstLineBySpeaker', () {
    test('first non-empty line under each heading', () {
      final Map<String, String> hints = firstLineBySpeaker(twoSpeakers);
      expect(
        hints['Speaker 1'],
        'Ended up getting fired and then moved to Austin.',
      );
      expect(hints['Speaker 2'], 'I told Speaker 1 to wait.');
      expect(hints['[unattributed]'], 'mumble');
    });

    test('ellipsises at 80 chars', () {
      final String long = 'w' * 200;
      final String hint = firstLineBySpeaker('## Speaker 1\n\n$long')['Speaker 1']!;
      expect(hint.length, 80);
      expect(hint.endsWith('…'), isTrue);
      expect(hint.substring(0, 79), 'w' * 79);
    });

    test('exactly 80 chars is kept whole', () {
      final String edge = 'e' * 80;
      expect(firstLineBySpeaker('## Speaker 1\n$edge')['Speaker 1'], edge);
    });

    test('a heading with no body has no hint', () {
      expect(
        firstLineBySpeaker('## Speaker 1\n\n\n## Speaker 2\nhi'),
        <String, String>{'Speaker 2': 'hi'},
      );
    });
  });

  group('applySpeakerNames', () {
    test('rewrites the heading and the Old: turn prefix', () {
      const String fallback = '## Speaker 1\n'
          '\n'
          '[00:00] Speaker 1: hello there\n'
          'Speaker 1: again\n'
          'Speaker 1:\n'
          '\n'
          '## Speaker 2\n'
          '\n'
          'Speaker 2: fine';
      final String out = applySpeakerNames(
        fallback,
        <String, String>{'Speaker 1': 'Alice', 'Speaker 2': 'Bob'},
      );
      expect(
        out,
        '## Alice\n'
        '\n'
        '[00:00] Speaker 1: hello there\n'
        'Alice: again\n'
        'Alice:\n'
        '\n'
        '## Bob\n'
        '\n'
        'Bob: fine',
      );
    });

    test('never touches the label inside prose', () {
      final String out = applySpeakerNames(
        twoSpeakers,
        <String, String>{'Speaker 1': 'Alice'},
      );
      expect(out, contains('## Alice\n'));
      expect(out, contains('I told Speaker 1 to wait.'));
      expect(out, isNot(contains('I told Alice to wait.')));
      // `Speaker 10:` is not a `Speaker 1:` prefix.
      expect(
        applySpeakerNames('Speaker 10: hi', <String, String>{'Speaker 1': 'A'}),
        'Speaker 10: hi',
      );
    });

    test('blank name leaves that speaker unchanged', () {
      expect(
        applySpeakerNames(
          twoSpeakers,
          <String, String>{'Speaker 1': '   ', 'Speaker 2': ''},
        ),
        twoSpeakers,
      );
      final String out = applySpeakerNames(
        twoSpeakers,
        <String, String>{'Speaker 1': '', 'Speaker 2': 'Bob'},
      );
      expect(out, contains('## Speaker 1\n'));
      expect(out, contains('## Bob\n'));
    });

    test('trims and collapses whitespace in names', () {
      final String out = applySpeakerNames(
        twoSpeakers,
        <String, String>{'Speaker 1': '  Alice \t  Smith \n'},
      );
      expect(out, contains('## Alice Smith\n'));
      expect(normalizeSpeakerName('  a   b '), 'a b');
    });

    test('is idempotent', () {
      const Map<String, String> renames = <String, String>{
        'Speaker 1': 'Alice',
        'Speaker 2': 'Bob',
      };
      final String once = applySpeakerNames(twoSpeakers, renames);
      expect(applySpeakerNames(once, renames), once);
    });

    test('swapping two labels does not chain', () {
      final String out = applySpeakerNames(
        twoSpeakers,
        <String, String>{'Speaker 1': 'Speaker 2', 'Speaker 2': 'Speaker 1'},
      );
      expect(out.indexOf('## Speaker 2\n'), lessThan(out.indexOf('## Speaker 1\n')));
      expect(detectSpeakers(out), <String>['Speaker 2', 'Speaker 1']);
    });

    test('unknown label is ignored and the identical string comes back', () {
      expect(
        identical(
          applySpeakerNames(twoSpeakers, <String, String>{'Speaker 9': 'Zed'}),
          twoSpeakers,
        ),
        isTrue,
      );
      expect(applySpeakerNames(twoSpeakers, const <String, String>{}), twoSpeakers);
    });

    test('preserves CRLF endings on rewritten lines', () {
      expect(
        applySpeakerNames(
          '## Speaker 1\r\n\r\nSpeaker 1: hi\r\n',
          <String, String>{'Speaker 1': 'Al'},
        ),
        '## Al\r\n\r\nAl: hi\r\n',
      );
    });
  });

  group('suggestedSpeakerNames', () {
    test('filters speaker labels, [unattributed] and section headings', () {
      expect(
        suggestedSpeakerNames(<String>[
          '## Meeting Summary\n\nx\n\n## Action Items\n\n- y\n\n## Transcript\n\n'
              '## Summary\n\n## Speaker 1\n\nhi\n\n## Alice\n\nyo\n\n'
              '## [unattributed]\n\nz\n\n## \n\nblank heading',
        ]),
        <String>['Alice'],
      );
    });

    test('newest first, then document order within a transcript', () {
      expect(
        suggestedSpeakerNames(<String>[
          '## Carol\n\na\n\n## Dave\n\nb',
          '## Alice\n\nc\n\n## Bob\n\nd',
        ]),
        <String>['Carol', 'Dave', 'Alice', 'Bob'],
      );
    });

    test('case-exact dedupe keeps the first sighting', () {
      expect(
        suggestedSpeakerNames(<String>[
          '## Alice\n\na\n\n## alice\n\nb',
          '## Alice\n\nc',
        ]),
        <String>['Alice', 'alice'],
      );
    });

    test('caps at 8', () {
      final List<String> many = List<String>.generate(
        12,
        (int i) => '## Person $i\n\nhi',
      );
      final List<String> out = suggestedSpeakerNames(many);
      expect(out.length, 8);
      expect(out.first, 'Person 0');
      expect(out.last, 'Person 7');
    });

    test('empty input yields empty', () {
      expect(suggestedSpeakerNames(const <String>[]), isEmpty);
      expect(suggestedSpeakerNames(<String>['no headings here']), isEmpty);
    });
  });

  group('collidingSpeakerNames', () {
    test('second field with a duplicate name collides, first does not', () {
      expect(
        collidingSpeakerNames(twoSpeakers, <String, String>{
          'Speaker 1': 'Alice',
          'Speaker 2': ' Alice ',
        }),
        <String>{'Speaker 2'},
      );
    });

    test('a name that is already a heading collides', () {
      expect(
        collidingSpeakerNames(twoSpeakers, <String, String>{
          'Speaker 1': 'Speaker 2',
          'Speaker 2': '',
        }),
        <String>{'Speaker 1'},
      );
      expect(
        collidingSpeakerNames(twoSpeakers, <String, String>{
          'Speaker 1': '[unattributed]',
        }),
        <String>{'Speaker 1'},
      );
    });

    test('blank entries and distinct names never collide', () {
      expect(
        collidingSpeakerNames(twoSpeakers, <String, String>{
          'Speaker 1': 'Alice',
          'Speaker 2': '',
        }),
        isEmpty,
      );
    });
  });
}
