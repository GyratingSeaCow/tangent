# On-Device Android Transcription Implementation Plan

> **For agentic workers:** Execute inline with strict RED→GREEN cycles. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Tangent's server-side transcription path with checksum-verified Whisper large-v3 inference on the Android phone.

**Architecture:** Durable recordings remain Opus in the SAF folder. A native Android decoder creates a temporary PCM WAV, Dart converts it to mono 16 kHz PCM, and whisper.cpp performs local inference. The transcript is committed to SQLite and the public sidecar before the UI reports success; server sync is optional replication only.

**Tech Stack:** Flutter 3.27+, Riverpod, Drift/SQLite, Kotlin/Android MediaCodec, `whisper_cpp_flutter_plus` 0.4.1, whisper.cpp 1.9.2.

## Global Constraints

- Use full multilingual `ggml-large-v3.bin`; never silently fall back to a smaller or remote model.
- Pin revision `5359861c739e955e79d9a303bcbc70fb988958b1` and SHA-256 `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`.
- Preserve all existing `.opus` recordings and metadata.
- Server availability must not affect local transcription.
- Install in place with application ID `dev.tangent.tangent`; do not uninstall or clear app data.
- Completion requires successful transcription while the network/server is unavailable.

---

### Task 1: Model definition and testable local service boundary

**Files:**
- Modify: `client/pubspec.yaml`
- Create: `client/lib/services/on_device_transcription.dart`
- Test: `client/test/unit/services/on_device_transcription_test.dart`

**Interfaces:**
- `LocalModelSpec` exposes exact model metadata.
- `AudioDecoder.decodeToWav(Uint8List source, Directory temporaryDirectory) -> Future<File>`.
- `WhisperRuntime.installModel(void Function(ModelProgress) onProgress) -> Future<File>`.
- `WhisperRuntime.transcribe(File wav, void Function(int) onProgress) -> Future<String>`.
- `OnDeviceTranscriptionService.transcribe(Uint8List audio, {required void Function(LocalTranscriptionProgress) onProgress}) -> Future<String>`.
- `OnDeviceTranscriptionService.cancel() -> void`.

- [ ] Write a failing test proving the service decodes locally, invokes the local runtime, forwards progress, trims output, and always deletes temporary files.
- [ ] Run `flutter test test/unit/services/on_device_transcription_test.dart --reporter expanded`; expect failure because the service does not exist.
- [ ] Add `whisper_cpp_flutter_plus: 0.4.1` and implement the smallest dependency-injected orchestration needed to pass.
- [ ] Add RED→GREEN tests for empty output, cancellation, decoder errors, model errors, and preservation of the original audio bytes.
- [ ] Commit the passing vertical slice.

### Task 2: Checksum-pinned large-v3 runtime

**Files:**
- Create: `client/lib/services/whisper_local_runtime.dart`
- Test: `client/test/unit/services/whisper_local_runtime_test.dart`

**Interfaces:**
- `largeV3ModelSpec` contains filename, immutable HTTPS URL, byte count, and SHA-256.
- `WhisperLocalRuntime.isInstalled() -> Future<bool>` verifies the cached file.
- `WhisperLocalRuntime.install(...)` uses resumable `WhisperModelManager.download` with the pinned checksum.
- `WhisperLocalRuntime.transcribe(...)` reuses one loaded engine for sequential notes, reads WAV through `WhisperAudio.readWav`, performs balanced multilingual inference, returns text, and disposes the engine after a two-minute idle window.

- [ ] Write a failing metadata test asserting every exact model constant and HTTPS immutable revision.
- [ ] Implement the model specification and make the test pass.
- [ ] Write failing adapter tests using injected manager/engine facades to prove no download occurs when verified, progress is surfaced, checksum failures propagate, inference uses language `auto`, sequential requests reuse the engine, failed loads can retry, and idle disposal releases native memory.
- [ ] Implement and make all focused tests pass.
- [ ] Commit.

### Task 3: Android Opus-to-WAV preparation

**Files:**
- Create: `client/lib/services/android_audio_decoder.dart`
- Modify: `client/android/app/src/main/kotlin/dev/tangent/tangent/MainActivity.kt`
- Test: `client/test/unit/services/android_audio_decoder_test.dart`

**Interfaces:**
- Method channel: `dev.tangent.tangent/audio`.
- Method: `decodeOpusToWav`.
- Arguments: `{inputPath: String, outputPath: String}`.
- Result: `{sampleRate: int, channels: int, pcmBytes: int}`.

