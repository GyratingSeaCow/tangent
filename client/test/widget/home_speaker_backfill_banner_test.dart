// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_providers.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/screens/home/speaker_backfill_banner.dart';
import 'package:tangent/screens/recording/recording_controller.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/services/recording_service.dart';
import 'package:tangent/services/screen_awake.dart';
import 'package:tangent/services/transcription_client.dart';

import '../support/dump_view_fixture.dart';
import '../support/fake_notebook_repository.dart';
import '../support/widget_recording_coordinator.dart';

/// Leftovers sweep L5: the v20 speaker back-fill records the dump ids it
/// REFUSED (ambiguous pairing) in `settings['speaker_backfill_skipped']`.
/// Home shows that list once as a dismissible banner above the record
/// area; tapping it opens Recordings filtered to those ids; dismissing
/// deletes the key so the banner never returns; no skips → no banner.
///
/// The banner reads the REAL settings row through the real LocalDb (the
/// same query the production provider runs), so a migration that stops
/// writing the key fails here, not only in the migration unit test.

class _StubClient extends TranscriptionClient {
  _StubClient() : super(baseUrl: 'http://test');
}

class _NoopScreenAwake implements ScreenAwake {
  @override
  Future<void> setEnabled(bool enabled) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotebookRepository notebooks;

  /// Mounts Home over a real in-memory LocalDb whose skipped list holds
  /// [skipped] (written through the migration's own INSERT shape) and
  /// whose recordings list carries [rows].
  Future<LocalDb> mountHome(
    WidgetTester tester, {
    required List<String> skipped,
    List<DumpRow> rows = const <DumpRow>[],
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
    // Open real SQLite outside the widget fake clock (home_screen_test
    // does the same) and seed the row the migration would have written.
    await tester.runAsync(() async {
      await db.listDumps();
      if (skipped.isNotEmpty) {
        await db.customStatement(
          'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
          <Object>[
            LocalDb.speakerBackfillSkippedKey,
            '[${skipped.map((String id) => '"$id"').join(',')}]',
          ],
        );
      }
    });
    notebooks = FakeNotebookRepository();
    addTearDown(notebooks.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          localDbProvider.overrideWithValue(db),
          transcriptionClientProvider.overrideWith((_) => _StubClient()),
          recordingServiceProvider.overrideWithValue(StubRecordingService()),
          recordingCoordinatorProvider.overrideWith(
            (ref) =>
                WidgetRecordingCoordinator(ref.watch(recordingServiceProvider)),
          ),
          captureReadyProvider.overrideWith((ref) async {}),
          catalogSyncProvider.overrideWith((ref) async {}),
          settingsStoreProvider.overrideWithValue(SettingsStore()),
          screenAwakeProvider.overrideWithValue(_NoopScreenAwake()),
          deletionEligibilityProvider.overrideWith(
            (_) => Stream<Map<String, Eligibility>>.value(
              const <String, Eligibility>{},
            ),
          ),
          dumpsProvider.overrideWith(
            (_) => Stream<List<DumpRow>>.value(rows),
          ),
          notebookRepositoryProvider.overrideWithValue(notebooks),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return db;
  }

  Future<void> unmountHome(WidgetTester tester, LocalDb db) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  }

  Finder bannerText(int count) => find.descendant(
        of: find.byKey(SpeakerBackfillBanner.bannerKey),
        matching: find.text(speakerBackfillBannerText(count)),
      );

  testWidgets('no skips -> no banner', (tester) async {
    final LocalDb db = await mountHome(tester, skipped: const <String>[]);

    expect(find.byKey(SpeakerBackfillBanner.bannerKey), findsNothing);
    expect(
      find.textContaining('kept their old speaker headings'),
      findsNothing,
    );
    expect(find.byKey(HomeScreen.recordButtonKey), findsOneWidget);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets('two skips -> the banner shows the count, above the record key',
      (tester) async {
    final LocalDb db =
        await mountHome(tester, skipped: const <String>['odd-1', 'odd-2']);

    expect(find.byKey(SpeakerBackfillBanner.bannerKey), findsOneWidget);
    expect(bannerText(2), findsOneWidget);
    expect(
      speakerBackfillBannerText(2),
      '2 recordings kept their old speaker headings — open one to name '
      'speakers again',
    );
    expect(
      tester.getBottomLeft(find.byKey(SpeakerBackfillBanner.bannerKey)).dy,
      lessThan(tester.getTopLeft(find.byKey(HomeScreen.recordButtonKey)).dy),
      reason: 'banner sits ABOVE the record area',
    );
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets('one skip reads in the singular', (tester) async {
    final LocalDb db = await mountHome(tester, skipped: const <String>['odd']);

    expect(bannerText(1), findsOneWidget);
    expect(
      speakerBackfillBannerText(1),
      '1 recording kept its old speaker headings — open it to name '
      'speakers again',
    );

    await unmountHome(tester, db);
  });

  testWidgets('dismiss -> key deleted -> banner gone, and stays gone',
      (tester) async {
    final LocalDb db =
        await mountHome(tester, skipped: const <String>['odd-1', 'odd-2']);
    expect(bannerText(2), findsOneWidget);

    await tester.tap(find.byKey(SpeakerBackfillBanner.dismissKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(SpeakerBackfillBanner.bannerKey), findsNothing);
    late List<String> after;
    late int rowsWithKey;
    await tester.runAsync(() async {
      after = await db.speakerBackfillSkippedIds();
      rowsWithKey = (await db.customSelect(
        'SELECT value FROM settings WHERE key = ?',
        variables: <Variable<Object>>[
          Variable<String>(LocalDb.speakerBackfillSkippedKey),
        ],
      ).get())
          .length;
    });
    expect(after, isEmpty, reason: 'dismiss clears the key');
    expect(rowsWithKey, 0, reason: 'the row is deleted, not emptied');

    // Remount over the same database: one-time means once.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[localDbProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: Scaffold(body: SpeakerBackfillBanner()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(SpeakerBackfillBanner.bannerKey), findsNothing);
    expect(tester.takeException(), isNull);

    await unmountHome(tester, db);
  });

  testWidgets('tapping the banner opens Recordings filtered to the skipped ids',
      (tester) async {
    final LocalDb db = await mountHome(
      tester,
      skipped: const <String>['odd-1', 'odd-2'],
      rows: <DumpRow>[viewRow('fine-a'), viewRow('odd-1'), viewRow('odd-2')],
    );

    await tester.tap(bannerText(2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(DumpsListScreen), findsOneWidget);
    expect(
      tester.widget<DumpsListScreen>(find.byType(DumpsListScreen)).filterIds,
      <String>{'odd-1', 'odd-2'},
    );
    expect(find.text('odd-1'), findsOneWidget);
    expect(find.text('odd-2'), findsOneWidget);
    expect(
      find.text('fine-a'),
      findsNothing,
      reason: 'not a skip: filtered out',
    );
    // Opening does not dismiss: the key survives until the X is tapped.
    late List<String> still;
    await tester.runAsync(() async {
      still = await db.speakerBackfillSkippedIds();
    });
    expect(still, <String>['odd-1', 'odd-2']);
    expect(tester.takeException(), isNull);

    Navigator.of(tester.element(find.byType(DumpsListScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await unmountHome(tester, db);
  });
}
