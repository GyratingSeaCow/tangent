// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dump_detail_screen.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/services/note_persistence.dart';
import 'package:tangent/services/recording_playback.dart';

import '../support/bound_row_fixture.dart';
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/legacy_audio_storage_fixture.dart';
import '../support/scripted_storage_backend.dart';

/// Task 9: note-aware detail presentation. A `text_note` row hides the
/// playback card, every Transcribe control, and the duration chip while
/// keeping the Mode and sync chips, the title editor, an always-editable
/// body labeled `Note` whose explicit Save persists AND republishes the
/// sidecar, and the existing Delete confirm. Recording detail is
/// regression-frozen.

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

void main() {
  void useHandsetViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Harness whose teardown survives mid-test failures: unmount the tree,
  /// drain the coordinator, then close the fixture (real I/O under runAsync).
  /// Same pattern as note_compose_test.dart.
  CatalogHarness harnessFor(WidgetTester tester) {
    final h = CatalogHarness();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      var drained = false;
      await tester.runAsync(() async {
        unawaited(h.mutations.drain().then((_) => drained = true));
      });
      await pumpBoundUntil(tester, () => drained);
      await tester.runAsync(() async {
        await h.backend.drain();
        await h.f.backend.drain();
        await h.f.db.close();
        await h.f.root.delete(recursive: true);
      });
    });
    return h;
  }

  /// Real catalog bootstrap: OS futures settle under runAsync while the fake
  /// zone keeps pumping (bound-lifetime pattern).
  Future<void> bootstrapPumped(WidgetTester tester, CatalogHarness h) async {
    Object? bootError;
    var booted = false;
    await tester.runAsync(() async {
      unawaited(
        h.bootstrap().then(
          (_) => booted = true,
          onError: (Object e) {
            bootError = e;
            booted = true;
          },
        ),
      );
    });
    await pumpBoundUntil(tester, () => booted);
    if (bootError != null) throw bootError!;
  }

  /// Seeds a committed note row through the REAL pipeline (Task 4).
  Future<DumpRow> seedNote(
    WidgetTester tester,
    CatalogHarness h,
    String text,
  ) async {
    final notes = NotePersistence(
      db: h.f.db,
      backend: h.backend,
      mutations: h.mutations,
      catalog: h.catalog,
    );
    DumpRow? row;
    Object? error;
    await tester.runAsync(() async {
      unawaited(
        notes.saveNote(text: text, now: DateTime.utc(2030, 1, 2, 3, 4, 5)).then(
          (r) => row = r,
          onError: (Object e) => error = e,
        ),
      );
    });
    await pumpBoundUntil(tester, () => row != null || error != null);
    if (error != null) throw error!;
    return row!;
  }

  Future<void> mountNoteDetail(
    WidgetTester tester,
    CatalogHarness h,
    DumpRow row,
    RecordingPlaybackEngine Function() engineFactory,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(h.f.db),
          storageBackendProvider.overrideWithValue(h.backend),
          recordingMutationsProvider.overrideWithValue(h.mutations),
          recordingPlaybackEngineFactoryProvider
              .overrideWithValue(engineFactory),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: row.id,
            audioPath: row.audioPath,
            durationSeconds: row.durationSeconds,
          ),
        ),
      ),
    );
    // Live dumpByIdProvider: wait for the real Drift row to render.
    await pumpBoundUntil(
      tester,
      () => find.text('Mode: Text Note').evaluate().isNotEmpty,
    );
    // Let the playback-initialization decision settle before assertions.
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets(
      'note detail hides playback, Transcribe, and the duration chip while '
      'keeping Mode and sync chips, title edit, and Delete', (tester) async {
    useHandsetViewport(tester);
    final h = harnessFor(tester);
    await bootstrapPumped(tester, h);
    final row = await seedNote(tester, h, 'typed note body');
    var engineBuilds = 0;
    await mountNoteDetail(tester, h, row, () {
      engineBuilds++;
      return _StubEngine();
    });

    expect(find.text('Mode: Text Note'), findsOneWidget);
    expect(
      find.text('Pending'),
      findsOneWidget,
      reason: 'notes legitimately sync — the sync chip stays',
    );
    expect(
      find.text('${row.durationSeconds}s'),
      findsNothing,
      reason: 'the duration chip is meaningless for a typed note',
    );
    expect(find.text('Recording playback'), findsNothing);
    expect(find.byKey(const ValueKey('recording-seek-bar')), findsNothing);
    expect(find.byKey(ValueKey('transcribe-${row.id}')), findsNothing);
    expect(find.text('Transcribe'), findsNothing);
    expect(
      engineBuilds,
      0,
      reason: 'a note must never open a playback engine',
    );
    expect(find.byKey(ValueKey('title-editor-${row.id}')), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Save'),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    // Unmount inside the test body so Drift stream-close timers flush before
    // the framework's pending-timer invariant (dump_detail pattern).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
      'note body editor is labeled Note and its Save persists and '
      'republishes the sidecar', (tester) async {
    useHandsetViewport(tester);
    final h = harnessFor(tester);
    await bootstrapPumped(tester, h);
    const original = 'original note body';
    final row = await seedNote(tester, h, original);
    await mountNoteDetail(tester, h, row, _StubEngine.new);

    expect(find.text('Note'), findsOneWidget);
    expect(find.text('Transcript'), findsNothing);
    final editorFinder = find.byKey(ValueKey('transcript-editor-${row.id}'));
    expect(tester.widget<TextField>(editorFinder).controller!.text, original);

    const edited = 'edited note body\nwith a second line';
    await tester.enterText(editorFinder, edited);
    await tester.pump();
    final saveFinder = find.byKey(ValueKey('save-transcript-${row.id}'));
    final saveButton = tester.widget<FilledButton>(saveFinder);
    expect(
      saveButton.onPressed,
      isNotNull,
      reason: 'a dirty not_applicable note must allow explicit body Save',
    );
    await tester.runAsync(() async {
      saveButton.onPressed!();
    });
    // Notes publish inside the Tangent Text Notes child (T1); the sidecar
    // republishes beside the .md there, not at the folder root.
    final sidecarFile = File(
      p.join(
        h.f.directory('A'),
        textNoteSubdirectoryName,
        '${row.id}.meta.json',
      ),
    );
    await pumpBoundUntil(tester, () async {
      final saved = await h.f.db.getDump(row.id);
      if (saved == null ||
          saved.transcript != edited ||
          saved.transcriptionError != null) {
        return false;
      }
      if (!await sidecarFile.exists()) return false;
      final metadata =
          jsonDecode(await sidecarFile.readAsString()) as Map<String, dynamic>;
      return metadata['transcript'] == edited;
    });
    late DumpRow saved;
    late Map<String, dynamic> metadata;
    await tester.runAsync(() async {
      saved = (await h.f.db.getDump(row.id))!;
      metadata =
          jsonDecode(await sidecarFile.readAsString()) as Map<String, dynamic>;
    });
    expect(saved.transcript, edited);
    expect(
      saved.transcriptionError,
      isNull,
      reason: 'publication must clear the sidecar_sync_pending marker',
    );
    expect(saved.transcriptionStatus, 'not_applicable');
    expect(metadata['transcript'], edited);
    expect(metadata['transcriptionError'], isNull);
    expect(metadata['transcriptionStatus'], 'not_applicable');
    await tester.pump();
    expect(find.text('Transcript saved'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('note delete reaches the existing local deletion confirm dialog',
      (tester) async {
    useHandsetViewport(tester);
    final h = harnessFor(tester);
    await bootstrapPumped(tester, h);
    final row = await seedNote(tester, h, 'note headed for deletion');
    await mountNoteDetail(tester, h, row, _StubEngine.new);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await pumpBoundUntil(
      tester,
      () => find.text('Delete 1 local recordings?').evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('local-delete-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Delete 1 local recordings?'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
      'regression: recording detail still shows playback, Transcribe, and '
      'the duration chip', (tester) async {
    useHandsetViewport(tester);
    final temp = Directory.systemTemp.createTempSync('tangent-note-detail-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final bound = await createBoundServiceFixture(db, registerDrain: false);
    addTearDown(() async {
      await disposeBoundWidget(tester, bound);
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final row = DumpRow(
      id: 'note-reg-recording',
      createdAt: DateTime.utc(2026, 9, 17),
      updatedAt: DateTime.utc(2026, 9, 17),
      mode: 'brain_dump',
      durationSeconds: 4,
      title: 'Recording stays a recording',
      audioPath: storage.pathFor('note-reg-recording').path,
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: 'not_transcribed',
      transcriptionAttempt: 0,
    );
    await seedFileFixtureRow(db, row);
    storage.pathFor(row.id).writeAsBytesSync([1, 2, 3]);
    var engineBuilds = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          recordingMutationsProvider.overrideWithValue(bound.mutations),
          recordingAccessProvider.overrideWithValue(bound.access),
          dumpByIdProvider(row.id).overrideWith(
            (ref) => Stream<DumpRow?>.value(row),
          ),
          recordingPlaybackEngineFactoryProvider.overrideWithValue(() {
            engineBuilds++;
            return _StubEngine();
          }),
        ],
        child: MaterialApp(
          home: DumpDetailScreen(
            dumpId: row.id,
            audioPath: row.audioPath,
            durationSeconds: row.durationSeconds,
          ),
        ),
      ),
    );
    await pumpBoundUntil(
      tester,
      () => find.byIcon(Icons.play_arrow).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    expect(find.text('Recording playback'), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-seek-bar')), findsOneWidget);
    expect(find.text('Transcribe'), findsOneWidget);
    expect(find.text('4s'), findsOneWidget);
    expect(
      engineBuilds,
      1,
      reason: 'audio modes still open exactly one playback engine',
    );
    expect(find.text('Transcript'), findsNothing);
    expect(find.text('Note'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
