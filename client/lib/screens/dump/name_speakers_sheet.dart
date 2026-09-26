// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Name-speakers sheet (docs/design/2026-09-26-speaker-naming.md §3).
//
// One text field per `## Speaker N` heading in the dump's transcript; Save
// rewrites the transcript text in place (decision S1=b) through the same
// guarded manual-edit path the detail editor uses. No autosave, no name map.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../data/manual_transcript_publication.dart';
import '../../data/storage/storage_contract.dart';
import '../../data/storage/storage_providers.dart';
import '../../services/speaker_naming.dart';
import '../home/home_screen.dart' show localDbProvider;

/// Shown when the transcript moved underneath the sheet (spec §3).
const String staleTranscriptMessage =
    'Transcript changed underneath you — reopen and try again';

/// Success snackbar text (spec §3).
const String speakersNamedMessage = 'Speakers named';

/// Opens the Name-speakers sheet for [row]. Resolves `true` when a rename
/// was saved, `false` on cancel — and immediately `false`, without showing
/// anything, when the transcript has no speakers (the entry points are
/// absent in that case; this is the belt to their braces).
///
/// Save acquires an edit lease, calls `updateDumpTranscript` against the
/// row's current transcript / attempt / requestId, then publishes the
/// manual-edit sidecar exactly as the detail editor's Save does.
Future<bool> showNameSpeakersSheet(
  BuildContext context,
  WidgetRef ref,
  DumpRow row,
) async {
  final String transcript = row.transcript ?? '';
  if (detectSpeakers(transcript).isEmpty) return false;
  final LocalDb db = ref.read(localDbProvider);
  final RecordingMutationCoordinator mutations =
      ref.read(recordingMutationsProvider);
  // Captured before any await: publication can outlive the route.
  final RecordingAccess access = ref.read(recordingAccessProvider);
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final List<String> suggestions = suggestedSpeakerNames(
    await db.recentTranscriptsForSpeakerSuggestions(limit: 50),
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
        suggestions: suggestions,
        onSave: (String rewritten) => saveRenamedTranscript(
          row: row,
          transcript: rewritten,
          db: db,
          mutations: mutations,
          access: access,
        ),
      ),
    ),
  );
  if (saved == true) {
    messenger?.showSnackBar(const SnackBar(content: Text(speakersNamedMessage)));
    return true;
  }
  return false;
}

/// Persists a rewritten transcript for [row] under an edit lease. Throws
/// [StateError] when the row's transcript revision no longer matches the
/// one the sheet was opened with (stale), mirroring the detail editor.
Future<void> saveRenamedTranscript({
  required DumpRow row,
  required String transcript,
  required LocalDb db,
  required RecordingMutationCoordinator mutations,
  required RecordingAccess access,
}) async {
  final Outcome<UseLease> outcome = await mutations.acquire(row.id, UseKind.edit);
  final UseLease lease = switch (outcome) {
    Ok<UseLease>(:final UseLease value) => value,
    Fail<UseLease>(:final StorageProblem problem) => throw StorageFault(problem),
  };
  try {
    final DumpRow saved = await db.updateDumpTranscript(
      row.id,
      storageKey: lease.key,
      expectedTranscript: row.transcript ?? '',
      expectedTranscriptionAttempt: row.transcriptionAttempt,
      expectedTranscriptionRequestId: row.transcriptionRequestId,
      transcript: transcript,
      now: DateTime.now().toUtc(),
    );
    final bool published = await publishManualTranscriptSidecar(
      db: db,
      access: access,
      storageKey: lease.key,
      revision: saved,
    );
    if (!published) throw StateError('Manual edit was superseded');
  } finally {
    await lease.close();
  }
}

/// The sheet body. Pure presentation over [transcript]; persistence is the
/// injected [onSave], which throws [StateError] on a stale revision.
class NameSpeakersSheet extends StatefulWidget {
  const NameSpeakersSheet({
    super.key,
    required this.transcript,
    required this.onSave,
    this.suggestions = const <String>[],
  });

  final String transcript;

  /// Names used on other recordings, newest first — tap-to-fill chips.
  final List<String> suggestions;

  /// Persists the rewritten transcript. Throws [StateError] when the
  /// transcript changed underneath the sheet.
  final Future<void> Function(String transcript) onSave;

  @override
  State<NameSpeakersSheet> createState() => _NameSpeakersSheetState();
}

class _NameSpeakersSheetState extends State<NameSpeakersSheet> {
  late final List<String> _speakers = detectSpeakers(widget.transcript);
  late final Map<String, String> _hints = firstLineBySpeaker(widget.transcript);
  late final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{
    for (final String s in _speakers) s: TextEditingController(),
  };
  late final Map<String, FocusNode> _focus = <String, FocusNode>{
    for (final String s in _speakers) s: FocusNode(debugLabel: s),
  };
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

  bool get _anyFilled =>
      _typed.values.any((String v) => normalizeSpeakerName(v).isNotEmpty);

  bool get _canSave => _anyFilled && _colliding.isEmpty && !_saving;

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

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    final String rewritten = applySpeakerNames(widget.transcript, _typed);
    try {
      await widget.onSave(rewritten);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on StateError {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text(staleTranscriptMessage)),
      );
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Name speakers', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Names replace the speaker headings in the transcript. '
              'Listen mode keeps the original speaker labels.',
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
