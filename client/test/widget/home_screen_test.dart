// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/transcription_client.dart';
import 'package:drift/native.dart';

class _StubClient extends TranscriptionClient {
  _StubClient() : super(baseUrl: 'http://test');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Home screen renders title and record button', (tester) async {
    final db = LocalDb.forTesting(NativeDatabase.memory());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          transcriptionClientProvider.overrideWithValue(_StubClient()),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.text('Tangent'), findsOneWidget);
    expect(find.text('Tap to record'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });

  testWidgets('Home screen has sync, dumps, and settings buttons',
      (tester) async {
    final db = LocalDb.forTesting(NativeDatabase.memory());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          transcriptionClientProvider.overrideWithValue(_StubClient()),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    expect(find.byIcon(Icons.cloud_sync), findsOneWidget);
    expect(find.byIcon(Icons.list), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });
}