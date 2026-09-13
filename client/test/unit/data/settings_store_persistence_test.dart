// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsStore', () {
    test('default trigger mode is tap', () {
      expect(SettingsStore().triggerMode, TriggerMode.tap);
    });
    test('default wifi only is true', () {
      expect(SettingsStore().wifiOnlySync, isTrue);
    });
    test('setTriggerMode persists', () async {
      final s = SettingsStore();
      await s.setTriggerMode(TriggerMode.hold);
      expect(s.triggerMode, TriggerMode.hold);
    });
    test('setWifiOnlySync persists', () async {
      final s = SettingsStore();
      await s.setWifiOnlySync(true);
      expect(s.wifiOnlySync, isTrue);
    });
  });
}