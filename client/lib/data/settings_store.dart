// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_gain.dart';

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
  static const _deviceOnlyKey = 'keep_recordings_on_device_only';
  static const _inputDeviceIdKey = 'preferred_input_device_id';
  static const _inputDeviceLabelKey = 'preferred_input_device_label';
  static const _micGainKey = 'microphone_gain';
  static const _handwritingSearchKey = 'handwriting_search_enabled';
  static const _aiSummariesKey = 'ai_summaries_enabled';
  static const _autoBluetoothKey = 'auto_bluetooth_audio';

  final SharedPreferences? _preferences;

  /// Gates bulk upload/backup of recordings only (see [SyncEngine]).
  ///
  /// Transcription to the self-hosted server is a separate concern and is
  /// never gated by this flag or by [keepRecordingsOnDeviceOnly]: the audio a
  /// transcription request sends is the transcription request, not a backup.
  bool wifiOnlySync;
  bool autoSync;
  TriggerMode triggerMode;
  bool keepScreenAwakeWhileRecording;

  /// Record through a connected Bluetooth headset automatically, the way
  /// calls do. Default on; the permission prompt still gates the first use.
  bool autoBluetoothAudio;

  /// When true (the default) no recording is ever uploaded to the server for
  /// storage. Transcription still works, over Wi-Fi or cellular.
  bool keepRecordingsOnDeviceOnly;

  /// Platform id of the microphone the user opted into, or null to let the
  /// system pick its default input (almost always the built-in mic).
  ///
  /// Null is deliberately distinct from "chose the built-in mic": it is the
  /// only value that lets the recorder defer entirely to the platform, and it
  /// is the default because SCO/HFP headset audio is materially worse for
  /// transcription than the built-in mic. This preference is opt-in and is
  /// never set automatically just because a headset is connected.
  String? preferredInputDeviceId;

  /// Human label captured when the device was chosen, so Settings can still
  /// name a headset that is currently switched off or out of range.
  String? preferredInputDeviceLabel;

  /// Multiplier applied to every captured PCM sample.
  ///
  /// Unity is the default and leaves capture byte-identical to before this
  /// setting existed, INCLUDING the container: package:record can only hand
  /// Dart raw samples through its stream API, so amplified audio has to be
  /// written as WAV. Keeping unity on Opus means the ~8x storage cost is paid
  /// only by a user who actually asked for more sensitivity.
  double micGain;

  /// Server-side handwriting search (OCR of ink into a searchable index).
  ///
  /// OFF by default: turning it on installs a multi-gigabyte ML environment
  /// on the user's server, so it only ever happens through the Settings
  /// wizard's explicit confirm. While off, no OCR UI appears anywhere.
  bool handwritingSearchEnabled;

  /// AI summaries of meeting recordings (server-side Qwen summarizer).
  ///
  /// OFF by default for the same reason as [handwritingSearchEnabled]:
  /// turning it on downloads ~2.5 GB onto the user's server, so it only
  /// ever happens through the Settings wizard's explicit confirm. This is
  /// the LOCAL mirror used to seed the toggle; the auto-summarize gate
  /// itself lives server-side (it changes behavior for every device).
  bool aiSummariesEnabled;

  SettingsStore({
    this.wifiOnlySync = true,
    this.autoSync = true,
    this.triggerMode = TriggerMode.tap,
    this.keepScreenAwakeWhileRecording = true,
    this.autoBluetoothAudio = true,
    this.keepRecordingsOnDeviceOnly = true,
    this.preferredInputDeviceId,
    this.preferredInputDeviceLabel,
    this.micGain = defaultMicGain,
    this.handwritingSearchEnabled = false,
    this.aiSummariesEnabled = false,
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
      autoBluetoothAudio: preferences.getBool(_autoBluetoothKey) ?? true,
      keepRecordingsOnDeviceOnly: preferences.getBool(_deviceOnlyKey) ?? true,
      preferredInputDeviceId: preferences.getString(_inputDeviceIdKey),
      preferredInputDeviceLabel: preferences.getString(_inputDeviceLabelKey),
      // Clamped on read as well as write: a preference file can be edited by
      // hand or carried back from a future build, and a nonsense multiplier
      // would wreck every recording made afterwards.
      micGain: clampMicGain(preferences.getDouble(_micGainKey)),
      handwritingSearchEnabled:
          preferences.getBool(_handwritingSearchKey) ?? false,
      aiSummariesEnabled: preferences.getBool(_aiSummariesKey) ?? false,
    );
  }

  Future<void> setMicGain(double value) async {
    final double clamped = clampMicGain(value);
    micGain = clamped;
    await _preferences?.setDouble(_micGainKey, clamped);
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

  Future<void> setAutoBluetoothAudio(bool value) async {
    autoBluetoothAudio = value;
    await _preferences?.setBool(_autoBluetoothKey, value);
  }

  Future<void> setKeepRecordingsOnDeviceOnly(bool value) async {
    keepRecordingsOnDeviceOnly = value;
    await _preferences?.setBool(_deviceOnlyKey, value);
  }

  Future<void> setHandwritingSearchEnabled(bool value) async {
    handwritingSearchEnabled = value;
    await _preferences?.setBool(_handwritingSearchKey, value);
  }

  Future<void> setAiSummariesEnabled(bool value) async {
    aiSummariesEnabled = value;
    await _preferences?.setBool(_aiSummariesKey, value);
  }

  /// Records the user's explicit microphone choice. Passing a null [id] clears
  /// the choice and returns the recorder to the system default input.
  Future<void> setPreferredInputDevice({
    required String? id,
    required String? label,
  }) async {
    preferredInputDeviceId = id;
    preferredInputDeviceLabel = id == null ? null : label;
    final preferences = _preferences;
    if (preferences == null) return;
    if (id == null) {
      await preferences.remove(_inputDeviceIdKey);
      await preferences.remove(_inputDeviceLabelKey);
      return;
    }
    await preferences.setString(_inputDeviceIdKey, id);
    if (label == null) {
      await preferences.remove(_inputDeviceLabelKey);
    } else {
      await preferences.setString(_inputDeviceLabelKey, label);
    }
  }
}
