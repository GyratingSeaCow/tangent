// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Reproduces the on-device failure found on a Galaxy Tab S10 FE: with the
// microphone gain slider above 1.0x, the record button appeared to do nothing.
//
// The PCM stream genuinely opened (logcat showed AudioRecorder taking audio
// focus at 16 kHz mono) but nothing was ever saved, and the recorder was left
// wedged so the NEXT recording failed too — even after returning the slider to
// unity — until the app was restarted.
//
// Cause: an amplified capture is PCM in a WAV container, so the recorder
// legitimately stages `<id>.wav`. Validation and publication still recomputed
// the expected name from the capture MODE alone, which always says `.opus` for
// an audio mode, so every amplified recording was rejected as not-owned.
//
// These tests drive the real SqliteStorageCatalog and RecordingPersistence,
// not a mock, so they fail if any layer goes back to a mode-derived name.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/audio_gain.dart';

import '../../support/scripted_storage_backend.dart';
import '../../support/storage_fixture.dart';
import 'recording_staging_validation_test.dart' show saveWith;

void main() {
  group('an amplified capture survives save', () {
    test('gain above unity stages wav and still publishes', () async {
      final CatalogHarness h = CatalogHarness();
      addTearDown(h.close);
      await h.bootstrap();
      await h.choose('A');

      const double gain = 4.0;
      expect(usesAmplifiedCapture(gain), isTrue);

      final r = requireOk(
        await h.catalog.reserveCapture(mode: 'brain_dump', gain: gain),
      );

      // The recorder writes a WAV container, exactly as it does on device.
      expect(p.extension(r.stagingPath), '.wav');
      await File(r.stagingPath).writeAsBytes(
        <int>[0x52, 0x49, 0x46, 0x46, 0x2a, 0x00],
        flush: true,
      );

      // Before the fix this threw: staging validation compared the real
      // `<id>.wav` against a mode-derived `<id>.opus` and faulted, which is
      // what made the button look dead.
      final row = await saveWith(h.mutations, h.f.db, h.backend, r, 6);

      expect(row.audioSizeBytes, 6);
      expect(await h.f.db.getDump(row.id), isNotNull);
      expect(
        p.extension(row.audioPath),
        '.wav',
        reason: 'an amplified recording must publish as the wav it staged',
      );
      expect(await File(row.audioPath).exists(), isTrue);
    });

    test('unity gain is untouched and still publishes opus', () async {
      final CatalogHarness h = CatalogHarness();
      addTearDown(h.close);
      await h.bootstrap();
      await h.choose('A');

      expect(usesAmplifiedCapture(1.0), isFalse);

      final r = requireOk(
        await h.catalog.reserveCapture(mode: 'brain_dump', gain: 1.0),
      );
      expect(p.extension(r.stagingPath), '.opus');
      await File(r.stagingPath).writeAsBytes(
        <int>[0x4f, 0x67, 0x67, 0x53, 1],
        flush: true,
      );

      final row = await saveWith(h.mutations, h.f.db, h.backend, r, 5);
      expect(row.audioSizeBytes, 5);
      expect(p.extension(row.audioPath), '.opus');
      expect(await File(row.audioPath).exists(), isTrue);
    });

    test('a failed amplified save never destroys the staged audio', () async {
      // The wedge was worse than a rejected save: raw audio must survive any
      // failure so a recording is never lost to a naming disagreement.
      final CatalogHarness h = CatalogHarness();
      addTearDown(h.close);
      await h.bootstrap();
      await h.choose('A');

      final r = requireOk(
        await h.catalog.reserveCapture(mode: 'brain_dump', gain: 8.0),
      );
      await File(r.stagingPath).writeAsBytes(<int>[1, 2, 3], flush: true);

      try {
        await saveWith(h.mutations, h.f.db, h.backend, r, 3);
      } on StorageFault {
        expect(
          await File(r.stagingPath).exists(),
          isTrue,
          reason: 'failure paths preserve raw recordings',
        );
      }
    });
  });
}
