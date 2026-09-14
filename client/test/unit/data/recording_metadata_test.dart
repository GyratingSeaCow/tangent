// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/recording_metadata.dart';

void main() {
  test('orphan recording without metadata gets a valid generated title', () {
    final row = importedDumpRow(
      id: '1789341285253510',
      locator: 'content://recording',
      sizeBytes: 19740,
      modifiedAt: DateTime.utc(2026, 9, 14, 19, 24),
    );
    expect(row.title, isNotEmpty);
    expect(row.title, startsWith('Recording '));
  });

  test('blank metadata title is repaired while other metadata is restored', () {
    final row = importedDumpRow(
      id: 'id-2',
      locator: 'content://recording-2',
      sizeBytes: 42,
      modifiedAt: DateTime.utc(2026, 9, 14),
      metadata: const {
        'title': '',
        'transcript': 'restored transcript',
        'durationSeconds': 9,
        'mode': 'meeting',
      },
    );
    expect(row.title, isNotEmpty);
    expect(row.transcript, 'restored transcript');
    expect(row.durationSeconds, 9);
    expect(row.mode, 'meeting');
  });
}
