// SPDX-License-Identifier: AGPL-3.0-or-later
/// The spoken-date grammar shared by `TodoVoiceParser` and
/// `CalendarVoiceParser`: one source string for every date phrase (absolute,
/// relative, weekday, ordinal, "a week from …", the tonight family), the time
/// phrase that may flank it, and the resolution of a match to ISO
/// `YYYY-MM-DD` anchored on the day the words were RECORDED.
///
/// Moved out of `todo_voice_parser.dart` unchanged (v1.35.0) so calendar
/// capture speaks exactly the same language; the To Do parser's output is
/// pinned byte-identical by its own tests.
library;

class VoiceDateGrammar {
  VoiceDateGrammar._();

  /// A month name, full or 3-letter (plus `Sept`), optional trailing period.
  /// `may` is a month only because every absolute form demands a day number
  /// right after it — "may call mom" never gets this far.
  static const String month =
      r'(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?'
      r'|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?'
      r'|dec(?:ember)?)\.?';

  static const String ordinal = r'(?:st|nd|rd|th)?';

  /// The v1.26.0 absolute forms, as one alternative of [phrase]:
  ///   `September 30th, 2027`  → m1 d1 y1
  ///   `the 30th of September` → d2 m2 y2
  ///   `9/30`, `09/30/2027`    → m3 d3 y3
  static const String absolute =
      r'(?:the\s+)?(?:'
      '(?<m1>$month)\\s+(?<d1>\\d{1,2})$ordinal(?:,?\\s+(?<y1>\\d{4}))?'
      '|(?<d2>\\d{1,2})$ordinal\\s+of\\s+(?<m2>$month)(?:,?\\s+(?<y2>\\d{4}))?'
      r'|(?<m3>\d{1,2})[/-](?<d3>\d{1,2})(?:[/-](?<y3>\d{4}))?'
      r')';

  /// Weekday names. Short forms are only a date when followed by the end of
  /// the item, a period or a comma — "buy sun screen" and "mon ami" are text
  /// (spec ambiguity guards). Full names still need the word boundary the
  /// whole phrase gets below.
  static const String weekdayNames =
      r'monday|tuesday|wednesday|thursday'
      r'|friday|saturday|sunday'
      r'|(?:mon|tue|tues|wed|weds|thu|thur|thurs|fri|sat|sun)(?=\.|,|\s*$)';

  static const String weekday = '(?<wd>$weekdayNames)';

  /// A time of day (V1). Recognised ONLY so the date phrase next to it can
  /// be removed cleanly; the time itself is never stripped from the item
  /// and never parsed into a value — the model is date-only. `a\.?m\.?`
  /// tolerates the "p.m" that [TodoVoiceParser]'s cleaner leaves after eating the final period.
  /// A spoken hour: `2`, `2:30`, or the word (`two`) — Whisper writes
  /// small numbers either way.
  static const String hourWords =
      'one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve';
  static const String hourish = '(?:\\d{1,2}(?::\\d{2})?|$hourWords)';
  static const String time =
      '(?:'
      '(?:at|around|by)\\s+(?:noon|midnight|$hourish'
      "(?:\\s*(?:a\\.?m\\.?|p\\.?m\\.?|o'?clock))?)"
      '|$hourish'
      "\\s*(?:a\\.?m\\.?|p\\.?m\\.?|o'?clock)"
      ')';

  /// `one` … `thirty`, or the article of "in a day" / "in a week".
  static const String numberWord =
      r'thirty|twenty(?:[\s-](?:one|two|three|four|five|six|seven|eight|nine))?'
      r'|nineteen|eighteen|seventeen|sixteen|fifteen|fourteen|thirteen|twelve'
      r'|eleven|ten|nine|eight|seven|six|five|four|three|two|one|an?';

