// SPDX-License-Identifier: AGPL-3.0-or-later
//
// While the app is working, it must say so.
//
// Reported from the device: stopping a recording left the screen looking idle
// while finalisation ran — no timer, no spinner, nothing — so there was no way
// to tell a slow save from a dead button. That ambiguity is exactly what made
// the amplified-capture bug read as "the button does nothing".
//
// RecordingState already carried `starting` and `saving`; the home screen only
// ever branched on `recording` and `idle`, so those two states rendered as an
// idle screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/theme/tangent_tokens.dart';

/// Drives the home screen with one pinned RecordingState.
///
/// RecordingController takes seven collaborators it never uses while merely
/// *displaying* a state, so this overrides the state machine rather than
/// standing up a recorder, coordinator, waveform and screen-awake lock.
class _FixedRecordingController extends StateNotifier<RecordingState>
    implements RecordingController {
  _FixedRecordingController(super.fixed);

  @override
  bool get isRecording => state == RecordingState.recording;

  /// The recording branch reads the timer; a fixed state has no clock.
  @override
  int get elapsedSeconds => 0;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> pumpHomeIn(WidgetTester tester, RecordingState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        recordingControllerProvider.overrideWith(
          (ref) => _FixedRecordingController(state),
        ),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  group('the home screen shows that work is in progress', () {
    testWidgets('finalising a recording shows a spinner', (tester) async {
      await pumpHomeIn(tester, RecordingState.saving);

      expect(
        find.byKey(HomeScreen.busyIndicatorKey),
        findsOneWidget,
        reason: 'a save with no indicator is indistinguishable from a no-op',
      );
    });

    testWidgets('starting a recording shows a spinner', (tester) async {
      await pumpHomeIn(tester, RecordingState.starting);

      expect(find.byKey(HomeScreen.busyIndicatorKey), findsOneWidget);
    });

    testWidgets('an idle screen has no spinner', (tester) async {
      await pumpHomeIn(tester, RecordingState.idle);

      expect(find.byKey(HomeScreen.busyIndicatorKey), findsNothing);
    });

    testWidgets('a running recording has no spinner', (tester) async {
      // The waveform and the ticking timer already show liveness; a spinner on
      // top of them would imply the app was busy with something else.
      await pumpHomeIn(tester, RecordingState.recording);

      expect(find.byKey(HomeScreen.busyIndicatorKey), findsNothing);
    });

    testWidgets('the spinner is grey, not the record or signal colour',
        (tester) async {
      await pumpHomeIn(tester, RecordingState.saving);

      final CircularProgressIndicator spinner =
          tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: find.byKey(HomeScreen.busyIndicatorKey),
          matching: find.byType(CircularProgressIndicator),
        ),
      );

      // Red means capture and lime means live. A save is neither, so the
      // spinner stays on the dim metadata tone.
      expect(spinner.color, TangentColors.textDim);
      expect(spinner.color, isNot(TangentColors.record));
      expect(spinner.color, isNot(TangentColors.signal));
    });

    testWidgets('the record button is not tappable mid-save', (tester) async {
      // Tapping through a finalising save is what produced orphaned staging
      // files: a second capture started before the first had committed.
      await pumpHomeIn(tester, RecordingState.saving);

      final GestureDetector button = tester.widget<GestureDetector>(
        find.byKey(HomeScreen.recordButtonKey),
      );
      expect(button.onTap, isNull);
    });
  });
}
