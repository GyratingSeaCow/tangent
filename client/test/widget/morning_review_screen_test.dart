// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/home/morning_review_screen.dart';
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/theme/tangent_theme.dart';
import 'package:tangent/theme/tangent_tokens.dart';

/// v1.40 full-screen morning review (replaces the v1.39 Home card).
///
/// The boundary timer is replaced with [_NeverTimer] (a real "next 8:00"
/// timer would outlive the test and trip the pending-timer invariant), and
/// the database is closed INSIDE each test (drift's stream cache holds its
/// own short timer until close).
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
    bool pinned = false,
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
            pinned: Value(pinned),
          ),
        );
  }

  Future<void> insertTodo(
    String id,
    String body, {
    String? due,
    bool pinned = false,
  }) async {
    await db.into(db.todos).insert(
          TodosCompanion.insert(
            id: id,
            body: body,
            createdAt: '2026-09-28T10:00:00Z',
            updatedAt: '2026-09-28T10:00:00Z',
            dueDate: Value(due),
            pinned: Value(pinned),
          ),
        );
  }

  /// Home stand-in: the real app bar pair (sun LEFT of settings) and the
  /// invisible auto-presenter, without Home's unrelated provider graph.
  Future<ProviderContainer> mount(WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        localDbProvider.overrideWithValue(db),
        settingsStoreProvider.overrideWithValue(store),
        morningReviewClockProvider.overrideWithValue(() => morning),
        morningReviewTimerFactoryProvider
            .overrideWithValue((_, __) => _NeverTimer()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: tangentTheme(),
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Home'),
              actions: <Widget>[
                const MorningReviewSunButton(),
                IconButton(
                  key: const Key('settings'),
                  icon: const Icon(Icons.settings),
                  onPressed: () {},
                ),
              ],
            ),
            body: const Column(
              children: <Widget>[MorningReviewAutoPresenter(), Text('home')],
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return container;
  }

  Future<void> unmount(WidgetTester tester, ProviderContainer c) async {
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  }

  Finder screen() => find.byKey(MorningReviewScreen.screenKey);
  Finder sun() => find.byKey(MorningReviewSunButton.buttonKey);

  testWidgets('auto-presents full screen on daybreak blue, once per morning',
      (tester) async {
    await insertDump('Standup', DateTime(2026, 9, 29, 9, 30));
    final ProviderContainer c = await mount(tester);

    expect(screen(), findsOneWidget);
    final Scaffold scaffold = tester.widget<Scaffold>(screen());
    expect(scaffold.backgroundColor, TangentColors.daybreak);
    // Covers the whole window, not a card.
    expect(
      tester.getSize(screen()),
      tester.view.physicalSize / tester.view.devicePixelRatio,
    );
    expect(store.morningReviewViewedDay, '2026-09-30');

    await tester.tap(find.byKey(MorningReviewScreen.closeKey));
    await settle(tester);
    expect(screen(), findsNothing);
    expect(find.text('home'), findsOneWidget);

    // Same morning, fresh Home mount: does NOT present again.
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
    final ProviderContainer again = await mount(tester);
    expect(screen(), findsNothing);
    await unmount(tester, again);
  });

  testWidgets('sun icon sits left of settings, reopens, live-hides when off',
      (tester) async {
    await store.setMorningReviewViewedDay('2026-09-30');
    final ProviderContainer c = await mount(tester);
    expect(screen(), findsNothing, reason: 'already viewed today');
    expect(sun(), findsOneWidget);
    expect(
      tester.getCenter(sun()).dx,
      lessThan(tester.getCenter(find.byKey(const Key('settings'))).dx),
    );
    // Plain: no badge.
    expect(
      find.descendant(of: sun(), matching: find.byType(Badge)),
      findsNothing,
    );

    await tester.tap(sun());
    await settle(tester);
    expect(screen(), findsOneWidget);
    // Nothing anywhere: a calm empty state, not hollow headings.
    expect(find.byKey(MorningReviewScreen.emptyKey), findsOneWidget);
    expect(find.byKey(MorningReviewScreen.capturesKey), findsNothing);
    await tester.tap(find.byKey(MorningReviewScreen.closeKey));
    await settle(tester);

    c.read(morningReviewEnabledProvider.notifier).state = false;
    await settle(tester);
    expect(sun(), findsNothing);
    c.read(morningReviewEnabledProvider.notifier).state = true;
    await settle(tester);
    expect(sun(), findsOneWidget);
    await unmount(tester, c);
  });

  testWidgets('empty morning still auto-presents the calm empty state',
      (tester) async {
    final ProviderContainer c = await mount(tester);
    expect(screen(), findsOneWidget);
    expect(find.byKey(MorningReviewScreen.emptyKey), findsOneWidget);
    expect(store.morningReviewViewedDay, '2026-09-30');
    await unmount(tester, c);
  });

  testWidgets('setting OFF: no sun and no auto-present', (tester) async {
    store = SettingsStore(morningReviewEnabled: false);
    await insertDump('Standup', DateTime(2026, 9, 29, 9, 30));
    final ProviderContainer c = await mount(tester);
    expect(sun(), findsNothing);
    expect(screen(), findsNothing);
    expect(store.morningReviewViewedDay, isNot('2026-09-30'));
    await unmount(tester, c);
  });

  testWidgets(
      'lists ALL yesterday captures uncapped, due to-dos and pinned items',
      (tester) async {
    for (int i = 0; i < 9; i++) {
      await insertDump('Capture $i', DateTime(2026, 9, 29, 8 + i));
    }
    await insertDump('Today already', DateTime(2026, 9, 30, 8, 30));
    await insertDump(
      'Pinned plan',
      DateTime(2026, 9, 1),
      pinned: true,
    );
    await insertTodo('t-due', 'Call the plumber', due: '2026-09-30');
    await insertTodo('t-late', 'Return library book', due: '2026-09-27');
    await insertTodo('t-later', 'Renew passport', due: '2026-10-09');
    await insertTodo('t-pin', 'Weekly reset', pinned: true);
    final ProviderContainer c = await mount(tester);

    expect(screen(), findsOneWidget);
    // Scroll surface: every capture is reachable, no five-item cap.
    for (int i = 0; i < 9; i++) {
      await tester.scrollUntilVisible(
        find.byKey(MorningReviewScreen.captureKey('Capture $i')),
        120,
        scrollable: find.descendant(
          of: screen(),
          matching: find.byType(Scrollable),
        ),
      );
    }
    expect(find.text('9 recordings'), findsOneWidget);
    expect(find.text('Today already'), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(MorningReviewScreen.todoKey('t-late')),
      120,
      scrollable:
          find.descendant(of: screen(), matching: find.byType(Scrollable)),
    );
    expect(find.byKey(MorningReviewScreen.todoKey('t-due')), findsOneWidget);
    expect(find.text('Overdue'), findsOneWidget);
    expect(find.byKey(MorningReviewScreen.todoKey('t-later')), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(MorningReviewScreen.pinKey('t-pin')),
      120,
      scrollable:
          find.descendant(of: screen(), matching: find.byType(Scrollable)),
    );
    expect(
      find.byKey(MorningReviewScreen.pinKey('Pinned plan')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await unmount(tester, c);
  });
}

/// Fixed pumps: the route transition is 420 ms and the screen streams; a
/// pumpAndSettle would also work but fixed frames keep timing explicit.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}