  /// Every date phrase the parser knows, absolute or relative, with its
  /// optional preposition. ONE source string, composed three ways below so
  /// the sentence head and the item start/end recognise exactly the same
  /// language and [resolve] reads the same named groups from all three.
  static const String phrase =
      r'(?:(?:for|on|by|due(?:\s+on)?)\s+)?'
      r'(?:'
      '$absolute'
      r'|(?<today>today)'
      r'|(?<tomorrow>tomorrow)'
      r'|(?<dayAfter>(?:the\s+)?day\s+after\s+tomorrow)'
      '|(?:this\\s+|next\\s+)?$weekday\\.?'
      '|in\\s+(?<n>\\d{1,3}|$numberWord)\\s+(?<unit>days?|weeks?)'
      r'|next\s+(?<next>week|month)'
      r'|(?:the\s+)?end\s+of\s+(?:the\s+)?(?<endOf>week|month)'
      r'|(?<weekend>this|next)\s+weekend'
      r'|the\s+(?<dom>\d{1,2})(?:st|nd|rd|th)'
      '|(?<wn>\\d{1,2}|$numberWord)\\s+weeks?\\s+from\\s+'
      '(?:this\\s+|next\\s+)?(?<from>today|tomorrow|$weekdayNames)'
      r'|(?<dayish>tonight|this\s+(?:morning|afternoon|evening)'
      r'|(?:the\s+)?end\s+of\s+(?:the\s+)?day)'
      r')'
      r'(?![0-9a-z])';

  /// The sentence date: ONE phrase at the head of the span, right after the
  /// trigger, before splitting (D1 position, any phrase from the table).
  /// The trailing `to` is the "to go to the store" of the real recording;
  /// it belongs to the phrase, not the item (v1.26.0 fixture 1).
  static final RegExp headDate = RegExp(
    '^[.,;:!?…\\s]*(?:(?<tb>$time)\\s+)?$phrase'
    '(?:\\s+(?<ta>$time))?[.,:]?\\s*(?:to\\s+)?',
    caseSensitive: false,
  );

  /// A per-item phrase at the END of an already-cleaned item. Anchored at
  /// the end on purpose: "call mom on Sunday about the trip" is NOT dated —
  /// a mid-sentence weekday is as often a topic as a deadline (R2).
  ///
  /// A time phrase may sit on either side of the date (V1: `tomorrow at 3
  /// pm`, `at 3 pm tomorrow`); it is captured as `tb`/`ta` so the caller can
  /// put it back where the date was. A time ALONE is not a date phrase.
  static final RegExp itemEndDate = RegExp(
    '(?<!\\S)(?:(?<tb>$time)\\s+)?$phrase(?:\\s+(?<ta>$time))?\\.?\$',
    caseSensitive: false,
  );

  /// A per-item phrase at the START of an already-cleaned item
  /// ("Sunday call mom", "tomorrow buy milk").
  static final RegExp itemStartDate = RegExp(
    '^$phrase(?:\\s+(?<ta>$time))?[.,:]?\\s*',
    caseSensitive: false,
  );

  /// A time without a date at an item's end (`call Dana by 5`). Its date is
  /// the day containing the next matching wall-clock occurrence.
  static final RegExp itemEndTime = RegExp(
    '(?<!\\S)(?<only>$time)\\.?\$',
    caseSensitive: false,
  );

  static const List<String> monthPrefixes = <String>[
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];

  static const List<String> numberWords = <String>[
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
    'ten',
    'eleven',
    'twelve',
    'thirteen',
    'fourteen',
    'fifteen',
    'sixteen',
    'seventeen',
    'eighteen',
    'nineteen',
    'twenty',
  ];

  static const Map<String, int> weekdays = <String, int>{
    'mon': DateTime.monday,
    'tue': DateTime.tuesday,
    'wed': DateTime.wednesday,
    'thu': DateTime.thursday,
    'fri': DateTime.friday,
    'sat': DateTime.saturday,
    'sun': DateTime.sunday,
  };

