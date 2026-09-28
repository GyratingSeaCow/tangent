// SPDX-License-Identifier: AGPL-3.0-or-later

/// One spoken to-do: its text and the date phrase attached to THAT item
/// (v1.27.0, R2). [dueDate] is only the item's OWN date — null when the
/// item said none, even if the sentence named one; callers fall back to
/// [VoiceTodoParse.dueDate] (`entry.dueDate ?? parse.dueDate`).
class VoiceTodoItem {
  const VoiceTodoItem(this.text, {this.dueDate});

  final String text;

  /// ISO `YYYY-MM-DD`, or null when the item carried no date phrase of its own.
  final String? dueDate;

  @override
  bool operator ==(Object other) =>
      other is VoiceTodoItem && other.text == text && other.dueDate == dueDate;

  @override
  int get hashCode => Object.hash(text, dueDate);

  @override
  String toString() => 'VoiceTodoItem($text, dueDate: $dueDate)';
}

/// The result of [TodoVoiceParser.parseWithDate]: the items plus the ONE
/// sentence-level due date a leading date phrase gave every item (v1.26.0,
/// D1), and since v1.27.0 the per-item dates in [entries].
class VoiceTodoParse {
  const VoiceTodoParse({required this.entries, this.dueDate});

  /// The items spoken after the trigger, in order, each with its own date.
  final List<VoiceTodoItem> entries;

  /// The SENTENCE date: ISO `YYYY-MM-DD`, or null when no leading date
  /// phrase was recognised. Items without their own date inherit it.
  final String? dueDate;

  /// The item texts only (see [TodoVoiceParser.parse]).
  List<String> get items =>
      entries.map((VoiceTodoItem e) => e.text).toList(growable: false);

  static const VoiceTodoParse empty = VoiceTodoParse(entries: <VoiceTodoItem>[]);
}

/// Pulls to-do items out of a spoken transcript (To Do arc Phase 2).
///
/// Pure and side-effect free on purpose: the detection rules are the part
/// that has to be provably right, so they live away from the database and
/// the sync engine where they can be unit-tested one rule at a time.
///
/// Spec: docs/design/2026-09-27-todo-voice-capture.md §"Parsing rules";
/// due dates: docs/design/2026-09-27-voice-todo-due-dates.md; relative and
/// per-item dates: docs/design/2026-09-27-voice-todo-relative-dates.md;
/// times of day, weekends, day-of-month, "a week from", "tonight" (V1-V5):
/// docs/design/2026-09-27-desktop-reminders-and-date-followups.md §Half B.
class TodoVoiceParser {
  const TodoVoiceParser._();

  /// At most this many items from one transcript — a runaway transcript must
  /// not be able to bury the To Do screen under hundreds of fragments.
  static const int maxItems = 20;

  /// Each item is truncated to this length.
  static const int maxItemLength = 200;

  /// The trigger family (V2). Spelling of "to do" is tolerated as one word,
  /// two words or hyphenated, and a trailing colon (which speech-to-text
  /// engines like to insert before a list) is swallowed with the phrase.
  ///
  /// The FIRST match wins and the captured span runs to the end of the
  /// transcript, so a second trigger later on is ordinary item text.
  static final RegExp _trigger = RegExp(
    r'(?:'
    r'add\s+to\s+my\s+to[\s-]?do\s+list'
    r'|add\s+that\s+to\s+my\s+list'
    r'|put\s+on\s+my\s+to[\s-]?do\s+list'
    r'|remind\s+me\s+to'
    r')\s*:?',
    caseSensitive: false,
  );

  /// Item separators: a comma, or a STANDALONE "and". The whitespace on both
  /// sides is what keeps "brand" and "android" intact — a bare `\band\b`
  /// would still be safe here, but requiring the spaces states the intent.
  static final RegExp _separator = RegExp(r',|\s+and\s+', caseSensitive: false);

