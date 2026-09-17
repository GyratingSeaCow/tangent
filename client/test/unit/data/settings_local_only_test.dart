// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/settings_store.dart';

/// `keepRecordingsOnDeviceOnly` governs bulk upload/backup of recordings.
/// It is deliberately independent of transcription connectivity: reaching the
/// self-hosted server to transcribe is never gated by this flag, nor by
/// `wifiOnlySync`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsStore device-only recordings', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to on so recordings never leave the device', () {
      expect(SettingsStore().keepRecordingsOnDeviceOnly, isTrue);
    });

    test('defaults to on when nothing is persisted yet', () async {
      final loaded = await SettingsStore.load();
      expect(loaded.keepRecordingsOnDeviceOnly, isTrue);
    });

    test('round-trips through SharedPreferences', () async {
      final first = await SettingsStore.load();
      await first.setKeepRecordingsOnDeviceOnly(false);
      expect(first.keepRecordingsOnDeviceOnly, isFalse);

      final reloaded = await SettingsStore.load();
      expect(reloaded.keepRecordingsOnDeviceOnly, isFalse);

      await reloaded.setKeepRecordingsOnDeviceOnly(true);
      expect((await SettingsStore.load()).keepRecordingsOnDeviceOnly, isTrue);
    });

    test('is independent of the wifi-only upload window', () async {
      final store = await SettingsStore.load();
      await store.setKeepRecordingsOnDeviceOnly(false);
      expect(store.wifiOnlySync, isTrue,
          reason: 'turning off device-only storage must not widen the '
              'upload connection window',);

      await store.setWifiOnlySync(false);
      expect((await SettingsStore.load()).keepRecordingsOnDeviceOnly, isFalse);
    });
  });
}
