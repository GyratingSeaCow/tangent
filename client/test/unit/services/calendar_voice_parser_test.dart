// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/dump_mode.dart';
import 'package:tangent/services/calendar_voice_parser.dart';
import 'package:tangent/services/voice_date_grammar.dart';

/// Spec: docs/design/2026-09-28-voice-calendar-events.md — trigger family,
/// date + time grammar table, the C3 mode rule. Recorded on Monday
/// 2026-09-28 at 20:00 local for every case.
void main() {
  final DateTime on = DateTime(2026, 9, 28, 20);
  List<VoiceCalendarEvent> p(String t, {DumpMode mode = DumpMode.brainDump}) =>
      CalendarVoiceParser.parse(t, recordedOn: on, mode: mode);

  group('CalendarVoiceParser', () {
    test('date + time → timed one-hour event, title stripped of the phrase',
        () {
      final VoiceCalendarEvent e =
          p('so anyway add the dentist Thursday at two to my calendar').single;
      expect(e.title, 'The dentist');
      expect(e.start, '2026-10-01T14:00:00');
      expect(e.end, '2026-10-01T15:00:00');
      expect(e.allDay, isFalse);
      expect(e.needsDate, isFalse);
    });

    test(
        'phrase may follow the trigger too: "add to my calendar X Thursday at 2"',
        () {
      final VoiceCalendarEvent e =
          p('add to my calendar dentist Thursday at 2 pm').single;
      expect(e.title, 'Dentist');
      expect(e.start, '2026-10-01T14:00:00');
    });

    test('date only → all-day, end is the next day (Google exclusive end)', () {
      final VoiceCalendarEvent e =
          p('put the car inspection on my calendar for October 15th').single;
      expect(e.start, '2026-10-15');
      expect(e.end, '2026-10-16');
      expect(e.allDay, isTrue);
      expect(e.needsDate, isFalse);
      expect(e.title, 'The car inspection');
    });

    test('no date, brain dump → today all-day, flagged', () {
      final VoiceCalendarEvent e =
          p('add this to my calendar renew the passport').single;
      expect(e.start, '2026-09-28');
      expect(e.end, '2026-09-29');
      expect(e.allDay, isTrue);
      expect(e.needsDate, isTrue);
      expect(e.title, 'Renew the passport');
    });

    test('time only, brain dump → today at that time, flagged', () {
      final VoiceCalendarEvent e = p('calendar this dentist at 2').single;
      expect(e.start, '2026-09-28T14:00:00');
      expect(e.end, '2026-09-28T15:00:00');
      expect(e.allDay, isFalse);
      expect(e.needsDate, isTrue);
      expect(e.title, 'Dentist');
    });

    test('no date, MEETING → skipped (C3)', () {
      expect(
        p('we should put that on the calendar', mode: DumpMode.meeting),
        isEmpty,
      );
      expect(
        p('calendar this dentist at 2', mode: DumpMode.meeting),
        isEmpty,
        reason: 'time-only counts as no date',
      );
    });

    test('dated, MEETING → still created', () {
      final VoiceCalendarEvent e = p(
        'add to my calendar sprint review Friday at 10',
        mode: DumpMode.meeting,
      ).single;
      expect(e.start, '2026-10-02T10:00:00');
      expect(e.needsDate, isFalse);
    });

    test('text note never captures', () {
      expect(
        p('add to my calendar dentist Thursday at 2', mode: DumpMode.textNote),
        isEmpty,
      );
    });

    test('two triggers → two events, spans split at the next trigger', () {
      final List<VoiceCalendarEvent> es = p(
        'add to my calendar dentist Thursday at two and also put this on my '
        'calendar oil change Saturday',
      );
      expect(es.map((VoiceCalendarEvent e) => e.title), <String>[
        'Dentist',
        'Oil change',
      ]);
      expect(es[0].start, '2026-10-01T14:00:00');
      expect(es[1].start, '2026-10-03');
    });

    test('one event per trigger — commas and "and" do NOT split', () {
      final VoiceCalendarEvent e =
          p('add to my calendar lunch with Sam and Alex tomorrow').single;
      expect(e.title, 'Lunch with Sam and Alex');
      expect(e.start, '2026-09-29');
    });

    test('no trigger → nothing; the To Do trigger is not a calendar trigger',
        () {
      expect(p('remind me to call mom tomorrow'), isEmpty);
      expect(p('add that to my to do list dentist Thursday'), isEmpty);
    });

    test('empty title after stripping the phrase → nothing', () {
      expect(p('add this to my calendar tomorrow'), isEmpty);
      expect(p('add this to my calendar'), isEmpty);
      expect(p('add this to my calendar.'), isEmpty);
    });

    test('trigger spellings: the/my, google, optional colon, case', () {
      expect(
        p('Add It To The Google Calendar: dentist Thursday').single.title,
        'Dentist',
      );
      expect(
        p('put this on the calendar dentist Thursday').single.title,
        'Dentist',
      );
      expect(
        p('add to my google calendar dentist Thursday').single.title,
        'Dentist',
      );
    });

    test('Whisper punctuation after the trigger is cleaned', () {
      final VoiceCalendarEvent e =
          p('add this to my calendar. Dentist Thursday at 2.').single;
      expect(e.title, 'Dentist');
      expect(e.start, '2026-10-01T14:00:00');
    });

    test('time before the date works too ("at 2 on Thursday")', () {
      final VoiceCalendarEvent e =
          p('add to my calendar dentist at 2 on Thursday').single;
      expect(e.start, '2026-10-01T14:00:00');
      expect(e.title, 'Dentist');
    });

    test('title is capped at 200 characters', () {
      final String long = List<String>.filled(60, 'word').join(' ');
      final VoiceCalendarEvent e =
          p('add to my calendar $long tomorrow').single;
      expect(e.title.length, lessThanOrEqualTo(200));
    });

    test('recording zone: the event carries the local IANA zone name', () {
      final VoiceCalendarEvent e =
          p('add to my calendar dentist Thursday at 2').single;
      expect(e.timeZone, isNotEmpty);
    });
  });

  group('parseTimePhrase', () {
    test('bare hours: 1-7 pm, 8-11 am, 12 noon', () {
      expect(parseTimePhrase('at 3')!.hour, 15);
      expect(parseTimePhrase('at 7')!.hour, 19);
      expect(parseTimePhrase('at 8')!.hour, 8);
      expect(parseTimePhrase('at 9')!.hour, 9);
      expect(parseTimePhrase('at 11')!.hour, 11);
      expect(parseTimePhrase('at 12')!.hour, 12);
    });

    test('explicit meridiem wins over the bare-hour rule', () {
      expect(parseTimePhrase('3 am')!.hour, 3);
      expect(parseTimePhrase('at 9 pm')!.hour, 21);
      expect(parseTimePhrase('12 am')!.hour, 0);
      expect(parseTimePhrase('12 p.m.')!.hour, 12);
    });

    test('minutes, noon/midnight, 24h, o clock, around', () {
      final ParsedTime half = parseTimePhrase('3:30 am')!;
      expect((half.hour, half.minute), (3, 30));
      expect(parseTimePhrase('noon')!.hour, 12);
      expect(parseTimePhrase('at midnight')!.hour, 0);
      expect(parseTimePhrase('at 15:00')!.hour, 15);
      expect(parseTimePhrase("3 o'clock")!.hour, 15);
      expect(parseTimePhrase('around 4')!.hour, 16);
    });

    test('in the morning forces am', () {
      expect(parseTimePhrase('at 7 in the morning')!.hour, 7);
    });

    test('not a time → null', () {
      expect(parseTimePhrase('tomorrow'), isNull);
      expect(parseTimePhrase('at 25'), isNull);
      expect(parseTimePhrase('3:75 pm'), isNull);
      expect(parseTimePhrase(''), isNull);
    });
  });
}
