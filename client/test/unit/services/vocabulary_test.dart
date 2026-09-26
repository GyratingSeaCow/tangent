// SPDX-License-Identifier: AGPL-3.0-or-later
/// `normalizeVocabulary` must count the way the server's
/// `normalize_vocabulary` does, or the live `"<N> terms · ~<T> tokens"` line
/// jumps the moment Save returns. Rules pinned here mirror spec §2.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/vocabulary.dart';

void main() {
  group('normalizeVocabulary', () {
    test('splits on newlines', () {
      expect(
        normalizeVocabulary('Hermes\nCachyOS\nTangent'),
        <String>['Hermes', 'CachyOS', 'Tangent'],
      );
    });

    test('splits on commas', () {
      expect(
        normalizeVocabulary('Hermes, CachyOS,Tangent'),
        <String>['Hermes', 'CachyOS', 'Tangent'],
      );
    });

    test('splits on both delimiters in one text', () {
      expect(
        normalizeVocabulary('Hermes, CachyOS\nTangent,Drift\n'),
        <String>['Hermes', 'CachyOS', 'Tangent', 'Drift'],
      );
    });

    test('strips whitespace and drops empties', () {
      expect(
        normalizeVocabulary('  Hermes  ,, \n\n , Tangent \t'),
        <String>['Hermes', 'Tangent'],
      );
    });

    test('de-dupes case-insensitively, first spelling wins', () {
      expect(
        normalizeVocabulary('Hermes\nhermes\nHERMES\nTangent'),
        <String>['Hermes', 'Tangent'],
      );
      expect(
        normalizeVocabulary('hermes, Hermes'),
        <String>['hermes'],
      );
    });

    test('canonical round-trip example from the spec: "b\\n a,b" → [b, a]',
        () {
      expect(normalizeVocabulary('b\n a,b'), <String>['b', 'a']);
    });

    test('empty and whitespace-only text → []', () {
      expect(normalizeVocabulary(''), isEmpty);
      expect(normalizeVocabulary('   \n , \n'), isEmpty);
    });

    test('does not split on spaces or other punctuation', () {
      expect(
        normalizeVocabulary('Visual Studio Code; Hermes Agent'),
        <String>['Visual Studio Code; Hermes Agent'],
      );
    });
  });

  group('token estimate', () {
    test('is len ~/ 4 over the canonical comma-joined text', () {
      final List<String> terms = normalizeVocabulary('Hermes\nCachyOS\nTangent');
      // "Hermes, CachyOS, Tangent" is 24 chars → 6.
      expect(vocabularyText(terms), 'Hermes, CachyOS, Tangent');
      expect(estimateVocabularyTokens(terms), 6);
    });

    test('empty list → 0', () {
      expect(estimateVocabularyTokens(const <String>[]), 0);
    });

    test('budget constant matches faster-whisper max_length // 2 - 1', () {
      expect(kVocabularyTokenBudget, 223);
    });
  });

  group('vocabularyStatusLine', () {
    test('plain form', () {
      expect(
        vocabularyStatusLine(termCount: 3, tokenEstimate: 6, overBudget: false),
        '3 terms · ~6 tokens',
      );
    });

    test('over-budget form names the budget and the consequence', () {
      expect(
        vocabularyStatusLine(
          termCount: 90,
          tokenEstimate: 240,
          overBudget: true,
        ),
        '90 terms · ~240 tokens — over the 223-token budget; later terms '
        'will be ignored',
      );
    });
  });
}