  /// A leading "to " left over by "remind me to … and to …".
  static final RegExp _leadingTo = RegExp(r'^to\s+', caseSensitive: false);

  static final RegExp _whitespace = RegExp(r'\s+');

  /// Something a human would read as content. An item that is only
  /// punctuation ("." or "…") carries nothing and is dropped.
  static final RegExp _hasContent = RegExp(r'[0-9a-zA-Z\u00c0-\uffff]');

  /// A month name, full or 3-letter (plus `Sept`), optional trailing period.
  /// `may` is a month only because every absolute form demands a day number
  /// right after it — "may call mom" never gets this far.
  static const String _month =
      r'(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?'
      r'|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?'
      r'|dec(?:ember)?)\.?';

  static const String _ordinal = r'(?:st|nd|rd|th)?';

  /// The v1.26.0 absolute forms, as one alternative of [_phrase]:
  ///   `September 30th, 2027`  → m1 d1 y1
  ///   `the 30th of September` → d2 m2 y2
  ///   `9/30`, `09/30/2027`    → m3 d3 y3
  static const String _absolute = r'(?:the\s+)?(?:'
      '(?<m1>$_month)\\s+(?<d1>\\d{1,2})$_ordinal(?:,?\\s+(?<y1>\\d{4}))?'
      '|(?<d2>\\d{1,2})$_ordinal\\s+of\\s+(?<m2>$_month)(?:,?\\s+(?<y2>\\d{4}))?'
      r'|(?<m3>\d{1,2})[/-](?<d3>\d{1,2})(?:[/-](?<y3>\d{4}))?'
      r')';

  /// Weekday names. Short forms are only a date when followed by the end of
  /// the item, a period or a comma — "buy sun screen" and "mon ami" are text
  /// (spec ambiguity guards). Full names still need the word boundary the
  /// whole phrase gets below.
  static const String _weekdayNames = r'monday|tuesday|wednesday|thursday'
      r'|friday|saturday|sunday'
      r'|(?:mon|tue|tues|wed|weds|thu|thur|thurs|fri|sat|sun)(?=\.|,|\s*$)';

  static const String _weekday = '(?<wd>$_weekdayNames)';

  /// A time of day (V1). Recognised ONLY so the date phrase next to it can
  /// be removed cleanly; the time itself is never stripped from the item
  /// and never parsed into a value — the model is date-only. `a\.?m\.?`
  /// tolerates the "p.m" that [_clean] leaves after eating the final period.
  static const String _time = r'(?:'
      r'(?:at|around)\s+(?:noon|midnight|\d{1,2}(?::\d{2})?'
      r"(?:\s*(?:a\.?m\.?|p\.?m\.?|o'?clock))?)"
      r"|\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?|o'?clock)"
      r')';

  /// `one` … `thirty`, or the article of "in a day" / "in a week".
  static const String _numberWord =
      r'thirty|twenty(?:[\s-](?:one|two|three|four|five|six|seven|eight|nine))?'
      r'|nineteen|eighteen|seventeen|sixteen|fifteen|fourteen|thirteen|twelve'
      r'|eleven|ten|nine|eight|seven|six|five|four|three|two|one|an?';

  /// Every date phrase the parser knows, absolute or relative, with its
  /// optional preposition. ONE source string, composed three ways below so
  /// the sentence head and the item start/end recognise exactly the same
  /// language and [_resolve] reads the same named groups from all three.
  static const String _phrase = r'(?:(?:for|on|by|due(?:\s+on)?)\s+)?'
      r'(?:'
      '$_absolute'
      r'|(?<today>today)'
      r'|(?<tomorrow>tomorrow)'
      r'|(?<dayAfter>(?:the\s+)?day\s+after\s+tomorrow)'
      '|(?:this\\s+|next\\s+)?$_weekday\\.?'
      '|in\\s+(?<n>\\d{1,3}|$_numberWord)\\s+(?<unit>days?|weeks?)'
      r'|next\s+(?<next>week|month)'
      r'|(?:the\s+)?end\s+of\s+(?:the\s+)?(?<endOf>week|month)'
      r'|(?<weekend>this|next)\s+weekend'
      r'|the\s+(?<dom>\d{1,2})(?:st|nd|rd|th)'
      '|(?<wn>\\d{1,2}|$_numberWord)\\s+weeks?\\s+from\\s+'
      '(?:this\\s+|next\\s+)?(?<from>today|tomorrow|$_weekdayNames)'
      r'|(?<dayish>tonight|this\s+(?:morning|afternoon|evening)'
      r'|(?:the\s+)?end\s+of\s+(?:the\s+)?day)'
      r')'
      r'(?![0-9a-z])';

