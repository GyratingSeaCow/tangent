// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/screens/home/morning_review_screen.dart';
import 'package:tangent/services/summaries_client.dart';
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

  /// The injected clock reads this, so a test can roll to the next morning.
  late DateTime clockNow;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    store = SettingsStore(morningReviewEnabled: true);
    clockNow = morning;
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
  Future<ProviderContainer> mount(
    WidgetTester tester, {
    int presenters = 1,
    Future<MorningBriefResult> Function(String isoDay)? brief,
  }) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        localDbProvider.overrideWithValue(db),
        settingsStoreProvider.overrideWithValue(store),
        morningBriefFetcherProvider.overrideWithValue(
          brief ?? (_) async => const MorningBriefNotGenerated(),
        ),
        morningReviewClockProvider.overrideWithValue(() => clockNow),
        morningReviewTimerFactoryProvider
            .overrideWithValue((_, _) => _NeverTimer()),
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
            body: Column(
              children: <Widget>[
                for (int i = 0; i < presenters; i++)
                  const MorningReviewAutoPresenter(),
                const Text('home'),
              ],
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
    // Overdue is its own section, not filed under "Due today".
    expect(find.text('OVERDUE'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(MorningReviewScreen.overdueKey),
        matching: find.byKey(MorningReviewScreen.todoKey('t-late')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(MorningReviewScreen.dueKey),
        matching: find.byKey(MorningReviewScreen.todoKey('t-late')),
      ),
      findsNothing,
    );
    expect(find.text('Sep 27'), findsOneWidget);
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

  testWidgets('dark status-bar icons over daybreak blue', (tester) async {
    final ProviderContainer c = await mount(tester);
    final AnnotatedRegion<SystemUiOverlayStyle> region =
        tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find
          .ancestor(
            of: screen(),
            matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          )
          .first,
    );
    expect(region.value.statusBarIconBrightness, Brightness.dark);
    expect(region.value.statusBarBrightness, Brightness.light);
    // Route-scoped status bar only: any nav-bar field here would never be
    // reverted (Flutter sends only non-null fields) and leaks app-wide.
    expect(region.value.systemNavigationBarColor, isNull);
    expect(region.value.systemNavigationBarIconBrightness, isNull);
    expect(region.value.systemNavigationBarDividerColor, isNull);
    expect(region.value.systemNavigationBarContrastEnforced, isNull);
    await unmount(tester, c);
  });

  testWidgets('never double-pushes when the fire time passes while open',
      (tester) async {
    await insertDump('Standup', DateTime(2026, 9, 29, 9, 30));
    final ProviderContainer c = await mount(tester);
    expect(screen(), findsOneWidget);
    // Left open past the NEXT morning's fire time: the boundary timer
    // invalidates the briefing and a new, unviewed review day appears.
    clockNow = DateTime(2026, 10, 1, 9);
    c.invalidate(morningBriefingProvider);
    await settle(tester);
    expect(screen(), findsOneWidget, reason: 'one review route, not two');
    await tester.tap(find.byKey(MorningReviewScreen.closeKey));
    await settle(tester);
    await settle(tester);
    // The open screen recorded the new day when it rebuilt, so closing
    // returns to Home rather than presenting again.
    expect(store.morningReviewViewedDay, '2026-10-01');
    expect(screen(), findsNothing);
    await unmount(tester, c);
  });

  testWidgets('does not present over another screen; waits for Home',
      (tester) async {
    await tester.runAsync(() => store.setMorningReviewViewedDay('2026-09-30'));
    final ProviderContainer c = await mount(tester);
    expect(screen(), findsNothing);
    // User navigates away from Home.
    final NavigatorState nav = tester.state(find.byType(Navigator));
    unawaited(
      nav.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('elsewhere')),
        ),
      ),
    );
    await settle(tester);
    // A new review morning becomes due while elsewhere.
    await tester.runAsync(() => store.setMorningReviewViewedDay(''));
    c.invalidate(morningBriefingProvider);
    await settle(tester);
    expect(screen(), findsNothing, reason: 'never over a non-Home route');
    expect(find.text('elsewhere'), findsOneWidget);
    // Back on Home: now it presents.
    nav.pop();
    await settle(tester);
    await settle(tester);
    expect(screen(), findsOneWidget);
    await unmount(tester, c);
  });

  testWidgets('source lines are rounded bordered cards', (tester) async {
    await insertDump('Standup', DateTime(2026, 9, 29, 9, 30));
    final ProviderContainer c = await mount(tester);
    expect(screen(), findsOneWidget);

    final Finder line = find.byKey(MorningReviewScreen.captureKey('Standup'));
    expect(tester.getSize(line).height, greaterThanOrEqualTo(58));
    final Container card = tester.widget<Container>(
      find.descendant(of: line, matching: find.byType(Container)).first,
    );
    final BoxDecoration deco = card.decoration! as BoxDecoration;
    expect(
      deco.borderRadius,
      BorderRadius.circular(TangentShapes.panelRadius),
    );
    expect(deco.border, isNotNull, reason: 'source cards carry an edge');
    await unmount(tester, c);
  });

  testWidgets(
      'two presents scheduled in one frame open ONE review '
      '(post-frame isCurrent re-check)', (tester) async {
    // Two presenters both see an unviewed morning in the same build and
    // each schedules a post-frame present — the same shape as any rebuild
    // landing before the first push. The first push covers Home
    // synchronously, so the second callback must find Home not current.
    final ProviderContainer c = await mount(tester, presenters: 2);
    expect(screen(), findsOneWidget);
    final NavigatorState nav = tester.state(find.byType(Navigator));
    nav.pop();
    await settle(tester);
    expect(screen(), findsNothing, reason: 'no second review underneath');
    expect(find.text('home'), findsOneWidget);
    await unmount(tester, c);
  });

  group('Morning Brief (v1.41)', () {
    final List<String> asked = <String>[];
    setUp(asked.clear);

    // Every brief test has one capture from yesterday, so "the rest of the
    // review stands" is observable.
    Future<ProviderContainer> mountWith(
      WidgetTester tester,
      Future<MorningBriefResult> Function(String) brief,
    ) async {
      await insertDump('Standup', DateTime(2026, 9, 29, 9, 30));
      return mount(tester, brief: brief);
    }

    Future<MorningBriefResult> Function(String) answer(MorningBriefResult r) =>
        (String day) async {
          asked.add(day);
          return r;
        };

    Finder briefCard() => find.byKey(MorningReviewScreen.briefKey);

    testWidgets('renders the brief markdown at the TOP of the review',
        (tester) async {
      final ProviderContainer c = await mountWith(
        tester,
        answer(
          MorningBriefReady(
            date: '2026-09-30',
            briefMd: 'A busy day.\n\n**Highlights**\n- Launch moved.',
            generatedAt: DateTime(2026, 9, 30, 5),
            model: 'qwen',
          ),
        ),
      );
      expect(screen(), findsOneWidget);
      expect(asked, <String>['2026-09-30'], reason: 'one GET per open');
      expect(briefCard(), findsOneWidget);
      expect(find.text('YOUR BRIEF'), findsOneWidget);
      expect(find.textContaining('A busy day.'), findsOneWidget);
      expect(find.textContaining('Launch moved.'), findsOneWidget);
      // Above every section (slivers aren't RenderBoxes: compare the
      // brief's heading text with the first capture row).
      final double briefY = tester.getTopLeft(find.text('YOUR BRIEF')).dy;
      final double captureY = tester
          .getTopLeft(find.byKey(MorningReviewScreen.captureKey('Standup')))
          .dy;
      expect(briefY, lessThan(captureY));
      await unmount(tester, c);
    });

    for (final (String name, MorningBriefResult r)
        in <(String, MorningBriefResult)>[
      ('409 not installed', const MorningBriefUnavailable(disabled: false)),
      ('409 disabled', const MorningBriefUnavailable(disabled: true)),
      ('404 not generated', const MorningBriefNotGenerated()),
      (
        'empty',
        MorningBriefReady(
          date: '2026-09-30',
          briefMd: '  \n',
          generatedAt: DateTime(2026),
          model: 'qwen',
        ),
      ),
    ]) {
      testWidgets('hidden on $name; the rest of the review stands',
          (tester) async {
        final ProviderContainer c = await mountWith(tester, answer(r));
        expect(screen(), findsOneWidget);
        expect(briefCard(), findsNothing);
        expect(find.text('YOUR BRIEF'), findsNothing);
        expect(find.byKey(MorningReviewScreen.capturesKey), findsOneWidget);
        await unmount(tester, c);
      });
    }

    testWidgets('a failed fetch hides the brief, no error surfaced',
        (tester) async {
      final ProviderContainer c = await mountWith(
        tester,
        (_) async => throw Exception('offline'),
      );
      expect(screen(), findsOneWidget);
      expect(briefCard(), findsNothing);
      expect(tester.takeException(), isNull);
      await unmount(tester, c);
    });

    testWidgets('a slow fetch never blocks the review (no spinner)',
        (tester) async {
      final Completer<MorningBriefResult> pending =
          Completer<MorningBriefResult>();
      final ProviderContainer c =
          await mountWith(tester, (_) => pending.future);
      expect(screen(), findsOneWidget);
      expect(find.byKey(MorningReviewScreen.capturesKey), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      pending.complete(const MorningBriefNotGenerated());
      await settle(tester);
      await unmount(tester, c);
    });
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
