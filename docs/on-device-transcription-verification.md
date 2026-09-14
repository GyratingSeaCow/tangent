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
