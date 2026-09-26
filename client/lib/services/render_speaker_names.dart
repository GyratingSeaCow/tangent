// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Speaker name rendering (v1.17.0, spec §3): look-up everywhere.
//
// The stored transcript keeps raw `## Speaker N` labels; every surface
// renders names through [renderSpeakerNames]. Edit mode shows the rendered
// text and applies [unrenderSpeakerNames] on save, so the stored text is
// never derived from what the user saw — only from the map they saw it
// through.

import '../models/speaker_names.dart';

/// [transcript] with each `## <label>` heading and line-leading `<label>: `
/// turn prefix replaced by `names.nameFor(label)`. Prose is untouched;
/// unmapped labels pass through; pure; returns [transcript] itself when
/// [names] is empty or nothing matches.
String renderSpeakerNames(String transcript, SpeakerNames names) =>
    rewriteSpeakerLabels(transcript, names.entries);

/// The reverse map for Edit-mode save: `## Jeff` → `## Speaker 1` and
/// `Jeff: ` → `Speaker 1: ` for every (label, name) in [names]. A heading
/// or prefix that matches no mapped name is left exactly as typed.
String unrenderSpeakerNames(String rendered, SpeakerNames names) =>
    rewriteSpeakerLabels(rendered, <String, String>{
      for (final MapEntry<String, String> e in names.entries.entries)
        e.value: e.key,
    });

/// Rewrites `## <from>` heading lines and whole-word `<from>:` turn prefixes
/// (at line start only) to `<to>`. Each line is matched against the
/// ORIGINAL keys exactly once, so a swap (`Speaker 1`↔`Speaker 2`) cannot
/// chain. Case-exact; CR line endings preserved; prose never touched.
String rewriteSpeakerLabels(String text, Map<String, String> mapping) {
  final Map<String, String> effective = <String, String>{
    for (final MapEntry<String, String> e in mapping.entries)
      if (e.key.isNotEmpty && e.value.isNotEmpty && e.key != e.value)
        e.key: e.value,
  };
  if (effective.isEmpty || text.isEmpty) return text;

  final List<String> lines = text.split('\n');
  bool changed = false;
  for (int i = 0; i < lines.length; i++) {
    final String raw = lines[i];
    final bool cr = raw.endsWith('\r');
    final String line = cr ? raw.substring(0, raw.length - 1) : raw;
    final String eol = cr ? '\r' : '';
    for (final MapEntry<String, String> e in effective.entries) {
      final String from = e.key;
      final String to = e.value;
      if (line.startsWith('## ') && line.substring(3).trimRight() == from) {
        lines[i] = '## $to$eol';
        changed = true;
        break;
      }
      if (line.startsWith('$from:') &&
          (line.length == from.length + 1 ||
              line[from.length + 1].trim().isEmpty)) {
        lines[i] = '$to:${line.substring(from.length + 1)}$eol';
        changed = true;
        break;
      }
    }
  }
  return changed ? lines.join('\n') : text;
}
