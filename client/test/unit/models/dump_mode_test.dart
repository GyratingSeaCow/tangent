// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/dump_mode.dart';

void main() {
  test('textNote wire and display values', () {
    expect(DumpMode.textNote.wireValue, 'text_note');
    expect(DumpMode.fromWire('text_note'), DumpMode.textNote);
    expect(DumpMode.textNote.displayName, 'Text Note');
  });
  test('existing modes unchanged', () {
    expect(DumpMode.brainDump.wireValue, 'brain_dump');
    expect(DumpMode.meeting.wireValue, 'meeting');
  });
}
