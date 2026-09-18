# T5 Bluetooth mic — verified status (2026-09-17)

Device: Galaxy Z Fold (REDACTED_DEVICE_MODEL), AirPods Pro connected. Build `fa2ceec`.

## What is PROVEN WORKING on hardware

- Enumeration: the picker lists `AirPods Pro (Bluetooth telephony SCO, ...:35:C2)`
  alongside `Built-in (bottom)` and `Built-in (back)`.
- Persistence: choosing them wrote
  `flutter.preferred_input_device_id = 1535` and the full label to
  SharedPreferences, and it survives an app restart.
- The quality caveat renders on screen as written (SCO/HFP, mono, 8-16 kHz,
  transcribes worse, opt-in only).
- Recording still starts promptly with a device selected: timer reached 00:02
  with a live waveform, no stall reintroduced on the record path.
- `BLUETOOTH_CONNECT` turned out NOT to be required for enumeration on this
  device: `granted=false` and the AirPods were still listed. The permission is
  declared and harmless, but the earlier claim that enumeration would return an
  empty list without it is WRONG on this hardware.

## What is NOT working — the actual mic never switches

`dumpsys audio` during an active recording:

    RecordActivityMonitor
      session:6713 -- source client=MIC, dev=1ch 16000Hz ...
      pack:dev.tangent.tangent -- silenced:false

    Computed Preferred communication device: null
    Applied  Preferred communication device: null
    Active communication device: role:output type:bt_a2dp addr:...:35:C2
                                 name:AirPods Pro
    mScoAudioState: SCO_STATE_INACTIVE

Reading:
- `source client=MIC` — capture came from the BUILT-IN microphone.
- `type:bt_a2dp`, and role is **output** — A2DP is a playback profile and carries
  no microphone. The headset mic lives on HFP/SCO.
- `SCO_STATE_INACTIVE` — the SCO link was never brought up.
- `Preferred communication device: null` — nothing called
  `AudioManager.setCommunicationDevice()`.

So the selection is stored and passed down, but the audio HAL never routes to the
headset mic. The recording is real audio from the wrong microphone.

## Root cause

`record` 6.2.1 -> `record_android` 1.5.2 drives Bluetooth with the DEPRECATED
`startBluetoothSco()` / `setBluetoothScoOn()` pair
(`record/bluetooth/BluetoothReceiver.kt:99-117`), invoked from
`RecorderWrapper.maybeStartBluetooth()`. On Android 12+ the supported API is
`AudioManager.setCommunicationDevice(AudioDeviceInfo)` with a device of
`TYPE_BLUETOOTH_SCO`. The deprecated call did not activate SCO on this device.

## Options

1. App-side native Kotlin: call `setCommunicationDevice()` before capture starts
   and `clearCommunicationDevice()` after. SCO activation is asynchronous, so it
   must NOT block the record tap — this app just removed a 5.8s stall from that
   path and must not regain one. Likely shape: start capture immediately on the
   built-in mic, switch routing when SCO connects, and be honest in the UI that
   the first moment may be built-in.
2. Check for a newer `record_android` that migrated to the modern API.
3. Leave as-is and mark the headset option unsupported, hiding SCO devices from
   the picker rather than offering a choice that silently does nothing.

Option 3 is the only one acceptable to ship AS-IS, because the current UI implies
a switch that does not happen. Either make it work or stop offering it.

## Not yet measured

The real SCO capture sample rate on this hardware. The UI states 8-16 kHz from
the spec; that number is UNVERIFIED because SCO never activated.
