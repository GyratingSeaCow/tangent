# Next iteration

Work agreed but deliberately not started, so it is not carried in conversation
alone. Each item states what is already true, so the next session does not
re-derive it.

---

## 1. Open items

### 1.0 Naming: KEEP "Tangent" — decided, closed (2026-09-23)

Jeff evaluated the "Tangent Notes" (tangentnotes.com) collision and decided
to keep the name: "they are different enough that we can make our own path
down that lane." Do not re-raise a rename. Differentiate in positioning
instead — self-hosted voice+ink for Android/Linux vs their lane. Candidate
research preserved in session history (Inkramble/Sidetangent/Inkmutter all
had clean namespaces) in case circumstances ever change.

### 1.1 Linux AppImage: verify handwriting search on desktop (v1.7.0 E2E gate)

**Status:** owed. The v1.7.0 tag's Release workflow builds and attaches
`Tangent-x86_64.AppImage`, so no local Linux build is needed — download it
from the release and run the checks below.

This is E2E checkpoint 6 and it is the WHOLE REASON the feature is
server-side: ML Kit is Android/iOS-only, so the Linux desktop must be able
to search handwriting with no on-device recognizer present. Everything it
depends on is already proven on Android:

- server indexes and serves the rows (248 rows / 10 notebooks / 0 errors);
- `include_ink_index=true` pull works and the client mirror applies it;
- search, highlight and next/prev all verified on the Fold's cover screen.

What to check on the AppImage: the search icon appears on both Notebooks
home and in-notebook, a query returns match counts + snippets, tapping a
result opens at the highlighted match, and next/prev wraps. No install
wizard should be reachable or needed — the desktop never installs an OCR
env, it only consumes the synced index.

Note: the desktop fallback base URL is fixed (`900f726`):
`defaultServerBaseUrl()` returns `http://localhost:8765` on desktop, the
emulator alias only on Android. An unpaired desktop now fails loud
(connection refused) instead of black-holing into `10.0.2.2`. Pairing
before testing is still the right path for checkpoint 6.

### 1.2 Bluetooth mic: request BLUETOOTH_CONNECT at runtime (TONIGHT — needs Jeff + AirPods)

**Status:** queued for tonight's session (2026-09-23). Jeff is at work and
cannot record test audio until evening. Blocked only on a human wearing
the headset.

**Jeff's hypothesis (2026-09-23, likely correct):** Google Meet prompted
him to "allow local devices" when using Bluetooth — that is Android 12+'s
**Nearby devices** runtime permission group, i.e. `BLUETOOTH_CONNECT`.
Tangent declares it in the manifest but NOTHING ever requests it at
runtime (grep confirms zero request calls), so it sits `granted=false`
forever — verified live on the Fold via
`dumpsys package dev.tangent.tangent`.

**Why this explains the T5 failure** (see
`docs/superpowers/plans/2026-09-17-t5-bluetooth-status.md`): enumeration
worked and selection persisted, but capture stayed on the built-in mic —
`mScoAudioState: SCO_STATE_INACTIVE`, `Preferred communication device:
null`. On Android 12+, bringing up the SCO link requires
BLUETOOTH_CONNECT, and it fails **silently** without it — exactly the
corpse we found. The denied permission also kneecaps the native
`setCommunicationDevice()` routing already written
(`AndroidCommunicationDevices.kt`, `CommunicationRouting.kt`):
`availableCommunicationDevices` won't offer BT SCO devices either. The
deprecated `startBluetoothSco()` in record_android 1.5.2 may have been
innocent, or at least not the only culprit.

**Wrinkle:** after T5 we HID Bluetooth mics from the Settings picker
entirely (`input_device_section.dart`, `_isOffered` filters
bluetooth/sco labels) — so the AirPods can't even be selected today.

**Tonight's plan:**

1. Isolate the variable first, zero code: `adb shell pm grant
   dev.tangent.tangent android.permission.BLUETOOTH_CONNECT` on the
   Fold, temporarily un-hide BT devices, Jeff connects AirPods, selects
   them, records ~10 s; read `dumpsys audio` mid-recording. Confirmed =
   SCO active + `source client` no longer MIC.
