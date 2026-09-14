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
- Default v1 model: multilingual Whisper `large-v3-turbo` (greedy decoding, 8-thread CPU inference, engine cached in RAM for 15 minutes).
- Optional model: multilingual Whisper `large-v3` (kept available via the runtime API; the same checksum-pinned spec, file name `ggml-large-v3.bin`, and SHA-256 `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`).
- Default filename: `ggml-large-v3-turbo.bin`.
- Immutable source revision: `5359861c739e955e79d9a303bcbc70fb988958b1`.
- Default download size: `1,624,555,275` bytes.
- Default SHA-256: `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`.
- Optional `large-v3` download size: `3,095,033,483` bytes.
- Optional `large-v3` SHA-256: `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`.
- SHA-256: `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`.
- Model storage: app support storage. Recordings remain in the user-authorized public SAF folder; the model may be re-downloaded after uninstall.
- No smaller or remote fallback. Missing/corrupt models fail loudly and remain visibly actionable.

## Components

### `OnDeviceTranscriptionService`

A testable Dart boundary owns model discovery/download, audio preparation, whisper.cpp model loading, inference progress, cancellation, and native-resource cleanup. Platform/plugin calls live behind adapters so unit and widget tests do not load native libraries.

### `AndroidAudioDecoder`

Tangent recordings remain compact Opus. Before inference, Android `MediaExtractor` + `MediaCodec` decode the selected Opus recording to a temporary PCM WAV file. The decoder streams PCM to disk rather than retaining an entire long recording in Kotlin heap. `WhisperAudio.readWav` then mixes/resamples the WAV to mono 16 kHz Float32 PCM. Temporary input and WAV files are deleted in `finally` blocks.

This supports existing recovered `.opus` recordings and future recordings without converting durable storage to large WAV files.

### Playback, model state, and UI

Every Dump detail includes an in-app audio player backed by the recording's durable file or SAF content URI. It provides play/pause, elapsed and total time, and a draggable seek bar so the recording can be reviewed before deciding whether to transcribe it. Playback is local and stops when the detail screen is disposed.

Settings shows an **On-device transcription model** section with model name, installed/not-installed status, size, and a download action with byte progress. Pressing **Transcribe** also starts the checksum-verified download automatically when the model is absent, with explicit progress text. Once installed, transcription does not access the network.

The active action is owned by a shared coordinator rather than a screen instance. A persistent progress panel survives navigation and shows the exact preparing, downloading, model-loading, transcribing, cancelling, complete, or error state; determinate percentage where available; an animated indeterminate bar during native model initialization; elapsed time; model name and model size; first-load guidance; and a Cancel control. The Dumps list marks the active recording with a spinner and current local stage so the user can identify it without reopening every clip. Cancellation during native model loading is cooperative and remains visibly **Cancelling…** until the plugin returns. Corrupt model verification presents an explicit error and a re-download path.

Transcription requests use a coordinator-owned FIFO queue around the single native engine. Starting one recording never disables Transcribe on other rows. A repeated request for an active or queued dump returns the existing job rather than creating a duplicate. Active and queued rows/details expose distinct state, queued position, and a queued-item Cancel action. Removing a queued job does not interrupt the active job. Every terminal active outcome (success, failure, or cancellation) advances the queue, and each successful item independently commits SQLite plus its public sidecar before the next result is reported complete.

The loaded native engine is reused for sequential recordings to avoid paying the multi-minute initialization cost for every note. It is disposed after 15 minutes idle to balance queue/retry responsiveness against native memory use.

### Local persistence

On successful inference:

1. Trim and validate the local result.
2. Update the dump's `transcript` and `updatedAt` in local SQLite.
3. Rewrite the public metadata sidecar with the transcript.
4. Refresh the detail and searchable dump providers.

Local transcription does not mark a recording remotely synced. Sync status continues to describe optional server replication only.

### Meeting workflow

The Dumps screen keeps a process-lifetime filter selection directly below search: **All**, **Brain Dump**, **Meeting**, and **Awaiting**. Search results are intersected with the selected filter. **Awaiting** includes pending, syncing, and failed replication states but excludes synced and deliberately local-only meetings.

After Whisper returns a transcript for a `meeting` recording, a deterministic extractive processor creates local secretary notes before that queue job completes. It uses only transcript sentences and performs no network or model call. The output contains a subject/title, concise extractive summary, key discussion points, decisions, action items, open questions, and raw transcript. Missing evidence is rendered as **None stated**. Action-item owner and date are copied only when explicitly present; otherwise each is **Not stated**.

Schema version 3 adds nullable `meeting_notes` without replacing `transcript`. Migration from schema 2 preserves raw transcripts and marks existing meetings local-only. Fresh databases include both fields. Meeting detail renders secretary notes first and keeps the independent raw transcript behind an expander. Sidecars contain both values for durable recovery.

### Optional server sync

Server configuration moves out of the startup gate. Storage authorization remains required, but a server is optional and is labeled accordingly in Settings. `SyncEngine` may upload brain dumps when configured, but it must not enqueue server transcription. Meeting audio, transcripts, and secretary notes remain local-only and are never sent to the server.

## Error handling

- Missing network during first model download: preserve partial download for resume and show a clear one-time-download error.
- Checksum mismatch: do not install the model; show corruption and permit removal/re-download.
- Unsupported or corrupt audio: preserve the original Opus and report audio preparation failure.
- Native model-load or inference failure: preserve audio and any previous transcript; report the exact local error.
- Empty transcription: do not overwrite a previous transcript with blank text.
- Cancellation: stop the native task, clean temporary files, preserve the dump and prior transcript.
- App navigation/disposal: keep shared transcription work visible and persist its result independently of any screen; stop screen-owned audio playback. Release an idle loaded model after the reuse window.

## Verification requirements

1. Unit tests prove model selection, checksum-pinned download state, engine reuse, persistence, cancellation, error preservation, playback/seek behavior, and that no HTTP transcription client is invoked.
2. A native/device test proves an existing Opus recording is converted into a readable WAV.
3. Full Flutter tests and analysis pass.
4. Build and install in place with the same `dev.tangent.tangent` application ID.
5. Download and verify the exact large-v3 model on the connected `arm64-v8a` phone.
6. Disable Wi-Fi/mobile data or otherwise make the server unreachable.
7. Play, pause, and seek the newly recorded phrase directly in its Dump detail.
8. Transcribe that phrase and verify the expected words appear in the UI, SQLite-backed detail view, and public metadata sidecar.
9. Confirm PID-scoped logcat has no Flutter/native errors and no HTTP transcription request occurred.