  /// The sentence date: ONE phrase at the head of the span, right after the
  /// trigger, before splitting (D1 position, any phrase from the table).
  /// The trailing `to` is the "to go to the store" of the real recording;
  /// it belongs to the phrase, not the item (v1.26.0 fixture 1).
  static final RegExp _headDate = RegExp(
    '^[.,;:!?…\\s]*$_phrase[.,:]?\\s*(?:to\\s+)?',
    caseSensitive: false,
  );

  /// A per-item phrase at the END of an already-cleaned item. Anchored at
  /// the end on purpose: "call mom on Sunday about the trip" is NOT dated —
  /// a mid-sentence weekday is as often a topic as a deadline (R2).
  ///
  /// A time phrase may sit on either side of the date (V1: `tomorrow at 3
  /// pm`, `at 3 pm tomorrow`); it is captured as `tb`/`ta` so [_entry] can
  /// put it back where the date was. A time ALONE is not a date phrase.
  static final RegExp _itemEndDate = RegExp(
    '(?<!\\S)(?:(?<tb>$_time)\\s+)?$_phrase(?:\\s+(?<ta>$_time))?\\.?\$',
    caseSensitive: false,
  );

  /// A per-item phrase at the START of an already-cleaned item
  /// ("Sunday call mom", "tomorrow buy milk").
  static final RegExp _itemStartDate = RegExp(
    '^$_phrase[.,:]?\\s*',
    caseSensitive: false,
  );

  static const List<String> _monthPrefixes = <String>[
    'jan', 'feb', 'mar', 'apr', 'may', 'jun',
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];

  static const List<String> _numberWords = <String>[
    'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
    'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen',
    'seventeen', 'eighteen', 'nineteen', 'twenty',
  ];

  static const Map<String, int> _weekdays = <String, int>{
    'mon': DateTime.monday,
    'tue': DateTime.tuesday,
    'wed': DateTime.wednesday,
    'thu': DateTime.thursday,
    'fri': DateTime.friday,
    'sat': DateTime.saturday,
    'sun': DateTime.sunday,
  };

  /// Returns true when [transcript] contains a trigger phrase at all.
  static bool hasTrigger(String? transcript) =>
      transcript != null && _trigger.hasMatch(transcript);

  /// The items spoken after the first trigger phrase, in order.
  ///
  /// Returns an empty list when there is no trigger, or when the span after
  /// the trigger is empty/whitespace (rule 6: saying the phrase alone does
  /// nothing — no items, and therefore no card).
  ///
  /// Date phrases are stripped from the items exactly as [parseWithDate]
  /// does; the dates themselves are only reachable there. The day the
  /// transcript was recorded is irrelevant to the TEXT of the items, so any
  /// anchor day gives the same list.
  static List<String> parse(String? transcript) =>
      parseWithDate(transcript, recordedOn: _anyDay).items;

  static final DateTime _anyDay = DateTime(2000, 1, 1);

