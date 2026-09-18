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


---

# UPDATE — native routing implemented (commit pending)

`CommunicationRouting` (Kotlin, 10 unit tests) + `AndroidCommunicationDevices`
now call `AudioManager.setCommunicationDevice()`. Measured on the same hardware
with AirPods Pro connected.

## What CHANGED — the routing call works

BEFORE:

    Applied Preferred communication device: null
    Active communication device: role:output type:bt_a2dp   <- playback profile
    mScoAudioState: SCO_STATE_INACTIVE

AFTER:

    Applied Preferred communication device: AudioDeviceAttributes:
        role:output type:bt_sco addr:...:35:C2 name:AirPods Pro

    [DeviceInfo: type:0x10 (bt_sco) name:AirPods Pro ...]
    [DeviceInfo: type:0x80000008 (bt_sco_hs) name:AirPods Pro ...]
    strategy: 1 role:1 devices:[... type:bt_sco ... name:AirPods Pro]
    strategy: 7 role:1 devices:[... type:bt_sco ... name:AirPods Pro]

The profile flipped a2dp -> **bt_sco**, the headset registered as both `bt_sco`
and `bt_sco_hs`, and two routing strategies now point at it. `setCommunicationDevice()`
is accepted; the earlier `null` is gone.

Release also verified: after stopping, `Applied Preferred communication device: null`.
The phone leaves call-audio mode, so music playback and headset quality are not
left degraded.

## What STILL does not change — the capture source

    session:6729 -- source client=MIC, dev=1ch 16000Hz ... pack:dev.tangent.tangent

Still the built-in mic, sampled at t+1.3s, t+3.2s, t+4.7s and t+6.3s after the
record tap.

## Diagnosis

The applied route is `role:output` in every reading. Android brought the SCO
link up for the OUTPUT direction, but the recorder's capture stream was already
opened and bound to the built-in mic before the asynchronous route landed. The
input side of the patch (`patch:1578`) never moved.

This is the cost of the deliberate no-stall design: routing is fired without
being awaited so the record tap stays fast, which means capture opens first.

## Options from here

1. Re-open the capture stream once routing completes — stop and restart the
   recorder mid-capture. Risks a gap or a truncated file at the very start; the
   staging/publication contract would need to tolerate a restart.
2. Await SCO connection before opening capture, with a hard timeout (~1s) and
   fallback to the built-in mic. Directly contradicts the T6 work that removed
   a 5.8s stall from the record tap, though a bounded 1s is not 5.8s.
3. Warm the route when the headset is SELECTED in Settings rather than at record
   time, so SCO is already up before the tap. Costs battery while idle and the
   user's stated rule is no idle microphone pre-warming — but a communication
   route is not a microphone open, so this may be acceptable.
4. Ship the current state: routing applied, capture still built-in. NOT
   acceptable on its own, because the UI implies a mic switch that does not
   happen.

Option 3 followed by 1 is the most promising. Neither is written yet.

## Honest status

The native routing layer is correct and proven to take effect. The feature as a
whole — "record through my earbuds" — is NOT yet delivered. Do not describe T5
as working.
