// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/local_deletion_service.dart';
import 'package:tangent/data/storage/storage_codec.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import '../support/bound_row_fixture.dart';
import '../support/bound_service_fixture.dart';
import '../support/bound_widget_lifetime.dart';
import '../support/scripted_storage_backend.dart';
import '../support/storage_fixture.dart';

/// Task 10: dumps list treats text notes as first-class rows — a `Text Note`
/// mode-filter chip, an [Icons.edit_note] row affordance where recordings
/// show a duration, FTS search over note bodies (transcript column), and
/// multi-select deletion removing the row plus BOTH durable components
/// (`.md` + sidecar) through the real deletion service.

DumpRow _row(
  String id,
  String title, {
  String mode = 'brain_dump',
  int duration = 9,
  String status = 'not_transcribed',
  String? transcript,
}) =>
    DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 17),
      updatedAt: DateTime.utc(2026, 9, 17),
      mode: mode,
      durationSeconds: duration,
      title: title,
      transcript: transcript,
      audioPath: mode == 'text_note'
          ? 'content://tangent/$id.md'
          : 'content://tangent/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: status,
      transcriptionAttempt: 0,
    );

DumpRow _noteRow(String id, String title, {String? body}) => _row(
      id,
      title,
      mode: 'text_note',
      duration: 0,
      status: 'not_applicable',
      transcript: body ?? 'note body of $title',
    );

/// Records every component deletion the scripted backend performs so the
/// test can prove exactly which durable files each flow destroyed.
final class _CountingBackend extends ScriptedStorageBackend {
  final calls =
      <({BoundRecording binding, RecordingComponent component})>[];
  @override
  IoOperation<ComponentResult> deleteComponent(
    BoundRecording binding,
    RecordingComponent component,
    String operationId,
  ) {
    calls.add((binding: binding, component: component));
    return super.deleteComponent(binding, component, operationId);
  }
}

/// Seeds a durable text-note pair (`<id>.md` + `<id>.meta.json`) with its
/// bound row, mirroring [StorageFixture.seed] for the note shape produced by
/// NotePersistence: body in `transcript`, `.md` locator in `audioPath`.
Future<BoundRecording> _seedNote(
  StorageFixture f,
  String id,
  String body, {
  String folder = 'A',
}) async {
  if (!id.startsWith('fixture-')) throw ArgumentError('Synthetic IDs only');
  final location = fileLocation(folder, f.directory(folder));
  final bytes = utf8.encode(body);
  final md = File(p.join(f.directory(folder), '$id.md'));
  await md.writeAsBytes(bytes, flush: true);
  await File(p.join(f.directory(folder), '$id.meta.json')).writeAsString(
    jsonEncode({
      'schemaVersion': 2,
      'id': id,
      'title': id,
      'mode': 'text_note',
      'transcript': body,
      'transcriptionStatus': 'not_applicable',
    }),
    flush: true,
  );
  final now = DateTime.utc(2030, 1, 3);
  await f.db.into(f.db.dumps).insert(
        DumpRow(
          id: id,
          createdAt: now,
          updatedAt: now,
          mode: 'text_note',
          durationSeconds: 0,
          title: id,
          transcript: body,
          audioPath: md.path,
          audioSizeBytes: bytes.length,
          syncStatus: 'local_only',
          syncAttempts: 0,
          transcriptionStatus: 'not_applicable',
          transcriptionAttempt: 0,
        ),
      );
  await f.db.customStatement(
    'INSERT OR IGNORE INTO storage_locations(id,canonical_key,directory_json,label) VALUES(?,?,?,?)',
    [
      folder,
      StorageCodec.canonicalKey(location.directory),
      StorageCodec.encodeDirectory(location.directory),
      folder,
    ],
  );
  await f.db.customStatement(
    'INSERT INTO recording_bindings(dump_id,incarnation,location_id,audio_json,metadata_name,resolved) VALUES(?,?,?,?,?,1)',
    [
      id,
      'incarnation-$id',
      folder,
      StorageCodec.encodeAudio((kind: 'file', value: md.path)),
      '$id.meta.json',
    ],
  );
  return (
    key: (dumpId: id, incarnation: 'incarnation-$id'),
    location: location,
    audio: (kind: 'file', value: md.path),
    metadataName: '$id.meta.json'
  );
}

