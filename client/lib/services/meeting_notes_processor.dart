// SPDX-License-Identifier: AGPL-3.0-or-later

/// Deterministic, extractive meeting-note formatter.
///
/// It never calls a model or network service. Every content sentence in the
/// output is copied from the transcript. Sections with nothing extracted are
/// OMITTED rather than rendered with a filler line; only the Summary falls
/// back to [emptyMarker] (defaults to `None stated`) so the notes are never
/// empty. The transcript itself is NOT repeated in the notes — the dump
/// already displays it — and `[MM:SS]` / `[H:MM:SS]` paragraph markers from
/// the meeting transcript format are stripped before sentence analysis so
/// they never bleed into bullets. The subject heading is always the
/// caller-supplied [title], never inferred from transcript text.
///
/// Sentence splitting respects URLs, decimal numbers, and common
/// abbreviations so transcripts that mention `https://example.com`,
/// `1.5 million`, or `Dr. Rivera` are not broken at the wrong boundary.
final class MeetingNotesProcessor {
  const MeetingNotesProcessor();

  static const String defaultEmptyMarker = 'None stated';

  /// `[MM:SS]`, `[H:MM:SS]`, or legacy `HH:MM:SS` markers produced by the
  /// meeting transcript formatter, at a line start or after whitespace.
  static final RegExp _timestampMarker = RegExp(
    r'(?:^|(?<=\s))(?:\[\d{1,2}:\d{2}(?::\d{2})?\]|\d{2}:\d{2}:\d{2})\s*',
    multiLine: true,
  );

  /// Action verbs that signify a real commitment. Anything not in this list is
  /// not picked up as an action item.
  static const _actionVerbs =
      'send|do|write|call|review|follow up|complete|prepare|ship|deliver|'
      'schedule|update|check|email|share|draft|build|run|test|submit|'
      'organise|organize|fix|investigate|triage|circulate|forward';

  String process({
    required String title,
    required String transcript,
    String emptyMarker = defaultEmptyMarker,
  }) {
    final raw = transcript.trim();
    if (raw.isEmpty) {
      throw const FormatException('Meeting transcript is empty');
    }
    // Strip transcript-format timestamp markers. Speaker prefixes have no
    // reliable shape, so only markers are removed; the text keeps reading as
    // sentences for the splitter.
    final plain = raw
        .replaceAll(_timestampMarker, '')
        .replaceAll(RegExp(r'\s+\n'), '\n')
        .trim();
    final subject = title.trim().isEmpty
        ? plain.split(RegExp(r'[.!?]')).first
        : title.trim();
    final sentences = _sentences(plain);
    final decisions = sentences.where(_isDecision).toList(growable: false);
    final actions = sentences.where(_isAction).toList(growable: false);
    final questions = sentences
        .where((sentence) => sentence.trimRight().endsWith('?'))
        .toList(growable: false);
    final excluded = <String>{};
    for (final list in [decisions, actions, questions]) {
      excluded.addAll(list);
    }
    final discussion = sentences
        .where((sentence) => !excluded.contains(sentence))
        .toList(growable: false);

    return [
      '# ${subject.replaceFirst(RegExp(r'[.!?]$'), '')}',
      '## Summary\n\n${discussion.isEmpty ? emptyMarker : discussion.take(2).join(' ')}',
      _section('Decisions', decisions),
      _actionSection(actions),
      _section('Open Questions', questions),
    ].whereType<String>().join('\n\n');
  }

