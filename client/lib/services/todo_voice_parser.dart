// SPDX-License-Identifier: AGPL-3.0-or-later
import 'voice_date_grammar.dart';

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

  static const VoiceTodoParse empty =
      VoiceTodoParse(entries: <VoiceTodoItem>[]);
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
    final RegExpMatch? date = VoiceDateGrammar.headDate.firstMatch(span);
    if (date != null) {
      final String? resolved = VoiceDateGrammar.resolve(date, recordedOn);
      // An unresolvable phrase (Feb 30) is left in place as item text — the
      // user said something, and guessing a date would be worse than none.
      // A relative word that IS the whole span ("…to-do list, today.") is
      // kept as an item too (phrase-was-the-whole-item rule, fixture 9);
      // an absolute date alone still yields no items, as in v1.26.0.
      final bool wholeSpan = span.substring(date.end).trim().isEmpty;
      final bool keepAsText = wholeSpan &&
          date.namedGroup('m1') == null &&
          date.namedGroup('m2') == null &&
          date.namedGroup('m3') == null;
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
    final RegExpMatch? atEnd = VoiceDateGrammar.itemEndDate.firstMatch(cleaned);
    if (atEnd != null) {
      dueDate = VoiceDateGrammar.resolve(atEnd, recordedOn);
      if (dueDate != null) {
        // V5: "tonight" carries the date AND belongs in the text.
        if (VoiceDateGrammar.keepsText(atEnd)) {
          return VoiceTodoItem(cleaned, dueDate: dueDate);
        }
        // V1: the time phrase stays where the date phrase was.
        final String time = <String?>[
          atEnd.namedGroup('tb'),
          atEnd.namedGroup('ta'),
        ].whereType<String>().join(' ');
        rest = '${cleaned.substring(0, atEnd.start)} $time';
      }
    }
    if (dueDate == null) {
      final RegExpMatch? atStart =
          VoiceDateGrammar.itemStartDate.firstMatch(cleaned);
      if (atStart != null) {
        dueDate = VoiceDateGrammar.resolve(atStart, recordedOn);
        if (dueDate != null) {
          if (VoiceDateGrammar.keepsText(atStart)) {
            return VoiceTodoItem(cleaned, dueDate: dueDate);
          }
          rest = cleaned.substring(atStart.end);
        }
      }
    }
    if (dueDate == null) return VoiceTodoItem(cleaned);
    final String text = _clean(rest);
    if (text.isEmpty) return VoiceTodoItem(cleaned);
    return VoiceTodoItem(text, dueDate: dueDate);
  }

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
