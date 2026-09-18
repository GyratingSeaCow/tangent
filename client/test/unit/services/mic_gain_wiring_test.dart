// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The gain the user sets in Settings must actually reach capture.
//
// Every layer below this is already tested in isolation: the multiplier, the
// preference, the WAV writer, the staging extension. None of that matters if
// the wiring is missing -- the slider would save a number nothing reads, which
// is exactly the kind of control that lies to the user.
//
// Two links are checked here because BOTH must hold, and they must agree:
// the recorder amplifies, and the reservation names the file .wav. If only one
// fires, PCM is streamed into a file called .opus and the recording is
// unreadable.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/audio_gain.dart';

import '../../support/scripted_storage_backend.dart';
import '../../support/storage_fixture.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('the stored gain drives the staging extension', () {
    test('a stored gain above unity reserves a wav path', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'microphone_gain': 2.0,
      });
      final SettingsStore settings = await SettingsStore.load();

      expect(
        stagingExtension(mode: 'brain_dump', gain: settings.micGain),
        'wav',
      );
    });

    test('an untouched install still reserves opus', () async {
      final SettingsStore settings = await SettingsStore.load();

      expect(
        stagingExtension(mode: 'brain_dump', gain: settings.micGain),
        'opus',
      );
    });
  });

  group('the recorder and the reservation cannot disagree', () {
    test('both sides read the same predicate', () async {
      // The single source of truth. If these diverged, amplified samples
      // would be written into a container named for the other format.
      for (final double gain in <double>[0.5, 1.0, 1.5, 2.0, 4.0, 8.0]) {
        final bool amplified = usesAmplifiedCapture(gain);
        final String extension =
            stagingExtension(mode: 'brain_dump', gain: gain);
        expect(
          extension,
          amplified ? 'wav' : 'opus',
          reason: 'gain $gain: capture path and staging name must agree',
        );
      }
    });

    test('a gain saved through Settings survives a reload', () async {
      // The store is what the recorder and the catalog both read, so a value
      // that does not survive here never reaches capture at all.
      final SettingsStore settings = await SettingsStore.load();
      await settings.setMicGain(3.5);

      final SettingsStore reloaded = await SettingsStore.load();
      expect(reloaded.micGain, closeTo(3.5, 0.001));
      expect(usesAmplifiedCapture(reloaded.micGain), isTrue);
      expect(
        stagingExtension(mode: 'meeting', gain: reloaded.micGain),
        'wav',
      );
    });
  });

  group('the real catalog reserves the amplified name', () {
    // The earlier groups test the RULE. This exercises the actual
    // SqliteStorageCatalog: if reserveCapture ignored the gain, or the
    // provider failed to pass it, an amplified recording would be staged as
    // .opus and rejected by the native port at publish time.
    late CatalogHarness h;

    setUp(() async {
      h = CatalogHarness();
      await h.bootstrap();
      await h.choose('A');
    });
    tearDown(() async => h.close());

    test('amplified gain stages a .wav file', () async {
      final r = requireOk(
        await h.catalog.reserveCapture(mode: 'brain_dump', gain: 2.0),
      );

      expect(
        r.stagingPath.endsWith('.wav'),
        isTrue,
        reason: 'staged as ${r.stagingPath}',
      );
    });

    test('unity gain still stages .opus', () async {
      final r = requireOk(
        await h.catalog.reserveCapture(mode: 'brain_dump', gain: 1.0),
      );

      expect(r.stagingPath.endsWith('.opus'), isTrue);
    });

    test('the default argument keeps existing callers on opus', () async {
      // Every call site that does not know about gain must be unaffected.
      final r = requireOk(await h.catalog.reserveCapture(mode: 'meeting'));

      expect(r.stagingPath.endsWith('.opus'), isTrue);
    });

    test('a text note is markdown whatever the gain', () async {
      final r = requireOk(
        await h.catalog.reserveCapture(mode: 'text_note', gain: 4.0),
      );

      expect(r.stagingPath.endsWith('.md'), isTrue);
    });
  });
}