2. If confirmed, real fix: request Nearby-devices permission when a
   Bluetooth mic is tapped in the picker (same UX as Meet), un-hide BT
   devices behind the existing quality caveat (SCO/HFP, mono, 8–16 kHz,
   transcribes worse, opt-in), keep the native routing already written.
   RED-first tests; full parity install on all three devices.

### 1.3 Capitalize the app name everywhere it's user-visible (future release)

Jeff, 2026-09-23: "we need to capitalize the app name … Don't worry about
changing it now. We can catch that in a future release." The Flutter
`MaterialApp` title already says 'Tangent'; the launcher/window names
don't. Audited sites (display strings only):

- `client/android/app/src/main/AndroidManifest.xml:30` —
  `android:label="tangent"` → `"Tangent"` (the home-screen launcher name;
  the most visible one)
- `client/windows/runner/main.cpp:30` — window title `L"tangent"`
- `client/windows/runner/Runner.rc:93-98` — FileDescription /
  InternalName / ProductName `"tangent"` (OriginalFilename stays
  lowercase `tangent.exe`)
- Linux: `.desktop` entry name under `packaging/` if it says lowercase
  (check at fix time; AppImage display name rides on it)

Do NOT touch: `pubspec.yaml name: tangent` (Dart package name, must stay
lowercase), `BINARY_NAME` in both CMakeLists (executable filename),
`APPLICATION_ID`/`applicationId` `dev.tangent.tangent` (changing it
orphans installed apps' data). Display strings only.

### 1.4 Hardware-feedback-gated ideas (no work queued)

Hover-ring linger/thickness tuning if 250 ms feels wrong on device; toolbar
`visualDensity.compact` eyeball; flip-to-erase only if this pen ever emits
`invertedStylus`. New arcs come from daily-use annoyances.

## 2. Done (2026-09-21, v1.6.0 → v1.6.1)

- v1.6.0 cut: pen colours + highlighter (6-task SDD arc), notebook image
  import, Linux desktop AppImage via CI, all version sites reconciled.
- Eraser reach follows the rendered highlighter band (`d298386`).
- PDF export renders imported images, corrupt-bytes fallback (`9b5bdf3`).
- Pairing codes in Settings — no more docker-log reading (`117a305`);
  server display_name renamed "Tangent Server" (was "Jeff"), setup hint
  now says to name the machine, not yourself.
- Pen hover cursor, phase 6 (`ebaf43e`): honest-radius ring (pen width /
  highlighter band / eraser reach), stylus-only, cleared on contact,
  lasso-mode exempt (`9f038a2`). Phase 5 (side-button eraser) discovered
  already shipped in `_isErasing`.
- Lasso measures real block footprints via RenderBox (`3020553`); dump
  cards stay on the nominal 300×90 the 40% threshold was tuned against.

## 3. Done (2026-09 arc, earlier)

- Pen input phases 1–4: palm rejection, pressure width, fountain pen
  (`f238d3a`), italic nib + gamma (`2b98407`) — hardware-verified.
- Smart lasso: ink + blocks/recordings, 40% catch threshold, drag/delete/
  undo (`3a06581`, `add5ce4`, `a11ebb1`, `4c8f349`).
- Multi-step undo/redo, 100 deep (`09a9b73`).
- Save-on-back everywhere, replacing discard dialogs (`e13ea6e`).
- DEBUG banner removed (`4c8f349`).
- Multi-device sync discovery/pairing (`4f352bc` server, `e01ad1e` client):
  unauthenticated `/v1/server/info/public` beacon, client /24 sweep ("Find
  my server"), 6-digit log-code pairing minting device-bound revocable
  tokens. E2E-verified against the live container and by Jeff on hardware.
- Pen-writes-without-draw-mode (`dea6b39`), lined page templates
  (`f0916cb`), dumps filter bar (`523bc47`), amplified capture
  (`8b65a6f` + `baa6a7f`) — all verified per 2026-09-19 status sweep.
- Keystore backed up to local NAS (2026-09-19).
