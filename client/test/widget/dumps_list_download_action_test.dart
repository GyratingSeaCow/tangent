// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The download-audio action on the recordings list.
//
// A synced recording arrives carrying metadata and a transcript but no audio.
// The action that fetches it must appear ONLY on those rows: offering it on a
// recording this device already holds would be a control that does nothing,
// and hiding it on a row that genuinely needs it strands the audio on the
// server with no way to ask for it.
//
// These tests exist because a service with no call sites passes every unit
// test while doing nothing at runtime — the default outcome for work split
// across layers, and the reason the menu wiring gets its own proof.
import 'dart:async' show Completer;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/services/synced_audio_download.dart';
import 'package:tangent/widgets/item_action_sheet.dart';

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

void main() {
  group('dumpNeedsAudioDownload', () {
    test('needs both halves: server has it AND this device does not', () {
      expect(dumpNeedsAudioDownload(remoteRow('a')), isTrue);

      expect(
        dumpNeedsAudioDownload(viewRow('b')),
        isFalse,
        reason: 'a local recording has nothing to fetch',
      );

      expect(
        dumpNeedsAudioDownload(
          viewRow('c').copyWith(audioOnServer: const Value<bool?>(true)),
        ),
        isFalse,
        reason: 'audio already on this device must not offer a download',
      );

      expect(
        dumpNeedsAudioDownload(
          viewRow('d').copyWith(
            audioPath: '',
            remoteOnly: const Value<bool?>(true),
          ),
        ),
        isFalse,
        reason: 'the server has no audio, so there is nothing to fetch',
      );
    });

    test('a row predating the sync columns reads as not downloadable', () {
      // Both columns are nullable: null means "before this feature existed",
      // which must degrade to the old behaviour rather than offering a fetch
      // that would 404.
      expect(dumpNeedsAudioDownload(viewRow('legacy')), isFalse);
    });
  });

  testWidgets('a remote-only recording offers Download audio',
      (WidgetTester tester) async {
    final ProviderContainer container =
        await mountSelection(tester, CountingDeletion());
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

    await tester.tap(find.byKey(const ValueKey('dump-more-fixture-a')));
    await pumpSelection(tester);

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.download)),
      findsOneWidget,
      reason: 'the server holds audio this device does not',
    );
  });

  testWidgets('a recording that already has its audio offers no download',
      (WidgetTester tester) async {
    await mountSelection(tester, CountingDeletion());

    // fixture-a is an ordinary local recording.
    await tester.tap(find.byKey(const ValueKey('dump-more-fixture-a')));
    await pumpSelection(tester);

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.download)),
      findsNothing,
      reason: 'a control that cannot do anything must not be shown',
    );
    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.rename)),
      findsOneWidget,
      reason: 'the rest of the menu is unchanged',
    );
  });

  testWidgets('download does not disturb the existing menu contract',
      (WidgetTester tester) async {
    final ProviderContainer container =
        await mountSelection(tester, CountingDeletion());
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

    // Long-press must STILL be multi-select, not the sheet. 28 tests encode
    // that contract and the new action must not have touched it.
    await tester.longPress(find.byKey(const ValueKey('dump-row-fixture-a')));
    await pumpSelection(tester);

    expect(
      find.byKey(ItemActionSheet.keyFor(ItemAction.download)),
      findsNothing,
      reason: 'long-press is the bulk-delete entry point, not the menu',
    );
    expect(
      find.byKey(const ValueKey('dump-select-fixture-a')),
      findsOneWidget,
      reason: 'long-press must still enter selection mode',
    );
  });

  testWidgets('tapping download with no usable folder says so, never silently',
      (WidgetTester tester) async {
    // The Fold's defect shape: the entry is ENABLED when the sheet opens
    // (a downloader existed), but by tap time the folder state has dropped
    // and _downloadAudio's ref.read returns null. The old code returned
    // without a word, which is indistinguishable from a broken app.
    final StateProvider<SyncedAudioDownloader?> downloaderFixture =
        StateProvider<SyncedAudioDownloader?>(
      (_) => SyncedAudioDownloader(
        db: LocalDb.forTesting(NativeDatabase.memory()),
        backend: FilesystemStorageBackend(),
        location: fileLocation('fixture-folder', '/synthetic'),
        fetch: (_) async => const <int>[],
      ),
    );
    final ProviderContainer container = await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[
        syncedAudioDownloaderProvider
            .overrideWith((ref) => ref.watch(downloaderFixture)),
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

    await tester.tap(find.byKey(const ValueKey('dump-more-fixture-a')));
    await pumpSelection(tester);

    // The folder becomes unavailable between sheet-open and tap.
    container.read(downloaderFixture.notifier).state = null;

    await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.download)));
    await pumpSelection(tester);

    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('Choose a storage folder first'),
      ),
      findsOneWidget,
      reason: 'a tapped control must always report what happened',
    );
  });

  testWidgets('a downloading row shows a busy indicator until the fetch ends',
      (WidgetTester tester) async {
    // _downloading was bookkeeping with no renderer: the screen tracked ids
    // mid-download but no widget read the set, so a slow fetch looked like
    // a dead tap. The row must show progress while its download runs.
    final Completer<List<int>> gate = Completer<List<int>>();
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // The downloader consults the row before fetching; without it the run
    // fails at the first step and the indicator never gets a chance to show.
    await db.into(db.dumps).insert(
          DumpsCompanion.insert(
            id: 'fixture-a',
            createdAt: DateTime.utc(2026, 9, 18),
            updatedAt: DateTime.utc(2026, 9, 18),
            mode: 'brain_dump',
            durationSeconds: 12,
            title: 'From the other device',
            audioPath: '',
            audioSizeBytes: 0,
            syncStatus: 'synced',
            remoteOnly: const Value<bool?>(true),
            audioOnServer: const Value<bool?>(true),
          ),
        );
    final ProviderContainer container = await mountSelection(
      tester,
      CountingDeletion(),
      extraOverrides: <Override>[
        syncedAudioDownloaderProvider.overrideWith(
          (ref) => SyncedAudioDownloader(
            db: db,
            backend: FilesystemStorageBackend(),
            location: fileLocation('fixture-folder', '/synthetic'),
            fetch: (_) => gate.future,
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

    await tester.tap(find.byKey(const ValueKey('dump-more-fixture-a')));
    await pumpSelection(tester);
    await tester.tap(find.byKey(ItemActionSheet.keyFor(ItemAction.download)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byKey(const ValueKey('dump-downloading-fixture-a')),
      findsOneWidget,
      reason: 'an in-flight download must be visible on its row',
    );

    // The fetch fails (empty payload publish will error or complete); either
    // way the indicator must clear when the download settles.
    gate.complete(const <int>[]);
    await pumpSelection(tester);

    expect(
      find.byKey(const ValueKey('dump-downloading-fixture-a')),
      findsNothing,
      reason: 'the indicator must not outlive the download',
    );
  });
}
