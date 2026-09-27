// SPDX-License-Identifier: AGPL-3.0-or-later
/// v1.19.0 Part A: language names and the tag-worthiness rule.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/language_display.dart';

void main() {
  group('languageDisplayName', () {
    test('names the common Whisper languages', () {
      expect(languageDisplayName('en'), 'English');
      expect(languageDisplayName('es'), 'Spanish');
      expect(languageDisplayName('fr'), 'French');
      expect(languageDisplayName('de'), 'German');
      expect(languageDisplayName('it'), 'Italian');
      expect(languageDisplayName('pt'), 'Portuguese');
      expect(languageDisplayName('nl'), 'Dutch');
      expect(languageDisplayName('ru'), 'Russian');
      expect(languageDisplayName('zh'), 'Chinese');
      expect(languageDisplayName('ja'), 'Japanese');
      expect(languageDisplayName('ko'), 'Korean');
      expect(languageDisplayName('ar'), 'Arabic');
      expect(languageDisplayName('hi'), 'Hindi');
      expect(languageDisplayName('tr'), 'Turkish');
      expect(languageDisplayName('pl'), 'Polish');
      expect(languageDisplayName('uk'), 'Ukrainian');
      expect(languageDisplayName('sv'), 'Swedish');
      expect(languageDisplayName('cs'), 'Czech');
      expect(languageDisplayName('el'), 'Greek');
      expect(languageDisplayName('he'), 'Hebrew');
    });

    test('falls back to the upper-cased code', () {
      expect(languageDisplayName('cy'), 'CY');
      expect(languageDisplayName('haw'), 'HAW');
    });

    test('is case- and whitespace-insensitive; empty stays empty', () {
      expect(languageDisplayName(' ES '), 'Spanish');
      expect(languageDisplayName(''), '');
    });
  });

  group('isForeignLanguage', () {
    test('null, empty and English are not tag-worthy', () {
      expect(isForeignLanguage(null), isFalse);
      expect(isForeignLanguage(''), isFalse);
      expect(isForeignLanguage('en'), isFalse);
      expect(isForeignLanguage('EN'), isFalse);
    });

    test('anything else is', () {
      expect(isForeignLanguage('es'), isTrue);
      expect(isForeignLanguage('cy'), isTrue);
    });
  });
}
