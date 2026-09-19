// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/legacy_audio_storage_fixture.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_providers.dart';
import 'package:tangent/screens/home/home_screen.dart';

void main() {
  testWidgets('list renders every durable status and two independent filters',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-list-status-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    addTearDown(() async {
      await db.close();
      temp.deleteSync(recursive: true);
    });

    final rows = [
      _row('not-a', 'Brain without transcript'),
      _row('not-b', 'Meeting without transcript', mode: 'meeting'),
      _row('uploading', 'Uploading recording', status: 'uploading'),
      _row('queued', 'Queued meeting', mode: 'meeting', status: 'queued'),
      _row('running', 'Running recording', status: 'running'),
      _row(
        'done-a',
        'Completed recording',
        status: 'completed',
        transcript: 'first transcript',
      ),
      _row(
        'done-b',
        'Completed meeting',
        mode: 'meeting',
        status: 'completed',
        transcript: 'second transcript',
      ),
      _row('failed', 'Failed meeting', mode: 'meeting', status: 'failed'),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          audioStorageProvider.overrideWithValue(storage),
          // This status/filter presentation fixture has no bound storage owner.
          // Eligibility/lifetime behavior is covered by the selection and bound detail suites.
          deletionEligibilityProvider.overrideWith((_) => Stream.value(const {})),
          dumpsProvider.overrideWith((_) => Stream.value(rows)),
        ],
        child: const MaterialApp(home: DumpsListScreen()),
      ),
    );
    await _pumpData(tester);

    _expectPill('not-a', 'not-transcribed', 'Not transcribed');
    _expectPill('not-b', 'not-transcribed', 'Not transcribed');
    _expectPill('uploading', 'uploading', 'Uploading');
    _expectPill('queued', 'queued', 'Queued');
    _expectPill('running', 'running', 'Transcribing');
    _expectPill('done-a', 'completed', 'Transcribed');
    _expectPill('done-b', 'completed', 'Transcribed');
    _expectPill('failed', 'failed', 'Failed');

    // One bar, two dropdowns; the full option set lives inside the menus
    // (dumps_list_filter_bar_test proves the menu contents).
    expect(find.text('Mode · All'), findsOneWidget);
    expect(find.text('Transcript · All'), findsOneWidget);

    // Filters are dropdowns now: open the menu, then tap the same key.
    // Bounded pumps, not pumpAndSettle: the in-progress row's spinner
    // animates forever and pumpAndSettle would time out.
    await tester.tap(find.byKey(const ValueKey('mode-filter-menu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('mode-filter-meeting')));
    await _pumpData(tester);
    await tester.tap(find.byKey(const ValueKey('transcript-filter-menu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('transcript-filter-needsTranscript')),
    );
    await _pumpData(tester);

    expect(find.text('Meeting without transcript'), findsOneWidget);
    expect(find.text('Brain without transcript'), findsNothing);
    expect(find.text('Queued meeting'), findsNothing);
    expect(find.text('Completed meeting'), findsNothing);
    expect(find.text('Failed meeting'), findsNothing);

    await _disposeTree(tester);
  });

  testWidgets('list pill reacts from running to completed durable state',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final temp = Directory.systemTemp.createTempSync('tangent-list-reactive-');
    final db = LocalDb.forTesting(NativeDatabase.memory());
    final storage = AudioStorage.test(temp);
    final rows = StreamController<List<DumpRow>>();
    addTearDown(() async {
      await rows.close();
      await db.close();
      temp.deleteSync(recursive: true);
    });
    final running = _row('reactive', 'Reactive recording', status: 'running');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          audioStorageProvider.overrideWithValue(storage),
          // This status/filter presentation fixture has no bound storage owner.
          // Eligibility/lifetime behavior is covered by the selection and bound detail suites.
          deletionEligibilityProvider.overrideWith((_) => Stream.value(const {})),
          dumpsProvider.overrideWith((_) => rows.stream),
        ],
        child: const MaterialApp(home: DumpsListScreen()),
      ),
    );
    rows.add([running]);
    await _pumpData(tester);
    _expectPill('reactive', 'running', 'Transcribing');

    rows.add([
      running.copyWith(
        updatedAt: DateTime.utc(2026, 9, 15),
        transcript: const Value('Completed reactively'),
        transcriptionStatus: 'completed',
        transcriptionCompletedAt: Value(DateTime.utc(2026, 9, 15)),
      ),
    ]);
    await _pumpData(tester);

    expect(
      find.byKey(const ValueKey('transcription-pill-reactive-running')),
      findsNothing,
    );
    _expectPill('reactive', 'completed', 'Transcribed');

    await _disposeTree(tester);
  });
}

Future<void> _pumpData(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _disposeTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void _expectPill(String id, String status, String label) {
  final pill = find.byKey(ValueKey('transcription-pill-$id-$status'));
  expect(pill, findsOneWidget);
  expect(find.descendant(of: pill, matching: find.text(label)), findsOneWidget);
}

DumpRow _row(
  String id,
  String title, {
  String mode = 'brain_dump',
  String status = 'not_transcribed',
  String? transcript,
}) =>
    DumpRow(
      id: id,
      createdAt: DateTime.utc(2026, 9, 14),
      updatedAt: DateTime.utc(2026, 9, 14),
      mode: mode,
      durationSeconds: 9,
      title: title,
      transcript: transcript,
      audioPath: 'content://tangent/$id.opus',
      audioSizeBytes: 3,
      syncStatus: 'pending',
      syncAttempts: 0,
      transcriptionStatus: status,
      transcriptionAttempt: 0,
    );