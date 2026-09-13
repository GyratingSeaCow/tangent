# Live recording waveform design

## Status

Approved by Jeff on 2026-09-13.

## Purpose

Show immediate, trustworthy visual feedback that Tangent is receiving microphone audio while a recording is active. The waveform must represent real recorder amplitude rather than a decorative animation, and it must not compromise recording reliability.

## User experience

- While recording, show a horizontally scrolling waveform between the elapsed-time display and the stop button.
- New samples enter from the right and older samples move left.
- Louder input creates taller peaks; silence settles near the center line.
- Use the existing recording accent color so the waveform reads as part of the active recording state.
- Hide and clear the waveform outside an active recording.
- The stop button, timer, recording mode, and explanatory copy remain usable without scrolling on the current phone layout.
- When the platform requests reduced motion, sample and repaint at a lower rate while still showing real amplitude changes.

## Architecture

### Recorder amplitude source

Extend `RecordingService` with a real-amplitude stream. `DefaultRecordingService` adapts `AudioRecorder.onAmplitudeChanged(...)` from the existing `record` 6.2.1 dependency. This reuses the active microphone recorder and does not open a second microphone session or retain raw PCM samples.

The production sampling interval is 60 milliseconds. In reduced-motion mode the UI consumes samples at approximately 250 milliseconds. The service exposes current dBFS values; normalization is handled outside the recorder adapter.

The test recording service provides a controllable amplitude stream so behavior can be tested without platform channels.

### Waveform state

A focused Riverpod notifier owns a fixed-size history of 72 normalized samples. Each dBFS sample is:

1. clamped to the range -60 dBFS through 0 dBFS;
2. converted to the range 0 through 1;
3. passed through light exponential smoothing to avoid single-sample spikes;
4. appended to the right while the oldest sample is discarded.

The recording controller starts the subscription only after recording starts successfully. It cancels the subscription and clears waveform state on stop, start failure, recording error, and disposal.

### Rendering

A dedicated `RecordingWaveform` widget uses `CustomPainter` inside a `RepaintBoundary`. The painter draws a quiet center line plus a symmetric accent-colored waveform from the fixed sample history. The widget has explicit semantics: `Live microphone waveform` while recording. It has no touch behavior and cannot obscure the stop control.

Only the waveform repaint boundary updates for amplitude samples; the entire home screen must not rebuild at waveform frequency. The existing elapsed timer continues updating once per second.

## Data flow

```text
Active AudioRecorder
  -> onAmplitudeChanged(60 ms)
  -> RecordingService amplitude stream (dBFS)
  -> waveform notifier (clamp, normalize, smooth, retain 72)
  -> RecordingWaveform CustomPainter
```

No waveform samples are saved, uploaded, added to recording metadata, or used for transcription. The audio recording remains the source of truth.

## Failure handling

- If amplitude monitoring is unsupported or emits zeros, recording continues and the waveform displays a quiet center line.
- An amplitude-stream error stops only waveform monitoring; it must not stop or corrupt the recording.
- Starting, stopping, or disposing repeatedly must not leak stream subscriptions or timers.
- Waveform state is reset before the next recording so prior audio is never displayed as current input.

## Verification

Automated tests must prove:

1. dBFS normalization clamps silence and loud input correctly.
2. Sample history remains fixed at 72 values and scrolls in the correct direction.
3. Starting recording subscribes to amplitude only after recorder startup succeeds.
4. Stop, error, and disposal cancel the subscription and clear waveform state.
5. A waveform-stream error does not stop the recording.
6. The widget renders a center line for silence and nonzero peaks for emitted amplitudes.
7. The waveform appears only during recording and does not move the stop button off-screen on the target phone dimensions.
8. Existing recording, persistence, timer, keep-awake, settings, and sync tests remain green.

Device verification must include a real recording with silence, normal speech, and louder speech; the waveform must visibly react to each, the timer must advance, the screen-awake setting must work, and stopping must produce a decodable local Opus file plus a visible database-backed dump entry.

## Non-goals

- Editing audio from the waveform.
- Seeking or playback waveform generation.
- Persisting waveform previews.
- Spectrogram or frequency visualization.
- A fake idle animation when no microphone signal is available.
