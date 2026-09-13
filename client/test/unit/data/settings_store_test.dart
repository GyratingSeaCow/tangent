// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/settings_store.dart';

void main() {
  group('SettingsStore', () {
    test('defaults are wifi-only sync, auto-sync on, tap trigger', () {
      final store = SettingsStore();
      expect(store.wifiOnlySync, isTrue);
      expect(store.autoSync, isTrue);
      expect(store.triggerMode, TriggerMode.tap);
    });

    test('can override defaults via constructor', () {
      final store = SettingsStore(
        wifiOnlySync: false,
        autoSync: false,
        triggerMode: TriggerMode.hold,
      );
      expect(store.wifiOnlySync, isFalse);
      expect(store.autoSync, isFalse);
      expect(store.triggerMode, TriggerMode.hold);
    });

    test('values are mutable', () {
      final store = SettingsStore();
      store.wifiOnlySync = false;
      store.triggerMode = TriggerMode.hold;
      expect(store.wifiOnlySync, isFalse);
      expect(store.triggerMode, TriggerMode.hold);
    });

    test('TriggerMode displayName is human-readable', () {
      expect(TriggerMode.tap.displayName, 'Tap to toggle');
      expect(TriggerMode.hold.displayName, 'Hold to record');
    });
  });
}