  /// [parse] plus the sentence due date and each item's own date.
  ///
  /// [recordedOn] is the day the words were spoken (the dump's
  /// `created_at`), NOT now: a recording transcribed days later still means
  /// the date it was said on. Only its date part is read, in whatever zone
  /// it is expressed in — callers pass local time.
  static VoiceTodoParse parseWithDate(
    String? transcript, {
    required DateTime recordedOn,
  }) {
    if (transcript == null || transcript.isEmpty) return VoiceTodoParse.empty;
    final RegExpMatch? match = _trigger.firstMatch(transcript);
    if (match == null) return VoiceTodoParse.empty;

    String span = transcript.substring(match.end);
    if (span.trim().isEmpty) return VoiceTodoParse.empty;

    String? dueDate;
    final RegExpMatch? date = _headDate.firstMatch(span);
    if (date != null) {
      final String? resolved = _resolve(date, recordedOn);
      // An unresolvable phrase (Feb 30) is left in place as item text — the
      // user said something, and guessing a date would be worse than none.
      // A relative word that IS the whole span ("…to-do list, today.") is
      // kept as an item too (phrase-was-the-whole-item rule, fixture 9);
      // an absolute date alone still yields no items, as in v1.26.0.
      final bool wholeSpan = span.substring(date.end).trim().isEmpty;
      final bool keepAsText = wholeSpan && date.namedGroup('m1') == null &&
          date.namedGroup('m2') == null && date.namedGroup('m3') == null;
      if (resolved != null && !keepAsText) {
        dueDate = resolved;
        // At the sentence HEAD there is no item for a V5 word to belong
        // to ("…to-do list tonight, call mom" must not yield an item
        // called "tonight"), so every head phrase is removed; V5's
        // keep-the-word rule applies inside items only (see _entry).
        span = span.substring(date.end);
      }
    }
    if (span.trim().isEmpty) {
      return VoiceTodoParse(entries: const <VoiceTodoItem>[], dueDate: dueDate);
    }

    final List<VoiceTodoItem> entries = <VoiceTodoItem>[];
    for (final String raw in span.split(_separator)) {
      final VoiceTodoItem? entry = _entry(raw, recordedOn);
      if (entry == null) continue;
      entries.add(entry);
      if (entries.length == maxItems) break;
    }
    return VoiceTodoParse(entries: entries, dueDate: dueDate);
  }

  /// One split fragment → an item with its OWN date, if it ends or starts
  /// with a date phrase (R2). End wins over start. If stripping the phrase
  /// would leave nothing, the phrase WAS the item: keep the text, no date.
  static VoiceTodoItem? _entry(String raw, DateTime recordedOn) {
    final String cleaned = _clean(raw);
    if (cleaned.isEmpty) return null;

    String? dueDate;
    String rest = cleaned;
    final RegExpMatch? atEnd = _itemEndDate.firstMatch(cleaned);
    if (atEnd != null) {
      dueDate = _resolve(atEnd, recordedOn);
      if (dueDate != null) {
        // V5: "tonight" carries the date AND belongs in the text.
        if (_keepsText(atEnd)) return VoiceTodoItem(cleaned, dueDate: dueDate);
        // V1: the time phrase stays where the date phrase was.
        final String time = <String?>[atEnd.namedGroup('tb'), atEnd.namedGroup('ta')]
            .whereType<String>()
            .join(' ');
        rest = '${cleaned.substring(0, atEnd.start)} $time';
      }
    }
    if (dueDate == null) {
      final RegExpMatch? atStart = _itemStartDate.firstMatch(cleaned);
      if (atStart != null) {
        dueDate = _resolve(atStart, recordedOn);
        if (dueDate != null) {
          if (_keepsText(atStart)) return VoiceTodoItem(cleaned, dueDate: dueDate);
          rest = cleaned.substring(atStart.end);
        }
      }
    }
    if (dueDate == null) return VoiceTodoItem(cleaned);
    final String text = _clean(rest);
    if (text.isEmpty) return VoiceTodoItem(cleaned);
    return VoiceTodoItem(text, dueDate: dueDate);
  }

