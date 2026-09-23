// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/tangent_tokens.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../recording/recording_controller.dart';
import 'settings_screen.dart';

/// Lets the user record through a Bluetooth headset or external mic.
///
/// Deliberately opt-in. A headset mic reaches Android over SCO/HFP, which is
/// mono and narrow/wideband (8-16 kHz, compressed) — materially worse for
/// transcription than the phone's built-in mic. Tangent therefore never
/// switches to a headset just because one is connected; the user must choose
/// it here, and the trade-off is stated on screen.
///
/// Enumeration happens here and on demand, never on the record path.
class InputDeviceSection extends ConsumerStatefulWidget {
  const InputDeviceSection({super.key});

  @override
  ConsumerState<InputDeviceSection> createState() => _InputDeviceSectionState();
}

class _InputDeviceSectionState extends ConsumerState<InputDeviceSection> {
  List<InputDevice> _devices = const [];
  bool _loading = false;
  bool _enumerated = false;

  /// True when the remembered choice exists on the device but is deliberately
  /// not offered (a Bluetooth headset). Distinct from "gone": a hidden device
  /// will never come back, so it must not be shown as merely unavailable.
  bool _selectionHidden = false;

  // Deliberately NOT enumerating unconditionally on mount. Touching
  // recordingServiceProvider would construct the recorder (and its storage
  // dependencies) merely because Settings was opened. The one case that does
  // need it up front is a REMEMBERED device: the row has to be able to say
  // "unavailable" when the headset is off, rather than implying it is in use.
  late bool _autoBluetooth = ref.read(settingsStoreProvider).autoBluetoothAudio;

  @override
  void initState() {
    super.initState();
    if (ref.read(settingsStoreProvider).preferredInputDeviceId != null) {
      _refresh();
    }
  }

  /// Bluetooth headset mics are hidden, not offered-and-broken.
  ///
  /// Verified on device (Galaxy Z Fold + AirPods Pro, 2026-09-17): the routing
  /// plumbing works — AudioManager.setCommunicationDevice() applies, the
  /// headset reaches mScoAudioState: SCO_STATE_ACTIVE_INTERNAL before capture
  /// opens, and the route is released on stop. Capture STILL reports
  /// `source client=MIC` and Android exposes no input-role device, so the
  /// recorder never receives the headset microphone.
  ///
  /// Listing it would be dishonest: the row would say "AirPods Pro" while the
  /// phone quietly recorded from its own mic. Capturing from SCO needs a
  /// custom Android recorder, which is not built. Until then these are hidden.
  ///
  /// See docs/superpowers/plans/2026-09-17-t5-bluetooth-status.md.
  static bool _isRecordable(InputDevice device) {
    final label = device.label.toLowerCase();
    return !label.contains('bluetooth') && !label.contains('sco');
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    // No setState here: _refresh is also called from initState, before the
    // first build. Assigning directly is safe because the pending awaits
    // resolve after the first frame, and the setState below repaints.
    _loading = true;
    final service = ref.read(recordingServiceProvider);
    final devices = await service.listInputDevices();
    if (!mounted) return;
    final offered = devices.where(_isRecordable).toList(growable: false);
    final chosen = ref.read(settingsStoreProvider).preferredInputDeviceId;
    setState(() {
      _devices = offered;
      _loading = false;
      _enumerated = true;
      _selectionHidden = chosen != null &&
          devices.any((d) => d.id == chosen) &&
          !offered.any((d) => d.id == chosen);
    });
  }

  String? get _selectedId =>
      ref.read(settingsStoreProvider).preferredInputDeviceId;

  InputDevice? get _selectedDevice {
    final id = _selectedId;
    if (id == null) return null;
    for (final device in _devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  bool get _selectionMissing =>
      _enumerated && _selectedId != null && _selectedDevice == null;

  String _subtitle() {
    if (_loading) return 'Checking available microphones…';
    final settings = ref.read(settingsStoreProvider);
    final id = settings.preferredInputDeviceId;
    if (id == null) return 'System default microphone';
    final device = _selectedDevice;
    // A choice saved on an earlier build may name a Bluetooth headset that is
    // no longer offered. Never present it as the microphone in use — recording
    // would come from the built-in mic regardless.
    //
    // Decided by ABSENCE from the filtered list rather than by sniffing the
    // saved label: the stored label is whatever the picker showed at the time
    // (e.g. plain "Galaxy Buds"), which need not contain "Bluetooth" at all.
    // Note this deliberately also covers a device that simply went away, since
    // in both cases recording will use the system default and saying anything
    // else would be false.
    if (_enumerated && _selectionHidden) {
      return 'System default microphone';
    }
    final label = device?.label ??
        settings.preferredInputDeviceLabel ??
        'Selected microphone';
    // A device that simply went away still reports honestly: the user's choice
    // is not being honoured and recording falls back to the default.
    if (_selectionMissing) {
      return '$label — unavailable, recording will use the system default';
    }
    return label;
  }

  Future<void> _choose() async {
    await _refresh();
    if (!mounted) return;
    final chosen = await showModalBottomSheet<_DeviceChoice>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Record from',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              title: const Text('System default'),
              subtitle: const Text('Best transcription quality'),
              selected: _selectedId == null,
              onTap: () => Navigator.of(context).pop(const _DeviceChoice(null)),
            ),
            for (final device in _devices)
              ListTile(
                title: Text(device.label),
                selected: device.id == _selectedId,
                onTap: () => Navigator.of(context).pop(_DeviceChoice(device)),
              ),
            if (_devices.isEmpty)
              const ListTile(
                title: Text('No other microphones found'),
                subtitle: Text(
                  'Connect a headset, then reopen this list. Bluetooth '
                  'devices may also need the Nearby devices permission.',
                ),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final device = chosen.device;
    await ref.read(settingsStoreProvider).setPreferredInputDevice(
          id: device?.id,
          label: device?.label,
        );
    await ref.read(recordingServiceProvider).selectInputDevice(device);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Audio input',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          title: const Text('Microphone'),
          subtitle: Text(_subtitle()),
          trailing: _loading
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _loading ? null : _choose,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            'Choose which built-in microphone records. If a chosen '
            'microphone is unavailable, recording still starts on the '
            'system default.',
            style: TextStyle(fontSize: 12, color: TangentColors.textDim),
          ),
        ),
        SwitchListTile(
          title: const Text('Auto-enable Bluetooth audio'),
          value: _autoBluetooth,
          onChanged: (value) {
            setState(() => _autoBluetooth = value);
            unawaited(
              ref.read(settingsStoreProvider).setAutoBluetoothAudio(value),
            );
          },
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            'When a Bluetooth headset is connected, record through its '
            'microphone automatically — the same way phone calls do. With '
            'no headset connected, the microphone above is used. Note: '
            'Bluetooth voice audio is narrowband, so headset recordings '
            'sound thinner than the built-in microphone.',
            style: TextStyle(fontSize: 12, color: TangentColors.textDim),
          ),
        ),
      ],
    );
  }
}

class _DeviceChoice {
  const _DeviceChoice(this.device);
  final InputDevice? device;
}
