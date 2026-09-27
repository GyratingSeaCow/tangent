// SPDX-License-Identifier: AGPL-3.0-or-later
import '../data/local_db.dart';
import '../data/todo_repository.dart';
import 'todo_voice_parser.dart';

/// Auto-adds to-dos spoken into a brain dump (To Do arc Phase 2).
///
/// This is the ONE place the idempotency rule lives. Two sinks persist a
/// completed transcript — the sync engine's remote dump apply (server-made
/// transcripts) and `completeTranscriptionAttempt` (this device's own
/// transcription) — and both route through here, so a re-sync, a
/// re-transcribe, or a manual repair can never double-add.
///
/// The guard is provenance, not content: a dump that has ANY todo carrying
/// its id as `source_ref` is already captured, even if every one of those
/// rows is soft-deleted. That is what makes Undo permanent — the spec's
/// "re-sync can't resurrect them".
///
/// Spec: docs/design/2026-09-27-todo-voice-capture.md.
Future<List<TodoRow>> captureVoiceTodos({
  required LocalDb db,
  required String dumpId,
  required String? transcript,
  TodoRepository? repository,
}) async {
  final TodoRepository repo = repository ?? TodoRepository(db: db);
  // Ask BEFORE parsing: the answer is cheap and it short-circuits every
  // repeat arrival for the overwhelmingly common already-captured dump.
  if (await repo.hasTodosFromSource(dumpId)) return const <TodoRow>[];
  final List<String> items = TodoVoiceParser.parse(transcript);
  if (items.isEmpty) return const <TodoRow>[];
  final List<TodoRow> created = <TodoRow>[];
  for (final String item in items) {
    created.add(
      await repo.add(item, source: voiceTodoSource, sourceRef: dumpId),
    );
  }
  return created;
}

/// The `source` value phase 1 reserved for voice-captured items.
const String voiceTodoSource = 'voice';

/// Calls [captureVoiceTodos] and swallows any failure.
///
/// Used at the transcript-persistence sinks only: a bug in to-do capture
/// must never cost the user a transcript that just finished, which is the
/// far more expensive thing in flight at that moment.
Future<void> captureVoiceTodosQuietly({
  required LocalDb db,
  required String dumpId,
  required String? transcript,
}) async {
  try {
    await captureVoiceTodos(db: db, dumpId: dumpId, transcript: transcript);
  } catch (_) {
    // Deliberately ignored; see above.
  }
}
