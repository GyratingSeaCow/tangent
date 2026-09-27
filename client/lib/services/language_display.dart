// SPDX-License-Identifier: AGPL-3.0-or-later
/// Human names for the ISO 639-1 codes Whisper reports (v1.19.0 Part A).
///
/// Only the ~20 languages people actually record in; anything else falls
/// back to the code upper-cased ('CY'), which is still recognisable and
/// never wrong.
library;

const Map<String, String> _languageNames = <String, String>{
  'en': 'English',
  'es': 'Spanish',
  'fr': 'French',
  'de': 'German',
  'it': 'Italian',
  'pt': 'Portuguese',
  'nl': 'Dutch',
  'ru': 'Russian',
  'zh': 'Chinese',
  'ja': 'Japanese',
  'ko': 'Korean',
  'ar': 'Arabic',
  'hi': 'Hindi',
  'tr': 'Turkish',
  'pl': 'Polish',
  'uk': 'Ukrainian',
  'sv': 'Swedish',
  'cs': 'Czech',
  'el': 'Greek',
  'he': 'Hebrew',
};

/// 'Spanish' for 'es'; the upper-cased code for anything unlisted. Case-
/// insensitive on input; an empty code yields an empty string.
String languageDisplayName(String code) {
  final String key = code.trim().toLowerCase();
  if (key.isEmpty) return '';
  return _languageNames[key] ?? key.toUpperCase();
}

/// True when the row's detected language warrants a tag: known and not
/// English (the common case stays quiet).
bool isForeignLanguage(String? code) {
  final String? key = code?.trim().toLowerCase();
  return key != null && key.isNotEmpty && key != 'en';
}
