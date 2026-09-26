// SPDX-License-Identifier: AGPL-3.0-or-later
/// The client-side mirror of the server's effective-template rule: the
/// picker marks the row the server would ACTUALLY apply, so the two must
/// agree — dump.summary_template ?? mode default.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/dump/summarize_flow.dart';

void main() {
  group('effectiveTemplateId', () {
    test('a persisted template wins over the mode default', () {
      expect(effectiveTemplateId('lecture', 'meeting'), 'lecture');
      expect(effectiveTemplateId('actions_only', 'brain_dump'), 'actions_only');
      expect(effectiveTemplateId('custom', 'text_note'), 'custom');
    });

    test('meeting defaults to the meeting preset', () {
      expect(effectiveTemplateId(null, 'meeting'), 'meeting');
    });

    test('brain_dump defaults to the brain_dump preset', () {
      expect(effectiveTemplateId(null, 'brain_dump'), 'brain_dump');
    });

    test('text_note defaults to brain_dump (no attendee/action framing)', () {
      expect(effectiveTemplateId(null, 'text_note'), 'brain_dump');
    });

    test('a blank persisted template counts as unset', () {
      expect(effectiveTemplateId('', 'meeting'), 'meeting');
      expect(effectiveTemplateId('   ', 'brain_dump'), 'brain_dump');
    });

    test('an unknown mode falls back to brain_dump', () {
      expect(effectiveTemplateId(null, 'whatever'), 'brain_dump');
    });
  });
}
