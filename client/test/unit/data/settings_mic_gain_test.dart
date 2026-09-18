// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Microphone gain preference: persistence, clamping, and the format decision
// that follows from it.
//
// Gain above unity forces WAV capture, because `package:record` can only hand
// Dart raw PCM through its stream API -- the encoded path never exposes
// samples to multiply. Unity therefore keeps Opus and today's storage cost;
// only a user who asks for more sensitivity pays the ~8x size.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/services/audio_gain.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('microphone gain preference', () {
    test('defaults to unity', () async {
      final SettingsStore store = await SettingsStore.load();

      expect(
        store.micGain,
        defaultMicGain,
        reason: 'an untouched install must record exactly as it does today',
      );
    });

    test('a stored value is restored', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'microphone_gain': 2.5,
      });

      final SettingsStore store = await SettingsStore.load();

      expect(store.micGain, closeTo(2.5, 0.001));
    });

    test('setting the gain persists it', () async {
      final SettingsStore store = await SettingsStore.load();

      await store.setMicGain(3.0);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getDouble('microphone_gain'),
        closeTo(3.0, 0.001),
        reason: 'the choice must be written, not just held in memory',
      );
      expect((await SettingsStore.load()).micGain, closeTo(3.0, 0.001));
    });

    test('a gain above the ceiling is clamped', () async {
      final SettingsStore store = await SettingsStore.load();

      await store.setMicGain(99.0);

      expect(
        store.micGain,
        maxMicGain,
        reason: 'beyond the ceiling the microphone self-noise dominates; '
            'amplifying hiss is not a feature',
      );
    });

    test('a gain below the floor is clamped', () async {
      final SettingsStore store = await SettingsStore.load();

      await store.setMicGain(0.01);

      expect(store.micGain, minMicGain);
    });

    test('a corrupt stored value falls back to unity', () async {
      // A preference file can be edited or carried from a future build. A
      // nonsense gain must not silently destroy a recording's level.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'microphone_gain': 500.0,
      });

      expect((await SettingsStore.load()).micGain, maxMicGain);
    });
  });

  group('capture format follows the gain', () {
    test('unity gain records opus', () {
      expect(
        captureExtensionForGain('brain_dump', defaultMicGain),
        'opus',
        reason: 'the default must not cost 8x storage',
      );
    });

    test('gain above unity records wav', () {
      expect(
        captureExtensionForGain('brain_dump', 2.0),
        'wav',
        reason: 'samples can only be amplified on the raw PCM path',
      );
    });

    test('text notes stay markdown at any gain', () {
      expect(captureExtensionForGain('text_note', 4.0), 'md');
      expect(captureExtensionForGain('text_note', defaultMicGain), 'md');
    });

    test('a gain barely above unity still switches format', () {
      // No dead band: if the user moved the slider at all, the gain must
      // actually apply, or the setting silently does nothing.
      expect(captureExtensionForGain('meeting', 1.1), 'wav');
    });

    test('every audio mode honours the gain', () {
      for (final String mode in <String>['brain_dump', 'meeting', 'idea']) {
        expect(captureExtensionForGain(mode, 2.0), 'wav', reason: mode);
        expect(captureExtensionForGain(mode, 1.0), 'opus', reason: mode);
      }
    });
  });
}
