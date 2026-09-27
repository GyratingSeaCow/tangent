// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pulls to-do items out of a spoken transcript (To Do arc Phase 2).
///
/// Pure and side-effect free on purpose: the detection rules are the part
/// that has to be provably right, so they live away from the database and
/// the sync engine where they can be unit-tested one rule at a time.
///
/// Spec: docs/design/2026-09-27-todo-voice-capture.md §"Parsing rules".
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
  static List<String> parse(String? transcript) {
    if (transcript == null || transcript.isEmpty) return const <String>[];
    final RegExpMatch? match = _trigger.firstMatch(transcript);
    if (match == null) return const <String>[];

    final String span = transcript.substring(match.end);
    if (span.trim().isEmpty) return const <String>[];

    final List<String> items = <String>[];
    for (final String raw in span.split(_separator)) {
      final String item = _clean(raw);
      if (item.isEmpty) continue;
      items.add(item);
      if (items.length == maxItems) break;
    }
    return items;
  }

  static String _clean(String raw) {
    String item = raw.trim().replaceAll(_whitespace, ' ');
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
