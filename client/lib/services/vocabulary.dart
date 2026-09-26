// SPDX-License-Identifier: AGPL-3.0-or-later
/// Client-side mirror of the server's custom-vocabulary canonicalisation
/// (`server/app/vocabulary.py`, spec §2).
///
/// The Settings editor shows `"<N> terms · ~<T> tokens"` live as the user
/// types, before anything reaches the server. For that line to be honest it
/// must count the way the server will: same delimiters, same trimming, same
/// case-insensitive first-spelling-wins de-dupe, same `len ~/ 4` token
/// heuristic over the canonical comma-joined text. After a Save the server's
/// own numbers replace these — this file only has to agree with it well
/// enough that the count never jumps on Save.
library;

/// faster-whisper's hotwords cap (`max_length // 2 - 1`). Terms past this
/// are silently dropped server-side, so the editor warns instead.
const int kVocabularyTokenBudget = 223;

/// Rule 4 limits — the server answers 422 past either. Mirrored here only
/// for tests and copy; the editor lets the server be the judge.
const int kVocabularyMaxTermLength = 64;
const int kVocabularyMaxTerms = 200;

final RegExp _kDelimiters = RegExp(r'[\n,]');

/// Spec §2 rules 1–3: split on newline AND comma, strip, drop empties,
/// de-dupe case-insensitively keeping the first spelling seen.
List<String> normalizeVocabulary(String text) {
  final Set<String> seen = <String>{};
  final List<String> terms = <String>[];
  for (final String raw in text.split(_kDelimiters)) {
    final String term = raw.trim();
    if (term.isEmpty) continue;
    if (!seen.add(term.toLowerCase())) continue;
    terms.add(term);
  }
  return terms;
}

/// The canonical comma-joined form the server stores and feeds to
/// `hotwords` — what the token estimate is measured over.
String vocabularyText(List<String> terms) => terms.join(', ');

/// The server's fallback heuristic when no tokenizer is loaded:
/// `len(text) // 4` over the canonical text.
int estimateVocabularyTokens(List<String> terms) =>
    vocabularyText(terms).length ~/ 4;

/// The status line under the editor. One place so the widget and its test
/// cannot drift on wording.
String vocabularyStatusLine({
  required int termCount,
  required int tokenEstimate,
  required bool overBudget,
}) {
  final String base = '$termCount terms · ~$tokenEstimate tokens';
  if (!overBudget) return base;
  return '$base — over the $kVocabularyTokenBudget-token budget; later terms '
      'will be ignored';
}
