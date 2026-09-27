// SPDX-License-Identifier: AGPL-3.0-or-later
/// v1.18.0: the recordings list says 'Summarizing…' on a row whose summary
/// the server is still writing (summary_requested_at newer than
/// summarized_at and under ten minutes old), and nothing on any other row.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart' show foldersProvider;
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';
import 'package:tangent/services/summary_pending.dart';

import '../support/legacy_audio_storage_fixture.dart';
import '../support/resolved_temp.dart';

DumpRow _row(
  String id,
  String title, {
  int? requestedAt,
  int? summarizedAt,
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
      summary: summarizedAt == null ? null : '## Summary\nold',
      summarizedAt: summarizedAt,
      summaryRequestedAt: requestedAt,
    );

void main() {
  testWidgets('a pending row shows the Summarizing pill; others do not',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = createResolvedTempSync('tangent-list-pending-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    addTearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });

    final int nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rows = [
      // Asked 30 s ago, last answer 10 min before that: in progress.
      _row(
        'pending',
        'Being summarized',
        requestedAt: nowSeconds - 30,
        summarizedAt: nowSeconds - 630,
      ),
      // Asked, and the answer already landed.
      _row(
        'answered',
        'Already summarized',
        requestedAt: nowSeconds - 120,
        summarizedAt: nowSeconds - 60,
      ),
      // Asked 11 min ago with no answer: given up on.
      _row('stale', 'Forgotten request', requestedAt: nowSeconds - 660),
      _row('plain', 'Never asked'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          foldersProvider.overrideWith((_) => Stream.value(const <Folder>[])),
          audioStorageProvider.overrideWithValue(storage),
          deletionEligibilityProvider
              .overrideWith((_) => Stream.value(const {})),
          dumpsProvider.overrideWith((_) => Stream.value(rows)),
        ],
        child: const MaterialApp(home: DumpsListScreen()),
      ),
    );
    // Bounded pumps: the pending pill's spinner animates forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final Finder pill =
        find.byKey(const ValueKey<String>('summary-pending-pill-pending'));
    expect(pill, findsOneWidget);
    expect(
      find.descendant(of: pill, matching: find.text('Summarizing…')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: pill,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    // The transcription pill still stands next to it.
    expect(
      find.byKey(const ValueKey<String>('transcription-pill-pending-completed')),
      findsOneWidget,
    );
    for (final String id in <String>['answered', 'stale', 'plain']) {
      expect(
        find.byKey(ValueKey<String>('summary-pending-pill-$id')),
        findsNothing,
        reason: '$id is not in progress',
      );
    }

    // The give-up: eleven minutes later with no answer, the pill is gone
    // even though no row change ever arrived.
    final DateTime start = DateTime.now();
    addTearDown(() => summaryPendingClock = DateTime.now);
    summaryPendingClock = () => start.add(const Duration(minutes: 11));
    await tester.pump(const Duration(minutes: 11));
    await tester.pump(const Duration(milliseconds: 100));
    expect(pill, findsNothing, reason: 'no signal for 10 min: stop spinning');
    summaryPendingClock = DateTime.now;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
