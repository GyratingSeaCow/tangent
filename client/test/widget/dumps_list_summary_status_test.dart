// SPDX-License-Identifier: AGPL-3.0-or-later
/// v1.19.0: the recordings list carries a red 'Summary failed' pill on a
/// row whose last summary attempt the server reported failed (until the
/// user dismisses it on this device), and a language tag ('ES', or
/// 'ES → EN' once translated) on non-English recordings. English and
/// unknown-language rows carry nothing.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/tag_repository.dart' show tagStoreProvider;
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart' show foldersProvider;
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';

import '../support/legacy_audio_storage_fixture.dart';
import '../support/resolved_temp.dart';
import '../support/fake_tag_store.dart';

DumpRow _row(
  String id,
  String title, {
  String? summaryStatus,
  String? summaryError,
  int? dismissedAt,
  String? language,
  bool? translated,
}) =>
    DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 26),
      updatedAt: DateTime.utc(2026, 9, 26),
      mode: 'meeting',
      durationSeconds: 9,
      title: title,
      transcript: 'some words',
      audioPath: 'content://tangent/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'synced',
      syncAttempts: 0,
      transcriptionStatus: 'completed',
      transcriptionAttempt: 1,
      summary: '## Summary\nold',
      summarizedAt: 1790000000,
      summaryStatus: summaryStatus,
      summaryError: summaryError,
      summaryErrorDismissedAt: dismissedAt,
      language: language,
      translated: translated,
    );

void main() {
  Future<void> mountList(WidgetTester tester, List<DumpRow> rows) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = createResolvedTempSync('tangent-list-status-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    addTearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          // A real drift db here: the tag projections must not open drift
          // streams too, or teardown trips !timersPending.
          tagStoreProvider.overrideWithValue(FakeTagStore()),
          foldersProvider.overrideWith((_) => Stream.value(const <Folder>[])),
          audioStorageProvider.overrideWithValue(storage),
          deletionEligibilityProvider
              .overrideWith((_) => Stream.value(const {})),
          dumpsProvider.overrideWith((_) => Stream.value(rows)),
        ],
        child: const MaterialApp(home: DumpsListScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('the red Summary failed pill sits on the failed row only, and '
      'not once dismissed', (tester) async {
    await mountList(tester, <DumpRow>[
      _row(
        'failed',
        'Broken summary',
        summaryStatus: 'failed',
        summaryError: 'RuntimeError: model missing',
      ),
      _row(
        'dismissed',
        'Broken but hidden',
        summaryStatus: 'failed',
        summaryError: 'RuntimeError: model missing',
        dismissedAt: 1790000500,
      ),
      _row('queued', 'Waiting', summaryStatus: 'queued'),
      _row('plain', 'Fine'),
    ]);

    final Finder pill =
        find.byKey(const ValueKey<String>('summary-failed-pill-failed'));
    expect(pill, findsOneWidget);
    expect(
      find.descendant(of: pill, matching: find.text('Summary failed')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pill, matching: find.byIcon(Icons.error_outline)),
      findsOneWidget,
    );
    // The transcription pill still stands next to it.
    expect(
      find.byKey(const ValueKey<String>('transcription-pill-failed-completed')),
      findsOneWidget,
    );
    for (final String id in <String>['dismissed', 'queued', 'plain']) {
      expect(
        find.byKey(ValueKey<String>('summary-failed-pill-$id')),
        findsNothing,
        reason: '$id has no visible failure',
      );
    }
    // The failed row is not "in progress" either.
    expect(
      find.byKey(const ValueKey<String>('summary-pending-pill-failed')),
      findsNothing,
    );
    // ...while the server-queued row is.
    expect(
      find.byKey(const ValueKey<String>('summary-pending-pill-queued')),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('the language tag reads ES on a Spanish row, ES → EN once '
      'translated, and is absent for English and unknown', (tester) async {
    await mountList(tester, <DumpRow>[
      _row('es', 'Reunión', language: 'es'),
      _row('es-en', 'Reunión traducida', language: 'es', translated: true),
      _row('en', 'Meeting', language: 'en'),
      _row('en-t', 'Meeting flagged', language: 'en', translated: true),
      _row('unknown', 'Not yet transcribed'),
    ]);

    final Finder es = find.byKey(const ValueKey<String>('language-tag-es'));
    expect(es, findsOneWidget);
    expect(find.descendant(of: es, matching: find.text('ES')), findsOneWidget);
    expect(
      find.descendant(of: es, matching: find.byIcon(Icons.translate)),
      findsOneWidget,
    );

    final Finder esEn =
        find.byKey(const ValueKey<String>('language-tag-es-en'));
    expect(esEn, findsOneWidget);
    expect(
      find.descendant(of: esEn, matching: find.text('ES → EN')),
      findsOneWidget,
    );

    for (final String id in <String>['en', 'en-t', 'unknown']) {
      expect(
        find.byKey(ValueKey<String>('language-tag-$id')),
        findsNothing,
        reason: '$id: the common case carries no noise',
      );
    }
    // Neither the tag nor its absence disturbs the transcription pill.
    expect(
      find.byKey(const ValueKey<String>('transcription-pill-es-completed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('transcription-pill-en-completed')),
      findsOneWidget,
    );
    await unmount(tester);
  });
}
