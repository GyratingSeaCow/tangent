// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/calendar_event_repository.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/widgets/voice_events_card.dart';

/// v1.35.0: the "Added to your calendar" card on the recording detail
/// screen — rows, the Google link tap, the syncing/flagged states, Undo.
void main() {
  late LocalDb db;
  late CalendarEventRepository repo;
  late List<Uri> opened;
  int ids = 0;
  const String dumpId = 'dump-1';

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    ids = 0;
    opened = <Uri>[];
    repo = CalendarEventRepository(
      db: db,
      idFactory: () => 'ev-${++ids}',
      now: () => DateTime.utc(2026, 9, 28, 20),
    );
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localDbProvider.overrideWithValue(db),
          calendarEventRepositoryProvider.overrideWithValue(repo),
          openExternalProvider.overrideWithValue((Uri u) async {
            opened.add(u);
            return true;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: VoiceEventsCard(dumpId: dumpId),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  }

  Future<CalendarEventRow> add({
    String title = 'Dentist',
    String start = '2026-10-01T14:00:00',
    String end = '2026-10-01T15:00:00',
    bool allDay = false,
    bool needsDate = false,
    String? link,
  }) async {
    final CalendarEventRow row = await repo.add(
      title: title,
      start: start,
      end: end,
      allDay: allDay,
      timeZone: 'America/New_York',
      needsDate: needsDate,
      sourceRef: dumpId,
    );
    if (link != null) {
      await db.applyRemoteCalendarEvent(
        id: row.id,
        title: title,
        start: start,
        end: end,
        allDay: allDay,
        timeZone: 'America/New_York',
        needsDate: needsDate,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        seq: 1,
        googleEventId: 'g-${row.id}',
        googleHtmlLink: link,
      );
    }
    return row;
  }

  testWidgets('no rows → no card at all', (tester) async {
    await mount(tester);
    expect(
      find.byKey(const ValueKey('voice-events-card-$dumpId')),
      findsNothing,
    );
    expect(find.text('Added to your calendar'), findsNothing);
    await unmount(tester);
  });

  testWidgets('timed and all-day rows format their when-line', (tester) async {
    await add(link: 'https://cal/1');
    await add(
      title: 'Car inspection',
      start: '2026-10-15',
      end: '2026-10-16',
      allDay: true,
      link: 'https://cal/2',
    );
    await mount(tester);
    expect(find.text('Added to your calendar'), findsOneWidget);
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('Thu Oct 1, 2:00 PM'), findsOneWidget);
    expect(find.text('Car inspection'), findsOneWidget);
    expect(find.text('Thu Oct 15'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsNWidgets(2));
    await unmount(tester);
  });

  testWidgets('row with a Google link opens it externally on tap',
      (tester) async {
    await add(link: 'https://calendar.google.com/event?eid=abc');
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('voice-event-ev-1')));
    await tester.pump();
    expect(opened, [Uri.parse('https://calendar.google.com/event?eid=abc')]);
    await unmount(tester);
  });

  testWidgets('row without a link says syncing and tap is a no-op',
      (tester) async {
    await add();
    await mount(tester);
    expect(find.text('Thu Oct 1, 2:00 PM · syncing…'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsNothing);
    await tester.tap(find.byKey(const ValueKey('voice-event-ev-1')));
    await tester.pump();
    expect(opened, isEmpty);
    await unmount(tester);
  });

  testWidgets('flagged row says no date said — tap to fix', (tester) async {
    await add(
      title: 'Renew passport',
      start: '2026-09-28',
      end: '2026-09-29',
      allDay: true,
      needsDate: true,
      link: 'https://cal/3',
    );
    await mount(tester);
    expect(find.text('today (no date said) — tap to fix'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('Undo soft-deletes every row and the card disappears',
      (tester) async {
    await add();
    await add(title: 'Oil change');
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('voice-events-undo-$dumpId')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(const ValueKey('voice-events-card-$dumpId')),
      findsNothing,
    );
    expect(find.text('Removed 2 events'), findsOneWidget);
    final List<CalendarEventRow> all = await repo.eventsFromSource(dumpId);
    expect(all.length, 2);
    expect(all.every((r) => r.deletedAt != null), isTrue);
    await unmount(tester);
  });

  test('describeEventWhen: noon/midnight and minutes', () {
    CalendarEventRow row(
      String start, {
      bool allDay = false,
      bool nd = false,
    }) =>
        CalendarEventRow(
          id: 'x',
          title: 't',
          start: start,
          end: start,
          allDay: allDay,
          timeZone: 'z',
          needsDate: nd,
          source: 'voice',
          createdAt: '',
          updatedAt: '',
          syncDirty: false,
        );
    expect(
      describeEventWhen(row('2026-10-01T12:00:00')),
      'Thu Oct 1, 12:00 PM',
    );
    expect(
      describeEventWhen(row('2026-10-01T00:30:00')),
      'Thu Oct 1, 12:30 AM',
    );
    expect(
      describeEventWhen(row('2026-09-28T14:00:00', nd: true)),
      'today, 2:00 PM (no date said) — tap to fix',
    );
  });
}
