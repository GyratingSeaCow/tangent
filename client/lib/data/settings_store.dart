// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:shared_preferences/shared_preferences.dart';

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
  static const _wifiKey = 'wifi_only_sync';
  static const _autoKey = 'auto_sync';
  static const _triggerKey = 'trigger_mode';
  static const _awakeKey = 'keep_screen_awake_while_recording';

  final SharedPreferences? _preferences;
  bool wifiOnlySync;
  bool autoSync;
  TriggerMode triggerMode;
  bool keepScreenAwakeWhileRecording;

  SettingsStore({
    this.wifiOnlySync = true,
    this.autoSync = true,
    this.triggerMode = TriggerMode.tap,
    this.keepScreenAwakeWhileRecording = true,
    SharedPreferences? preferences,
  }) : _preferences = preferences;

  static Future<SettingsStore> load() async {
    final preferences = await SharedPreferences.getInstance();
    final trigger = preferences.getString(_triggerKey);
    return SettingsStore(
      preferences: preferences,
      wifiOnlySync: preferences.getBool(_wifiKey) ?? true,
      autoSync: preferences.getBool(_autoKey) ?? true,
      triggerMode: TriggerMode.values.firstWhere(
        (mode) => mode.wireValue == trigger,
        orElse: () => TriggerMode.tap,
      ),
      keepScreenAwakeWhileRecording: preferences.getBool(_awakeKey) ?? true,
    );
  }

  Future<void> setWifiOnlySync(bool v) async {
    wifiOnlySync = v;
    await _preferences?.setBool(_wifiKey, v);
  }

  Future<void> setAutoSync(bool v) async {
    autoSync = v;
    await _preferences?.setBool(_autoKey, v);
  }

  Future<void> setTriggerMode(TriggerMode m) async {
    triggerMode = m;
    await _preferences?.setString(_triggerKey, m.wireValue);
  }

  Future<void> setKeepScreenAwakeWhileRecording(bool value) async {
    keepScreenAwakeWhileRecording = value;
    await _preferences?.setBool(_awakeKey, value);
  }
}
