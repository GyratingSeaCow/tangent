// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/settings_store.dart';

/// Jeff records through Bluetooth earbuds. The chosen input device must
/// survive an app restart, and "no choice" must stay distinguishable from
/// "chose the built-in mic" so the recorder can defer to the system default.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsStore preferred input device', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to the system default device', () async {
      final store = await SettingsStore.load();
      expect(store.preferredInputDeviceId, isNull);
      expect(store.preferredInputDeviceLabel, isNull);
    });

    test('a chosen device survives a new store', () async {
      final first = await SettingsStore.load();
      await first.setPreferredInputDevice(
        id: 'bt-17',
        label: 'Galaxy Buds (Bluetooth telephony SCO, 00:11)',
      );
      expect(first.preferredInputDeviceId, 'bt-17');

      final reloaded = await SettingsStore.load();
      expect(reloaded.preferredInputDeviceId, 'bt-17');
      expect(
        reloaded.preferredInputDeviceLabel,
        'Galaxy Buds (Bluetooth telephony SCO, 00:11)',
      );
    });

    test('clearing the choice returns to the system default', () async {
      final first = await SettingsStore.load();
      await first.setPreferredInputDevice(id: 'bt-17', label: 'Buds');
      await first.setPreferredInputDevice(id: null, label: null);
      expect(first.preferredInputDeviceId, isNull);
      expect(first.preferredInputDeviceLabel, isNull);

      final reloaded = await SettingsStore.load();
      expect(reloaded.preferredInputDeviceId, isNull);
      expect(reloaded.preferredInputDeviceLabel, isNull);
    });
  });
}
