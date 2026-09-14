# Tangent Android v1 Device Verification

**Date:** 2026-09-14
**Device:** Samsung REDACTED_DEVICE_MODEL (`arm64-v8a`)
**Application ID:** `dev.tangent.tangent`

## Build gates

- `flutter test --reporter expanded`: **91 tests passed**.
- `flutter analyze`: **No issues found**.
- `flutter build apk --debug`: succeeded.
- `git diff --check`: passed.
- Installed in place with `adb install -r`; only `dev.tangent.tangent` was targeted and app data was retained.
- Final APK SHA-256: `eeb878d19710578797db7fcc625a677d52985c1540d634ee6df3e68ad05d7a34`.

## Model verification

- File: `files/whisper_models/ggml-large-v3.bin`.
- Size: `3,095,033,483` bytes.
- SHA-256: `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`.
- The checksum matches the immutable model specification.

## Playback verification

Recording `1789352434950426` was opened directly from its persisted Android SAF locator.

1. Playback advanced from `00:00` to `00:09` and returned to Play at completion.
2. The draggable seek bar moved backward to `00:04`.
3. Playback resumed from that position and paused at `00:05 / 00:09`.
4. PID-scoped logs contained no playback exception or source error.
5. A stale Android completed-state race found during this test was fixed and covered by a regression test.

## Local transcription verification

- Wi-Fi and mobile data were both disabled before starting transcription; their prior values were recorded and restored afterward.
- Tangent visibly progressed through local audio preparation and native `Whisper large-v3` loading.
- The shared progress panel remained visible after navigation/backgrounding and showed stage, model size, elapsed time, progress animation, and cancellation.
- The nine-second recording completed with this nonempty local transcript:

> They bring out over 200 different additives, including high fructose corn syrup, artificial sweeteners, and preservatives. Be you! And they only source the best

The same transcript was independently verified in:

- Tangent's Dump detail UI.
- Public sidecar `1789352434950426.meta.json`, with `updatedAt` `2026-09-14T12:39:20.525717Z`.
- SQLite row `1789352434950426`, with sync status still `pending`.

The cleared operation log contains no HTTP URL, Dio request, audio upload, server transcription enqueue, or `/v1/` request. Wi-Fi was inadvertently re-enabled when the user switched apps during the long native load, then disabled again; no network transcription activity occurred and persistence remained entirely local.

## Active-list and cancellation verification

- While recording `1789352584881163` was active, the Dumps list showed **Preparing audio locally…** and a spinner only on that row.
- Returning to its detail screen showed **Loading Whisper large-v3** with the ongoing elapsed time.
- Pressing Cancel changed the panel to **Cancelling local transcription** and disabled the button as **Cancelling…**.
- Because the plugin's model loader cannot terminate its isolate mid-load, the Tangent test process was then force-stopped to release memory.
- Relaunch succeeded, the 3.1 GB model remained installed, and the cancelled recording's sidecar remained intact with `transcript: null`.

## Restored device state

- Wi-Fi: enabled (`1`).
- Mobile data: enabled (`1`).
- Airplane mode: unchanged (`0`).
- Temporary USB stay-awake: restored to disabled (`0`).

## Large-v3-turbo and queue addendum

- Installed in place on Samsung `REDACTED_DEVICE_MODEL`, serial `REDACTED_DEVICE`; app data and public recordings were preserved.
- Verified private model `files/whisper_models/ggml-large-v3-turbo.bin`: `1,624,555,275` bytes; SHA-256 `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`.
- Queue reproduction: recording `1789393892907091` was active while recording `1789392589582077` retained an enabled Transcribe action. Tapping it displayed `Queued #1`. Dumps showed `Transcribing locally` only on the first row and `Queued #1` only on the second. Navigation remained responsive.
- FIFO advancement: the first recording completed at `2026-09-14T14:06:51Z`; the second began automatically and completed at `2026-09-14T14:12:44Z` without another tap.
- Timed turbo inference including first model initialization: `333 s` wall clock for a four-second clip (`10:01:18` to `10:06:51` EDT). Reused-engine queued inference: `353 s` for a nine-second clip (`10:06:51` to `10:12:44` EDT). This device is functionally correct, but CPU inference is not interactive-speed.
- First transcript shown in UI, SQLite, and `/sdcard/Documents/Tangent/1789393892907091.meta.json`: `Testing, testing, one, two, three. Testing, testing.` Sync status remained `pending`.
- Second sidecar `/sdcard/Documents/Tangent/1789392589582077.meta.json` contains `Testing the meeting notes. Next action item is taking care of the i9 processors.`
- PID-scoped logcat contained no HTTP URL, `/v1/`, upload, enqueue, Dio, SocketException, crash, SIGSEGV, or local-transcription exception controlling either run. Samsung MediaCodec emitted `LegacyMessageQueue` warnings immediately after local Opus decoding; decoding and both inferences nevertheless completed and persisted correctly.
- Post-queue automated verification: `100` Flutter tests passed; `flutter analyze` reported `No issues found!`; debug APK size `198,581,510` bytes and SHA-256 `55f7b32dbc252e0213fe6c6c437254d9c6185bd65970253c07dbd202a60bfc83`.
