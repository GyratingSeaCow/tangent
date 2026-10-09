// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert' show utf8;

import 'package:crypto/crypto.dart' show sha1;

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
/// The guard is keyed by (dumpId, fingerprint of the parsed RESULT) —
/// v1.28.0, docs/design/2026-09-27-retranscribe-guard-and-due-reminders.md
/// Half A. Rows for the dump (live OR soft-deleted) carrying the SAME
/// fingerprint mean this exact capture already happened: nothing to do.
/// A DIFFERENT fingerprint is a re-transcription: entries whose text has no
/// row yet are added, live rows with the same text are kept (their id is
/// what the user's other devices know), stale live rows are left alone
/// (they may be user-edited), and soft-deleted texts are never re-created.
/// That last rule is what makes Undo permanent — the spec's "re-sync can't
/// resurrect them".
///
/// [recordedOn] is the dump's `created_at` — the day the words were spoken,
/// which anchors "September 30th" and "Friday" (v1.26.0 D2). Never
/// `DateTime.now()`: a recording transcribed days later still means the
/// date it was said on. Each row gets its item's OWN date when it named
/// one, else the sentence date (v1.27.0, R2).
///
/// Spec: docs/design/2026-09-27-todo-voice-capture.md,
/// docs/design/2026-09-27-voice-todo-due-dates.md and
/// docs/design/2026-09-27-voice-todo-relative-dates.md.
Future<List<TodoRow>> captureVoiceTodos({
  required LocalDb db,
  required String dumpId,
  required String? transcript,
  required DateTime recordedOn,
  TodoRepository? repository,
  Future<void> Function()? onTimedTodosCreated,
}) async {
  final TodoRepository repo = repository ?? TodoRepository(db: db);
  // The recording DAY is a local-calendar notion; sync hands us UTC stamps.
  final VoiceTodoParse parse = TodoVoiceParser.parseWithDate(
    transcript,
    recordedOn: recordedOn.toLocal(),
  );
  final List<VoiceTodoItem> entries = <VoiceTodoItem>[
    for (final VoiceTodoItem entry in parse.entries)
      VoiceTodoItem(
        entry.text,
        dueDate: entry.dueDate ?? parse.dueDate,
        dueTime: entry.dueTime ?? parse.dueTime,
      ),
  ];
  final List<TodoRow> existing = await repo.todosFromSource(dumpId);
  if (existing.isEmpty) {
    if (entries.isEmpty) return const <TodoRow>[];
    final String fingerprint = captureFingerprintOf(entries);
    final List<TodoRow> created = <TodoRow>[
      for (final VoiceTodoItem entry in entries)
        await repo.add(
          entry.text,
          dueDate: entry.dueDate,
          dueTime: entry.dueTime,
          source: voiceTodoSource,
          sourceRef: dumpId,
          captureFingerprint: fingerprint,
        ),
    ];
    if (created.any((TodoRow row) => row.dueTime != null)) {
      await onTimedTodosCreated?.call();
    }
    return created;
  }
  // Something was captured before. Same result → nothing to do; and a
  // transcript that no longer yields any item must not touch rows either.
  if (entries.isEmpty) return const <TodoRow>[];
  final String fingerprint = captureFingerprintOf(entries);
  if (existing.any((TodoRow row) => row.captureFingerprint == fingerprint)) {
    return const <TodoRow>[];
  }
  // A re-transcription. Reconcile by text; never delete, never resurrect.
  final List<TodoRow> created = <TodoRow>[];
  bool timedTodoChanged = false;
  for (final VoiceTodoItem entry in entries) {
    final Iterable<TodoRow> sameText = existing.where(
      (TodoRow row) => row.body == entry.text,
    );
    if (sameText.isEmpty) {
      created.add(
        await repo.add(
          entry.text,
          dueDate: entry.dueDate,
          dueTime: entry.dueTime,
          source: voiceTodoSource,
          sourceRef: dumpId,
          captureFingerprint: fingerprint,
        ),
      );
      timedTodoChanged |= entry.dueTime != null;
      continue;
    }
    for (final TodoRow row in sameText) {
      // Soft-deleted rows stay deleted (Undo is permanent). Live rows keep
      // their id; a date is added only when the row has none yet.
      if (row.deletedAt != null) continue;
      if (row.dueDate == null && entry.dueDate != null) {
        await repo.setDueDate(row.id, entry.dueDate, dueTime: entry.dueTime);
        timedTodoChanged |= entry.dueTime != null;
      }
    }
  }
  // Remember this parse so the same transcript arriving again is a no-op.
  await repo.setCaptureFingerprint(dumpId, fingerprint);
  if (timedTodoChanged) await onTimedTodosCreated?.call();
  return created;
}

/// SHA-1 hex over the parsed RESULT: `text|dueDate|dueTime` per entry, joined by
/// `\n`. Two transcripts that yield identical to-dos share a fingerprint;
/// a changed word inside an item, or a newly recognised date, does not.
/// Deliberately NOT a hash of the raw transcript (spec rule 1).
String captureFingerprintOf(Iterable<VoiceTodoItem> entries) {
  final String joined = entries
      .map(
        (VoiceTodoItem e) => '${e.text}|${e.dueDate ?? ''}|${e.dueTime ?? ''}',
      )
      .join('\n');
  return sha1.convert(utf8.encode(joined)).toString();
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
  required DateTime recordedOn,
  Future<void> Function()? onTimedTodosCreated,
}) async {
  try {
    await captureVoiceTodos(
      db: db,
      dumpId: dumpId,
      transcript: transcript,
      recordedOn: recordedOn,
      onTimedTodosCreated: onTimedTodosCreated,
    );
  } catch (_) {
    // Deliberately ignored; see above.
  }
}
