// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Windows capture format: Media Foundation has no Opus ENCODER (only a
// decoder), so encoded-opus start fails on Windows — proven on the bench
// 2026-09-25. Capture there must take the PCM→WAV stream path even at
// unity gain, riding the exact pipeline the mic-gain feature proved.
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart'
    show publishableContentSuffixes;
import 'package:tangent/services/audio_gain.dart';

void main() {
  tearDown(() {
    debugIsWindowsCaptureOverride = null;
  });

  group('usesPcmCapture', () {
    test('non-Windows, unity gain: encoded opus path', () {
      debugIsWindowsCaptureOverride = false;
      expect(usesPcmCapture(defaultMicGain), isFalse);
    });

    test('non-Windows, applied gain: PCM path (gain rule unchanged)', () {
      debugIsWindowsCaptureOverride = false;
      expect(usesPcmCapture(2.0), isTrue);
    });

    test('Windows: PCM path even at unity gain', () {
      debugIsWindowsCaptureOverride = true;
      expect(usesPcmCapture(defaultMicGain), isTrue);
    });

    test('Windows does not make unity gain count as amplified', () {
      debugIsWindowsCaptureOverride = true;
      // The gain multiplier must still be a no-op at unity — Windows only
      // changes the CONTAINER decision, not the amplification decision.
      expect(usesAmplifiedCapture(defaultMicGain), isFalse);
    });
  });

  group('captureExtensionForGain', () {
    test('Windows audio capture stages as wav at unity gain', () {
      debugIsWindowsCaptureOverride = true;
      expect(captureExtensionForGain('brain_dump', defaultMicGain), 'wav');
    });

    test('non-Windows audio capture stays opus at unity gain', () {
      debugIsWindowsCaptureOverride = false;
      expect(captureExtensionForGain('brain_dump', defaultMicGain), 'opus');
    });

    test('text notes are markdown everywhere', () {
      debugIsWindowsCaptureOverride = true;
      expect(captureExtensionForGain('text_note', defaultMicGain), 'md');
    });

    test('wav is a publishable suffix (allow-list already covers it)', () {
      expect(publishableContentSuffixes, contains('.wav'));
    });
  });
}
