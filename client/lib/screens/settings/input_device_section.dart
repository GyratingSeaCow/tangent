// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
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

  // Deliberately NOT enumerating unconditionally on mount. Touching
  // recordingServiceProvider would construct the recorder (and its storage
  // dependencies) merely because Settings was opened. The one case that does
  // need it up front is a REMEMBERED device: the row has to be able to say
  // "unavailable" when the headset is off, rather than implying it is in use.
  @override
  void initState() {
    super.initState();
    if (ref.read(settingsStoreProvider).preferredInputDeviceId != null) {
      _refresh();
    }
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
    setState(() {
      _devices = devices;
      _loading = false;
      _enumerated = true;
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
    final label = _selectedDevice?.label ??
        settings.preferredInputDeviceLabel ??
        'Selected microphone';
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
              onTap: () =>
                  Navigator.of(context).pop(const _DeviceChoice(null)),
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
            'A Bluetooth headset mic records over the phone-call audio path '
            '(SCO/HFP): mono, 8–16 kHz and compressed. That is lower quality '
            'than the built-in mic and transcribes less accurately, so Tangent '
            'only uses a headset when you pick one here. If the headset is off '
            'or out of range, recording still starts on the system default.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
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
