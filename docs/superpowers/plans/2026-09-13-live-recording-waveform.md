# Live Recording Waveform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real, scrolling microphone-amplitude waveform to Tangent’s active recording screen without reducing recording reliability.

**Architecture:** Adapt the existing `record` 6.2.1 recorder amplitude stream through `RecordingService`, normalize it into a bounded 72-sample Riverpod state history, and draw that state with an isolated `CustomPainter`. The amplitude subscription follows the recording lifecycle but failures remain isolated from audio recording.

**Tech Stack:** Flutter 3.27+, Dart 3.6+, Riverpod 2.5.1, record 6.2.1, flutter_test.

## Global Constraints

- The waveform represents real microphone amplitude; never substitute decorative animation.
- Production sampling interval is exactly 60 milliseconds.
- Retain exactly 72 normalized samples, oldest on the left and newest on the right.
- Clamp source amplitude to -60 dBFS through 0 dBFS and normalize to 0 through 1.
- Hide and clear waveform state outside an active recording.
- Amplitude errors must never stop or corrupt recording.
- Use the current recording accent color and keep timer, stop control, selector, and copy visible at target phone dimensions.
- Reduced-motion mode consumes updates at approximately 250 milliseconds.
- Do not add a second microphone session or persist/upload waveform samples.
- Finish only after the full Flutter tests, analyze, APK build, in-place `adb install -r`, and real-phone recording verification pass.

---

### Task 1: Expose recorder amplitude safely

**Files:**
- Modify: `client/lib/services/recording_service.dart`
- Test: `client/test/unit/services/recording_service_test.dart`

**Interfaces:**
- Produces: `Stream<double> amplitudeStream(Duration interval)` on `RecordingService`, returning current dBFS values.
- Consumes: `AudioRecorder.onAmplitudeChanged(Duration)` from record 6.2.1.

- [ ] **Step 1: Write a failing service test**

Add a controllable amplitude controller to `StubRecordingService` and test the public interface:

```dart
test('stub exposes emitted dBFS amplitude', () async {
  final service = StubRecordingService();
  final values = <double>[];
  final subscription = service
      .amplitudeStream(const Duration(milliseconds: 60))
      .listen(values.add);
  service.emitAmplitude(-18.0);
  await Future<void>.delayed(Duration.zero);
  expect(values, [-18.0]);
  await subscription.cancel();
  await service.dispose();
});
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
~/AppData/Local/flutter/bin/flutter.bat test test/unit/services/recording_service_test.dart --reporter expanded
```

Expected: compile failure because `amplitudeStream` and `emitAmplitude` do not exist.

- [ ] **Step 3: Implement the minimal adapter**

Add to the interface and implementations:

```dart
abstract class RecordingService {
  Stream<double> amplitudeStream(Duration interval);
}
```

```dart
@override
Stream<double> amplitudeStream(Duration interval) =>
    _ensureRecorder.onAmplitudeChanged(interval).map((value) => value.current);
```

The stub uses a broadcast `StreamController<double>`, closes it in `dispose`, and exposes `emitAmplitude(double dbfs)` for tests.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the focused command from Step 2. Expected: PASS with no uncaught async errors.

### Task 2: Normalize and retain scrolling samples

**Files:**
- Create: `client/lib/screens/recording/waveform_state.dart`
- Create: `client/test/unit/screens/recording/waveform_state_test.dart`

**Interfaces:**
- Produces: `double normalizeDbfs(double dbfs)`.
- Produces: `WaveformNotifier`, whose state is an immutable `List<double>` of exactly 72 values.
- Produces: `waveformProvider` as `StateNotifierProvider<WaveformNotifier, List<double>>`.

- [ ] **Step 1: Write failing normalization and scrolling tests**

```dart
test('normalization clamps dBFS to zero through one', () {
  expect(normalizeDbfs(-80), 0);
  expect(normalizeDbfs(-60), 0);
  expect(normalizeDbfs(-30), closeTo(0.5, 0.0001));
  expect(normalizeDbfs(0), 1);
  expect(normalizeDbfs(6), 1);
});

test('new samples enter on right and history remains 72 values', () {
  final notifier = WaveformNotifier();
  for (var index = 0; index < 80; index++) {
    notifier.addNormalized(index / 80);
  }
  expect(notifier.state, hasLength(72));
  expect(notifier.state.last, closeTo(79 / 80, 0.0001));
  expect(notifier.state.first, closeTo(8 / 80, 0.0001));
});
```

- [ ] **Step 2: Run focused test and verify RED**

```bash
~/AppData/Local/flutter/bin/flutter.bat test test/unit/screens/recording/waveform_state_test.dart --reporter expanded
```

Expected: compile failure because `waveform_state.dart` does not exist.

- [ ] **Step 3: Implement normalization, fixed history, smoothing, and clear**

Implement a 72-zero initial state, `(dbfs.clamp(-60.0, 0.0) + 60.0) / 60.0`, light exponential smoothing before append, immutable state replacement, and `clear()` restoring 72 zeros. Keep raw-normalized insertion testable separately from dBFS insertion so direction and clamping remain unambiguous.

- [ ] **Step 4: Run focused test and verify GREEN**

Run the Step 2 command. Expected: all waveform-state tests PASS.

### Task 3: Bind waveform subscription to recording lifecycle

**Files:**
- Modify: `client/lib/screens/recording/recording_controller.dart`
- Modify: `client/test/widget/recording_controller_test.dart`

**Interfaces:**
- Consumes: `RecordingService.amplitudeStream(Duration)`.
- Consumes: `waveformProvider.notifier.addDbfs(double)` and `.clear()`.
- Produces: no new public recording commands; existing `start()`, `stop()`, and `dispose()` remain the lifecycle API.

