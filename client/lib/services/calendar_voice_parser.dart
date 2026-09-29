// SPDX-License-Identifier: AGPL-3.0-or-later
/// "Add this to my calendar …" → Google Calendar events, spoken in a
/// recording. Spec: docs/design/2026-09-28-voice-calendar-events.md.
///
/// Mirrors [TodoVoiceParser] but with two deliberate differences:
///  - ONE event per trigger — commas and "and" do not split ("lunch with
///    Sam and Alex" is a title, not two items).
///  - the time phrase is parsed into a VALUE ([parseTimePhrase]) — the To Do
///    model is date-only, the calendar model is not.
///
/// The no-date rule depends on the recording's mode (C3): a Brain Dump
/// creates a flagged all-day event on the recording day; a Meeting skips
/// it, because "put that on the calendar" is said conversationally there.
library;

import 'package:flutter_timezone/flutter_timezone.dart';

import '../models/dump_mode.dart';
import 'voice_date_grammar.dart';

/// One parsed calendar event, ready to become a `calendar_events` row.
class VoiceCalendarEvent {
  const VoiceCalendarEvent({
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    required this.needsDate,
    required this.timeZone,
  });

  /// Sentence-cased captured span with the date/time phrase removed.
  final String title;

  /// `YYYY-MM-DD` when [allDay], else local `YYYY-MM-DDTHH:MM:SS`.
  final String start;

  /// Same shape as [start]. All-day: the NEXT day (Google's exclusive end);
  /// timed: start + 60 minutes.
  final String end;
  final bool allDay;

  /// The phrase carried no date (C3): the event sits on the recording day
  /// and the card asks the user to fix it.
  final bool needsDate;

  /// IANA zone name of the device at capture time.
  final String timeZone;

  @override
  String toString() =>
      'VoiceCalendarEvent($title, $start → $end, allDay=$allDay, '
      'needsDate=$needsDate, $timeZone)';
}

class CalendarVoiceParser {
  CalendarVoiceParser._();

  static const int maxTitleLength = 200;

  /// The trigger family (spec "Trigger family"), two shapes:
  ///  - subject AFTER: `add this/that/it to my calendar X`, `put this on the
  ///    calendar X`, `add to my calendar X`, `calendar this X`;
  ///  - subject BEFORE: `add X to my calendar`, `put X on my calendar` — X is
  ///    the words between the verb and the calendar phrase (`<pre>`).
  /// `(?:google\s+)?` tolerates "my google calendar"; `:?` the colon
  /// Whisper sometimes writes.
  static final RegExp trigger = RegExp(
    r'(?:'
    r'\badd\s+(?<pre>(?!to\s)[^.,;!?]{1,120}?)\s+to\s+(?:my|the)\s+(?:google\s+)?calendar'
    r'|\bput\s+(?<pre2>[^.,;!?]{1,120}?)\s+on\s+(?:my|the)\s+(?:google\s+)?calendar'
    r'|\badd\s+to\s+(?:my|the)\s+(?:google\s+)?calendar'
    r'|\bcalendar\s+(?:this|that)'
    r')\s*:?',
    caseSensitive: false,
  );

  static final RegExp _pronoun =
      RegExp(r'^(?:this|that|it)$', caseSensitive: false);
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _leadingPunctuation = RegExp(r'^[.,;:!?…\s]+');
  static final RegExp _hasContent = RegExp(r'[0-9a-zA-Z\u00c0-\uffff]');

  /// "… and also", "… and" left when the next trigger cut the span.
  static final RegExp _trailingJoin = RegExp(
    r'\s+(?:and\s+also|and|also|then|plus)$',
    caseSensitive: false,
  );
  static final RegExp _leadingJoin = RegExp(
    r'^(?:and\s+also|and|also|then)\s+',
    caseSensitive: false,
  );
  static final RegExp _danglingPreposition = RegExp(
    r'\s+(?:on|for|at|by|around)$',
    caseSensitive: false,
  );

  /// A time phrase alone at either end of the span ("dentist at 2",
  /// "at 2 dentist") when no date phrase claimed it.
  static final RegExp _timeAtEnd = RegExp(
    '(?<!\\S)(?<t>${VoiceDateGrammar.time})\\.?\$',
    caseSensitive: false,
  );
  static final RegExp _timeAtStart = RegExp(
    '^(?<t>${VoiceDateGrammar.time})[.,:]?\\s*',
    caseSensitive: false,
  );

  static bool hasTrigger(String? transcript) =>
      transcript != null && trigger.hasMatch(transcript);

  /// Every event spoken in [transcript]. [recordedOn] is the dump's
  /// `created_at` in LOCAL time (the day the words were said, never now).
  /// [timeZone] defaults to the device zone; tests pass one explicitly.
  static List<VoiceCalendarEvent> parse(
    String? transcript, {
    required DateTime recordedOn,
    required DumpMode mode,
    String timeZone = 'local',
  }) {
    if (transcript == null || transcript.isEmpty) return const [];
    if (mode == DumpMode.textNote) return const [];
    final List<RegExpMatch> triggers = trigger.allMatches(transcript).toList();
    if (triggers.isEmpty) return const [];

    final List<VoiceCalendarEvent> events = <VoiceCalendarEvent>[];
    for (int i = 0; i < triggers.length; i++) {
      final int from = triggers[i].end;
      final int to =
          i + 1 < triggers.length ? triggers[i + 1].start : transcript.length;
      // Subject-before shape: the words between the verb and the phrase are
      // the subject unless they are just the pronoun ("add this to …").
      final String? pre =
          triggers[i].namedGroup('pre') ?? triggers[i].namedGroup('pre2');
      final String subject =
          pre == null || _pronoun.hasMatch(pre.trim()) ? '' : pre.trim();
      final VoiceCalendarEvent? event = _event(
        '$subject ${transcript.substring(from, to)}',
        recordedOn: recordedOn,
        mode: mode,
        timeZone: timeZone,
      );
      if (event != null) events.add(event);
    }
    return events;
  }

