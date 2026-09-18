// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression: an amplified capture must survive validation and publication.
//
// Found on a Galaxy Tab S10 FE, not in the suite. With gain at 4.0x the record
// button did nothing: the PCM stream genuinely opened (logcat showed
// AudioRecorder taking audio focus at 16 kHz mono) but no file appeared, the
// UI never entered the recording state, and the recorder was left wedged so
// the NEXT recording failed too -- even after dropping gain back to unity.
// Only an app restart cleared it.
//
// The cause was extension derivation. Eight call sites still computed the
// content name from the capture MODE alone (`contentExtensionForMode`), so
// they expected `<id>.opus` while an amplified capture legitimately stages
// `<id>.wav`. Staging validation therefore rejected the file that had just
// been recorded.
//
// These tests pin the rule end to end: whatever the gain, the name the
// pipeline EXPECTS must equal the name the reservation actually produced.
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/audio_gain.dart';

import '../../support/scripted_storage_backend.dart';
import '../../support/storage_fixture.dart';

void main() {
  late CatalogHarness h;

  setUp(() async {
    h = CatalogHarness();
    await h.bootstrap();
    await h.choose('A');
  });
  tearDown(() async => h.close());

  group('the expected content name follows the staged file', () {
    test('an amplified reservation expects the wav it actually staged',
        () async {
      final r = requireOk(
        await h.catalog.reserveCapture(mode: 'brain_dump', gain: 4.0),
      );

      // This is the comparison staging validation performs. Deriving it from
      // the mode yields '.opus' and rejects the real recording.
      expect(
        '${r.id}.${contentExtensionForReservation(r.mode, r.stagingPath)}',
        r.stagingPath.split(RegExp(r'[/\\]')).last,
        reason: 'validation must expect the file the recorder just wrote',
      );
    });

    test('a unity reservation still expects opus', () async {
      final r = requireOk(
        await h.catalog.reserveCapture(mode: 'brain_dump', gain: 1.0),
      );

      expect(
        '${r.id}.${contentExtensionForReservation(r.mode, r.stagingPath)}',
        r.stagingPath.split(RegExp(r'[/\\]')).last,
      );
      expect(r.stagingPath.endsWith('.opus'), isTrue);
    });

    test('a text note still expects markdown', () async {
      final r = requireOk(
        await h.catalog.reserveCapture(mode: 'text_note', gain: 4.0),
      );

      expect(
        contentExtensionForReservation(r.mode, r.stagingPath),
        'md',
      );
    });
  });

  group('published names match staged names at every gain', () {
    test('across the whole supported range', () async {
      // One reservation per harness: the catalog allows a single live capture
      // at a time and rejects the next with 'Recording or finalization is
      // active', so reusing one harness would test the busy guard instead of
      // the naming rule.
      for (final double gain in <double>[0.5, 1.0, 2.0, 4.0, 8.0]) {
        final CatalogHarness local = CatalogHarness();
        await local.bootstrap();
        await local.choose('A');
        try {
          final r = requireOk(
            await local.catalog.reserveCapture(mode: 'brain_dump', gain: gain),
          );
          final String staged = r.stagingPath.split(RegExp(r'[/\\]')).last;
          final String expected =
              '${r.id}.${contentExtensionForReservation(r.mode, r.stagingPath)}';

          expect(expected, staged, reason: 'gain $gain');
          expect(
            r.stagingPath
                .endsWith(usesAmplifiedCapture(gain) ? '.wav' : '.opus'),
            isTrue,
            reason: 'gain $gain staged ${r.stagingPath}',
          );
        } finally {
          await local.close();
        }
      }
    });
  });
}
