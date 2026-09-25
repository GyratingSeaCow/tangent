// SPDX-License-Identifier: AGPL-3.0-or-later
/// Requirement 8: the Transcription status line is a STATUS line again.
///
/// It used to read `Connected · default model: large-v3 · available: tiny,
/// base, small, medium, large-v3 · N dumps` — an "available" list that
/// looked like a menu and selected nothing. The model list now lives in
/// [WhisperModelSection] as real radios, so the status line shrinks to
/// `Connected · N dumps` and the busy / unreachable / not-configured
/// branches stay exactly as they were.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/secure_storage.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/models/server_info.dart';
import 'package:tangent/screens/server/server_connection_screen.dart';
import 'package:tangent/screens/settings/settings_screen.dart';
import 'package:tangent/screens/settings/whisper_model_section.dart';
import 'package:tangent/services/transcription_client.dart';
import 'package:tangent/services/whisper_model_client.dart';

const ServerInfo _info = ServerInfo(
  version: 'fixture',
  setupComplete: true,
  defaultModel: 'large-v3',
  availableModels: <String>['tiny', 'base', 'small', 'medium', 'large-v3'],
  storageUsedBytes: 0,
  dumpCount: 7,
);

class _StubClient extends Fake implements TranscriptionClient {
  _StubClient({this.info, this.error});

  final ServerInfo? info;
  final Object? error;
  final Completer<ServerInfo> gate = Completer<ServerInfo>();

  @override
  Future<ServerInfo> getServerInfo() async {
    final Object? err = error;
    if (err != null) throw err;
    final ServerInfo? value = info;
    if (value == null) return gate.future;
    return value;
  }
}

class _Store extends Fake implements SecureStore {
  _Store({this.url = 'http://synthetic.invalid:8000'});

  final String? url;

  @override
  Future<String?> getServerUrl() async => url;

  @override
  Future<String?> getToken() async => 'synthetic-fixture-only';
}

Future<void> _mount(
  WidgetTester tester, {
  required _StubClient client,
  String? url = 'http://synthetic.invalid:8000',
}) async {
  // The Settings ListView is far taller than the default 800x600 surface,
  // and finders skip offstage children — give it room to show the whole
  // screen (the storage_settings_test precedent).
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    if (!client.gate.isCompleted) client.gate.complete(_info);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsStoreProvider.overrideWithValue(SettingsStore()),
        secureStoreProvider.overrideWithValue(_Store(url: url)),
        transcriptionClientProvider.overrideWith((_) => client),
        // No live server in a widget test: the section takes its offline
        // path deterministically instead of dialling synthetic.invalid.
        whisperModelClientProvider.overrideWith(
          (ref) => Future<WhisperModelClient>.error(
            StateError('no server in tests'),
          ),
        ),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets(
      'a connected server shows "Connected · N dumps" and no model list',
      (tester) async {
    await _mount(tester, client: _StubClient(info: _info));
    await tester.pumpAndSettle();

    expect(find.text('Connected · 7 dumps'), findsOneWidget);
    // The dead menu is gone: neither the default-model note nor the
    // "available:" list may appear in the status line any more.
    expect(find.textContaining('default model'), findsNothing);
    expect(find.textContaining('available:'), findsNothing);
    expect(
      find.textContaining('tiny, base, small, medium, large-v3'),
      findsNothing,
    );
  });

  testWidgets('the real picker replaces it under the Transcription header',
      (tester) async {
    await _mount(tester, client: _StubClient(info: _info));
    await tester.pumpAndSettle();

    expect(find.byType(WhisperModelSection), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('whisper-model-row-large-v3')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('whisper-model-row-tiny')),
      findsOneWidget,
    );
  });

  testWidgets('a setup-incomplete server still warns, after the dump count',
      (tester) async {
    await _mount(
      tester,
      client: _StubClient(
        info: const ServerInfo(
          version: 'fixture',
          setupComplete: false,
          defaultModel: 'large-v3',
          availableModels: <String>['large-v3'],
          storageUsedBytes: 0,
          dumpCount: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('SETUP INCOMPLETE'), findsOneWidget);
    expect(find.textContaining('Connected · 0 dumps'), findsOneWidget);
  });

  testWidgets('the busy, unreachable and not-configured branches are unchanged',
      (tester) async {
    // Busy: the info call has not answered yet.
    final _StubClient held = _StubClient();
    await _mount(tester, client: held);
    expect(find.text('Loading server information…'), findsOneWidget);
    held.gate.complete(_info);
    await tester.pumpAndSettle();
    expect(find.text('Connected · 7 dumps'), findsOneWidget);
  });

  testWidgets('an unreachable server still says so', (tester) async {
    await _mount(
      tester,
      client: _StubClient(error: Exception('connection refused')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Server unreachable:'), findsOneWidget);
  });

  testWidgets('no server configured keeps its setup prompt', (tester) async {
    await _mount(tester, client: _StubClient(info: _info), url: '');
    await tester.pumpAndSettle();

    expect(
      find.text('Not configured — tap Server above to set up'),
      findsOneWidget,
    );
  });
}
