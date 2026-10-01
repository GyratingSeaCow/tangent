// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Name-speakers sheet (docs/design/2026-09-26-speaker-name-map.md §4).
//
// One text field per `## Speaker N` heading in the dump's transcript,
// prefilled with the CURRENT mapped name. Save writes the per-recording
// name MAP (`LocalDb.updateSpeakerNames`) — the transcript text keeps its
// raw labels (decision N1=a) and every surface renders names by look-up.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../models/speaker_names.dart';
import '../../services/speaker_naming.dart';
import '../../widgets/sheet_drag_handle.dart';
import '../home/home_screen.dart' show localDbProvider;

/// Success snackbar text (spec §3).
const String speakersNamedMessage = 'Speakers named';

/// Opens the Name-speakers sheet for [row]. Resolves `true` when the map
/// was saved, `false` on cancel — and immediately `false`, without showing
/// anything, when the transcript has no speakers (the entry points are
/// absent in that case; this is the belt to their braces).
Future<bool> showNameSpeakersSheet(
  BuildContext context,
  WidgetRef ref,
  DumpRow row,
) async {
  final String transcript = row.transcript ?? '';
  if (detectSpeakers(transcript).isEmpty) return false;
  final LocalDb db = ref.read(localDbProvider);
  final SpeakerNames current = SpeakerNames.decode(row.speakerNames);
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final List<String> suggestions = await db.recentSpeakerNamesForSuggestions(
    exclude: current.names,
  );
  if (!context.mounted) return false;
  final bool? saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: NameSpeakersSheet(
        transcript: transcript,
        names: current,
        suggestions: suggestions,
        onSave: (SpeakerNames names) async {
          await db.updateSpeakerNames(row.id, names);
        },
      ),
    ),
  );
  if (saved == true) {
    messenger?.showSnackBar(const SnackBar(content: Text(speakersNamedMessage)));
    return true;
  }
  return false;
}

/// The sheet body. Pure presentation over [transcript] and the current
/// [names]; persistence is the injected [onSave].
class NameSpeakersSheet extends StatefulWidget {
  const NameSpeakersSheet({
    super.key,
    required this.transcript,
    required this.onSave,
    this.names = const SpeakerNames.empty(),
    this.suggestions = const <String>[],
  });

  final String transcript;

  /// The recording's current map; each field prefills from it.
  final SpeakerNames names;

  /// Names used on other recordings, newest first — tap-to-fill chips.
  final List<String> suggestions;

  /// Persists the new map: the current one with every non-blank field
  /// applied as a rename and every cleared field removed.
  final Future<void> Function(SpeakerNames names) onSave;

  @override
  State<NameSpeakersSheet> createState() => _NameSpeakersSheetState();
}

class _NameSpeakersSheetState extends State<NameSpeakersSheet> {
  late final List<String> _speakers = detectSpeakers(widget.transcript);
  late final Map<String, String> _hints = firstLineBySpeaker(widget.transcript);
  late final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{
    for (final String s in _speakers)
      s: TextEditingController(
        text: widget.names.hasName(s) ? widget.names.nameFor(s) : '',
      ),
  };
  late final Map<String, FocusNode> _focus = <String, FocusNode>{
    for (final String s in _speakers) s: FocusNode(debugLabel: s),
  };

  /// Labels whose current name the user asked to drop (Clear). A blank
  /// field on its own means "unchanged" (v1.15.0 semantics); only Clear
  /// removes a key from the map.
  final Set<String> _cleared = <String>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final TextEditingController c in _controllers.values) {
      c.addListener(_onChanged);
    }
    for (final FocusNode f in _focus.values) {
      f.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in _controllers.values) {
      c.dispose();
    }
    for (final FocusNode f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Map<String, String> get _typed => <String, String>{
        for (final String s in _speakers) s: _controllers[s]!.text,
      };

  Set<String> get _colliding =>
      collidingSpeakerNames(widget.transcript, _typed);

  /// The map Save would write: current names, cleared keys dropped, then
  /// every non-blank field applied as a rename.
  SpeakerNames get _result {
    SpeakerNames next = widget.names;
    for (final String s in _cleared) {
      next = next.without(s);
    }
    for (final MapEntry<String, String> e in _typed.entries) {
      if (normalizeSpeakerName(e.value).isNotEmpty) {
        next = next.withRename(e.key, e.value);
      }
    }
    return next;
  }

  bool get _changed => _result != widget.names;

  bool get _canSave => _changed && _colliding.isEmpty && !_saving;

  /// Chip tap: the focused field, else the first empty one (spec §3).
  void _fill(String name) {
    String? target;
    for (final String s in _speakers) {
      if (_focus[s]!.hasFocus) {
        target = s;
        break;
      }
    }
    target ??= _speakers.cast<String?>().firstWhere(
          (String? s) => _controllers[s]!.text.trim().isEmpty,
          orElse: () => null,
        );
    if (target == null) return;
    _controllers[target]!.text = name;
  }

  void _clear(String label) {
    _controllers[label]!.clear();
    setState(() => _cleared.add(label));
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_result);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      rethrow;
    }
  }

  /// `Speaker N` → `N`, used in the mandated widget keys.
  static String _n(String label) => label.substring('Speaker '.length);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Set<String> colliding = _colliding;
    return SafeArea(
      child: Column(
        key: const ValueKey<String>('name-speakers-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SheetDragHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('Name speakers', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Names show in place of the speaker labels on this recording. '
              'The transcript itself is not changed.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (widget.suggestions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                key: const ValueKey<String>('speaker-suggestions'),
                spacing: 8,
                runSpacing: 4,
                children: <Widget>[
                  for (final String name in widget.suggestions)
                    ActionChip(
                      key: ValueKey<String>('speaker-suggestion-$name'),
                      label: Text(name),
                      onPressed: _saving ? null : () => _fill(name),
                    ),
                ],
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: <Widget>[
                for (final String label in _speakers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: 88,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              label,
                              key: ValueKey<String>(
                                'speaker-label-${_n(label)}',
                              ),
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            key: ValueKey<String>('speaker-name-${_n(label)}'),
                            controller: _controllers[label],
                            focusNode: _focus[label],
                            enabled: !_saving,
                            textInputAction: TextInputAction.next,
                            decoration: InputDecoration(
                              hintText: label,
                              errorText: colliding.contains(label)
                                  ? 'Already used'
                                  : null,
                              helper: _hints[label] == null
                                  ? null
                                  : Text(
                                      _hints[label]!,
                                      key: ValueKey<String>(
                                        'speaker-hint-${_n(label)}',
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                            ),
                          ),
                        ),
                        // Only a field that currently carries a mapped name
                        // can be cleared; a blank field alone means
                        // "leave it as it is".
                        if (widget.names.hasName(label) &&
                            !_cleared.contains(label))
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: TextButton(
                              key: ValueKey<String>(
                                'speaker-clear-${_n(label)}',
                              ),
                              onPressed: _saving ? null : () => _clear(label),
                              child: const Text('Clear'),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  key: const ValueKey<String>('speakers-cancel'),
                  onPressed:
                      _saving ? null : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey<String>('speakers-save'),
                  onPressed: _canSave ? _save : null,
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
