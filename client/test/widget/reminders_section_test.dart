// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/settings_store.dart';
import 'package:tangent/screens/settings/reminders_section.dart';
import 'package:tangent/screens/settings/settings_screen.dart'
    show settingsStoreProvider;
import 'package:tangent/services/due_reminder_scheduler.dart';
import 'package:tangent/services/morning_review_scheduler.dart';

import '../support/fake_due_reminder_port.dart';

/// Spec 2026-09-27 Half B, N4: the Reminders section. The morning review
/// (Ask-arc queued item 2) lives under the same heading on its own
/// scheduler and port; its tests sit alongside.
void main() {
  late FakeDueReminderPort port;
  late FakeDueReminderPort morningPort;
  late SettingsStore store;
  List<TodoRow> todos = <TodoRow>[];

  setUp(() {
    port = FakeDueReminderPort();
    morningPort = FakeDueReminderPort();
    store = SettingsStore();
    todos = <TodoRow>[];
  });

  Widget host({bool supported = true}) => ProviderScope(
        overrides: <Override>[
          settingsStoreProvider.overrideWithValue(store),
          remindersSupportedProvider.overrideWithValue(supported),
          dueReminderPortProvider.overrideWithValue(port),
          dueReminderSchedulerProvider.overrideWith(
            (ref) => DueReminderScheduler(
              port: port,
              loadTodos: () async => todos,
              now: () => DateTime(2026, 9, 27, 6, 30),
            ),
          ),
          morningReviewPortProvider.overrideWithValue(morningPort),
          morningReviewSchedulerProvider.overrideWith(
            (ref) => MorningReviewScheduler(
              port: morningPort,
              loadDumps: () async => <DumpRow>[],
              now: () => DateTime(2026, 9, 27, 6, 30),
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: RemindersSection())),
        ),
      );

  Finder switchFinder() => find.byKey(RemindersSection.enabledKey);
  SwitchListTile theSwitch(WidgetTester t) =>
      t.widget<SwitchListTile>(switchFinder());
  ListTile timeRow(WidgetTester t) =>
      t.widget<ListTile>(find.byKey(RemindersSection.timeKey));
  String statusText(WidgetTester t) =>
      t.widget<Text>(find.byKey(RemindersSection.statusKey)).data!;

  testWidgets('hidden entirely on unsupported hosts', (tester) async {
    await tester.pumpWidget(host(supported: false));
    await tester.pump();
    expect(switchFinder(), findsNothing);
    expect(find.text('Reminders'), findsNothing);
  });

  testWidgets('remindersSupportedProvider is true on this desktop host',
      (tester) async {
    // Half A: the production gate admits Linux and Windows, not just
    // Android. The test host IS one of those, so the real provider says so.
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(remindersSupportedProvider), isTrue);
  });

  testWidgets('visible on Linux/Windows via the provider override',
      (tester) async {
    await tester.pumpWidget(host(supported: true));
    await tester.pump();
    expect(switchFinder(), findsOneWidget);
    expect(find.text('Reminders'), findsOneWidget);
    expect(
      find.text(
        'Shows a system notification each morning listing to-dos due today.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Open system settings hidden when the port cannot open them',
      (tester) async {
    port.grant = false;
    port.canOpenSettings = false;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(switchFinder());
    await tester.pumpAndSettle();
    expect(statusText(tester), contains('blocked'));
    expect(find.byKey(RemindersSection.openSettingsKey), findsNothing);
  });

  testWidgets('off by default; time row disabled while off', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    expect(theSwitch(tester).value, isFalse);
    expect(timeRow(tester).enabled, isFalse);
    expect(timeRow(tester).onTap, isNull);
    expect(statusText(tester), 'Off');
    expect(port.scheduledAt, isEmpty);
    expect(port.permissionRequests, 0);
  });

  testWidgets('enabling asks permission, schedules, persists; status granted',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(switchFinder());
    await tester.pumpAndSettle();
    expect(port.permissionRequests, 1);
    expect(port.scheduledAt, <DateTime>[DateTime(2026, 9, 27, 7)]);
    expect(store.remindersEnabled, isTrue);
    expect(theSwitch(tester).value, isTrue);
    expect(timeRow(tester).enabled, isTrue);
    expect(statusText(tester), startsWith('Next: '));
    expect(statusText(tester), contains('7:00 AM'));
    expect(find.byKey(RemindersSection.openSettingsKey), findsNothing);
  });

  testWidgets('denied permission: says so, offers system settings, no alarm',
      (tester) async {
    port.grant = false;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(switchFinder());
    await tester.pumpAndSettle();
    expect(port.permissionRequests, 1);
    expect(port.scheduledAt, isEmpty);
    expect(
      statusText(tester),
      'Notifications blocked \u2014 open system settings',
    );
    await tester.tap(find.byKey(RemindersSection.openSettingsKey));
    await tester.pump();
    expect(port.openSettingsCalls, 1);
  });

  testWidgets('inexact fallback is stated in the status line', (tester) async {
    port.exact = false;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(switchFinder());
    await tester.pumpAndSettle();
    expect(port.scheduledExact, <bool>[false]);
    expect(statusText(tester), contains('exact alarms not allowed'));
  });

  testWidgets('disabling cancels and persists off', (tester) async {
    store = SettingsStore(remindersEnabled: true);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    // Already on from a previous session: re-armed on show.
    expect(port.scheduledAt, hasLength(1));
    await tester.tap(switchFinder());
    await tester.pumpAndSettle();
    expect(port.cancels, 1);
    expect(store.remindersEnabled, isFalse);
    expect(theSwitch(tester).value, isFalse);
    expect(statusText(tester), 'Off');
  });

  testWidgets('time picker changes the minute and re-schedules',
      (tester) async {
    store = SettingsStore(remindersEnabled: true);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(RemindersSection.timeKey));
    await tester.pumpAndSettle();
    // Switch the dialog to keyboard entry and type 8:15.
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final Finder fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '8');
    await tester.enterText(fields.at(1), '15');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(store.reminderMinuteOfDay, 8 * 60 + 15);
    expect(port.scheduledAt.last, DateTime(2026, 9, 27, 8, 15));
    expect(timeRow(tester).subtitle, isA<Text>());
    expect(statusText(tester), contains('8:15 AM'));
  });

  // ---- Morning review (Ask-arc queued item 2) ---------------------------

  Finder morningSwitchFinder() =>
      find.byKey(RemindersSection.morningEnabledKey);
  SwitchListTile morningSwitch(WidgetTester t) =>
      t.widget<SwitchListTile>(morningSwitchFinder());
  ListTile morningTimeRow(WidgetTester t) =>
      t.widget<ListTile>(find.byKey(RemindersSection.morningTimeKey));
  String morningStatusText(WidgetTester t) =>
      t.widget<Text>(find.byKey(RemindersSection.morningStatusKey)).data!;

  testWidgets('morning review: off by default at 8:00; row disabled',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    expect(morningSwitch(tester).value, isFalse);
    expect(morningTimeRow(tester).enabled, isFalse);
    expect(morningTimeRow(tester).onTap, isNull);
    expect(morningStatusText(tester), 'Off');
    // The default time is the spec's 8:00, shown even while off.
    expect(find.text('8:00 AM'), findsOneWidget);
    expect(morningPort.scheduledAt, isEmpty);
    expect(morningPort.permissionRequests, 0);
  });

  testWidgets(
      'enabling the morning review asks permission, schedules 08:00, '
      'persists — and never touches the due reminder', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(morningSwitchFinder());
    await tester.pumpAndSettle();
    expect(morningPort.permissionRequests, 1);
    expect(morningPort.scheduledAt, <DateTime>[DateTime(2026, 9, 27, 8)]);
    expect(store.morningReviewEnabled, isTrue);
    expect(morningSwitch(tester).value, isTrue);
    expect(morningTimeRow(tester).enabled, isTrue);
    expect(morningStatusText(tester), startsWith('Next: '));
    expect(morningStatusText(tester), contains('8:00 AM'));
    // Its own alarm, not the due reminder's.
    expect(port.permissionRequests, 0);
    expect(port.scheduledAt, isEmpty);
    expect(store.remindersEnabled, isFalse);
  });

  testWidgets('disabling the morning review cancels and persists off',
      (tester) async {
    store = SettingsStore(morningReviewEnabled: true);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    // Already on from a previous session: re-armed on show.
    expect(morningPort.scheduledAt, hasLength(1));
    await tester.tap(morningSwitchFinder());
    await tester.pumpAndSettle();
    expect(morningPort.cancels, 1);
    expect(store.morningReviewEnabled, isFalse);
    expect(morningSwitch(tester).value, isFalse);
    expect(morningStatusText(tester), 'Off');
  });

  testWidgets('morning review denied: says so and offers system settings',
      (tester) async {
    morningPort.grant = false;
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(morningSwitchFinder());
    await tester.pumpAndSettle();
    expect(morningPort.permissionRequests, 1);
    expect(morningPort.scheduledAt, isEmpty);
    expect(
      morningStatusText(tester),
      'Notifications blocked — open system settings',
    );
  });

  testWidgets('morning time picker changes the minute and re-schedules',
      (tester) async {
    store = SettingsStore(morningReviewEnabled: true);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(RemindersSection.morningTimeKey));
    await tester.pumpAndSettle();
    // Switch the dialog to keyboard entry and type 9:30.
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final Finder fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '9');
    await tester.enterText(fields.at(1), '30');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(store.morningReviewMinuteOfDay, 9 * 60 + 30);
    expect(morningPort.scheduledAt.last, DateTime(2026, 9, 27, 9, 30));
    expect(morningTimeRow(tester).subtitle, isA<Text>());
    expect(morningStatusText(tester), contains('9:30 AM'));
  });
}
