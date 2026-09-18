// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The reservation's staging extension must follow the user's gain.
//
// Dart and Kotlin agree on the published filename by both deriving it from the
// capture mode. Gain breaks that assumption -- an amplified capture is WAV, not
// Opus -- so the reservation has to carry the real extension and the SAF port
// has to accept it. A mismatch surfaces as `Invalid reservation staging path`
// and a save that leaves no row: audio recorded, then lost.
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/audio_gain.dart';

void main() {
  group('staging extension follows the gain', () {
    test('unity gain reserves an opus path', () {
      expect(
        stagingExtension(mode: 'brain_dump', gain: defaultMicGain),
        'opus',
      );
    });

    test('amplified capture reserves a wav path', () {
      expect(stagingExtension(mode: 'brain_dump', gain: 2.0), 'wav');
    });

    test('meetings honour the gain too', () {
      expect(stagingExtension(mode: 'meeting', gain: 4.0), 'wav');
      expect(stagingExtension(mode: 'meeting', gain: defaultMicGain), 'opus');
    });

    test('text notes ignore the gain entirely', () {
      // A text note has no audio; a gain slider must never change its
      // extension or the SAF port will refuse to publish it.
      expect(stagingExtension(mode: 'text_note', gain: 4.0), 'md');
      expect(stagingExtension(mode: 'text_note', gain: defaultMicGain), 'md');
    });

    test('an out-of-range gain still yields a legal extension', () {
      // Clamping happens on read, but the staging path is the one place a
      // bad value would create a file nothing downstream can find.
      expect(stagingExtension(mode: 'brain_dump', gain: 999.0), 'wav');
      // A negative gain clamps to the 0.5x floor -- still a real multiplier,
      // so it must take the PCM path like any other non-unity gain.
      expect(stagingExtension(mode: 'brain_dump', gain: -5.0), 'wav');
    });
  });

  group('the published suffix set', () {
    test('accepts every extension the app can produce', () {
      // This set is mirrored in Kotlin (AndroidDocumentsPort,
      // CapturePublication). Anything missing here is a capture that cannot
      // be published.
      expect(publishableContentSuffixes, containsAll(<String>['.opus', '.md']));
      expect(
        publishableContentSuffixes,
        contains('.wav'),
        reason: 'amplified captures are WAV and must be publishable',
      );
    });
  });
}