  /// Turns a [phrase] match into ISO `YYYY-MM-DD`, or null when the spoken
  /// phrase is not a real calendar date. All arithmetic goes through
  /// `DateTime(y, m, d + n)` so a DST change can never shift a day.
  static String? resolve(RegExpMatch m, DateTime recordedOn) {
    final DateTime anchor = DateTime(
      recordedOn.year,
      recordedOn.month,
      recordedOn.day,
    );
    String? g(String name) => m.namedGroup(name);

    if (g('m1') != null || g('m2') != null || g('m3') != null) {
      return resolveAbsolute(m, anchor);
    }
    if (g('today') != null) return isoOf(anchor);
    if (g('tomorrow') != null) return isoOf(plusDays(anchor, 1));
    if (g('dayAfter') != null) return isoOf(plusDays(anchor, 2));

    final String? weekday = g('wd');
    if (weekday != null) {
      // R1: the next occurrence STRICTLY after the recording day — a
      // weekday name on that same weekday means next week's. "next
      // <weekday>" is deliberately the same day (spec: no week-after-next).
      return isoOf(plusDays(anchor, weekdayDelta(anchor, weekday)));
    }

    final String? count = g('n');
    if (count != null) {
      final int? n = number(count);
      if (n == null || n < 1) return null;
      final bool weeks = g('unit')!.toLowerCase().startsWith('w');
      return isoOf(plusDays(anchor, weeks ? n * 7 : n));
    }

    final String? next = g('next');
    if (next != null) {
      if (next.toLowerCase() == 'week') {
        // R3: Monday strictly after the recording day.
        int delta = (DateTime.monday - anchor.weekday) % 7;
        if (delta == 0) delta = 7;
        return isoOf(plusDays(anchor, delta));
      }
      // R3: the 1st of the following month (month 13 rolls the year).
      return isoOf(DateTime(anchor.year, anchor.month + 1, 1));
    }

    final String? endOf = g('endOf');
    if (endOf != null) {
      if (endOf.toLowerCase() == 'week') {
        // The coming Sunday, or the recording day itself if it is a Sunday.
        return isoOf(plusDays(anchor, (DateTime.sunday - anchor.weekday) % 7));
      }
      // Day 0 of next month is the last day of this one.
      return isoOf(DateTime(anchor.year, anchor.month + 1, 0));
    }

    final String? weekend = g('weekend');
    if (weekend != null) {
      // V2: the coming Saturday STRICTLY after the recording day (R1: said
      // on a Saturday → next Saturday); "next weekend" is the one after.
      int delta = (DateTime.saturday - anchor.weekday) % 7;
      if (delta == 0) delta = 7;
      if (weekend.toLowerCase() == 'next') delta += 7;
      return isoOf(plusDays(anchor, delta));
    }

    final String? dom = g('dom');
    if (dom != null) {
      // V3: the next such day-of-month on or after the recording day,
      // skipping months that do not have it (the 31st in September).
      final int day = int.parse(dom);
      if (day < 1 || day > 31) return null;
      for (int i = 0; i <= 12; i++) {
        final DateTime first = DateTime(anchor.year, anchor.month + i, 1);
        if (!isValidDate(first.year, first.month, day)) continue;
        final DateTime candidate = DateTime(first.year, first.month, day);
        if (!candidate.isBefore(anchor)) return isoOf(candidate);
      }
      return null;
    }

    final String? weeksFrom = g('wn');
    if (weeksFrom != null) {
      // V4: resolve the inner phrase, then +7 per week.
      final int? n = number(weeksFrom);
      if (n == null || n < 1) return null;
      final String from = g('from')!.toLowerCase();
      final int inner;
      if (from == 'today') {
        inner = 0;
      } else if (from == 'tomorrow') {
        inner = 1;
      } else {
        inner = weekdayDelta(anchor, from);
      }
      return isoOf(plusDays(anchor, inner + n * 7));
    }

    // V5: tonight / this morning|afternoon|evening / end of the day → today.
    if (g('dayish') != null) return isoOf(anchor);
    return null;
  }

  /// V5 phrases carry a date but are natural item text ("call mom tonight"):
  /// the date is taken and NOTHING is stripped.
  static bool keepsText(RegExpMatch m) => m.namedGroup('dayish') != null;

  /// R1: days until the next [weekday] STRICTLY after [anchor].
  static int weekdayDelta(DateTime anchor, String weekday) {
    final int target = weekdays[weekday.toLowerCase().substring(0, 3)]!;
    int delta = (target - anchor.weekday) % 7;
    if (delta == 0) delta = 7;
    return delta;
  }