  static VoiceCalendarEvent? _event(
    String raw, {
    required DateTime recordedOn,
    required DumpMode mode,
    required String timeZone,
  }) {
    // Join words left when the NEXT trigger cut this span ("… Thursday at
    // two and also") must go first or the end-anchored date grammar misses.
    final String cleaned = _clean(_clean(raw).replaceFirst(_trailingJoin, ''));
    if (cleaned.isEmpty) return null;

    String? date;
    String? timeText;
    String rest = cleaned;

    // A date phrase at the END (with a time on either side of it) …
    final RegExpMatch? atEnd = VoiceDateGrammar.itemEndDate.firstMatch(cleaned);
    if (atEnd != null) {
      date = VoiceDateGrammar.resolve(atEnd, recordedOn);
      if (date != null) {
        timeText = atEnd.namedGroup('tb') ?? atEnd.namedGroup('ta');
        rest = VoiceDateGrammar.keepsText(atEnd)
            ? cleaned
            : cleaned.substring(0, atEnd.start);
      }
    }
    // … or at the START ("tomorrow dentist at 2").
    if (date == null) {
      final RegExpMatch? atStart =
          VoiceDateGrammar.itemStartDate.firstMatch(cleaned);
      if (atStart != null) {
        date = VoiceDateGrammar.resolve(atStart, recordedOn);
        if (date != null) {
          rest = VoiceDateGrammar.keepsText(atStart)
              ? cleaned
              : cleaned.substring(atStart.end);
        }
      }
    }
    // A time may still sit at an end of what is left ("dentist at 2" with
    // the date at the start, or no date at all).
    if (timeText == null) {
      final RegExpMatch? tEnd = _timeAtEnd.firstMatch(rest);
      if (tEnd != null && parseTimePhrase(tEnd.namedGroup('t')!) != null) {
        timeText = tEnd.namedGroup('t');
        rest = rest.substring(0, tEnd.start);
      } else {
        final RegExpMatch? tStart = _timeAtStart.firstMatch(rest);
        if (tStart != null &&
            parseTimePhrase(tStart.namedGroup('t')!) != null) {
          timeText = tStart.namedGroup('t');
          rest = rest.substring(tStart.end);
        }
      }
    }

    final String title = _title(rest);
    if (title.isEmpty) return null;

    final ParsedTime? time =
        timeText == null ? null : parseTimePhrase(timeText);
    final bool needsDate = date == null;
    if (needsDate && mode != DumpMode.brainDump) return null; // C3

    final DateTime day = date == null
        ? DateTime(recordedOn.year, recordedOn.month, recordedOn.day)
        : DateTime.parse(date);

    if (time == null) {
      return VoiceCalendarEvent(
        title: title,
        start: _isoDate(day),
        end: _isoDate(DateTime(day.year, day.month, day.day + 1)),
        allDay: true,
        needsDate: needsDate,
        timeZone: timeZone,
      );
    }
    final DateTime start =
        DateTime(day.year, day.month, day.day, time.hour, time.minute);
    return VoiceCalendarEvent(
      title: title,
      start: _isoLocal(start),
      end: _isoLocal(start.add(const Duration(hours: 1))),
      allDay: false,
      needsDate: needsDate,
      timeZone: timeZone,
    );
  }

  /// The device's IANA zone, for the capture seam (tests never call this).
  static Future<String> deviceTimeZone() async {
    try {
      return await FlutterTimezone.getLocalTimezone();
    } catch (_) {
      return DateTime.now().timeZoneName;
    }
  }

  static String _clean(String raw) {
    String s = raw.trim().replaceAll(_whitespace, ' ');
    s = s.replaceFirst(_leadingPunctuation, '');
    while (s.endsWith('.') || s.endsWith(',')) {
      s = s.substring(0, s.length - 1).trimRight();
    }
    s = s.trim();
    if (s.isEmpty || !_hasContent.hasMatch(s)) return '';
    return s;
  }

  /// Trim, drop dangling prepositions the phrase removal leaves behind
  /// ("dentist on" / "dentist for"), sentence-case, cap.
  static String _title(String rest) {
    String s = _clean(rest);
    s = s.replaceFirst(_trailingJoin, '');
    s = s.replaceFirst(_danglingPreposition, '');
    s = s.replaceFirst(_leadingJoin, '');
    s = s.trim();
    if (s.isEmpty || !_hasContent.hasMatch(s)) return '';
    if (s.length > maxTitleLength) {
      s = s.substring(0, maxTitleLength).trimRight();
    }
    return s[0].toUpperCase() + s.substring(1);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _isoDate(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';
  static String _isoLocal(DateTime d) =>
      '${_isoDate(d)}T${_two(d.hour)}:${_two(d.minute)}:00';
}
