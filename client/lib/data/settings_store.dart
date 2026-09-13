// SPDX-License-Identifier: AGPL-3.0-or-later

enum TriggerMode {
  tap('tap'),
  hold('hold');

  const TriggerMode(this.wireValue);
  final String wireValue;

  String get displayName => switch (this) {
        TriggerMode.tap => 'Tap to toggle',
        TriggerMode.hold => 'Hold to record',
      };
}

class SettingsStore {
  bool wifiOnlySync;
  bool autoSync;
  TriggerMode triggerMode;

  SettingsStore({
    this.wifiOnlySync = true,
    this.autoSync = true,
    this.triggerMode = TriggerMode.tap,
  });

  Future<void> setWifiOnlySync(bool v) async {
    wifiOnlySync = v;
  }

  Future<void> setAutoSync(bool v) async {
    autoSync = v;
  }

  Future<void> setTriggerMode(TriggerMode m) async {
    triggerMode = m;
  }
}