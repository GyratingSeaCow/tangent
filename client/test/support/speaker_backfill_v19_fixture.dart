// SPDX-License-Identifier: AGPL-3.0-or-later
/// A pre-v20 (`user_version = 19`) SQLite database seeded with dump rows,
/// for tests that need the REAL v20 speaker-name back-fill to run when a
/// [LocalDb] is opened over it — the migration is the only production
/// writer of `settings['speaker_backfill_skipped']` (leftovers sweep L5).
library;

import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// The v19 dumps shape: every column up to summary_template, no
/// speaker_names, and no settings table (mirrors
/// test/unit/data/speaker_names_migration_test.dart).
const String _dumpsV19 = '''
  CREATE TABLE dumps (
    id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    mode TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL,
    title TEXT NOT NULL,
    transcript TEXT,
    meeting_notes TEXT,
    audio_path TEXT NOT NULL,
    audio_size_bytes INTEGER NOT NULL,
    sync_status TEXT NOT NULL,
    sync_attempts INTEGER NOT NULL DEFAULT 0,
    last_sync_error TEXT,
    transcription_status TEXT NOT NULL DEFAULT 'not_transcribed',
    transcription_request_id TEXT,
    transcription_job_id TEXT,
    transcription_attempt INTEGER NOT NULL DEFAULT 0,
    transcription_started_at INTEGER,
    transcription_updated_at INTEGER,
    transcription_completed_at INTEGER,
    transcription_error TEXT,
    folder_id TEXT,
    sync_dirty INTEGER,
    synced_seq INTEGER,
    remote_only INTEGER,
    audio_on_server INTEGER,
    summary TEXT,
    summary_model TEXT,
    summarized_at INTEGER,
    transcript_timings TEXT,
    summary_template TEXT,
    PRIMARY KEY (id)
  );
''';

/// A transcript the back-fill REFUSES: a raw `## Speaker 1` after a user
/// heading means position ≠ label, so converting would merge speakers.
const String ambiguousSpeakerTranscript =
    '## Jeff\nJeff: a\n## Speaker 1\nSpeaker 1: b\n';

/// A raw diarized transcript nobody renamed — never a skip.
const String rawSpeakerTranscript =
    '## Speaker 1\nSpeaker 1: hi\n\n## Speaker 2\nSpeaker 2: hey\n';

/// An in-memory v19 database holding one dump per [transcripts] entry
/// (id → transcript), titled by id. Wrap with `NativeDatabase.opened`.
sqlite3.Database v19DatabaseWithDumps(Map<String, String?> transcripts) {
  final sqlite3.Database raw = sqlite3.sqlite3.openInMemory();
  raw.execute(_dumpsV19);
  raw.execute('PRAGMA user_version = 19;');
  int createdAt = 100;
  for (final MapEntry<String, String?> entry in transcripts.entries) {
    createdAt += 1;
    raw.execute(
      'INSERT INTO dumps (id, created_at, updated_at, mode, duration_seconds, '
      'title, transcript, audio_path, audio_size_bytes, sync_status, '
      "sync_dirty, synced_seq) VALUES (?, ?, ?, 'brain_dump', 60, ?, ?, "
      "'/audio/x.opus', 1, 'synced', 0, 7)",
      <Object?>[entry.key, createdAt, createdAt, entry.key, entry.value],
    );
  }
  return raw;
}
