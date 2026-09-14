# Tangent On-Device Transcription Design

**Status:** Approved by Jeff on 2026-09-13

## Goal

Tangent transcribes recordings entirely on the Android phone after a one-time model download. Recording, transcription, search, and transcript persistence must work without the FastAPI server and without network connectivity.

## Non-goals

- Live partial transcription while recording.
- Cloud transcription fallback.
- Automatic substitution of a smaller model.
- Requiring a server connection before entering the app.

## Model and runtime

- Runtime: `whisper_cpp_flutter_plus` 0.4.1, which embeds whisper.cpp 1.9.2 and supports Android arm64 CPU inference.
- Default and only v1 model: multilingual Whisper `large-v3`.
- Filename: `ggml-large-v3.bin`.
- Immutable source revision: `5359861c739e955e79d9a303bcbc70fb988958b1`.
- Download size: `3,095,033,483` bytes.
- SHA-256: `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`.
- Model storage: app support storage. Recordings remain in the user-authorized public SAF folder; the model may be re-downloaded after uninstall.
- No smaller or remote fallback. Missing/corrupt models fail loudly and remain visibly actionable.

## Components

### `OnDeviceTranscriptionService`

A testable Dart boundary owns model discovery/download, audio preparation, whisper.cpp model loading, inference progress, cancellation, and native-resource cleanup. Platform/plugin calls live behind adapters so unit and widget tests do not load native libraries.

### `AndroidAudioDecoder`

Tangent recordings remain compact Opus. Before inference, Android `MediaExtractor` + `MediaCodec` decode the selected Opus recording to a temporary PCM WAV file. The decoder streams PCM to disk rather than retaining an entire long recording in Kotlin heap. `WhisperAudio.readWav` then mixes/resamples the WAV to mono 16 kHz Float32 PCM. Temporary input and WAV files are deleted in `finally` blocks.

This supports existing recovered `.opus` recordings and future recordings without converting durable storage to large WAV files.

### Model state and UI

Settings shows an **On-device transcription model** section with model name, installed/not-installed status, size, and a download action with byte progress. Pressing **Transcribe** also starts the checksum-verified download automatically when the model is absent, with explicit progress text. Once installed, transcription does not access the network.

The active action shows separate preparing, model loading, and inference progress. The user can cancel a download or inference. Corrupt model verification presents an explicit error and a re-download path.

### Local persistence

On successful inference:

1. Trim and validate the local result.
2. Update the dump's `transcript` and `updatedAt` in local SQLite.
3. Rewrite the public metadata sidecar with the transcript.
4. Refresh the detail and searchable dump providers.

Local transcription does not mark a recording remotely synced. Sync status continues to describe optional server replication only.

### Optional server sync

Server configuration moves out of the startup gate. Storage authorization remains required, but a server is optional and is labeled accordingly in Settings. `SyncEngine` may upload local records when configured, but it must not enqueue server transcription. The server can remain available for backup/replication without controlling the local transcript workflow.

## Error handling

- Missing network during first model download: preserve partial download for resume and show a clear one-time-download error.
- Checksum mismatch: do not install the model; show corruption and permit removal/re-download.
- Unsupported or corrupt audio: preserve the original Opus and report audio preparation failure.
- Native model-load or inference failure: preserve audio and any previous transcript; report the exact local error.
- Empty transcription: do not overwrite a previous transcript with blank text.
- Cancellation: stop the native task, clean temporary files, preserve the dump and prior transcript.
- App navigation/disposal: cancel screen-owned work and release the loaded engine after the job.

## Verification requirements

1. Unit tests prove model selection, checksum-pinned download state, persistence, cancellation, error preservation, and that no HTTP transcription client is invoked.
2. A native/device test proves an existing Opus recording is converted into a readable WAV.
3. Full Flutter tests and analysis pass.
4. Build and install in place with the same `dev.tangent.tangent` application ID.
5. Download and verify the exact large-v3 model on the connected `arm64-v8a` phone.
6. Disable Wi-Fi/mobile data or otherwise make the server unreachable.
7. Transcribe a newly recorded spoken phrase and verify the expected words appear in the UI, SQLite-backed detail view, and public metadata sidecar.
8. Confirm PID-scoped logcat has no Flutter/native errors and no HTTP transcription request occurred.
