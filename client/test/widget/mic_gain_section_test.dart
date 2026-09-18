// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The microphone gain slider in Settings.
//
// package:record exposes no numeric gain -- only a boolean AGC that its own
// docs say may LOWER recording volume -- so this slider multiplies the raw PCM
// samples instead. That has a visible consequence the UI must not hide:
// amplified capture is WAV rather than Opus, roughly 8x the file size. The
// screen states it rather than surprising the user later.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/settings/mic_gain_section.dart';
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/services/audio_gain.dart';
import 'package:tangent/services/recording_service.dart';

class FakeGainService with NoInputDeviceSelection implements RecordingService {
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> pump(WidgetTester tester, SettingsStore settings) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        recordingServiceProvider.overrideWithValue(FakeGainService()),
        settingsStoreProvider.overrideWithValue(settings),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: MicGainSection())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('the gain slider', () {
    testWidgets('shows unity by default', (tester) async {
      await pump(tester, await SettingsStore.load());

      expect(find.text('Microphone gain'), findsOneWidget);
      expect(find.text('1.0x (normal)'), findsOneWidget);
    });

    testWidgets('restores a stored gain', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'microphone_gain': 2.5,
      });

      await pump(tester, await SettingsStore.load());

      expect(find.text('2.5x'), findsOneWidget);
    });

    testWidgets('moving it persists the new gain', (tester) async {
      final SettingsStore settings = await SettingsStore.load();
      await pump(tester, settings);

      await tester.drag(find.byType(Slider), const Offset(200, 0));
      await tester.pumpAndSettle();

      expect(
        settings.micGain,
        greaterThan(defaultMicGain),
        reason: 'the choice must reach the store, not just the widget',
      );
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('microphone_gain'), greaterThan(defaultMicGain));
    });
  });

  group('the storage cost is disclosed', () {
    testWidgets('unity says recordings stay compressed', (tester) async {
      await pump(tester, await SettingsStore.load());

      expect(
        find.textContaining('Opus'),
        findsOneWidget,
        reason: 'the user should know the default format is unchanged',
      );
    });

    testWidgets('above unity warns about the larger WAV files', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'microphone_gain': 3.0,
      });

      await pump(tester, await SettingsStore.load());

      // Not buried in a tooltip: ~8x storage is a consequence the user is
      // entitled to see at the moment they choose it.
      expect(find.textContaining('WAV'), findsOneWidget);
      expect(find.textContaining('larger'), findsOneWidget);
    });
  });

  group('honesty about what gain is', () {
    testWidgets('does not claim to change the microphone itself',
        (tester) async {
      await pump(tester, await SettingsStore.load());

      // The slider amplifies captured samples; it does not raise a hardware
      // input level. Wording that implied otherwise would be a lie.
      expect(find.textContaining('Amplifies'), findsOneWidget);
    });

    testWidgets('warns that too much gain clips', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'microphone_gain': 6.0,
      });

      await pump(tester, await SettingsStore.load());

      expect(
        find.textContaining('clip'),
        findsOneWidget,
        reason: 'high gain distorts loud audio and hurts transcription',
      );
    });

    testWidgets('no clipping warning at modest gain', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'microphone_gain': 2.0,
      });

      await pump(tester, await SettingsStore.load());

      expect(find.textContaining('clip'), findsNothing);
    });
  });
}