  /// D2 resolution of the absolute forms:
  /// - explicit year → that date as spoken; invalid (Feb 30) → null;
  /// - no year → the next occurrence on or after the recording day, never in
  ///   the past; Feb 29 → the next leap occurrence within four years, else null.
  static String? resolveAbsolute(RegExpMatch m, DateTime anchor) {
    final int? month;
    final int? day;
    final String? yearText;
    if (m.namedGroup('m1') != null) {
      month = monthNumber(m.namedGroup('m1')!);
      day = int.tryParse(m.namedGroup('d1')!);
      yearText = m.namedGroup('y1');
    } else if (m.namedGroup('m2') != null) {
      month = monthNumber(m.namedGroup('m2')!);
      day = int.tryParse(m.namedGroup('d2')!);
      yearText = m.namedGroup('y2');
    } else {
      month = int.tryParse(m.namedGroup('m3')!);
      day = int.tryParse(m.namedGroup('d3')!);
      yearText = m.namedGroup('y3');
    }
    if (month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;

    if (yearText != null) {
      final int year = int.parse(yearText);
      return isValidDate(year, month, day) ? iso(year, month, day) : null;
    }

    for (int year = anchor.year; year <= anchor.year + 4; year++) {
      if (!isValidDate(year, month, day)) continue;
      if (!DateTime(year, month, day).isBefore(anchor)) {
        return iso(year, month, day);
      }
    }
    return null;
  }

  static DateTime plusDays(DateTime anchor, int days) =>
      DateTime(anchor.year, anchor.month, anchor.day + days);

  static int? monthNumber(String name) {
    final String key = name.toLowerCase();
    if (key.length < 3) return null;
    final int index = monthPrefixes.indexOf(key.substring(0, 3));
    return index < 0 ? null : index + 1;
  }

  /// `3`, `three`, `twenty-one`, `twenty one`, `thirty`, `a`/`an` → int.
  static int? number(String text) {
    final String key = text.toLowerCase().trim();
    final int? digits = int.tryParse(key);
    if (digits != null) return digits;
    if (key == 'a' || key == 'an') return 1;
    if (key == 'thirty') return 30;
    final List<String> parts = key.split(RegExp(r'[\s-]+'));
    int total = 0;
    for (final String part in parts) {
      final int index = numberWords.indexOf(part);
      if (index < 0) return null;
      total += index + 1;
    }
    return total;
  }

  static bool isValidDate(int year, int month, int day) {
    final DateTime d = DateTime(year, month, day);
    return d.year == year && d.month == month && d.day == day;
  }

  static String isoOf(DateTime d) => iso(d.year, d.month, d.day);

  static String iso(int year, int month, int day) =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';
}

/// A wall-clock time parsed from a spoken phrase ([parseTimePhrase]).
class ParsedTime {
  const ParsedTime(this.hour, this.minute, {this.dayOffset = 0});
  final int hour;
  final int minute;
  final int dayOffset;

  @override
  String toString() => 'ParsedTime($hour:$minute)';
}

/// `at 3`, `by 5`, `3:30 pm`, `noon`, `at 15:00`, `3 o'clock`, `at 7 in the
/// morning` → a value. Bare hours resolve to the next occurrence: start with
/// the conventional spoken half-day (1–7 pm, 8–11 am, 12 noon), then add
/// twelve hours when that occurrence has already passed on the due day.
ParsedTime? parseTimePhrase(String phrase, {DateTime? nextAfter}) {
  final RegExpMatch? m = _timeValue.firstMatch(phrase.trim());
  if (m == null) return null;
  if (m.namedGroup('noon') != null) return const ParsedTime(12, 0);
  if (m.namedGroup('midnight') != null) return const ParsedTime(0, 0);
  final String h = m.namedGroup('h')!.toLowerCase();
  int hour = int.tryParse(h) ?? (VoiceDateGrammar.numberWords.indexOf(h) + 1);
  final int minute = int.tryParse(m.namedGroup('mi') ?? '') ?? 0;
  if (hour > 23 || minute > 59) return null;
  final String? mer = m.namedGroup('mer')?.toLowerCase().replaceAll('.', '');
  final bool morning = m.namedGroup('morning') != null;
  if (hour > 12) return ParsedTime(hour, minute); // 24-hour as spoken
  if (mer == 'am' || morning) {
    if (hour == 12) hour = 0;
  } else if (mer == 'pm') {
    if (hour != 12) hour += 12;
  } else if (nextAfter != null && hour >= 1 && hour <= 12) {
    final int first = hour == 12 ? 0 : hour;
    final DateTime morning = DateTime(
      nextAfter.year,
      nextAfter.month,
      nextAfter.day,
      first,
      minute,
    );
    final DateTime evening = morning.add(const Duration(hours: 12));
    if (morning.isAfter(nextAfter)) return ParsedTime(first, minute);
    if (evening.isAfter(nextAfter)) return ParsedTime(first + 12, minute);
    return ParsedTime(first, minute, dayOffset: 1);
  } else if (hour >= 1 && hour <= 7) {
    hour += 12;
  }
  return ParsedTime(hour, minute);
}

final RegExp _timeValue = RegExp(
  r'^(?:at|around|by)?\s*(?:(?<noon>noon)|(?<midnight>midnight)'
  '|(?<h>\\d{1,2}|${VoiceDateGrammar.hourWords})(?::(?<mi>\\d{2}))?'
  r'\s*(?<mer>a\.?m\.?|p\.?m\.?)?'
  r"(?:\s*o'?clock)?(?:\s+in\s+the\s+(?<morning>morning))?)\s*$",
  caseSensitive: false,
);
