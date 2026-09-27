// SPDX-License-Identifier: AGPL-3.0-or-later

/// The result of [TodoVoiceParser.parseWithDate]: the items plus the ONE
/// due date a leading date phrase gave every item (v1.26.0, D1).
class VoiceTodoParse {
  const VoiceTodoParse({required this.items, this.dueDate});

  /// The items spoken after the trigger, in order (see [TodoVoiceParser.parse]).
  final List<String> items;

  /// ISO `YYYY-MM-DD`, or null when no leading date phrase was recognised.
  final String? dueDate;

  static const VoiceTodoParse empty = VoiceTodoParse(items: <String>[]);
}

/// Pulls to-do items out of a spoken transcript (To Do arc Phase 2).
///
/// Pure and side-effect free on purpose: the detection rules are the part
/// that has to be provably right, so they live away from the database and
/// the sync engine where they can be unit-tested one rule at a time.
///
/// Spec: docs/design/2026-09-27-todo-voice-capture.md §"Parsing rules";
/// due dates: docs/design/2026-09-27-voice-todo-due-dates.md.
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
  static const String _month =
      r'(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?'
      r'|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?'
      r'|dec(?:ember)?)\.?';

  static const String _day = r'(\d{1,2})(?:st|nd|rd|th)?';
  static const String _year = r'(?:,?\s+(\d{4}))?';

  /// ONE leading date phrase at the head of the span (D1: only at the
  /// front). Groups, per form:
  ///   1 month name  2 day  3 year        — `September 30th, 2027`
  ///   4 day  5 month name  6 year         — `the 30th of September`
  ///   7 month  8 day  9 year              — `9/30`, `09/30/2027`
  /// The trailing `to` is the "to go to the store" of the real recording;
  /// it belongs to the phrase, not the item (spec fixture 1 / sabotage S5).
  static final RegExp _leadingDate = RegExp(
    r'^[.,;:!?…\s]*'
    r'(?:(?:for|on|by|due(?:\s+on)?)\s+)?'
    r'(?:the\s+)?'
    r'(?:'
    '$_month\\s+$_day$_year'
    '|$_day\\s+of\\s+$_month$_year'
    r'|(\d{1,2})[/-](\d{1,2})(?:[/-](\d{4}))?'
    r')'
    r'(?![0-9a-z])'
    r'[.,:]?\s*'
    r'(?:to\s+)?',
    caseSensitive: false,
  );

  static const List<String> _monthPrefixes = <String>[
    'jan', 'feb', 'mar', 'apr', 'may', 'jun',
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];

  /// Returns true when [transcript] contains a trigger phrase at all.
  static bool hasTrigger(String? transcript) =>
      transcript != null && _trigger.hasMatch(transcript);

  /// The items spoken after the first trigger phrase, in order.
  ///
  /// Returns an empty list when there is no trigger, or when the span after
  /// the trigger is empty/whitespace (rule 6: saying the phrase alone does
  /// nothing — no items, and therefore no card).
  ///
  /// A leading date phrase is stripped from the first item exactly as
  /// [parseWithDate] does; the date itself is only reachable there. The
  /// day the transcript was recorded is irrelevant to the TEXT of the
  /// items, so any anchor day gives the same list.
  static List<String> parse(String? transcript) =>
      parseWithDate(transcript, recordedOn: _anyDay).items;

  static final DateTime _anyDay = DateTime(2000, 1, 1);

  /// [parse] plus the due date named by ONE leading date phrase.
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
    final RegExpMatch? date = _leadingDate.firstMatch(span);
    if (date != null) {
      dueDate = resolveSpokenDate(date, recordedOn);
      // An unresolvable phrase (Feb 30) is left in place as item text — the
      // user said something, and guessing a date would be worse than none.
      if (dueDate != null) span = span.substring(date.end);
    }
    if (span.trim().isEmpty) return VoiceTodoParse(items: const <String>[], dueDate: dueDate);

    final List<String> items = <String>[];
    for (final String raw in span.split(_separator)) {
      final String item = _clean(raw);
      if (item.isEmpty) continue;
      items.add(item);
      if (items.length == maxItems) break;
    }
    return VoiceTodoParse(items: items, dueDate: dueDate);
  }

  /// Turns a [_leadingDate] match into ISO `YYYY-MM-DD`, or null when the
  /// spoken date is not a real calendar date (D2 resolution).
  ///
  /// - explicit year → that date as spoken; invalid (Feb 30) → null;
  /// - no year → the next occurrence on or after [recordedOn] (date part
  ///   only), never in the past; Feb 29 → the next leap occurrence within
  ///   four years, else null.
  static String? resolveSpokenDate(RegExpMatch match, DateTime recordedOn) {
    final int? month;
    final int? day;
    final String? yearText;
    if (match.group(1) != null) {
      month = _monthNumber(match.group(1)!);
      day = int.tryParse(match.group(2)!);
      yearText = match.group(3);
    } else if (match.group(5) != null) {
      month = _monthNumber(match.group(5)!);
      day = int.tryParse(match.group(4)!);
      yearText = match.group(6);
    } else {
      month = int.tryParse(match.group(7)!);
      day = int.tryParse(match.group(8)!);
      yearText = match.group(9);
    }
    if (month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;

    if (yearText != null) {
      final int year = int.parse(yearText);
      return _isValidDate(year, month, day) ? _iso(year, month, day) : null;
    }

    final DateTime anchor =
        DateTime(recordedOn.year, recordedOn.month, recordedOn.day);
    for (int year = anchor.year; year <= anchor.year + 4; year++) {
      if (!_isValidDate(year, month, day)) continue;
      if (!DateTime(year, month, day).isBefore(anchor)) {
        return _iso(year, month, day);
      }
    }
    return null;
  }

  static int? _monthNumber(String name) {
    final String key = name.toLowerCase();
    if (key.length < 3) return null;
    final int index = _monthPrefixes.indexOf(key.substring(0, 3));
    return index < 0 ? null : index + 1;
  }

  static bool _isValidDate(int year, int month, int day) {
    final DateTime d = DateTime(year, month, day);
    return d.year == year && d.month == month && d.day == day;
  }

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