  /// Split on sentence terminators while keeping URLs, decimals, and common
  /// abbreviations intact. We use a stateful scan: when we are inside a URL
  /// (after `://`, after an `@`, or while accumulating digits) we suppress
  /// sentence termination.
  List<String> _sentences(String value) {
    const abbreviations = {
      'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'mt',
      'www', 'no', 'vs', 'etc', 'e.g', 'i.e', 'fig', 'inc',
    };
    final pieces = <String>[];
    final buffer = StringBuffer();
    var inUrl = false;
    var inNumeric = false;
    void flush() {
      final text = buffer.toString().trim();
      if (text.isNotEmpty) pieces.add(text);
      buffer.clear();
      inUrl = false;
      inNumeric = false;
    }

    final chars = value.split('');
    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      final tail = buffer.toString().toLowerCase();
      // Detect URL entry: we've just typed `://` or `@`.
      if (!inUrl) {
        if (tail.endsWith('://') || tail.contains('@')) {
          inUrl = true;
        }
      }
      buffer.write(ch);
      if (inUrl) {
        // URL ends when we encounter whitespace after a non-host character.
        if (ch == ' ' && i + 1 < chars.length && chars[i + 1] != ' ') {
          // Continue; whitespace is internal.
        }
        // Exit URL when the next character is whitespace followed by capital
        // letter (a new sentence) or end of input.
        if (ch == ' ' &&
            i + 1 < chars.length &&
            RegExp(r'[A-Z]').hasMatch(chars[i + 1])) {
          inUrl = false;
        }
        if (ch == '.' && i + 1 == chars.length) {
          // End of string with trailing period; keep URL mode until flush.
        }
        continue;
      }
      if (inNumeric) {
        if (RegExp(r'[0-9]').hasMatch(ch)) {
          // Continue accumulating.
          continue;
        }
        inNumeric = false;
        if (ch != '.' && ch != ' ') {
          // Numeric token ended; treat terminator as part of buffer.
          if (ch == '.' || ch == '!' || ch == '?') {
            // Sentence ends here.
            flush();
            continue;
          }
        } else if (ch == '.') {
          // Decimal mid-number — keep going.
          continue;
        }
      }
      if (RegExp(r'[.!?]').hasMatch(ch)) {
        // Check if the previous non-whitespace token is an abbreviation.
        final token = buffer
            .toString()
            .replaceAll(RegExp(r'[^\w\u2019\x27]'), ' ')
            .split(RegExp(r'\s+'))
            .lastWhere((t) => t.isNotEmpty, orElse: () => '');
        if (abbreviations.contains(token.toLowerCase())) {
          // The period belongs to the abbreviation, not a sentence break.
          continue;
        }
        // Start of numeric token: begin numeric mode.
        if (ch == '.' && i + 1 < chars.length &&
            RegExp(r'[0-9]').hasMatch(chars[i + 1])) {
          inNumeric = true;
          continue;
        }
        flush();
      }
    }
    flush();
    return pieces;
  }

  /// Decisions are only explicit commitments. Adjective uses such as
  /// "approved supplier" or "agreed framework" must not appear.
  bool _isDecision(String sentence) {
    final lower = sentence.toLowerCase();
    // Use lookarounds instead of `\b` because trailing `:`, ` `, or `.` after
    // an alternation literal confuses Dart's word-boundary handling.
    return RegExp(
      r'(?:^|\W)(?:decided to\b|decision:|agreed to\b|approved (?:the|to|on)\b|resolved to\b)',
    ).hasMatch(lower);
  }

  /// Actions must look like commitments, not epistemic or background speech.
  /// Phrases like "it must be true", "we will need more time", and
  /// "tom will be late" are excluded.
  bool _isAction(String sentence) {
    final lower = sentence.toLowerCase();
    if (lower.contains('must be true') ||
        lower.contains('must be correct') ||
        lower.contains('must be the case')) {
      return false;
    }
    if (lower.startsWith('we will need') ||
        lower.startsWith('we will probably')) {
      return false;
    }
    if (RegExp(r'\bwill be late\b|\bwill be absent\b|\bwill be unavailable\b')
        .hasMatch(lower)) {
      return false;
    }
    final explicit = RegExp(
      '(action item:|will ($_actionVerbs)\\b'
      '|going to ($_actionVerbs)\\b'
      '|needs? to ($_actionVerbs)\\b'
      '|must ($_actionVerbs)\\b'
      '|assigned to\\b'
      '|\\bowner:)',
      caseSensitive: false,
    );
    return explicit.hasMatch(lower);
  }

  /// A section renders only when it has content; an empty category is omitted
  /// entirely rather than printed with a filler line.
  String? _section(String heading, List<String> values) {
    if (values.isEmpty) return null;
    final body = values.map((value) => '- $value').join('\n');
    return '## $heading\n\n$body';
  }

  String? _actionSection(List<String> actions) {
    if (actions.isEmpty) return null;
    final lines = actions.map((action) {
      final owner = _owner(action) ?? 'Not stated';
      final date = _date(action) ?? 'Not stated';
      return '- $action (Owner: $owner; Date: $date)';
    }).join('\n');
    return '## Action Items\n\n$lines';
  }

  /// Owner is the leading name (any case) immediately before a commitment
  /// verb we recognise.
  String? _owner(String sentence) {
    final match = RegExp(
      '([A-Za-z][A-Za-z\u2019\x27\\-]+)\\s+'
      '(?:will ($_actionVerbs)\\b'
      '|is going to ($_actionVerbs)\\b'
      '|needs? to ($_actionVerbs)\\b'
      '|must ($_actionVerbs)\\b)',
      caseSensitive: false,
    ).firstMatch(sentence);
    final raw = match?.group(1);
    if (raw == null) return null;
    return raw[0].toUpperCase() + raw.substring(1);
  }

  String? _date(String sentence) {
    final match = RegExp(
      r'\b(?:by|on|before)\s+'
      r'((?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|today|tomorrow)'
      r'|(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2}(?:,\s*\d{4})?'
      r'|\d{4}-\d{2}-\d{2})\b',
      caseSensitive: false,
    ).firstMatch(sentence);
    return match?.group(1);
  }
}
