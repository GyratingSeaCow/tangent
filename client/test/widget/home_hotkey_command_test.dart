// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/services/instance_commands.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';

import '../support/widget_recording_coordinator.dart';

class _NoopScreenAwake implements ScreenAwake {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

/// The desktop global hotkey lands as a 'toggle-record' command on the
/// single-instance socket. The home screen must treat it exactly like a
/// record-button tap: start when idle, stop when recording.
void main() {
  testWidgets('toggle-record command starts and stops a capture',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final commands = StreamController<String>.broadcast();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          recordingCoordinatorProvider.overrideWith(
            (ref) =>
                WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),
          ),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
          instanceCommandsProvider.overrideWithValue(commands.stream),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await db.close();
      await commands.close();
    });

    // Idle: mic showing.
    expect(find.byIcon(Icons.mic), findsOneWidget);

    commands.add('toggle-record');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byIcon(Icons.stop),
      findsOneWidget,
      reason: 'hotkey while idle must start a capture',
    );

    commands.add('toggle-record');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byIcon(Icons.stop),
      findsNothing,
      reason: 'hotkey while recording must stop it',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown commands are ignored', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final commands = StreamController<String>.broadcast();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          recordingCoordinatorProvider.overrideWith(
            (ref) =>
                WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),
          ),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
          instanceCommandsProvider.overrideWithValue(commands.stream),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await db.close();
      await commands.close();
    });

    commands.add('bogus-command');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
