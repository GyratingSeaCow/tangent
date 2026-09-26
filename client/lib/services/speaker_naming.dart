// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Speaker naming (v1.15.0, docs/design/2026-09-26-speaker-naming.md §2).
//
// Pure text functions over a diarized transcript as rendered by
// `formatMeetingTranscript`: `## Speaker N` sections in order of first
// appearance, optional final `## [unattributed]`. Naming a speaker rewrites
// the transcript text in place (decision S1=b) — there is no name map, so
// everything here is a function of the transcript string alone.

/// `## <heading>` line; group 1 is the heading text with surrounding
/// whitespace trimmed away.
final RegExp _headingLine = RegExp(r'^## (.*?)\s*$');

/// A diarization label exactly as the formatter emits it.
final RegExp _speakerLabel = RegExp(r'^Speaker \d+$');

/// Section headings that are never speakers — the formatter's own
/// `[unattributed]` plus the headings the summarizer / meeting notes use.
const Set<String> _knownSectionHeadings = <String>{
  '[unattributed]',
  'Meeting Summary',
  'Action Items',
  'Transcript',
  'Summary',
};

/// Hint length cap (spec §2): longer first lines are cut and ellipsised.
const int _hintMaxChars = 80;

/// Speaker labels present in [transcript], in document order.
/// Matches `## Speaker N` headings only; `[unattributed]` is never a speaker.
List<String> detectSpeakers(String transcript) {
  final List<String> out = <String>[];
  for (final String heading in _headings(transcript)) {
    if (_speakerLabel.hasMatch(heading) && !out.contains(heading)) {
      out.add(heading);
    }
  }
  return out;
}

/// First non-empty line under each `## <label>` heading — the hint shown
/// beside the field ("Ended up getting fired and…", ellipsised at 80 chars).
///
/// Keyed by heading text for every heading, not just `Speaker N`, so the
/// sheet still gets hints for a speaker that was already renamed once.
Map<String, String> firstLineBySpeaker(String transcript) {
  final Map<String, String> out = <String, String>{};
  String? current;
  for (final String raw in transcript.split('\n')) {
    final String line = _stripCr(raw);
    final RegExpMatch? heading = _headingLine.firstMatch(line);
    if (heading != null) {
      current = heading.group(1)!;
      continue;
    }
    if (current == null || out.containsKey(current)) continue;
    final String text = line.trim();
    if (text.isEmpty) continue;
    out[current] = _ellipsise(text);
  }
  return out;
}

/// Rewrites [transcript] applying [renames] (old label → new name).
/// - Replaces the `## Old` heading line (exact) with `## New`.
/// - Replaces inline whole-word `Old:` turn prefixes (`^Old: ` at line start)
///   with `New: ` — covers the timestamped-paragraph fallback and any
///   hand-typed turns. Never touches `Old` inside prose.
/// - Empty / whitespace new name ⇒ that speaker is left unchanged.
/// - Trims names; collapses internal runs of whitespace to one space.
/// - Idempotent; returns [transcript] unchanged when nothing applies.
String applySpeakerNames(String transcript, Map<String, String> renames) {
  final Map<String, String> effective = <String, String>{};
  for (final MapEntry<String, String> entry in renames.entries) {
    final String name = normalizeSpeakerName(entry.value);
    if (name.isEmpty || name == entry.key) continue;
    effective[entry.key] = name;
  }
  if (effective.isEmpty) return transcript;

  final List<String> lines = transcript.split('\n');
  bool changed = false;
  for (int i = 0; i < lines.length; i++) {
    final String raw = lines[i];
    final String line = _stripCr(raw);
    final String eol = raw.length == line.length ? '' : '\r';
    // Each line is matched against the ORIGINAL labels exactly once, so a
    // swap (Speaker 1 → Speaker 2, Speaker 2 → Speaker 1) cannot chain.
    for (final MapEntry<String, String> entry in effective.entries) {
      final String old = entry.key;
      final String fresh = entry.value;
      if (line == '## $old') {
        lines[i] = '## $fresh$eol';
        changed = true;
        break;
      }
      // `Old:` as a whole-word turn prefix at line start only.
      if (line.startsWith('$old:') &&
          (line.length == old.length + 1 ||
              _isWhitespace(line[old.length + 1]))) {
        lines[i] = '$fresh:${line.substring(old.length + 1)}$eol';
        changed = true;
        break;
      }
    }
  }
  return changed ? lines.join('\n') : transcript;
}

/// Names a user has typed before: every `## <heading>` across [transcripts]
/// that is not `Speaker N`, `[unattributed]`, or a known section heading
/// (`Meeting Summary`, `Action Items`, `Transcript`, `Summary`); most-
/// recently-seen first (caller passes newest transcript first); max 8;
/// case-exact dedupe.
List<String> suggestedSpeakerNames(Iterable<String> transcriptsNewestFirst) {
  const int max = 8;
  final List<String> out = <String>[];
  for (final String transcript in transcriptsNewestFirst) {
    for (final String heading in _headings(transcript)) {
      if (heading.isEmpty ||
          _speakerLabel.hasMatch(heading) ||
          _knownSectionHeadings.contains(heading) ||
          out.contains(heading)) {
        continue;
      }
      out.add(heading);
      if (out.length >= max) return out;
    }
  }
  return out;
}

/// Trims and collapses internal whitespace runs to one space — the exact
/// normalisation [applySpeakerNames] writes, so collision checks compare
/// what would actually land in the transcript.
String normalizeSpeakerName(String name) =>
    name.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Collision rule (spec §2): labels whose typed name is refused.
///
/// [typed] maps each speaker label to whatever the user entered (blank
/// allowed). A label collides when its normalised name (a) equals a name
/// already claimed by an EARLIER label in [typed] iteration order — the
/// second field is the one that shows "Already used" — or (b) equals any
/// `## <heading>` already present in [transcript] (`Speaker 2` typed for
/// Speaker 1, say). Blank entries never collide.
Set<String> collidingSpeakerNames(
  String transcript,
  Map<String, String> typed,
) {
  final Set<String> headings = _headings(transcript).toSet();
  final Set<String> claimed = <String>{};
  final Set<String> colliding = <String>{};
  for (final MapEntry<String, String> entry in typed.entries) {
    final String name = normalizeSpeakerName(entry.value);
    if (name.isEmpty) continue;
    if (headings.contains(name) || !claimed.add(name)) {
      colliding.add(entry.key);
    }
  }
  return colliding;
}

Iterable<String> _headings(String transcript) sync* {
  for (final String raw in transcript.split('\n')) {
    final RegExpMatch? m = _headingLine.firstMatch(_stripCr(raw));
    if (m != null) yield m.group(1)!;
  }
}

String _stripCr(String line) =>
    line.endsWith('\r') ? line.substring(0, line.length - 1) : line;

bool _isWhitespace(String ch) => ch.trim().isEmpty;

String _ellipsise(String text) {
  if (text.length <= _hintMaxChars) return text;
  return '${text.substring(0, _hintMaxChars - 1).trimRight()}…';
}
