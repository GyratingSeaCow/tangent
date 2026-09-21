// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The bulk toolbar's download and transcribe buttons.
//
// What matters here is presence and gating: the buttons exist beside
// delete, disable with nothing selected, and enable once something is.
// The eligibility rules they apply are proven in bulk_dump_actions_test;
// this file proves the toolbar actually offers them — a bulk service with
// no button is the same defect as a download service with no menu entry.
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_providers.dart'
    show serverTranscriptionServiceProvider;
import 'package:tangent/services/server_transcription_service.dart';
import 'package:tangent/services/synced_audio_download.dart';
import 'package:tangent/services/transcription_client.dart';

import '../support/bound_service_fixture.dart';
import '../support/dump_selection_fixture.dart';
import '../support/dump_view_fixture.dart';
import '../support/storage_fixture.dart';

/// A recording whose audio is on the server but not on this device.
DumpRow remoteRow(String id) => viewRow(id).copyWith(
      audioPath: '',
      audioSizeBytes: 0,
      syncStatus: 'synced',
      remoteOnly: const Value<bool?>(true),
      audioOnServer: const Value<bool?>(true),
    );

/// Holds every transcribeDump call open until [gate] completes, so a test
/// can assert what the screen shows WHILE the bulk run is still working.
class _GatedTranscriptionService extends ServerTranscriptionService {
  _GatedTranscriptionService({
    required super.db,
    required super.recordingAccess,
    required super.mutations,
  }) : super(client: TranscriptionClient(baseUrl: 'http://test'));

  final Completer<void> gate = Completer<void>();
  final List<String> requested = <String>[];

  @override
  Future<void> transcribeDump(String dumpId) {
    requested.add(dumpId);
    return gate.future;
  }
}

void main() {
  testWidgets('bulk toolbar offers download and transcribe beside delete',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    // Enter selection mode via long-press (the documented entry point).
    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);

    for (final String key in <String>[
      'selection-download',
      'selection-transcribe',
      'selection-delete',
    ]) {
      expect(
        find.byKey(ValueKey<String>(key)),
        findsOneWidget,
        reason: '$key belongs on the bulk toolbar',
      );
    }
  });

  testWidgets('bulk buttons disable when the selection is empty',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);
    // Deselect the row long-press selected: toolbar stays, selection empty.
    await tester.tap(find.byKey(const ValueKey('dump-select-fixture-a')));
    await pumpSelection(tester);

    for (final String key in <String>[
      'selection-download',
      'selection-transcribe',
    ]) {
      final IconButton button =
          tester.widget<IconButton>(find.byKey(ValueKey<String>(key)));
      expect(
        button.onPressed,
        isNull,
        reason: '$key over nothing is a lying control',
      );
    }
  });

  testWidgets('a failed bulk download offers Details naming each failure',
      (WidgetTester tester) async {
    // A downloader whose DB knows none of the fixture rows: every eligible
    // row fails with the service's own wording ('Recording is missing').
    final ProviderContainer container = await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[
        syncedAudioDownloaderProvider.overrideWith(
          (ref) => SyncedAudioDownloader(
            db: LocalDb.forTesting(NativeDatabase.memory()),
            backend: FilesystemStorageBackend(),
            location: fileLocation('fixture-folder', '/synthetic'),
            fetch: (_) async => const <int>[],
          ),
        ),
      ],
    );
    container.read(presentedFixture.notifier).state = AsyncData(
      (
        scopeKey: 'all',
        generation: 2,
        settled: true,
        rows: <DumpRow>[remoteRow('fixture-a'), viewRow('fixture-b')],
        limit: null,
      ),
    );
    await pumpSelection(tester);

    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);
    await tester.tap(find.byKey(const ValueKey('selection-download')));
    await pumpSelection(tester);

    // The receipt names the failure and offers the detail.
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('1 failed'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Details'));
    await pumpSelection(tester);

    // The dialog names the row by TITLE and carries the service's wording —
    // an id alone means nothing to a person scanning 43 failures.
    expect(
      find.byKey(const ValueKey('bulk-failure-details')),
      findsOneWidget,
    );
    expect(find.textContaining('fixture-a'), findsWidgets);
    expect(find.textContaining('Recording is missing'), findsOneWidget);
  });

  testWidgets('bulk transcribe announces the run while work is in flight',
      (WidgetTester tester) async {
    // The bulk run is sequential and each large-v3 job takes minutes; the
    // old flow's only feedback was the END receipt, so a long-press →
    // transcribe looked like a dead button. The announcement must appear
    // IMMEDIATELY — while transcribeDump futures are still open.
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    final BoundServiceFixture bound = await tester.runAsync(
      () => createBoundServiceFixture(db, registerDrain: false),
    ) as BoundServiceFixture;
    addTearDown(() async {
      await bound.mutations.drain();
      await db.close();
    });
    final _GatedTranscriptionService service = _GatedTranscriptionService(
      db: db,
      recordingAccess: bound.access,
      mutations: bound.mutations,
    );
    await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[
        serverTranscriptionServiceProvider.overrideWith((ref) => service),
      ],
    );

    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);
    await tester.tap(find.byKey(const ValueKey('dump-select-fixture-b')));
    await pumpSelection(tester);
    await tester.tap(find.byKey(const ValueKey('selection-transcribe')));
    await tester.pump();

    // The run has started (first row requested, future still open) and the
    // screen SAYS so — before any completion.
    expect(service.requested, isNotEmpty);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('Transcribing 2'),
      ),
      findsOneWidget,
      reason: 'starting a bulk transcribe must be announced immediately, '
          'not only in the end receipt',
    );

    // Release the gate: the run completes and the receipt replaces the
    // announcement as before.
    service.gate.complete();
    await pumpSelection(tester);
    expect(
      find.byKey(const ValueKey('bulk-transcribe-result')),
      findsOneWidget,
    );
  });
}