  /// Turns a [_phrase] match into ISO `YYYY-MM-DD`, or null when the spoken
  /// phrase is not a real calendar date. All arithmetic goes through
  /// `DateTime(y, m, d + n)` so a DST change can never shift a day.
  static String? _resolve(RegExpMatch m, DateTime recordedOn) {
    final DateTime anchor =
        DateTime(recordedOn.year, recordedOn.month, recordedOn.day);
    String? g(String name) => m.namedGroup(name);

    if (g('m1') != null || g('m2') != null || g('m3') != null) {
      return _resolveAbsolute(m, anchor);
    }
    if (g('today') != null) return _isoOf(anchor);
    if (g('tomorrow') != null) return _isoOf(_plusDays(anchor, 1));
    if (g('dayAfter') != null) return _isoOf(_plusDays(anchor, 2));

    final String? weekday = g('wd');
    if (weekday != null) {
      // R1: the next occurrence STRICTLY after the recording day — a
      // weekday name on that same weekday means next week's. "next
      // <weekday>" is deliberately the same day (spec: no week-after-next).
      return _isoOf(_plusDays(anchor, _weekdayDelta(anchor, weekday)));
    }

    final String? count = g('n');
    if (count != null) {
      final int? n = _number(count);
      if (n == null || n < 1) return null;
      final bool weeks = g('unit')!.toLowerCase().startsWith('w');
      return _isoOf(_plusDays(anchor, weeks ? n * 7 : n));
    }

    final String? next = g('next');
    if (next != null) {
      if (next.toLowerCase() == 'week') {
        // R3: Monday strictly after the recording day.
        int delta = (DateTime.monday - anchor.weekday) % 7;
        if (delta == 0) delta = 7;
        return _isoOf(_plusDays(anchor, delta));
      }
      // R3: the 1st of the following month (month 13 rolls the year).
      return _isoOf(DateTime(anchor.year, anchor.month + 1, 1));
    }

    final String? endOf = g('endOf');
    if (endOf != null) {
      if (endOf.toLowerCase() == 'week') {
        // The coming Sunday, or the recording day itself if it is a Sunday.
        return _isoOf(_plusDays(anchor, (DateTime.sunday - anchor.weekday) % 7));
      }
      // Day 0 of next month is the last day of this one.
      return _isoOf(DateTime(anchor.year, anchor.month + 1, 0));
    }

    final String? weekend = g('weekend');
    if (weekend != null) {
      // V2: the coming Saturday STRICTLY after the recording day (R1: said
      // on a Saturday → next Saturday); "next weekend" is the one after.
      int delta = (DateTime.saturday - anchor.weekday) % 7;
      if (delta == 0) delta = 7;
      if (weekend.toLowerCase() == 'next') delta += 7;
      return _isoOf(_plusDays(anchor, delta));
    }

    final String? dom = g('dom');
    if (dom != null) {
      // V3: the next such day-of-month on or after the recording day,
      // skipping months that do not have it (the 31st in September).
      final int day = int.parse(dom);
      if (day < 1 || day > 31) return null;
      for (int i = 0; i <= 12; i++) {
        final DateTime first = DateTime(anchor.year, anchor.month + i, 1);
        if (!_isValidDate(first.year, first.month, day)) continue;
        final DateTime candidate = DateTime(first.year, first.month, day);
        if (!candidate.isBefore(anchor)) return _isoOf(candidate);
      }
      return null;
    }

    final String? weeksFrom = g('wn');
    if (weeksFrom != null) {
      // V4: resolve the inner phrase, then +7 per week.
      final int? n = _number(weeksFrom);
      if (n == null || n < 1) return null;
      final String from = g('from')!.toLowerCase();
      final int inner;
      if (from == 'today') {
        inner = 0;
      } else if (from == 'tomorrow') {
        inner = 1;
      } else {
        inner = _weekdayDelta(anchor, from);
      }
      return _isoOf(_plusDays(anchor, inner + n * 7));
    }

    // V5: tonight / this morning|afternoon|evening / end of the day → today.
    if (g('dayish') != null) return _isoOf(anchor);
    return null;
  }

