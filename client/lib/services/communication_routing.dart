// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/services.dart';

/// What happened when capture was routed to a chosen microphone.
enum CommunicationRoute {
  /// The headset mic is now the communication device.
  applied,

  /// The chosen device is not connected. Recording uses the default mic.
  absent,

  /// The selection is not a Bluetooth headset; nothing needed routing.
  notApplicable,

  /// The platform refused, failed, or is too old. Default mic is used.
  unavailable,
}

/// Routes capture to a Bluetooth headset microphone.
///
/// WHY THIS EXISTS: the `record` package (record_android 1.5.2) drives
/// Bluetooth with the deprecated `startBluetoothSco()` pair, which does not
/// bring the SCO link up on this project's target hardware. Verified on a
/// Galaxy Z Fold (REDACTED_DEVICE_MODEL) with AirPods Pro connected — while the headset was
/// the selected input, `dumpsys audio` during an active recording reported
/// `source client=MIC` (the built-in mic), `type:bt_a2dp` (a playback profile,
/// which carries no microphone), `mScoAudioState: SCO_STATE_INACTIVE` and
/// `Preferred communication device: null`. Selecting the headset changed
/// nothing but a stored preference.
///
/// The native side calls `AudioManager.setCommunicationDevice()` instead.
///
/// Every method here is best-effort and never throws. A headset that is off,
/// out of range, or refused by the platform must never prevent a recording —
/// capture proceeds on the built-in microphone instead.
class CommunicationRouting {
  CommunicationRouting({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('dev.tangent.tangent/audio');

  final MethodChannel _channel;

  /// Route capture to [inputDeviceId], the id of the chosen microphone.
  ///
  /// The id is a String because that is what `record` exposes: record_android
  /// stringifies Android's integer AudioDeviceInfo.id (`"id" to "${it.id}"` in
  /// DeviceUtils.kt). It is parsed back to an int here because
  /// setCommunicationDevice matches on the numeric id.
  ///
  /// Passing null means "system default", which needs no routing and costs no
  /// platform round trip.
  Future<CommunicationRoute> route(String? inputDeviceId) async {
    if (inputDeviceId == null) return CommunicationRoute.notApplicable;
    final numeric = int.tryParse(inputDeviceId);
    // A non-numeric id cannot be an Android audio device; nothing to route.
    if (numeric == null) return CommunicationRoute.notApplicable;
    try {
      final reply = await _channel.invokeMapMethod<String, Object?>(
        'routeCommunicationDevice',
        {'deviceId': numeric},
      );
      return _decode(reply?['state']);
    } on Object {
      // Deliberately swallowed: routing is an enhancement, not a precondition.
      return CommunicationRoute.unavailable;
    }
  }

  /// Release the route when capture ends.
  ///
  /// Leaving a communication device applied keeps the phone in call-audio mode,
  /// which degrades music playback and pins the headset to its low-quality SCO
  /// profile.
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clearCommunicationDevice');
    } on Object {
      // Nothing useful to do; the platform releases it when capture stops.
    }
  }

  CommunicationRoute _decode(Object? state) => switch (state) {
        'applied' => CommunicationRoute.applied,
        'absent' => CommunicationRoute.absent,
        'not_applicable' || 'notApplicable' => CommunicationRoute.notApplicable,
        _ => CommunicationRoute.unavailable,
      };
}
