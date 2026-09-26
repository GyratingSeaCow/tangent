// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Speaker name map (v1.17.0, docs/design/2026-09-26-speaker-name-map.md §1).
//
// Names live ONLY in this per-recording map; the transcript text keeps its
// raw `## Speaker N` labels and every surface renders names by look-up
// (decision N1=a). Stored as the JSON object `{"Speaker 1": "Jeff"}` in
// `dumps.speaker_names` on both client and server; null/absent = no names.

import 'dart:convert';

import '../services/speaker_naming.dart' show normalizeSpeakerName;

/// Immutable, value-equal map from raw diarization label (`Speaker 1`) to
/// the name a user gave it. Never contains blank names.
class SpeakerNames {
  /// Builds from [entries]; blank names and blank labels are dropped,
  /// names are trimmed with internal whitespace runs collapsed (the same
  /// normalisation the naming sheet applies).
  SpeakerNames(Map<String, String> entries)
      : _entries = Map<String, String>.unmodifiable(<String, String>{
          for (final MapEntry<String, String> e in entries.entries)
            if (e.key.trim().isNotEmpty &&
                normalizeSpeakerName(e.value).isNotEmpty)
              e.key: normalizeSpeakerName(e.value),
        });

  const SpeakerNames.empty() : _entries = const <String, String>{};

  /// From the decoded wire/column object. Non-string values are ignored.
  factory SpeakerNames.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SpeakerNames.empty();
    return SpeakerNames(<String, String>{
      for (final MapEntry<String, dynamic> e in json.entries)
        if (e.value is String) e.key: e.value as String,
    });
  }

  /// From the raw column text. Null, blank, malformed, or non-object JSON
  /// all decode to [SpeakerNames.empty] — a corrupt map must never brick a
  /// recording's screen.
  factory SpeakerNames.decode(String? json) {
    if (json == null || json.trim().isEmpty) return const SpeakerNames.empty();
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        return SpeakerNames.fromJson(decoded);
      }
    } on FormatException {
      // fall through
    }
    return const SpeakerNames.empty();
  }

  final Map<String, String> _entries;

  bool get isEmpty => _entries.isEmpty;
  bool get isNotEmpty => _entries.isNotEmpty;
  int get length => _entries.length;

  /// Label → name, insertion order, unmodifiable.
  Map<String, String> get entries => _entries;

  /// Raw labels that carry a name.
  Iterable<String> get labels => _entries.keys;

  /// Names in map order (chips, `speakers:` frontmatter).
  Iterable<String> get names => _entries.values;

  bool hasName(String label) => _entries.containsKey(label);

  /// The mapped name, or [label] itself when unmapped — callers render
  /// `nameFor(segment.speaker)` without a null check.
  String nameFor(String label) => _entries[label] ?? label;

  /// A copy with [label] renamed to [name]; blank [name] removes the key.
  SpeakerNames withRename(String label, String name) {
    final String clean = normalizeSpeakerName(name);
    final Map<String, String> next = Map<String, String>.of(_entries);
    if (clean.isEmpty) {
      next.remove(label);
    } else {
      next[label] = clean;
    }
    return SpeakerNames(next);
  }

  /// A copy without [label].
  SpeakerNames without(String label) => withRename(label, '');

  /// JSON object for the wire / column.
  Map<String, dynamic> toJson() => Map<String, dynamic>.of(_entries);

  /// Column text: null when empty (the "no names" representation on both
  /// sides), otherwise the encoded object.
  String? encode() => isEmpty ? null : jsonEncode(_entries);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SpeakerNames || other._entries.length != _entries.length) {
      return false;
    }
    for (final MapEntry<String, String> e in _entries.entries) {
      if (other._entries[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    int h = 0;
    for (final MapEntry<String, String> e in _entries.entries) {
      h ^= Object.hash(e.key, e.value);
    }
    return h;
  }

  @override
  String toString() => 'SpeakerNames($_entries)';
}