  /// V5 phrases carry a date but are natural item text ("call mom tonight"):
  /// the date is taken and NOTHING is stripped.
  static bool _keepsText(RegExpMatch m) => m.namedGroup('dayish') != null;

  /// R1: days until the next [weekday] STRICTLY after [anchor].
  static int _weekdayDelta(DateTime anchor, String weekday) {
    final int target = _weekdays[weekday.toLowerCase().substring(0, 3)]!;
    int delta = (target - anchor.weekday) % 7;
    if (delta == 0) delta = 7;
    return delta;
  }

  /// D2 resolution of the absolute forms:
  /// - explicit year → that date as spoken; invalid (Feb 30) → null;
  /// - no year → the next occurrence on or after the recording day, never in
  ///   the past; Feb 29 → the next leap occurrence within four years, else null.
  static String? _resolveAbsolute(RegExpMatch m, DateTime anchor) {
    final int? month;
    final int? day;
    final String? yearText;
    if (m.namedGroup('m1') != null) {
      month = _monthNumber(m.namedGroup('m1')!);
      day = int.tryParse(m.namedGroup('d1')!);
      yearText = m.namedGroup('y1');
    } else if (m.namedGroup('m2') != null) {
      month = _monthNumber(m.namedGroup('m2')!);
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
      return _isValidDate(year, month, day) ? _iso(year, month, day) : null;
    }

    for (int year = anchor.year; year <= anchor.year + 4; year++) {
      if (!_isValidDate(year, month, day)) continue;
      if (!DateTime(year, month, day).isBefore(anchor)) {
        return _iso(year, month, day);
      }
    }
    return null;
  }

  static DateTime _plusDays(DateTime anchor, int days) =>
      DateTime(anchor.year, anchor.month, anchor.day + days);

  static int? _monthNumber(String name) {
    final String key = name.toLowerCase();
    if (key.length < 3) return null;
    final int index = _monthPrefixes.indexOf(key.substring(0, 3));
    return index < 0 ? null : index + 1;
  }

  /// `3`, `three`, `twenty-one`, `twenty one`, `thirty`, `a`/`an` → int.
  static int? _number(String text) {
    final String key = text.toLowerCase().trim();
    final int? digits = int.tryParse(key);
    if (digits != null) return digits;
    if (key == 'a' || key == 'an') return 1;
    if (key == 'thirty') return 30;
    final List<String> parts = key.split(RegExp(r'[\s-]+'));
    int total = 0;
    for (final String part in parts) {
      final int index = _numberWords.indexOf(part);
      if (index < 0) return null;
      total += index + 1;
    }
    return total;
  }

  static bool _isValidDate(int year, int month, int day) {
    final DateTime d = DateTime(year, month, day);
    return d.year == year && d.month == month && d.day == day;
  }

  static String _isoOf(DateTime d) => _iso(d.year, d.month, d.day);

  static String _iso(int year, int month, int day) =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  /// Sentence punctuation Whisper glues to the FRONT of the first item:
  /// it closes the trigger phrase with a period ("…to do list. Go to the
  /// store"), so the span opens with ". ". Real-data finding, v1.23.0.
  static final RegExp _leadingPunctuation = RegExp(r'^[.,;:!?…\s]+');

  static String _clean(String raw) {
    String item = raw.trim().replaceAll(_whitespace, ' ');
    item = item.replaceFirst(_leadingPunctuation, '');
    item = item.replaceFirst(_leadingTo, '');
    // Trailing sentence punctuation, then any space it was hiding.
    while (item.endsWith('.')) {
      item = item.substring(0, item.length - 1).trimRight();
    }
    item = item.trim();
    if (item.isEmpty || !_hasContent.hasMatch(item)) return '';
    return item.length > maxItemLength
        ? item.substring(0, maxItemLength).trimRight()
        : item;
  }
}
