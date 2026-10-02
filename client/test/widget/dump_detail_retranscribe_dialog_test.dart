// SPDX-License-Identifier: AGPL-3.0-or-later
/// v1.19.0 (T1=b): the 'Overwrite transcript?' dialog behind Transcribe
/// again offers "keep the original language" / "translate to English" ONLY
/// for a recording Whisper detected as non-English, defaulting to the
/// stored transcript's current state; the confirm threads the pick to
/// `transcribeDump(translate:)`. English / unknown rows see the dialog they
/// always did, and confirm with translate: false.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/settings/ai_summaries_section.dart';
import 'package:tangent/services/recording_playback.dart';
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/transcription_client.dart';

import '../support/bound_row_fixture.dart';
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/legacy_audio_storage_fixture.dart';
import '../support/resolved_temp.dart';

final class _StubEngine implements RecordingPlaybackEngine {
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<bool> get completedStream => const Stream.empty();
  @override
  Future<Duration?> load(AudioLocator source) async =>
      const Duration(seconds: 4);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> dispose() async {}
}

/// Records every transcribeDump call (id, translate) and holds it open, so
/// the test asserts what was ASKED rather than driving a fake server.
class _RecordingTranscriptionService extends ServerTranscriptionService {
  _RecordingTranscriptionService({
    required super.db,
    required super.recordingAccess,
    required super.mutations,
  }) : super(client: TranscriptionClient(baseUrl: 'http://test'));

  final Completer<void> gate = Completer<void>();
  final List<(String, bool)> requested = <(String, bool)>[];

  @override
  Future<void> transcribeDump(String dumpId, {bool translate = false}) {
    requested.add((dumpId, translate));
    return gate.future;
  }
}

const String _dialogCopy =
    'The current transcript stays visible while replacement transcription '
    'runs. It is replaced only if the new transcription succeeds.';

void main() {
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  DumpRow completedRow(
    AudioStorage storage,
    String id, {
    String? language,
    bool? translated,
  }) =>
      DumpRow(
        id: id,
        createdAt: DateTime.utc(2026, 9, 26),
        updatedAt: DateTime.utc(2026, 9, 26),
        mode: 'brain_dump',
        durationSeconds: 4,
        title: 'Ideas',
        audioPath: storage.pathFor(id).path,
        audioSizeBytes: 3,
        syncStatus: 'synced',
        syncAttempts: 0,
        transcriptionStatus: 'completed',
        transcriptionAttempt: 1,
        transcript: 'hola a todos',
        language: language,
        translated: translated,
      );

  Future<_RecordingTranscriptionService> mountDetail(
    WidgetTester tester,
    String id, {
    String? language,
    bool? translated,
  }) async {
    useTallViewport(tester);
    final temp = createResolvedTempSync('tangent-retranscribe-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    final service = _RecordingTranscriptionService(
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    addTearDown(() async {
      if (!service.gate.isCompleted) service.gate.complete();
      service.dispose();
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final seeded = completedRow(
      storage,
      id,
      language: language,
      translated: translated,
    );
    await seedFileFixtureRow(db, seeded);
    storage.pathFor(id).writeAsBytesSync([1, 2, 3]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          serverTranscriptionServiceProvider.overrideWith((ref) => service),
          dumpByIdProvider(id).overrideWith(
            (ref) => Stream<DumpRow?>.value(seeded),
          ),
          recordingPlaybackEngineFactoryProvider
              .overrideWithValue(_StubEngine.new),
          summariesEnabledProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: id,
            audioPath: seeded.audioPath,
            durationSeconds: seeded.durationSeconds,
          ),
        ),
      ),
    );
    await pumpBoundUntil(
      tester,
      () => find.byIcon(Icons.play_arrow).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    return service;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> openDialog(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('transcribe-$id')));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite transcript?'), findsOneWidget);
    expect(find.text(_dialogCopy), findsOneWidget);
  }

  Finder original(String id) =>
      find.byKey(ValueKey<String>('retranscribe-original-$id'));
  Finder english(String id) =>
      find.byKey(ValueKey<String>('retranscribe-english-$id'));

  bool selected(WidgetTester tester, Finder tile) {
    final RadioGroup<bool> group = tester.widget<RadioGroup<bool>>(
      find.ancestor(of: tile, matching: find.byType(RadioGroup<bool>)),
    );
    return group.groupValue == tester.widget<RadioListTile<bool>>(tile).value;
  }

  testWidgets(
      'Spanish row: both radios, original selected by default; '
      'choosing English + Overwrite asks for translate: true', (tester) async {
    final service = await mountDetail(tester, 'rt-es', language: 'es');
    await openDialog(tester, 'rt-es');

    expect(original('rt-es'), findsOneWidget);
    expect(english('rt-es'), findsOneWidget);
    expect(find.text('In Spanish (original)'), findsOneWidget);
    expect(find.text('In English (translate)'), findsOneWidget);
    expect(
      selected(tester, original('rt-es')),
      isTrue,
      reason: 'the stored transcript is the original: that is the default',
    );
    expect(
      selected(tester, english('rt-es')),
      isFalse,
    );

    await tester.tap(english('rt-es'));
    await tester.pumpAndSettle();
    expect(
      selected(tester, english('rt-es')),
      isTrue,
    );
    expect(service.requested, isEmpty, reason: 'nothing until Overwrite');

    await tester.tap(find.widgetWithText(FilledButton, 'Overwrite'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Overwrite transcript?'), findsNothing);
    expect(service.requested, <(String, bool)>[('rt-es', true)]);
    await unmount(tester);
  });

  testWidgets(
      'Spanish row already translated: English is the default, and '
      'switching back to the original asks for translate: false',
      (tester) async {
    final service = await mountDetail(
      tester,
      'rt-es-en',
      language: 'es',
      translated: true,
    );
    await openDialog(tester, 'rt-es-en');

    expect(
      selected(tester, english('rt-es-en')),
      isTrue,
      reason: 'the stored transcript IS the translation',
    );
    expect(
      selected(tester, original('rt-es-en')),
      isFalse,
    );

    await tester.tap(original('rt-es-en'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Overwrite'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.requested, <(String, bool)>[('rt-es-en', false)]);
    await unmount(tester);
  });

  testWidgets('Spanish row: Cancel asks for nothing', (tester) async {
    final service = await mountDetail(tester, 'rt-cancel', language: 'es');
    await openDialog(tester, 'rt-cancel');
    await tester.tap(english('rt-cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite transcript?'), findsNothing);
    expect(service.requested, isEmpty);
    await unmount(tester);
  });

  testWidgets(
      'English row: the dialog is unchanged (no radios, same copy '
      'and buttons) and Overwrite asks for translate: false', (tester) async {
    final service = await mountDetail(tester, 'rt-en', language: 'en');
    await openDialog(tester, 'rt-en');

    expect(original('rt-en'), findsNothing);
    expect(english('rt-en'), findsNothing);
    expect(find.byType(RadioListTile<bool>), findsNothing);
    expect(find.textContaining('(original)'), findsNothing);
    expect(find.textContaining('(translate)'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Overwrite'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Overwrite'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.requested, <(String, bool)>[('rt-en', false)]);
    await unmount(tester);
  });

  testWidgets('unknown language (never detected): no radios, translate: false',
      (tester) async {
    final service = await mountDetail(tester, 'rt-null');
    await openDialog(tester, 'rt-null');

    expect(find.byType(RadioListTile<bool>), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Overwrite'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.requested, <(String, bool)>[('rt-null', false)]);
    await unmount(tester);
  });
}
