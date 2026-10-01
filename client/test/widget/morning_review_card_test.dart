// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/home/morning_review_card.dart';
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/theme/tangent_theme.dart';

/// Ask-arc queued item 2, the Home card: yesterday's captures only, a
/// light-blue panel that stays — across remounts — until viewed, then
/// tucks away; toggled off it renders nothing at all.
///
/// The card's boundary timer is replaced with [_NeverTimer]: a real timer
/// armed for "next 8:00" would outlive the test and trip the
/// pending-timer invariant. Same reason the database is closed INSIDE
/// each test (the voice_todos_card pattern): drift's stream cache holds
/// its own short timer until close.
class _NeverTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => false;

  @override
  int get tick => 0;
}

void main() {
  late LocalDb db;
  late SettingsStore store;

  /// The morning of 2026-09-30, after the default 08:00.
  final DateTime morning = DateTime(2026, 9, 30, 9);

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    store = SettingsStore(morningReviewEnabled: true);
  });

  Future<void> insertDump(
    String id,
    DateTime createdAt, {
    String mode = 'brain_dump',
  }) async {
    await db.into(db.dumps).insert(
          DumpsCompanion.insert(
            id: id,
            createdAt: createdAt,
            updatedAt: createdAt,
            mode: mode,
            durationSeconds: 30,
            title: id,
            audioPath: '/synthetic/$id.opus',
            audioSizeBytes: 1024,
            syncStatus: 'local_only',
          ),
        );
  }

  Future<void> mount(WidgetTester tester, {DateTime? now}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          localDbProvider.overrideWithValue(db),
          settingsStoreProvider.overrideWithValue(store),
          morningReviewClockProvider.overrideWithValue(() => now ?? morning),
          morningReviewTimerFactoryProvider
              .overrideWithValue((_, __) => _NeverTimer()),
        ],
        child: MaterialApp(
          theme: tangentTheme(),
          home: const Scaffold(
            body: SingleChildScrollView(child: MorningReviewCard()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // Let the panel's entrance (AnimatedSwitcher + AnimatedSize) finish so
    // taps land on settled geometry.
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  }

  Finder card() => find.byKey(MorningReviewCard.cardKey);

  testWidgets("lists yesterday's captures only, with the header lines",
      (tester) async {
    await insertDump('Standup', DateTime(2026, 9, 29, 9, 30));
    await insertDump('Walk thought', DateTime(2026, 9, 29, 18, 5),
        mode: 'text_note',);
    await insertDump('Today already', DateTime(2026, 9, 30, 8, 30));
    await insertDump('Two days back', DateTime(2026, 9, 28, 12));
    await mount(tester);

    expect(card(), findsOneWidget);
    expect(find.text('Morning review'), findsOneWidget);
    expect(find.text('Yesterday \u00B7 1 recording \u00B7 1 note'),
        findsOneWidget,);
    expect(find.text('Standup'), findsOneWidget);
    expect(find.text('Walk thought'), findsOneWidget);
    expect(find.text('Today already'), findsNothing);
    expect(find.text('Two days back'), findsNothing);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('long days fold into "and N more"', (tester) async {
    for (int i = 0; i < kMorningReviewCardMaxItems + 2; i++) {
      await insertDump('Capture $i', DateTime(2026, 9, 29, 8 + i));
    }
    await mount(tester);

    expect(card(), findsOneWidget);
    expect(find.text('Capture 0'), findsOneWidget);
    expect(find.text('Capture ${kMorningReviewCardMaxItems - 1}'),
        findsOneWidget,);
    expect(find.text('Capture $kMorningReviewCardMaxItems'), findsNothing);
    expect(find.byKey(MorningReviewCard.moreKey), findsOneWidget);
    expect(find.text('and 2 more'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('stays across remounts until viewed, then tucks away',
      (tester) async {
    await insertDump('Standup', DateTime(2026, 9, 29, 9, 30));
    await mount(tester);
    expect(card(), findsOneWidget);

    // A fresh mount — the app restarted — still shows the unviewed card.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await mount(tester);
    expect(card(), findsOneWidget);

    // Viewing tucks it: the viewed day persists and the panel folds.
    await tester.tap(find.byKey(MorningReviewCard.tuckKey));
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(store.morningReviewViewedDay, '2026-09-30');
    expect(card(), findsNothing);

    // And it stays tucked on the next mount of the same morning.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await mount(tester);
    expect(card(), findsNothing);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets("viewing YESTERDAY's review does not tuck today's",
      (tester) async {
    store = SettingsStore(
      morningReviewEnabled: true,
      morningReviewViewedDay: '2026-09-29',
    );
    await insertDump('Standup', DateTime(2026, 9, 29, 9, 30));
    await mount(tester);
    expect(card(), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('before the chosen time the card still shows the prior morning',
      (tester) async {
    // 07:00 on the 30th, review time 08:00: the standing review is still
    // the 29th's, whose "yesterday" is the 28th.
    await insertDump('Old capture', DateTime(2026, 9, 28, 15));
    await insertDump('Yesterday capture', DateTime(2026, 9, 29, 15));
    await mount(tester, now: DateTime(2026, 9, 30, 7));

    expect(card(), findsOneWidget);
    expect(find.text('Old capture'), findsOneWidget);
    expect(find.text('Yesterday capture'), findsNothing);

    await unmount(tester);
  });

  testWidgets('toggled off: no card at all', (tester) async {
    store = SettingsStore();
    await insertDump('Standup', DateTime(2026, 9, 29, 9, 30));
    await mount(tester);

    expect(card(), findsNothing);
    expect(find.text('Morning review'), findsNothing);
    expect(find.text('Standup'), findsNothing);
    expect(tester.takeException(), isNull);

    await unmount(tester);
  });

  testWidgets('no card when yesterday captured nothing — no empty shell',
      (tester) async {
    await insertDump('Today already', DateTime(2026, 9, 30, 8, 30));
    await mount(tester);

    expect(card(), findsNothing);
    expect(find.text('Morning review'), findsNothing);

    await unmount(tester);
  });
}