- [ ] Write a failing Dart method-channel contract test for exact method/arguments and returned output validation.
- [ ] Implement the Dart adapter and make the contract test pass.
- [ ] Add Kotlin streaming decode with `MediaExtractor` + `MediaCodec`: reserve a 44-byte RIFF header, stream PCM16 buffers to `RandomAccessFile`, patch the header after output format discovery, validate nonzero output, and release codec/extractor/file resources in `finally`.
- [ ] Reject unsupported PCM encodings and delete partial WAV output on failure.
- [ ] Build the Android APK to compile native code.
- [ ] Commit.

### Task 4: Local transcript persistence and UI

**Files:**
- Modify: `client/lib/main.dart`
- Modify: `client/lib/screens/home/home_providers.dart`
- Modify: `client/lib/screens/dump/dump_detail_screen.dart`
- Modify: `client/lib/screens/settings/settings_screen.dart`
- Create: `client/lib/services/recording_playback.dart`
- Test: `client/test/widget/dump_detail_screen_test.dart`
- Test: `client/test/widget/dump_detail_playback_test.dart`
- Test: `client/test/unit/services/recording_playback_test.dart`
- Test: `client/test/widget/settings_screen_test.dart`

**Interfaces:**
- `onDeviceTranscriptionProvider` supplies the production service and is overrideable in tests.
- `localModelStatusProvider` exposes missing/downloading/ready/error state.

- [ ] Write a failing widget test that taps Transcribe with an unreachable/failing HTTP client and proves the injected local service result is saved to SQLite and metadata.
- [ ] Replace `_transcribe()` upload/job/SSE logic with local service progress and local persistence; keep any previous transcript until replacement succeeds.
- [ ] Make the test pass.
- [ ] Add RED→GREEN tests for download progress copy, inference progress copy, cancellation, blank result, and error display.
- [ ] Add a Settings model card with exact model name/size/status, explicit download/re-download action, and progress.
- [ ] Add local in-app recording playback with play/pause, elapsed/total time, and a draggable seek bar backed by filesystem and Android SAF content URIs.
- [ ] Move active transcription ownership to a shared coordinator and keep a detailed progress/cancellation panel visible across Dump navigation.
- [ ] Mark the active clip in the Dumps list with a live spinner and current local-transcription stage.
- [ ] Commit.

### Task 5: Remove server transcription coupling

**Files:**
- Modify: `client/lib/main.dart`
- Modify: `client/lib/services/sync_engine.dart`
- Modify: `client/lib/screens/settings/settings_screen.dart`
- Modify: `client/test/unit/services/sync_engine_test.dart`
- Modify: `client/test/widget/home_screen_test.dart`

- [ ] Write a failing test proving sync uploads a locally transcribed dump without calling `enqueueTranscription`.
- [ ] Remove server transcription enqueueing from `SyncEngine`; sync status represents replication only.
- [ ] Make Home the post-storage startup destination even without a server URL.
- [ ] Relabel server configuration as optional sync and remove server connection as a startup requirement.
- [ ] Run focused tests and commit.

### Task 6: Full build and physical-device offline acceptance

**Files:**
- Update: `README.md`
- Update: `CHANGELOG.md`
- Create: `docs/on-device-transcription-verification.md`

- [ ] Run unfiltered `flutter test --reporter expanded` and record the exact count.
- [ ] Run `flutter analyze` and require zero issues.
- [ ] Build the APK with JDK 17 and calculate exact size and SHA-256.
- [ ] Back up public Tangent recordings, then install with `adb install -r`.
- [ ] Use Settings/Transcribe to download the 3,095,033,483-byte model; verify SHA-256 on-device.
- [ ] Decode an existing Opus recording to WAV on-device and verify nonzero PCM output.
- [ ] Disable Wi-Fi and mobile data with ADB after recording their prior states; clear PID-scoped logcat.
- [ ] Record a known spoken phrase, stop normally, and transcribe locally.
- [ ] Play, pause, and seek the saved recording in its Dump detail before transcribing.
- [ ] Verify the expected phrase appears in the detail UI and sidecar; verify no HTTP request and no Flutter/native error appears in PID-scoped logcat.
- [ ] Restore network state exactly as found.
- [ ] Run final full tests/analyze, `git diff --check`, commit, and push without creating a GitHub release.
