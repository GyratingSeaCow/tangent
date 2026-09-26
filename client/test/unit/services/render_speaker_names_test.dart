// SPDX-License-Identifier: AGPL-3.0-or-later
/// `renderSpeakerNames` / `unrenderSpeakerNames` (v1.17.0 spec §3).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/speaker_names.dart';
import 'package:tangent/services/render_speaker_names.dart';

const String _raw = '## Speaker 1\n'
    'Speaker 1: Morning, Speaker 2 was late again.\n'
    'we talked about Speaker 1 in prose\n'
    '\n'
    '## Speaker 2\n'
    'Speaker 2: Sorry.\n'
    'Speaker 2:\n'
    '\n'
    '## Speaker 3\n'
    'Speaker 3: unnamed stays\n'
    '\n'
    '## [unattributed]\n'
    'Speaker 10: not speaker 1\n'
    '## Summary\n'
    'Speaker 1 said things.\n';

final SpeakerNames _names =
    SpeakerNames(<String, String>{'Speaker 1': 'Jeff', 'Speaker 2': 'Sarah'});

void main() {
  group('renderSpeakerNames', () {
    test('replaces headings AND line-leading turn prefixes', () {
      final String out = renderSpeakerNames(_raw, _names);
      expect(out, contains('## Jeff\n'));
      expect(out, contains('## Sarah\n'));
      expect(
        out,
        contains('\nJeff: Morning, Speaker 2 was late again.\n'),
        reason: 'prefix renamed; the label inside prose is not',
      );
      expect(out, contains('\nSarah: Sorry.\n'));
      expect(out, contains('\nSarah:\n'), reason: 'bare prefix, no text');
      expect(out, isNot(contains('Speaker 1: ')));
      expect(out, isNot(contains('## Speaker 2')));
    });

    test('prose is untouched', () {
      final String out = renderSpeakerNames(_raw, _names);
      expect(out, contains('we talked about Speaker 1 in prose\n'));
      expect(out, contains('Speaker 1 said things.\n'));
      expect(
        out,
        contains('Speaker 10: not speaker 1\n'),
        reason: 'whole-word: Speaker 10 is not Speaker 1',
      );
    });

    test('unmapped labels and section headings pass through', () {
      final String out = renderSpeakerNames(_raw, _names);
      expect(out, contains('## Speaker 3\nSpeaker 3: unnamed stays\n'));
      expect(out, contains('## [unattributed]\n'));
      expect(out, contains('## Summary\n'));
    });

    test('empty map returns the identical string', () {
      expect(
        identical(renderSpeakerNames(_raw, const SpeakerNames.empty()), _raw),
        isTrue,
      );
    });

    test('a swap does not chain', () {
      final SpeakerNames swap = SpeakerNames(
        <String, String>{'Speaker 1': 'Speaker 2', 'Speaker 2': 'Speaker 1'},
      );
      const String t =
          '## Speaker 1\nSpeaker 1: a\n## Speaker 2\nSpeaker 2: b\n';
      expect(
        renderSpeakerNames(t, swap),
        '## Speaker 2\nSpeaker 2: a\n## Speaker 1\nSpeaker 1: b\n',
      );
    });

    test('CRLF lines keep their CR', () {
      expect(
        renderSpeakerNames('## Speaker 1\r\nSpeaker 1: hi\r\n', _names),
        '## Jeff\r\nJeff: hi\r\n',
      );
    });
  });

  group('unrenderSpeakerNames (reverse map on Edit save)', () {
    test('rendered text round-trips back to the raw labels', () {
      final String rendered = renderSpeakerNames(_raw, _names);
      expect(unrenderSpeakerNames(rendered, _names), _raw);
    });

    test('a typed heading that matches no name is left as typed', () {
      const String edited = '## Jeff\nJeff: hi\n## Dave\nDave: new person\n';
      expect(
        unrenderSpeakerNames(edited, _names),
        '## Speaker 1\nSpeaker 1: hi\n## Dave\nDave: new person\n',
      );
    });

    test('prose containing a name is untouched', () {
      const String edited =
          '## Jeff\nJeff: I told Sarah: no.\nSarah said Jeff: yes\n';
      expect(
        unrenderSpeakerNames(edited, _names),
        '## Speaker 1\nSpeaker 1: I told Sarah: no.\nSarah said Jeff: yes\n',
      );
    });

    test('empty map is the identity', () {
      const String edited = '## Jeff\nJeff: hi\n';
      expect(unrenderSpeakerNames(edited, const SpeakerNames.empty()), edited);
    });
  });
}
