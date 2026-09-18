// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/transcription_status.dart';

void main() {
  test('notApplicable wire round-trip', () {
    expect(TranscriptionStatus.notApplicable.wireValue, 'not_applicable');
    expect(
      TranscriptionStatus.fromWire('not_applicable'),
      TranscriptionStatus.notApplicable,
    );
  });
  test('existing statuses unchanged', () {
    for (final w in [
      'not_transcribed',
      'uploading',
      'queued',
      'running',
      'completed',
      'failed',
    ]) {
      expect(TranscriptionStatus.fromWire(w).wireValue, w);
    }
  });
}