- [ ] **Step 1: Write failing lifecycle tests**

Test that successful `start()` subscribes; emitted dBFS updates waveform state; `stop()` clears state; start failure never subscribes; amplitude errors leave `RecordingState.recording`; stop failure and disposal cancel and clear.

```dart
test('amplitude updates and stop clears waveform', () async {
  await controller.start();
  service.emitAmplitude(-12);
  await Future<void>.delayed(Duration.zero);
  expect(container.read(waveformProvider).last, greaterThan(0));
  await controller.stop();
  expect(container.read(waveformProvider), everyElement(0));
});
```

- [ ] **Step 2: Run focused test and verify RED**

```bash
~/AppData/Local/flutter/bin/flutter.bat test test/widget/recording_controller_test.dart --reporter expanded
```

Expected: waveform lifecycle assertions fail because no subscription exists.

- [ ] **Step 3: Implement lifecycle ownership**

After `_service.start()` succeeds, subscribe with exactly `const Duration(milliseconds: 60)`. On data, append dBFS. On stream error, cancel waveform monitoring and clear only the visual state; do not invoke recorder stop. In `stop()`, use `try/finally` so subscription, keep-screen-awake flag, timer, elapsed state, and waveform state are released even when recorder stop throws. In `dispose()`, cancel before disposing service.

- [ ] **Step 4: Run focused test and verify GREEN**

Run Step 2. Expected: all recording-controller tests PASS, including existing screen-awake error cleanup.

### Task 4: Render the waveform without full-screen repaint

**Files:**
- Create: `client/lib/screens/recording/recording_waveform.dart`
- Create: `client/test/widget/recording_waveform_test.dart`
- Modify: `client/lib/screens/home/home_screen.dart`

**Interfaces:**
- Produces: `RecordingWaveform({required List<double> samples, required Color color})`.
- Consumes: `waveformProvider` only in a focused consumer subtree wrapped by `RepaintBoundary`.

- [ ] **Step 1: Write failing widget tests**

Test that silence produces a center line, nonzero samples produce peaks, semantics says `Live microphone waveform`, the waveform appears only during recording, and the target layout does not overflow.

```dart
testWidgets('waveform exposes semantics without overflow', (tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: RecordingWaveform(
        samples: List<double>.filled(72, 0)..[71] = 1,
        color: Colors.pink,
      ),
    ),
  ));
  expect(find.bySemanticsLabel('Live microphone waveform'), findsOneWidget);
  expect(tester.takeException(), isNull);
});
```

Use a test surface matching the connected phone’s logical dimensions and verify no overflow exception.

- [ ] **Step 2: Run focused widget tests and verify RED**

```bash
~/AppData/Local/flutter/bin/flutter.bat test test/widget/recording_waveform_test.dart --reporter expanded
```

Expected: compile failure because `RecordingWaveform` does not exist.

- [ ] **Step 3: Implement painter and home integration**

Draw a low-opacity center line and a symmetric path from left-to-right samples. Use anti-aliased stroke with rounded caps, fixed height, horizontal constraints, `Semantics`, and `RepaintBoundary`. Insert between timer and stop control. Render only for active recording. Respect `MediaQuery.disableAnimationsOf(context)` by throttling UI consumption to approximately 250 ms without replacing real samples with fake motion.

- [ ] **Step 4: Run focused widget tests and verify GREEN**

Run Step 2. Expected: all waveform widget tests PASS with no overflow.

### Task 5: Full regression, build, in-place install, and device proof

**Files:**
- Modify only if a failing regression proves a necessary focused fix.
- Update: `docs/recording-device-evidence.md` with exact verified outcomes.

**Interfaces:**
- Consumes the completed waveform plus recording-save, orphan-import, settings persistence, keep-screen-awake, connection, and sync behavior already under repair.

- [ ] **Step 1: Run the full unfiltered test suite**

```bash
~/AppData/Local/flutter/bin/flutter.bat test --reporter expanded
```

Expected: exit 0; record the exact test count from unfiltered output.

- [ ] **Step 2: Run static analysis**

```bash
~/AppData/Local/flutter/bin/flutter.bat analyze
```

Expected: exit 0 with `No issues found!`.

- [ ] **Step 3: Build the APK**

Set `JAVA_HOME=C:/Program Files/Microsoft/jdk-17.0.20.8-hotspot` and `ANDROID_HOME=~/AppData/Local/Android/Sdk`, then run:

```bash
~/AppData/Local/flutter/bin/flutter.bat build apk --debug
```

Expected: exit 0 and a nonempty `client/build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 4: Install over the existing package**

Back up `Documents/Tangent` first, then run:

```bash
~/AppData/Local/Android/Sdk/platform-tools/adb.exe install -r ~/Documents/ADH2/client/build/app/outputs/flutter-apk/app-debug.apk
```

Expected: `Success`. Do not uninstall or clear app data. Verify exactly `package:dev.tangent.tangent` exists for user 0 and that stored connection state remains available.

- [ ] **Step 5: Verify on the connected phone**

Launch Tangent. Verify existing recordings are listed/recoverable. Record silence, normal speech, and louder speech while capturing screenshots: timer advances; waveform scrolls and changes height with actual input; configured screen-awake behavior applies; stop succeeds without Flutter exception; a new nonempty Opus file exists; `ffprobe` and full `ffmpeg -xerror` decode pass; the dump exists in Drift-backed UI with a valid generated title and metadata; the stop control remains on-screen. Capture PID-scoped logcat and require no new unhandled Flutter exception.

- [ ] **Step 6: Commit and push, but do not create a GitHub release**

Stage only Tangent source/tests/docs. Commit with a focused message, push `main` to the configured GitHub remote, and verify local HEAD equals remote `main`. Do not tag or publish a release.