void _useTaskViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpData(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _mountPresentation(
  WidgetTester tester,
  List<DumpRow> rows,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deletionEligibilityProvider.overrideWith(
          (_) => Stream.value(const <String, Eligibility>{}),
        ),
        dumpsProvider.overrideWith((_) => Stream.value(rows)),
      ],
      child: const MaterialApp(home: DumpsListScreen()),
    ),
  );
  await _pumpData(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('filterDumps with text notes', () {
    final rows = [
      _noteRow('note-1', 'Note one'),
      _row('rec-1', 'Recording one'),
      _row('meet-1', 'Meeting one', mode: 'meeting'),
    ];

    test('Text Note chip filters mode==text_note and is labeled exactly', () {
      expect(DumpModeFilter.textNote.label, 'Text Note');
      expect(
        filterDumps(rows, DumpModeFilter.textNote, TranscriptFilter.all)
            .map((r) => r.id),
        ['note-1'],
      );
      expect(
        filterDumps(rows, DumpModeFilter.brainDump, TranscriptFilter.all)
            .map((r) => r.id),
        ['rec-1'],
      );
      expect(
        filterDumps(rows, DumpModeFilter.all, TranscriptFilter.all)
            .map((r) => r.id),
        ['note-1', 'rec-1', 'meet-1'],
      );
    });

    test('notes never match any transcript-progress filter', () {
      for (final transcript in [
        TranscriptFilter.needsTranscript,
        TranscriptFilter.inProgress,
        TranscriptFilter.transcribed,
        TranscriptFilter.failed,
      ]) {
        expect(
          filterDumps(rows, DumpModeFilter.textNote, transcript),
          isEmpty,
          reason: 'notes are terminal not_applicable under $transcript',
        );
        expect(
          filterDumps(rows, DumpModeFilter.all, transcript)
              .map((r) => r.id),
          isNot(contains('note-1')),
        );
      }
    });
  });

  group('FTS search over note bodies', () {
    test('query matches the note body stored in transcript', () async {
      final db = LocalDb.forTesting(NativeDatabase.memory());
      await seedFileFixtureRow(
        db,
        _row(
          '1',
          'Untitled note',
          mode: 'text_note',
          duration: 0,
          status: 'not_applicable',
          transcript: 'sourdough starter feeding schedule',
        ).copyWith(audioPath: '/tmp/1.md'),
      );
      await seedFileFixtureRow(
        db,
        _row('2', 'Grocery recording', transcript: 'budget for groceries')
            .copyWith(audioPath: '/tmp/2.opus'),
      );
      final container = ProviderContainer(
        overrides: [localDbProvider.overrideWithValue(db)],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      container.read(searchQueryProvider.notifier).state = 'sourdough';
      final noteHits = await container.read(searchResultsProvider.future);
      expect(noteHits.map((r) => r.id), ['1']);
      expect(noteHits.single.mode, 'text_note');

      container.read(searchQueryProvider.notifier).state = 'budget';
      final recordingHits =
          await container.read(searchResultsProvider.future);
      expect(recordingHits.map((r) => r.id), ['2']);
    });
  });

  group('dumps list presentation', () {
    testWidgets('note rows show edit_note where recordings show duration',
        (tester) async {
      _useTaskViewport(tester);
      await _mountPresentation(tester, [
        _noteRow('note-1', 'Sourdough note'),
        _row('rec-1', 'Long recording'),
      ]);

      expect(
        find.byKey(const ValueKey('note-row-icon-note-1')),
        findsOneWidget,
        reason: 'note rows carry the edit_note affordance',
      );
      expect(
        tester
            .widget<Icon>(find.byKey(const ValueKey('note-row-icon-note-1')))
            .icon,
        Icons.edit_note,
      );
      expect(
        find.byKey(const ValueKey('note-row-icon-rec-1')),
        findsNothing,
        reason: 'recordings keep the duration text, not the note icon',
      );
      expect(find.textContaining('9s ·'), findsOneWidget);
      expect(
        find.textContaining('0s'),
        findsNothing,
        reason: 'a note must not render a meaningless zero duration',
      );
      expect(
        find.byKey(const ValueKey('transcription-pill-note-1-not-applicable')),
        findsOneWidget,
      );
    });

    testWidgets('Text Note chip filters the list; transcript filters stay sane',
        (tester) async {
      _useTaskViewport(tester);
      await _mountPresentation(tester, [
        _noteRow('note-1', 'Sourdough note'),
        _row('rec-1', 'Long recording'),
      ]);

      // One bar, two dropdowns; each closed anchor names its selection.
      expect(find.text('Mode · All'), findsOneWidget);
      expect(find.text('Transcript · All'), findsOneWidget);

      // Filters are dropdowns now: open the menu, then tap the same key.
      await tester.tap(find.byKey(const ValueKey('mode-filter-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mode-filter-textNote')));
      await _pumpData(tester);
      expect(find.text('Sourdough note'), findsOneWidget);
      expect(find.text('Long recording'), findsNothing);

      // Filters are dropdowns now: open the menu, then tap the same key.
      await tester.tap(find.byKey(const ValueKey('transcript-filter-menu')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('transcript-filter-needsTranscript')),
      );
      await _pumpData(tester);
      expect(
        find.text('Sourdough note'),
        findsNothing,
        reason: 'notes never match transcript-progress filters',
      );
      expect(find.text('No dumps yet — record one!'), findsOneWidget);

      // Filters are dropdowns now: open the menu, then tap the same key.
      await tester.tap(find.byKey(const ValueKey('transcript-filter-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transcript-filter-all')));
      await _pumpData(tester);
      expect(find.text('Sourdough note'), findsOneWidget);

      // Filters are dropdowns now: open the menu, then tap the same key.
      await tester.tap(find.byKey(const ValueKey('mode-filter-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mode-filter-all')));
      await _pumpData(tester);
      expect(find.text('Long recording'), findsOneWidget);
    });
  });

  testWidgets(
      'multi-select deletion removes the note row, its .md, and its sidecar; '
      'recording deletion regression', (tester) async {
    _useTaskViewport(tester);
    final f = StorageFixture.create();
    final backend = _CountingBackend();
    BoundServiceFixture? bound;
    addTearDown(() async {
      if (bound != null) await disposeBoundWidget(tester, bound!);
      await tester.runAsync(() async {
        await backend.drain();
        await f.close();
      });
    });
    late DefaultLocalDeletionService deletion;
    const body = 'sourdough starter feeding schedule';
    await tester.runAsync(() async {
      bound = await createBoundServiceFixture(
        f.db,
        backend: backend,
        registerDrain: false,
      );
      deletion = DefaultLocalDeletionService(
        db: f.db,
        backend: backend,
        mutations: bound!.mutations,
      );
      await _seedNote(f, 'fixture-note', body);
      await f.seed('fixture-recording');
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(f.db),
          localDeletionServiceProvider.overrideWithValue(deletion),
        ],
        child: const MaterialApp(home: DumpsListScreen()),
      ),
    );

    final noteRow = find.byKey(const ValueKey('dump-row-fixture-note'));
    final recordingRow =
        find.byKey(const ValueKey('dump-row-fixture-recording'));
    await pumpBoundUntil(tester, () => noteRow.evaluate().isNotEmpty);
    await pumpBoundUntil(
      tester,
      () => tester.widget<ListTile>(noteRow).onLongPress != null,
    );

    await tester.longPress(noteRow);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('dump-select-fixture-note')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('selection-delete')));
    await pumpBoundUntil(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
    );
    expect(
      find.text('Delete 1 local recordings?'),
      findsOneWidget,
      reason: 'count-confirm dialog copy must be unchanged for notes',
    );
    expect(
      find.text(
        'Local audio, transcripts/notes, and metadata will be removed. '
        'Server copies are not deleted and server jobs are not canceled.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('local-delete-confirm')));
    await pumpBoundUntil(
      tester,
      () => find.text('1 deleted, 0 failed, 0 skipped').evaluate().isNotEmpty,
    );
    await pumpBoundUntil(tester, () => noteRow.evaluate().isEmpty);

    expect(
      backend.calls
          .where((c) => c.binding.key.dumpId == 'fixture-note')
          .map((c) => c.component)
          .toList(),
      [RecordingComponent.audio, RecordingComponent.metadata],
      reason: 'both note components must go through the scripted backend',
    );
    expect(backend.calls, hasLength(2));
    await tester.runAsync(() async {
      expect(await f.db.getDump('fixture-note'), isNull);
      expect(await f.db.boundRecording('fixture-note'), isNull);
      expect(
        File(p.join(f.directory('A'), 'fixture-note.md')).existsSync(),
        isFalse,
        reason: 'the published .md must be removed',
      );
      expect(
        File(p.join(f.directory('A'), 'fixture-note.meta.json')).existsSync(),
        isFalse,
        reason: 'the sidecar must be removed',
      );
      expect(await f.audio('A', 'fixture-recording').exists(), isTrue);
      expect(await f.metadata('A', 'fixture-recording').exists(), isTrue);
    });
    expect(recordingRow, findsOneWidget);

    // Recording deletion regression through the identical flow.
    await pumpBoundUntil(
      tester,
      () => tester.widget<ListTile>(recordingRow).onLongPress != null,
    );
    await tester.longPress(recordingRow);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('selection-delete')));
    await pumpBoundUntil(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
    );
    expect(find.text('Delete 1 local recordings?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('local-delete-confirm')));
    await pumpBoundUntil(tester, () => recordingRow.evaluate().isEmpty);

    expect(
      backend.calls
          .where((c) => c.binding.key.dumpId == 'fixture-recording')
          .map((c) => c.component)
          .toList(),
      [RecordingComponent.audio, RecordingComponent.metadata],
    );
    await tester.runAsync(() async {
      expect(await f.db.getDump('fixture-recording'), isNull);
      expect(await f.audio('A', 'fixture-recording').exists(), isFalse);
      expect(await f.metadata('A', 'fixture-recording').exists(), isFalse);
    });
    expect(find.text('No dumps yet — record one!'), findsOneWidget);
    await disposeBoundWidget(tester, bound!);
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.takeException(), isNull);
  });
}