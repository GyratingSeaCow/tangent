// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('keep screen awake defaults on and survives a new store', () async {
      final first = await SettingsStore.load();
      expect(first.keepScreenAwakeWhileRecording, isTrue);
      await first.setKeepScreenAwakeWhileRecording(false);

      final reloaded = await SettingsStore.load();
      expect(reloaded.keepScreenAwakeWhileRecording, isFalse);
    });

    test('handwriting search defaults OFF and survives a new store', () async {
      final first = await SettingsStore.load();
      expect(first.handwritingSearchEnabled, isFalse);
      await first.setHandwritingSearchEnabled(true);

      final reloaded = await SettingsStore.load();
      expect(reloaded.handwritingSearchEnabled, isTrue);
    });

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
