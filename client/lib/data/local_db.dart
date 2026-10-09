// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart' show Digest, sha256;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart' show Database;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/speaker_names.dart';
import '../models/sync_status.dart';
import '../models/transcription_status.dart';
import '../services/speaker_names_backfill.dart';
import 'storage/storage_tables.dart';
import 'storage/storage_contract.dart';
import 'storage/storage_codec.dart';
import '../services/transcript_search.dart'
    show DumpSearchMatch, countTranscriptMatches;
export '../services/transcript_search.dart' show DumpSearchMatch;

part 'local_db.g.dart';

@DataClassName('DumpRow')
class Dumps extends Table {
  TextColumn get id => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  TextColumn get mode => text().withLength(min: 1, max: 20)();
  IntColumn get durationSeconds => integer()();
  TextColumn get title => text().withLength(min: 1, max: 500)();
  TextColumn get transcript => text().nullable()();
  TextColumn get meetingNotes => text().nullable()();
  TextColumn get audioPath => text()();
  IntColumn get audioSizeBytes => integer()();
  TextColumn get syncStatus => text().withLength(min: 1, max: 20)();
  IntColumn get syncAttempts => integer().withDefault(const Constant(0))();
  TextColumn get lastSyncError => text().nullable()();
  TextColumn get transcriptionStatus => text().withDefault(
    Constant(TranscriptionStatus.notTranscribed.wireValue),
  )();
  TextColumn get transcriptionRequestId => text().nullable()();
  TextColumn get transcriptionJobId => text().nullable()();
  IntColumn get transcriptionAttempt =>
      integer().withDefault(const Constant(0))();
  DateTimeColumn get transcriptionStartedAt => dateTime().nullable()();
  DateTimeColumn get transcriptionUpdatedAt => dateTime().nullable()();
  DateTimeColumn get transcriptionCompletedAt => dateTime().nullable()();
  TextColumn get transcriptionError => text().nullable()();

  /// Which folder this recording or note is filed in, or null when unfiled.
  /// Same metadata approach as notebooks: filing never moves the audio file.
  /// v1.38: filing travels with the dump payload (null means unfiled), so a
  /// move syncs across devices exactly like a notebook or to-do filing.
  TextColumn get folderId => text().nullable()();

  /// v1.38 auto-file (server-authored, server→client only): unix seconds
  /// when the SERVER filed this capture after transcription, and the filing
  /// it replaced (null = it was unfiled). While [autoFiledAt] is set the
  /// card shows the `Auto-filed to … · Undo` chip; an undo or any manual
  /// re-file clears both here and, via the pushed filing, on the server.
  IntColumn get autoFiledAt => integer().nullable()();
  TextColumn get autoFilePrevFolderId => text().nullable()();

  /// Sync state, mirroring the notebook columns. [syncDirty] means this row
  /// has local metadata edits the server has not accepted yet; [syncedSeq]
  /// is the change_log checkpoint the server assigned when it did.
  /// Nullable so adding these columns does not force every existing
  /// construction site (141 of them, nearly all tests) to name a value that
  /// is only meaningful to the sync engine. Null reads as "not dirty",
  /// exactly how every row behaved before recording sync existed.
  BoolColumn get syncDirty => boolean().nullable()();
  IntColumn get syncedSeq => integer().nullable()();

  /// True when this row arrived from another device and its audio (if any)
  /// has not been downloaded here. The audio lives on the server; the user
  /// fetches it explicitly. A remote row keeps [audioPath] empty rather than
  /// naming a file this device does not have.
  BoolColumn get remoteOnly => boolean().nullable()();

  /// True when the SERVER holds this recording's audio, so a device without
  /// the bytes can offer to download them. Comes from the peer's payload,
  /// not from anything local.
  BoolColumn get audioOnServer => boolean().nullable()();

  /// Server-generated AI summary (markdown sections), or null when none has
  /// been generated. These three columns flow server→client ONLY: they
  /// arrive inside pulled dump payloads, the client never writes its own
  /// values and never pushes them (the server ignores client-sent summary
  /// keys anyway). Nullable because every dump predating v17 has none.
  TextColumn get summary => text().nullable()();

  /// The exact GGUF model stem that produced [summary]; null with it.
  TextColumn get summaryModel => text().nullable()();

  /// Unix seconds when the server generated [summary]; null with it.
  IntColumn get summarizedAt => integer().nullable()();

  /// Word-level transcript timings (JSON, see transcript_timings.dart),
  /// server-owned and server→client only like the summary columns. Null
  /// until a transcription with timings completes; the server nulls it
  /// when a re-transcription starts so stale timings never outlive their
  /// transcript. Backs "tap a word, hear that moment".
  TextColumn get transcriptTimings => text().nullable()();

  /// The summary template id the server last summarized this dump with
  /// ('meeting', 'brain_dump', 'lecture', 'actions_only', 'custom'), or null
  /// when the server has only ever applied the mode default. Server-owned
  /// and server→client only like the summary columns: the client chooses a
  /// template by POSTing /v1/dumps/{id}/summarize and the server persists
  /// it, so the client never writes or pushes this column itself.
  TextColumn get summaryTemplate => text().nullable()();

  /// Per-recording speaker name map (v1.17.0, spec §1): the JSON object
  /// `{"Speaker 1":"Jeff"}` as text, or null when no speaker is named.
  /// Device-authored — it rides the push payload next to [title] and
  /// competes on [updatedAt] like every other user edit. The transcript
  /// text keeps its raw `## Speaker N` labels; surfaces render through
  /// the map (`renderSpeakerNames`).
  TextColumn get speakerNames => text().nullable()();

  /// Unix seconds when THIS device last asked the server to (re)summarize
  /// (the summarize POST returned 202). LOCAL-ONLY: never pushed, never
  /// read from a pull. Drives the "summary in progress" strip: pending
  /// while newer than [summarizedAt] and under ten minutes old, cleared
  /// by [LocalDb.applyRemoteDump] the moment a summary at least that new
  /// syncs down. Null when nothing was ever requested from here.
  IntColumn get summaryRequestedAt => integer().nullable()();

  /// ISO 639-1 code Whisper detected for the audio (v1.19.0 Part A), e.g.
  /// 'es'; null until the first transcription lands. SERVER-authored: only
  /// ever set from a pull, never in the push payload.
  TextColumn get language => text().nullable()();

  /// True when the stored transcript is an English TRANSLATION of the audio
  /// (the job ran with `translate`). Server-authored like [language]; null
  /// reads as false (the column is nullable so the generated row class does
  /// not force every constructor to name it; the wire value is 0/1).
  BoolColumn get translated => boolean().nullable()();

  /// Server-side summary job state (v1.19.0 Part B): 'queued', 'running',
  /// 'failed', or null for idle/done. Server-authored, pull only.
  TextColumn get summaryStatus => text().nullable()();

  /// Short human reason when [summaryStatus] is 'failed'. Server-authored.
  TextColumn get summaryError => text().nullable()();

  /// 1-based place in the server's summary queue, only while 'queued'.
  /// Server-authored.
  IntColumn get summaryQueuePosition => integer().nullable()();

  /// Unix seconds when the user dismissed the 'Summary failed' line on THIS
  /// device. LOCAL-ONLY: never pushed, never read from a pull. Cleared by
  /// [LocalDb.applyRemoteDump] when the summary succeeds or a new attempt
  /// starts, so the line returns on the next failure.
  IntColumn get summaryErrorDismissedAt => integer().nullable()();

  /// User pin. Nullable so every pre-v30 row keeps the old unpinned
  /// appearance without a rewrite; null reads exactly like false.
  BoolColumn get pinned => boolean().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Small key/value store for client-local bookkeeping that belongs with
/// the data it describes (the speaker-name back-fill record, spec §2) —
/// NOT user preferences, which live in SharedPreferences via SettingsStore.
@DataClassName('LocalSettingRow')
class LocalSettings extends Table {
  @override
  String get tableName => 'settings';
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override
  Set<Column> get primaryKey => {key};
}

@DataClassName('SyncQueueRow')
class SyncQueue extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get dumpId =>
      text().references(Dumps, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get queuedAt => dateTime()();
}

/// One row per notebook: the whole document and ink layer save atomically.
///
/// Deliberately has no relationship to [Dumps]. A notebook may embed a dump as
/// a card, but embedding never moves, copies, deletes or cascades a recording;
/// a missing dump renders as a placeholder instead.
/// A folder is a label, not a directory.
///
/// Tangent publishes notebooks and recordings to durable storage (SAF on
/// Android). Making folders physical would mean moving published files on
/// every reorganise, and a half-failed move leaves orphans — the exact class
/// of defect the storage catalog exists to prevent. A nullable id on the row
/// moves nothing on disk and carries cleanly through sync.
@DataClassName('Folder')
class Folders extends Table {
  @override
  String get tableName => 'folders';
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get createdAt => integer()();

  /// Sync state, mirroring notebooks. Folders sync by ID only: same-named
  /// folders created independently on two devices stay separate (user
  /// decision). Nullable, and null reads as dirty for the same reason
  /// notebooks default dirty: a folder that existed before folder sync has
  /// never been pushed.
  BoolColumn get syncDirty => boolean().nullable()();
  IntColumn get syncedSeq => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('NotebookRow')
class Notebooks extends Table {
  @override
  String get tableName => 'notebooks';
  TextColumn get id => text()();
  TextColumn get title => text()();

  /// Epoch milliseconds, stored as integers so the JSON payload columns and the
  /// timestamps read identically from raw SQL.
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  TextColumn get docJson => text()();
  TextColumn get inkJson => text()();

  /// Null means unfiled. Deliberately NOT a foreign key with cascade: a
  /// deleted folder must unfile its notebooks, never delete them.
  TextColumn get folderId => text().nullable()();

  /// How the page is ruled: 'blank', 'small', or 'medium'.
  ///
  /// Stored as the enum's NAME rather than its index, so reordering the enum
  /// cannot silently re-rule every existing notebook. Nullable because every
  /// notebook written before v10 has no value, and null reads as blank —
  /// which is exactly how those pages have always rendered.
  TextColumn get ruling => text().nullable()();

  /// The nib last used in this notebook: 'ballpoint' or 'fountain'.
  ///
  /// Same contract as [ruling]: stored as the enum's NAME, nullable because
  /// every notebook written before v16 has no value, and null reads as the
  /// fountain default. Per-notebook because the user keeps different
  /// notebooks in different pens and each must reopen with its own.
  TextColumn get lastPenStyle => text().nullable()();

  /// PBKDF2-HMAC-SHA256 verifier metadata. Password text is never stored.
  /// All three are nullable together: null hash means protection is off.
  TextColumn get passwordHash => text().nullable()();
  TextColumn get passwordSalt => text().nullable()();
  IntColumn get passwordIterations => integer().nullable()();

  /// Previous verifier hash: proof for a transition and, after a clear, the
  /// durable tombstone that prevents a stale replica from restoring that hash.
  TextColumn get passwordHashPrev => text().nullable()();

  /// True when this notebook has local edits the server has not accepted.
  ///
  /// Set on every local save and cleared only by a push the server confirmed.
  /// Defaulting to TRUE matters: notebooks that already existed before sync
  /// arrived have never been pushed, so treating them as clean would leave a
  /// user's entire library invisible to their other devices forever.
  BoolColumn get syncDirty => boolean().withDefault(const Constant(true))();

  /// The server sequence this row was last reconciled at, or null if never.
  /// Diagnostic: it makes "did this actually sync?" answerable from the data.
  IntColumn get syncedSeq => integer().nullable()();

  /// Epoch ms when this notebook was moved to the trash; null means live.
  ///
  /// Deletion is a two-stage affair (user decision): a delete files the row
  /// here for 7 days before it is purged, so a deletion that synced from
  /// another device — or a slip of the finger — is recoverable from
  /// Settings → Trash.
  IntColumn get deletedAt => integer().nullable()();

  /// User pin. Nullable for an additive, appearance-preserving migration.
  BoolColumn get pinned => boolean().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

/// Deletions waiting to be told to the server.
///
/// A local delete removes the row, which would otherwise make the deletion
/// unpushable — the other device would never hear about it and would push the
/// notebook straight back on its next sync. The tombstone outlives the row
/// just long enough to be delivered.
@DataClassName('SyncTombstoneRow')
class SyncTombstones extends Table {
  @override
  String get tableName => 'sync_tombstones';

  /// 'notebook' or 'note'. Not an enum column: the server validates the
  /// vocabulary and a client that guesses wrong should fail loudly there.
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  IntColumn get deletedAt => integer()();
  @override
  Set<Column> get primaryKey => {entityType, entityId};
}

/// This device's sync identity and checkpoint. Exactly one row, id = 1.
@DataClassName('SyncStateRow')
class SyncStates extends Table {
  @override
  String get tableName => 'sync_state';
  IntColumn get id => integer().withDefault(const Constant(1))();

  /// Stable per-install replica id. A reinstall is legitimately a new replica
  /// and syncs from zero rather than inheriting a checkpoint it cannot honour.
  TextColumn get deviceId => text()();

  /// Highest server sequence this device has applied IN FULL. Advanced only
  /// after every change in a page lands, so a crash mid-page re-fetches that
  /// page instead of skipping it.
  IntColumn get lastPulledSeq => integer().withDefault(const Constant(0))();
  IntColumn get lastSyncedAt => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

/// Mirror of the server's word-level handwriting index (`ink_index`).
///
/// Rows arrive only via sync pull (replace-set per notebook) — the client
/// never writes its own recognition results. Searching is a local lookup
/// against `word_text_lower`; `stroke_ids_json` is what the find bar
/// highlights.
class InkIndexEntries extends Table {
  @override
  String get tableName => 'ink_index_entries';
  TextColumn get id => text()();
  TextColumn get notebookId => text()();
  TextColumn get lineId => text()();
  TextColumn get wordText => text()();
  TextColumn get wordTextLower => text()();
  TextColumn get bboxJson => text()();
  TextColumn get strokeIdsJson => text()();
  TextColumn get model => text()();
  IntColumn get indexedAt => integer()();
  @override
  Set<Column> get primaryKey => {notebookId, id};
}

/// To-do items (v23, Phase 1 of the To Do arc): a first-class synced
/// entity, device-authored like notebooks, newer-wins on `updated_at`,
/// soft-deleted so a delete can fan out (and be undone) instead of
/// vanishing.
///
/// Timestamps are ISO-8601 TEXT — the wire format verbatim — rather than
/// epoch integers, so a payload field and its column read identically and
/// no conversion can drift between push and pull. `due_date` is a bare
/// `YYYY-MM-DD`; `due_time` is local wall-clock `HH:MM`.
@DataClassName('TodoRow')
class Todos extends Table {
  @override
  String get tableName => 'todos';
  TextColumn get id => text()();

  /// The item text. Named explicitly: a getter called `text` would shadow
  /// the Drift column builder of the same name.
  TextColumn get body => text().named('text')();

  /// ISO instant when the item was checked off; null = open. Unchecking
  /// clears it. Nothing ever auto-deletes based on this.
  TextColumn get doneAt => text().nullable()();

  /// ISO date `YYYY-MM-DD`, no time. Null = Someday (undated).
  TextColumn get dueDate => text().nullable()();

  /// 'manual' now; 'voice', 'summary', 'notebook' reserved for Phases 2-3.
  TextColumn get source => text().withDefault(const Constant('manual'))();

  /// Reserved provenance link (dump id / notebook id + block id).
  TextColumn get sourceRef => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  /// ISO instant of the soft delete; null = live. Soft, not a tombstone
  /// row: the deletion travels as an ordinary upsert carrying this field,
  /// and the 5-second undo snackbar restores by clearing it.
  TextColumn get deletedAt => text().nullable()();

  /// Same contract as notebooks: true until the server confirms a push.
  BoolColumn get syncDirty => boolean().withDefault(const Constant(true))();
  IntColumn get syncedSeq => integer().nullable()();

  /// v1.24.0: the SHARED folder this item is filed under (same `folders`
  /// rows as recordings and notebooks). Null = unfiled. Declared last so a
  /// fresh onCreate and a v23 `addColumn` upgrade agree on column order.
  TextColumn get folderId => text().nullable()();

  /// v1.28.0: LOCAL-ONLY fingerprint of the voice parse that created (or
  /// last reconciled) this row — SHA-1 of the parsed RESULT, so a
  /// re-transcribe that yields the same items is the same capture. Never
  /// pushed, never read from a pull (same pattern as `summary_requested_at`).
  /// Null on manual rows and on rows that arrived from a peer.
  TextColumn get captureFingerprint => text().nullable()();

  /// User pin. Nullable for an additive, appearance-preserving migration.
  BoolColumn get pinned => boolean().nullable()();

  /// The Kanban lane. Nullable only so old databases can be upgraded safely;
  /// repository writes always assign the first live column.
  TextColumn get columnId => text().nullable()();

  /// Stable order within a lane. List mode deliberately ignores it.
  IntColumn get boardOrder => integer().withDefault(const Constant(0))();

  /// v36: local wall-clock `HH:MM`. Every dated row has one; nullable keeps
  /// the additive wire/schema compatible with old peers and undated rows.
  /// Declared last so fresh databases match the additive migration order.
  TextColumn get dueTime => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// User-defined Kanban lanes. Deletion is soft so the retirement and the
/// transactional todo moves can converge safely across devices.
@DataClassName('TodoColumnRow')
class TodoColumns extends Table {
  @override
  String get tableName => 'todo_columns';
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  BoolColumn get syncDirty => boolean().withDefault(const Constant(true))();
  IntColumn get syncedSeq => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

/// v1.35.0: calendar events spoken in a recording
/// calendar …"). Same sync spine as [Todos]; the three `google*` columns are
/// SERVER-authored and arrive only through a pull — a device push never
/// carries them (see the sync engine's projection).
/// Spec: docs/design/2026-09-28-voice-calendar-events.md.
@DataClassName('CalendarEventRow')
class CalendarEvents extends Table {
  @override
  String get tableName => 'calendar_events';
  TextColumn get id => text()();
  TextColumn get title => text()();

  /// `YYYY-MM-DD` when [allDay], else local `YYYY-MM-DDTHH:MM:SS`.
  TextColumn get start => text()();

  /// Same shape as [start]; all-day end is EXCLUSIVE (the next day). The
  /// column is `end_` because `end` is an SQL keyword; the wire key is `end`.
  TextColumn get end => text().named('end_')();
  BoolColumn get allDay => boolean().withDefault(const Constant(true))();
  TextColumn get timeZone => text()();

  /// The phrase carried no date (C3): sits on the recording day until the
  /// user fixes it on Google; cleared by the next pull that moves it.
  BoolColumn get needsDate => boolean().withDefault(const Constant(false))();
  TextColumn get source => text().withDefault(const Constant('voice'))();

  /// The dump id the event was captured from.
  TextColumn get sourceRef => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();
  BoolColumn get syncDirty => boolean().withDefault(const Constant(true))();
  IntColumn get syncedSeq => integer().nullable()();

  // Server-only (pull-only) — the card's link and the worker's cursor.
  TextColumn get googleEventId => text().nullable()();
  TextColumn get googleHtmlLink => text().nullable()();
  TextColumn get googleUpdated => text().nullable()();

  /// LOCAL-ONLY, same contract as [Todos.captureFingerprint].
  TextColumn get captureFingerprint => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

/// v1.37.0: server-authored Ask history. These rows are pull-only.
@DataClassName('AskMessageRow')
class AskMessages extends Table {
  @override
  String get tableName => 'ask_messages';
  TextColumn get id => text()();
  TextColumn get role => text()();
  TextColumn get body => text().named('text')();
  TextColumn get sourcesJson => text().withDefault(const Constant('[]'))();
  IntColumn get createdAt => integer()();
  IntColumn get serverSeq => integer()();
  @override
  Set<Column> get primaryKey => {id};
}

/// Which Ask citations have been opened, so a long source list shows what is
/// already checked.
///
/// LOCAL ONLY and deliberately a separate table: `ask_messages` is pull-only,
/// so a column there would be erased by the next server pull that rewrites
/// the row. Keyed by message id + the citation's index within that message,
/// which is the same identity the row keys already use.
@DataClassName('AskSourceVisitRow')
class AskSourceVisits extends Table {
  @override
  String get tableName => 'ask_source_visits';
  TextColumn get messageId => text()();
  IntColumn get sourceIndex => integer()();
  IntColumn get visitedAt => integer()();
  @override
  Set<Column> get primaryKey => {messageId, sourceIndex};
}

/// v33 shared custom tags: ONE vocabulary for notebooks and recordings.
///
/// A tag is a synced entity of its own (like a folder), so a rename lands on
/// every notebook and recording that carries it in a single change rather
/// than rewriting each target's payload. Names are unique per device,
/// case-insensitively; two devices that independently create "Work" while
/// offline still get two tags (sync is by id, the folder precedent).
@DataClassName('TagRow')
class Tags extends Table {
  @override
  String get tableName => 'tags';
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// Epoch milliseconds, integers like notebooks.
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  /// Folder contract: nullable, and null reads as dirty.
  BoolColumn get syncDirty => boolean().nullable()();
  IntColumn get syncedSeq => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

/// v33: which tag is on which notebook or recording.
///
/// Polymorphic on purpose: `target_type` is 'notebook' or 'dump', so one
/// table (and one sync entity) serves both libraries. Deliberately NOT a
/// foreign key to either target: a trashed notebook keeps its tags for a
/// restore, and a recording deleted on this device may still live on a peer.
///
/// The id is DERIVED from (tag, target type, target) — see
/// [LocalDb.tagAssignmentId] — so two devices that tag the same item with the
/// same tag converge on one row instead of trading duplicates.
@DataClassName('TagAssignmentRow')
class TagAssignments extends Table {
  @override
  String get tableName => 'tag_assignments';
  TextColumn get id => text()();
  TextColumn get tagId => text()();
  TextColumn get targetType => text()();
  TextColumn get targetId => text()();
  IntColumn get createdAt => integer()();
  BoolColumn get syncDirty => boolean().nullable()();
  IntColumn get syncedSeq => integer().nullable()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<Set<Column>> get uniqueKeys => <Set<Column>>[
    {tagId, targetType, targetId},
  ];
}

/// One row of the lightweight assignment projection: which tag sits on which
/// target. The list screens watch THIS, never a full notebook or dump row, so
/// tagging an item does not re-stream document bodies.
typedef TagLink = ({String targetId, String tagId});

/// A tag name the user typed is unusable (blank, too long, or taken).
class TagNameException implements Exception {
  const TagNameException(this.message);
  final String message;
  @override
  String toString() => message;
}

@DriftDatabase(
  tables: [
    Dumps,
    Folders,
    SyncQueue,
    StorageLocations,
    StorageCatalogStates,
    RecordingBindings,
    CaptureReservations,
    LocalDeletionBatches,
    LocalDeletionTickets,
    Notebooks,
    SyncTombstones,
    SyncStates,
    InkIndexEntries,
    LocalSettings,
    Todos,
    TodoColumns,
    CalendarEvents,
    AskMessages,
    AskSourceVisits,
    Tags,
    TagAssignments,
  ],
)
class LocalDb extends _$LocalDb implements StorageDatabaseOperations {
  LocalDb() : super(_openConnection());

  LocalDb.forTesting(super.executor);

  @override
  int get schemaVersion => 36;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createFtsInfrastructure();
      await _createTagIndexes();
      await initializeStorageCatalogRows();
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await _replaceFtsTriggers();
      }
      if (from < 3) {
        await m.addColumn(dumps, dumps.meetingNotes);
        // Migration v2 → v3 promotes meetings to private on-device state.
        // Already-synced meetings remain synced because the remote copy is
        // truth and we cannot prove the server has deleted it. Pending,
        // syncing, and failed meetings are demoted to local_only and have
        // their stale retry state cleared so the user does not see error
        // strings on rows that will never retry.
        await customStatement(
          'UPDATE dumps SET sync_status = \'local_only\', '
          'sync_attempts = 0, last_sync_error = NULL '
          'WHERE mode = \'meeting\' AND sync_status IN (\'pending\', \'syncing\', \'failed\')',
        );
      }
      if (from < 4) {
        await m.addColumn(dumps, dumps.transcriptionStatus);
        await m.addColumn(dumps, dumps.transcriptionRequestId);
        await m.addColumn(dumps, dumps.transcriptionJobId);
        await m.addColumn(dumps, dumps.transcriptionAttempt);
        await m.addColumn(dumps, dumps.transcriptionStartedAt);
        await m.addColumn(dumps, dumps.transcriptionUpdatedAt);
        await m.addColumn(dumps, dumps.transcriptionCompletedAt);
        await m.addColumn(dumps, dumps.transcriptionError);
        await customStatement(
          'UPDATE dumps SET transcription_status = CASE '
          "WHEN TRIM(COALESCE(transcript, '')) != '' THEN 'completed' "
          "ELSE 'not_transcribed' END, "
          'transcription_completed_at = CASE '
          "WHEN TRIM(COALESCE(transcript, '')) != '' THEN updated_at "
          'ELSE NULL END',
        );
      }
      if (from < 5) {
        await _createStorageCatalog(m);
      }
      if (from < 6) {
        // Notebooks are purely additive: no existing table is altered and
        // no existing row is touched.
        await m.createTable(notebooks);
      }
      if (from < 7) {
        // Folders arrive empty and every existing notebook stays unfiled,
        // so nothing a user already has can move or disappear.
        await m.createTable(folders);
        // The v6 step above calls createTable(notebooks), and createTable
        // builds from the CURRENT definition — which already carries
        // folder_id. Only a database that genuinely arrived here with a
        // v6-shaped notebooks table needs the column added; adding it to a
        // table just created would throw "duplicate column name" and leave
        // the app unable to open its own database.
        if (from >= 6) {
          await m.addColumn(notebooks, notebooks.folderId);
        }
      }
      if (from < 8) {
        // dumps is created by onCreate/createAll for a brand new database
        // and by nothing else, so on an upgrade path it may be absent
        // entirely (a fixture older than the table) or already carry
        // folder_id (created from the CURRENT definition during this same
        // upgrade). Both throw: "no such table" and "duplicate column
        // name". Ask the database what it actually has instead of
        // inferring it from the version number.
        final List<QueryRow> dumpsTable = await customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='dumps'",
        ).get();
        if (dumpsTable.isNotEmpty) {
          final List<QueryRow> columns = await customSelect(
            'PRAGMA table_info(dumps)',
          ).get();
          final bool hasFolderId = columns.any(
            (QueryRow row) => row.data['name'] == 'folder_id',
          );
          if (!hasFolderId) {
            await m.addColumn(dumps, dumps.folderId);
          }
        }
      }
      if (from < 9) {
        // Multi-device sync. Purely additive: two new tables, and two new
        // columns on notebooks.
        await m.createTable(syncTombstones);
        await m.createTable(syncStates);
        // As with v7/v8: createTable(notebooks) during an upgrade builds
        // from the CURRENT definition, which already carries these
        // columns. Only a database that genuinely arrived with an older
        // notebooks table needs them added, and adding a column twice
        // throws "duplicate column name" — which would leave the app
        // unable to open its own database.
        final List<QueryRow> notebookColumns = await customSelect(
          'PRAGMA table_info(notebooks)',
        ).get();
        final Set<String> present = notebookColumns
            .map((QueryRow row) => row.data['name'] as String)
            .toSet();
        if (notebookColumns.isEmpty) {
          // No notebooks table at all. A genuine v8 database has one (v6
          // created it), but the version number is not evidence — ask the
          // database, the same way the v7 and v8 steps do. createTable
          // builds from the current definition, so it arrives with both
          // sync columns already on it.
          await m.createTable(notebooks);
        } else {
          if (!present.contains('sync_dirty')) {
            await m.addColumn(notebooks, notebooks.syncDirty);
          }
          if (!present.contains('synced_seq')) {
            await m.addColumn(notebooks, notebooks.syncedSeq);
          }
          // Existing notebooks have never been pushed. addColumn backfills
          // the default, so this covers any row that somehow arrived NULL:
          // a notebook wrongly marked clean would stay invisible to the
          // user's other devices permanently, with nothing on screen to
          // reveal it.
          await customStatement(
            'UPDATE notebooks SET sync_dirty = 1 WHERE sync_dirty IS NULL',
          );
        }
      }

      if (from < 10) {
        // Page ruling. One nullable column; null reads as blank, which is
        // how every page has rendered until now, so there is nothing to
        // backfill and no existing notebook changes appearance.
        final List<QueryRow> rulingColumns = await customSelect(
          'PRAGMA table_info(notebooks)',
        ).get();
        if (rulingColumns.isEmpty) {
          // Ask the database rather than trusting the version number —
          // the same reasoning as v9, which is where "no such table:
          // notebooks" was caught.
          await m.createTable(notebooks);
        } else {
          final bool present = rulingColumns.any(
            (QueryRow row) => row.data['name'] == 'ruling',
          );
          // Adding a column twice throws "duplicate column name", which
          // would leave the app unable to open its own database.
          if (!present) {
            await m.addColumn(notebooks, notebooks.ruling);
          }
        }
      }

      if (from < 11) {
        // Recording sync. Four additive columns on dumps, each with a
        // defaulted value, so existing rows keep their exact current
        // meaning: not dirty, never synced, local (not remote-only),
        // and no known server-side audio until a sync says otherwise.
        final List<QueryRow> dumpColumns = await customSelect(
          'PRAGMA table_info(dumps)',
        ).get();
        final Set<String> names = <String>{
          for (final QueryRow row in dumpColumns) row.data['name'] as String,
        };
        // Ask the database, never the version number: adding a column
        // twice throws "duplicate column name" and bricks app launch for
        // every existing install.
        if (!names.contains('sync_dirty')) {
          await m.addColumn(dumps, dumps.syncDirty);
        }
        if (!names.contains('synced_seq')) {
          await m.addColumn(dumps, dumps.syncedSeq);
        }
        if (!names.contains('remote_only')) {
          await m.addColumn(dumps, dumps.remoteOnly);
        }
        if (!names.contains('audio_on_server')) {
          await m.addColumn(dumps, dumps.audioOnServer);
        }
      }

      if (from < 12) {
        // One-time repair, not a schema change.
        //
        // Before the apply-site fix, `applyRemoteDump` wrote a synced
        // transcript but left `transcription_status` at its table
        // default, so a recording carrying its full transcript still
        // read "Not transcribed". Fixing the apply site does not heal
        // those rows: their `synced_seq` is already current, so the
        // change feed never replays them. On Jeff's devices this was 35
        // rows on the tablet and 37 on the Fold.
        //
        // Ask the database for the column first. A very old install
        // (v6, v9) runs every step in sequence and reaches this one
        // before `transcription_status` has been added, where a bare
        // UPDATE throws "no such column" and bricks app launch for the
        // oldest installs — the exact upgrade-path hazard the v11
        // PRAGMA checks above exist to avoid. Those databases have no
        // synced transcripts to repair anyway.
        final List<QueryRow> repairColumns = await customSelect(
          'PRAGMA table_info(dumps)',
        ).get();
        final bool hasStatus = repairColumns.any(
          (QueryRow row) => row.data['name'] == 'transcription_status',
        );
        final bool hasTranscript = repairColumns.any(
          (QueryRow row) => row.data['name'] == 'transcript',
        );

        if (hasStatus && hasTranscript) {
          // Deliberately narrow. It touches ONLY rows whose status is
          // exactly 'not_transcribed' while holding non-blank transcript
          // text — never 'failed' (which would hide a real failure from
          // the retry path) and never 'not_applicable' (a typed note,
          // whose transcript column legitimately holds the note body).
          //
          // It also leaves updated_at, sync_dirty and synced_seq alone: a
          // local repair is not a user edit, and marking these dirty would
          // push dozens of pointless changes per device into the feed.
          //
          // TRIM() in SQLite strips SPACES only — not newlines or tabs —
          // so a transcript of "  \n " would pass a bare TRIM check and
          // get flipped to completed. Name every whitespace character.
          await customUpdate(
            "UPDATE dumps SET transcription_status = 'completed' "
            "WHERE transcription_status = 'not_transcribed' "
            "AND COALESCE(TRIM(transcript, ' ' || char(9) || char(10) || "
            "char(13)), '') <> ''",
            updates: <TableInfo<Table, dynamic>>{dumps},
          );
        }
      }

      if (from < 13) {
        // Folder sync. Two additive columns; ask the database, never the
        // version number — adding a column twice throws "duplicate column
        // name" and bricks app launch for every existing install.
        final List<QueryRow> folderColumns = await customSelect(
          'PRAGMA table_info(folders)',
        ).get();
        final Set<String> present = <String>{
          for (final QueryRow row in folderColumns) row.data['name'] as String,
        };
        if (folderColumns.isEmpty) {
          await m.createTable(folders);
        } else {
          if (!present.contains('sync_dirty')) {
            await m.addColumn(folders, folders.syncDirty);
          }
          if (!present.contains('synced_seq')) {
            await m.addColumn(folders, folders.syncedSeq);
          }
        }

        // Notebook trash: soft-deletes live 7 days before purge.
        final List<QueryRow> nbColumns = await customSelect(
          'PRAGMA table_info(notebooks)',
        ).get();
        final bool hasDeletedAt = nbColumns.any(
          (QueryRow row) => row.data['name'] == 'deleted_at',
        );
        if (!hasDeletedAt) {
          await m.addColumn(notebooks, notebooks.deletedAt);
        }

        // Repair: an earlier build wrote a folder id containing the
        // LITERAL text "folder-${DateTime...}" — a Dart interpolation
        // that never ran (single-quoted SQL heredoc territory). Any
        // device carrying it can collide on primary key the next time
        // that id template is written. Re-key it to a well-formed id
        // and carry the filing along. Found live on the Fold.
        final List<QueryRow> corrupt = await customSelect(
          r"SELECT id FROM folders WHERE id LIKE '%${%'",
        ).get();
        for (final QueryRow row in corrupt) {
          final String bad = row.data['id'] as String;
          final String good =
              'folder-repair-${DateTime.now().microsecondsSinceEpoch}';
          await customStatement(
            'UPDATE folders SET id = ?1 WHERE id = ?2',
            <Object>[good, bad],
          );
          await customStatement(
            'UPDATE notebooks SET folder_id = ?1 WHERE folder_id = ?2',
            <Object>[good, bad],
          );
          await customStatement(
            'UPDATE dumps SET folder_id = ?1 WHERE folder_id = ?2',
            <Object>[good, bad],
          );
        }
      }
      if (from < 14) {
        // One-time filing re-push. Notebooks filed BEFORE folder sync
        // existed are clean (sync_dirty = 0), so their folder_id never
        // travels: the peer sees the folder arrive empty. Marking every
        // filed, live notebook dirty makes the next sync carry its
        // filing. Harmless on fresh installs (no rows match) and cheap
        // on upgrades — a re-push of an identical body is idempotent.
        // Ask the database first: on ancient fixtures the earlier steps
        // may have built notebooks without these columns yet.
        final Set<String> nbColumns = <String>{
          for (final QueryRow row in await customSelect(
            'PRAGMA table_info(notebooks)',
          ).get())
            row.data['name'] as String,
        };
        if (nbColumns.containsAll(const <String>[
          'folder_id',
          'sync_dirty',
          'deleted_at',
        ])) {
          await customStatement(
            'UPDATE notebooks SET sync_dirty = 1 '
            'WHERE folder_id IS NOT NULL AND deleted_at IS NULL',
          );
        }
      }
      if (from < 15) {
        // Additive: the handwriting-search index mirror. Guarded because
        // a fresh install's onCreate already built it — createTable on an
        // existing table would throw and wedge the upgrade.
        final bool exists = (await customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'ink_index_entries'",
        ).get()).isNotEmpty;
        if (!exists) {
          await m.createTable(inkIndexEntries);
        }
      }
      if (from < 16) {
        // Per-notebook pen memory. One nullable column; null reads as
        // the fountain default, so no backfill and no existing notebook
        // changes behaviour until its nib is next switched. Same
        // ask-the-database guard as v10's ruling: adding a column twice
        // throws "duplicate column name" and wedges the upgrade.
        final List<QueryRow> penColumns = await customSelect(
          'PRAGMA table_info(notebooks)',
        ).get();
        final bool present = penColumns.any(
          (QueryRow row) => row.data['name'] == 'last_pen_style',
        );
        if (!present) {
          await m.addColumn(notebooks, notebooks.lastPenStyle);
        }
      }
      if (from < 17) {
        // AI summaries: three nullable, server-owned columns on dumps.
        // Null means "no summary yet", which is what every existing row
        // truthfully has, so there is nothing to backfill. Ask the
        // database, never the version number — adding a column twice
        // throws "duplicate column name" and bricks app launch (the
        // recurring upgrade-path hazard every step above guards against).
        final Set<String> dumpCols = <String>{
          for (final QueryRow row in await customSelect(
            'PRAGMA table_info(dumps)',
          ).get())
            row.data['name'] as String,
        };
        if (dumpCols.isNotEmpty) {
          if (!dumpCols.contains('summary')) {
            await m.addColumn(dumps, dumps.summary);
          }
          if (!dumpCols.contains('summary_model')) {
            await m.addColumn(dumps, dumps.summaryModel);
          }
          if (!dumpCols.contains('summarized_at')) {
            await m.addColumn(dumps, dumps.summarizedAt);
          }
        }
      }
      if (from < 18) {
        // Tap-to-hear: one nullable, server-owned column on dumps. Same
        // ask-the-database guard as v17 — a repeat addColumn would
        // throw "duplicate column name" and brick launch.
        final Set<String> dumpCols = <String>{
          for (final QueryRow row in await customSelect(
            'PRAGMA table_info(dumps)',
          ).get())
            row.data['name'] as String,
        };
        if (dumpCols.isNotEmpty && !dumpCols.contains('transcript_timings')) {
          await m.addColumn(dumps, dumps.transcriptTimings);
        }
      }
      if (from < 19) {
        // Summary templates: one nullable, server-owned column on dumps.
        // Null means "mode default", which is what every existing row
        // truthfully has, so there is nothing to backfill. Same
        // ask-the-database guard as v17/v18 — a repeat addColumn would
        // throw "duplicate column name" and brick launch.
        final Set<String> dumpCols = <String>{
          for (final QueryRow row in await customSelect(
            'PRAGMA table_info(dumps)',
          ).get())
            row.data['name'] as String,
        };
        if (dumpCols.isNotEmpty && !dumpCols.contains('summary_template')) {
          await m.addColumn(dumps, dumps.summaryTemplate);
        }
      }
      if (from < 20) {
        // Speaker name map (v1.17.0): one nullable, device-authored
        // column on dumps plus the client-local settings table, then
        // the one-time back-fill of the v1.15.0 rewrite-in-place.
        // Same ask-the-database guards as v17-v19.
        final Set<String> dumpCols = <String>{
          for (final QueryRow row in await customSelect(
            'PRAGMA table_info(dumps)',
          ).get())
            row.data['name'] as String,
        };
        if (dumpCols.isNotEmpty && !dumpCols.contains('speaker_names')) {
          await m.addColumn(dumps, dumps.speakerNames);
        }
        final List<QueryRow> settingsTable = await customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='settings'",
        ).get();
        if (settingsTable.isEmpty) {
          await m.createTable(localSettings);
        }
        if (dumpCols.contains('transcript')) {
          await _backfillSpeakerNames();
        }
      }
      if (from < 21) {
        // Summary-in-progress marker (v1.18.0): one nullable, local-only
        // column on dumps. Same ask-the-database guard as v17-v20.
        final Set<String> dumpCols = <String>{
          for (final QueryRow row in await customSelect(
            'PRAGMA table_info(dumps)',
          ).get())
            row.data['name'] as String,
        };
        if (dumpCols.isNotEmpty && !dumpCols.contains('summary_requested_at')) {
          await m.addColumn(dumps, dumps.summaryRequestedAt);
        }
      }
      if (from < 22) {
        // v1.19.0: translation (language, translated) and summary status
        // (summary_status, summary_error, summary_queue_position) —
        // all server-authored, pulled only — plus the local-only
        // summary_error_dismissed_at. Same ask-the-database guard.
        final Set<String> dumpCols = <String>{
          for (final QueryRow row in await customSelect(
            'PRAGMA table_info(dumps)',
          ).get())
            row.data['name'] as String,
        };
        if (dumpCols.isNotEmpty) {
          if (!dumpCols.contains('language')) {
            await m.addColumn(dumps, dumps.language);
          }
          if (!dumpCols.contains('translated')) {
            await m.addColumn(dumps, dumps.translated);
          }
          if (!dumpCols.contains('summary_status')) {
            await m.addColumn(dumps, dumps.summaryStatus);
          }
          if (!dumpCols.contains('summary_error')) {
            await m.addColumn(dumps, dumps.summaryError);
          }
          if (!dumpCols.contains('summary_queue_position')) {
            await m.addColumn(dumps, dumps.summaryQueuePosition);
          }
          if (!dumpCols.contains('summary_error_dismissed_at')) {
            await m.addColumn(dumps, dumps.summaryErrorDismissedAt);
          }
        }
      }
      if (from < 23) {
        // v1.23.0: the todos table (To Do arc Phase 1). Ask-the-database
        // guard like v15/v20: a fresh install's onCreate already built
        // it, and createTable on an existing table is a hard failure.
        final List<QueryRow> todosTable = await customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='todos'",
        ).get();
        if (todosTable.isEmpty) {
          await m.createTable(todos);
        }
      }
      if (from < 24) {
        // v1.24.0: to-do folders. Ask-the-database guard: the v23 branch
        // above may have just created the table WITH this column (a
        // createTable uses the current schema), and addColumn on an
        // existing column is a hard failure.
        final List<QueryRow> todoColumns = await customSelect(
          'PRAGMA table_info(todos)',
        ).get();
        final bool hasFolderId = todoColumns.any(
          (QueryRow row) => row.read<String>('name') == 'folder_id',
        );
        if (!hasFolderId) {
          await m.addColumn(todos, todos.folderId);
        }
      }
      if (from < 25) {
        // v1.28.0: local-only capture_fingerprint on todos. Same
        // ask-the-database guard as v24: the v23 createTable branch may
        // already have built the table with this column.
        final List<QueryRow> todoColumns = await customSelect(
          'PRAGMA table_info(todos)',
        ).get();
        final bool hasFingerprint = todoColumns.any(
          (QueryRow row) => row.read<String>('name') == 'capture_fingerprint',
        );
        if (!hasFingerprint) {
          await m.addColumn(todos, todos.captureFingerprint);
        }
      }
      if (from < 26) {
        // v1.35.0: voice → Google Calendar events.
        await m.createTable(calendarEvents);
      }
      if (from < 27) {
        final List<QueryRow> table = await customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='ask_messages'",
        ).get();
        if (table.isEmpty) await m.createTable(askMessages);
      }
      if (from < 28) {
        // v1.38.0: local-only record of which Ask citations were opened.
        final List<QueryRow> table = await customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='ask_source_visits'",
        ).get();
        if (table.isEmpty) await m.createTable(askSourceVisits);
      }
      if (from < 29) {
        // v1.38.0 auto-file: dump filing joins sync, plus the two
        // server-authored auto-file marker columns. Ask the database,
        // never the version number (the duplicate-column lesson from
        // v8/v24).
        final Set<String> dumpColumns = <String>{
          for (final QueryRow row in await customSelect(
            'PRAGMA table_info(dumps)',
          ).get())
            row.read<String>('name'),
        };
        if (!dumpColumns.contains('auto_filed_at')) {
          await m.addColumn(dumps, dumps.autoFiledAt);
        }
        if (!dumpColumns.contains('auto_file_prev_folder_id')) {
          await m.addColumn(dumps, dumps.autoFilePrevFolderId);
        }
        // One-time filing re-push, the v14 notebook precedent: dumps
        // filed BEFORE dump-filing sync existed are clean, so their
        // folder_id never travels — and worse, the first post-upgrade
        // pull would carry the server's authoritative folder_id: null
        // and erase the local filing. Marking every filed, live dump
        // dirty both pushes the filing up and shields it from that
        // pull (the dirty-row guard). Harmless on fresh installs.
        if (dumpColumns.contains('folder_id')) {
          await customStatement(
            'UPDATE dumps SET sync_dirty = 1 '
            'WHERE folder_id IS NOT NULL '
            'AND (remote_only IS NULL OR remote_only = 0)',
          );
        }
      }
      if (from < 30) {
        // v30: one nullable pin flag on each pinnable entity (v28 was
        // Ask citation visits, v29 the auto-file columns). Ask
        // sqlite_master first, then table_info: an empty PRAGMA is
        // ambiguous (missing table vs no columns), and a sideways
        // build may already carry the column.
        Future<void> addPinnedIfMissing(
          String tableName,
          TableInfo<Table, dynamic> table,
          GeneratedColumn<bool> column,
        ) async {
          final bool exists = (await customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            variables: <Variable<Object>>[Variable<String>(tableName)],
          ).get()).isNotEmpty;
          if (!exists) return;
          final List<QueryRow> columns = await customSelect(
            'PRAGMA table_info($tableName)',
          ).get();
          final bool hasPinned = columns.any(
            (QueryRow row) => row.data['name'] == 'pinned',
          );
          if (!hasPinned) await m.addColumn(table, column);
        }

        await addPinnedIfMissing('dumps', dumps, dumps.pinned);
        await addPinnedIfMissing('notebooks', notebooks, notebooks.pinned);
        await addPinnedIfMissing('todos', todos, todos.pinned);
      }
      if (from < 31) {
        // Three nullable verifier columns. Existing rows remain unlocked.
        // The v6 createTable step may already have used today's shape, so
        // introspect before every add to avoid duplicate-column failures.
        final List<QueryRow> notebookColumns = await customSelect(
          'PRAGMA table_info(notebooks)',
        ).get();
        final Set<String> names = <String>{
          for (final QueryRow row in notebookColumns) row.read<String>('name'),
        };
        if (notebookColumns.isNotEmpty) {
          if (!names.contains('password_hash')) {
            await m.addColumn(notebooks, notebooks.passwordHash);
          }
          if (!names.contains('password_salt')) {
            await m.addColumn(notebooks, notebooks.passwordSalt);
          }
          if (!names.contains('password_iterations')) {
            await m.addColumn(notebooks, notebooks.passwordIterations);
          }
        }
      }
      if (from < 32) {
        final List<QueryRow> notebookColumns = await customSelect(
          'PRAGMA table_info(notebooks)',
        ).get();
        final bool hasPrevious = notebookColumns.any(
          (QueryRow row) => row.read<String>('name') == 'password_hash_prev',
        );
        if (notebookColumns.isNotEmpty && !hasPrevious) {
          await m.addColumn(notebooks, notebooks.passwordHashPrev);
        }
      }
      if (from < 33) {
        // v33 shared tags: two brand-new tables, no existing row is
        // touched. Ask sqlite_master first (the v27/v28 rule) so a
        // sideways build that already created them cannot fail the
        // upgrade on a duplicate table.
        Future<bool> tableExists(String name) async => (await customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          variables: <Variable<Object>>[Variable<String>(name)],
        ).get()).isNotEmpty;
        if (!await tableExists('tags')) await m.createTable(tags);
        if (!await tableExists('tag_assignments')) {
          await m.createTable(tagAssignments);
        }
        await _createTagIndexes();
      }
      if (from < 34) {
        final bool columnsExist = (await customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='todo_columns'",
        ).get()).isNotEmpty;
        if (!columnsExist) await m.createTable(todoColumns);

        final List<QueryRow> todoInfo = await customSelect(
          'PRAGMA table_info(todos)',
        ).get();
        final Set<String> todoNames = <String>{
          for (final QueryRow row in todoInfo) row.read<String>('name'),
        };
        if (todoInfo.isNotEmpty && !todoNames.contains('column_id')) {
          await m.addColumn(todos, todos.columnId);
        }
        if (todoInfo.isNotEmpty && !todoNames.contains('board_order')) {
          await m.addColumn(todos, todos.boardOrder);
        }

        // Seed values are deliberately older than any real user edit. A peer
        // may already have renamed or retired one of these fixed ids; its
        // canonical row must beat this placeholder during the first sync.
        const String stamp = '1970-01-01T00:00:00.000Z';
        await customStatement(
          'INSERT OR IGNORE INTO todo_columns '
          '(id,name,sort_order,created_at,updated_at,sync_dirty) VALUES '
          "('todo-column-todo','To Do',0,?1,?1,1),"
          "('todo-column-progress','In Progress',1,?1,?1,1),"
          "('todo-column-done','Done',2,?1,?1,1)",
          <Object>[stamp],
        );
        if (todoInfo.isNotEmpty) {
          // Synthetic/sideways old schemas may predate the settings table even
          // when their user_version is newer. The marker is local metadata, so
          // create its table defensively before recording any rows.
          final bool settingsExist = (await customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='settings'",
          ).get()).isNotEmpty;
          if (!settingsExist) await m.createTable(localSettings);
          // Remember exactly which formerly-clean rows owe only the new board
          // placement. Pull runs before push; sync can accept a newer remote
          // body, then re-apply just this placement with a fresh stamp.
          await customStatement(
            'INSERT OR REPLACE INTO settings(key,value) '
            'SELECT \'todo_kanban_backfill:\' || id, CAST(rowid AS TEXT) '
            'FROM todos WHERE column_id IS NULL AND sync_dirty=0',
          );
          await customStatement(
            "UPDATE todos SET column_id='todo-column-todo', "
            'board_order=rowid, sync_dirty=1 '
            'WHERE column_id IS NULL',
          );
        }
      }
      if (from < 35) {
        // Content-derived ink row ids repeat when notebook conflict copies
        // duplicate the same strokes. The mirror key is therefore scoped
        // to its notebook. Rebuild just this table so every existing mirror
        // row survives; no user-authored table participates in the copy.
        final List<QueryRow> tableInfo = await customSelect(
          'PRAGMA table_info(ink_index_entries)',
        ).get();
        if (tableInfo.isEmpty) {
          // Defensive sideways-schema guard. A genuine v34 database has
          // this table, but creating it is safer than bricking launch.
          await m.createTable(inkIndexEntries);
        } else {
          final List<QueryRow> primaryKey =
              tableInfo
                  .where((QueryRow row) => row.read<int>('pk') > 0)
                  .toList()
                ..sort(
                  (QueryRow a, QueryRow b) =>
                      a.read<int>('pk').compareTo(b.read<int>('pk')),
                );
          final List<String> primaryKeyNames = primaryKey
              .map((QueryRow row) => row.read<String>('name'))
              .toList();
          final bool alreadyNotebookScoped =
              primaryKeyNames.length == 2 &&
              primaryKeyNames[0] == 'notebook_id' &&
              primaryKeyNames[1] == 'id';
          if (!alreadyNotebookScoped) {
            await m.alterTable(TableMigration(inkIndexEntries));
          }
        }
      }
      if (from < 36) {
        // Additive due time. A guarded add keeps interrupted/sideways
        // upgrades safe; old dated rows inherit 09:00 local.
        final List<QueryRow> todoInfo = await customSelect(
          'PRAGMA table_info(todos)',
        ).get();
        final bool hasDueTime = todoInfo.any(
          (QueryRow row) => row.read<String>('name') == 'due_time',
        );
        if (todoInfo.isNotEmpty && !hasDueTime) {
          await m.addColumn(todos, todos.dueTime);
        }
        if (todoInfo.isNotEmpty) {
          await customStatement(
            "UPDATE todos SET due_time='09:00' "
            'WHERE due_date IS NOT NULL AND due_time IS NULL',
          );
        }
      }
    },
  );

  /// Lookup indexes for the assignment projection: by target (the list
  /// screens) and by tag (the delete cascade and the filter). Idempotent.
  Future<void> _createTagIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS tag_assignments_target_idx '
      'ON tag_assignments(target_type, target_id)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS tag_assignments_tag_idx '
      'ON tag_assignments(tag_id)',
    );
  }

  /// Key of the settings row recording what [_backfillSpeakerNames] did.
  static const String speakerNamesBackfillKey = 'speaker_names_backfill';

  /// Key of the settings row listing the dump ids [_backfillSpeakerNames]
  /// REFUSED to convert (ambiguous pairing, spec L5): a JSON list, local
  /// only. Home shows it once as a banner; dismissing deletes the row.
  static const String speakerBackfillSkippedKey = 'speaker_backfill_skipped';

  /// One-time conversion of the v1.15.0 rewrite-in-place (spec §2).
  ///
  /// For every dump whose transcript carries a user speaker heading
  /// (`hasUserSpeakerNames`), pairs the non-section headings with
  /// `Speaker 1..k` in document order, writes the map to `speaker_names`,
  /// restores the raw labels in the text, bumps `updated_at` and marks the
  /// row dirty so the server and peers converge on the same shape.
  /// Idempotent: a second run finds no user headings and writes nothing.
  /// Nothing is deleted; the `speaker_names_backfill` settings row records
  /// `{dumpId: {names, rewrittenHeadings}}` for a one-shot undo.
  Future<void> _backfillSpeakerNames() async {
    final List<QueryRow> rows = await customSelect(
      'SELECT id, transcript FROM dumps '
      "WHERE transcript IS NOT NULL AND transcript LIKE '%## %'",
    ).get();
    final Map<String, dynamic> record = <String, dynamic>{};
    final List<String> skipped = <String>[];
    final int now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    for (final QueryRow row in rows) {
      final String id = row.data['id'] as String;
      final String transcript = row.data['transcript'] as String;
      final SpeakerNamesBackfillPlan? plan = planSpeakerNamesBackfill(
        transcript,
      );
      if (plan == null) {
        // Refused (ambiguous pairing) is recorded so Home can say so once;
        // a transcript with nothing to convert is simply not a skip.
        if (speakerNamesBackfillRefused(transcript)) skipped.add(id);
        continue;
      }
      await customUpdate(
        'UPDATE dumps SET transcript = ?, speaker_names = ?, '
        'updated_at = ?, sync_dirty = 1 WHERE id = ?',
        variables: <Variable<Object>>[
          Variable<String>(plan.transcript),
          Variable<String>(plan.names.encode()!),
          Variable<int>(now),
          Variable<String>(id),
        ],
        updates: {dumps},
      );
      record[id] = plan.toJson();
    }
    await _recordSpeakerBackfillSkipped(skipped);
    if (record.isEmpty) return;
    final List<QueryRow> prior = await customSelect(
      'SELECT value FROM settings WHERE key = ?',
      variables: <Variable<Object>>[Variable<String>(speakerNamesBackfillKey)],
    ).get();
    if (prior.isNotEmpty) {
      final Object? old = jsonDecode(prior.single.data['value'] as String);
      if (old is Map<String, dynamic>) {
        record.addEntries(old.entries.where((e) => !record.containsKey(e.key)));
      }
    }
    await customStatement(
      'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
      <Object>[speakerNamesBackfillKey, jsonEncode(record)],
    );
  }

  /// Unions [skipped] into the `speaker_backfill_skipped` row (spec L5).
  /// Writes nothing when there is nothing to add, so a re-run of the v20
  /// step never resurrects a list the user already dismissed.
  Future<void> _recordSpeakerBackfillSkipped(List<String> skipped) async {
    if (skipped.isEmpty) return;
    final List<String> ids = await speakerBackfillSkippedIds();
    for (final String id in skipped) {
      if (!ids.contains(id)) ids.add(id);
    }
    await customStatement(
      'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
      <Object>[speakerBackfillSkippedKey, jsonEncode(ids)],
    );
  }

  /// Dump ids the back-fill refused, oldest first; empty when none or
  /// after [clearSpeakerBackfillSkipped].
  Future<List<String>> speakerBackfillSkippedIds() async {
    final LocalSettingRow? row = await (select(
      localSettings,
    )..where((s) => s.key.equals(speakerBackfillSkippedKey))).getSingleOrNull();
    if (row == null) return <String>[];
    final Object? decoded = jsonDecode(row.value);
    if (decoded is! List) return <String>[];
    return decoded.whereType<String>().toList();
  }

  /// Deletes the skipped list: the banner was dismissed.
  Future<void> clearSpeakerBackfillSkipped() async {
    await (delete(
      localSettings,
    )..where((s) => s.key.equals(speakerBackfillSkippedKey))).go();
  }

  /// The back-fill record, or null when no dump was ever converted.
  Future<Map<String, dynamic>?> speakerNamesBackfillRecord() async {
    final LocalSettingRow? row = await (select(
      localSettings,
    )..where((s) => s.key.equals(speakerNamesBackfillKey))).getSingleOrNull();
    if (row == null) return null;
    return jsonDecode(row.value) as Map<String, dynamic>;
  }

  // ---- multi-device sync -------------------------------------------------

  /// This device's sync identity, created on first use.
  ///
  /// [newDeviceId] is supplied by the caller rather than generated here so the
  /// id is testable and so identity generation lives with the rest of the sync
  /// policy instead of in the data layer.
  Future<SyncStateRow> syncState({required String newDeviceId}) async {
    final SyncStateRow? existing = await (select(
      syncStates,
    )..where((t) => t.id.equals(1))).getSingleOrNull();
    if (existing != null) return existing;
    await into(syncStates).insert(
      SyncStatesCompanion.insert(deviceId: newDeviceId),
      mode: InsertMode.insertOrIgnore,
    );
    return (select(syncStates)..where((t) => t.id.equals(1))).getSingle();
  }

  /// Advances the pull checkpoint. Called only after a whole page is applied.
  Future<void> recordPullCheckpoint(int seq) async {
    await (update(syncStates)..where((t) => t.id.equals(1))).write(
      SyncStatesCompanion(
        lastPulledSeq: Value(seq),
        lastSyncedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// Re-emits every watcher whose table another CONNECTION may have written.
  ///
  /// The background sync isolate opens its own database handle, and drift
  /// stream queries only observe writes made through their own connection —
  /// a notebook pulled in the background is on disk but invisible to the
  /// open app's screens. Called on app-resume and after foreground syncs;
  /// it marks the synced tables dirty so their watchers re-read from disk.
  /// Purely a notification: no rows change, so calling it spuriously is
  /// harmless.
  Future<void> refreshExternalWrites() async {
    notifyUpdates({
      for (final TableInfo<Table, dynamic> table in <TableInfo<Table, dynamic>>[
        notebooks,
        dumps,
        folders,
        syncTombstones,
        syncStates,
        inkIndexEntries,
        askMessages,
      ])
        TableUpdate.onTable(table),
    });
  }

  /// Watches server-authored Ask history in stable conversational order.
  Stream<List<AskMessageRow>> watchAskHistory() =>
      (select(askMessages)..orderBy(<OrderingTerm Function($AskMessagesTable)>[
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.serverSeq),
          ]))
          .watch();

  Future<List<AskMessageRow>> askHistory() =>
      (select(askMessages)..orderBy(<OrderingTerm Function($AskMessagesTable)>[
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.serverSeq),
          ]))
          .get();

  /// Watches the set of opened citations as `<messageId>#<sourceIndex>` keys.
  Stream<Set<String>> watchAskSourceVisits() =>
      select(askSourceVisits).watch().map(_visitKeys);

  Future<Set<String>> askSourceVisitKeys() async =>
      _visitKeys(await select(askSourceVisits).get());

  static Set<String> _visitKeys(List<AskSourceVisitRow> rows) => <String>{
    for (final AskSourceVisitRow row in rows)
      '${row.messageId}#${row.sourceIndex}',
  };

  /// Records that a citation was opened. Idempotent: reopening a source keeps
  /// the row visited rather than toggling it off.
  Future<void> markAskSourceVisited({
    required String messageId,
    required int sourceIndex,
  }) => into(askSourceVisits).insertOnConflictUpdate(
    AskSourceVisitsCompanion.insert(
      messageId: messageId,
      sourceIndex: sourceIndex,
      visitedAt: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    ),
  );

  Future<void> applyRemoteAskMessage({
    required String id,
    required String role,
    required String text,
    required String sourcesJson,
    required int createdAt,
    required int seq,
  }) => into(askMessages).insertOnConflictUpdate(
    AskMessagesCompanion.insert(
      id: id,
      role: role,
      body: text,
      sourcesJson: Value<String>(sourcesJson),
      createdAt: createdAt,
      serverSeq: seq,
    ),
  );

  /// Replaces a notebook's mirrored index rows with a freshly pulled set.
  ///
  /// Replace-set in ONE transaction: the delete and inserts land atomically,
  /// so a reader never sees a half-swapped index and a crash mid-apply
  /// re-pulls the page instead of leaving stale words behind.
  Future<void> applyRemoteInkIndex({
    required String notebookId,
    required List<InkIndexEntriesCompanion> rows,
  }) async {
    await transaction(() async {
      await (delete(
        inkIndexEntries,
      )..where((t) => t.notebookId.equals(notebookId))).go();
      for (final InkIndexEntriesCompanion row in rows) {
        await into(inkIndexEntries).insertOnConflictUpdate(row);
      }
    });
  }

  /// Drops a notebook's mirrored index rows (its `ink_index` delete arrived —
  /// the notebook was purged server-side, so its words must stop matching).
  Future<void> applyRemoteInkIndexDeletion(String notebookId) async {
    await (delete(
      inkIndexEntries,
    )..where((t) => t.notebookId.equals(notebookId))).go();
  }

  /// Notebooks with local edits the server has not confirmed. Trashed rows
  /// stay out: their tombstone travels instead, and pushing a trashed body
  /// would resurrect it on the peer.
  Future<List<NotebookRow>> notebooksNeedingPush() => (select(
    notebooks,
  )..where((t) => t.syncDirty.equals(true) & t.deletedAt.isNull())).get();

  /// Marks a notebook as accepted by the server at [seq].
  ///
  /// Guarded on `updated_at`: if the notebook was edited again while the push
  /// was in flight, the row is still dirty and clearing the flag here would
  /// strand that newer edit, unsynced and invisible, until the next unrelated
  /// save happened to touch it.
  Future<void> markNotebookSynced(
    String id, {
    required int seq,
    required int pushedUpdatedAt,
  }) async {
    await (update(notebooks)
          ..where((t) => t.id.equals(id) & t.updatedAt.equals(pushedUpdatedAt)))
        .write(
          NotebooksCompanion(
            syncDirty: const Value(false),
            syncedSeq: Value(seq),
          ),
        );
  }

  /// Replaces only a rejected notebook's malformed verifier tuple with the
  /// server's canonical tuple. The body stays dirty so its local edit is
  /// retried on the next sync instead of wedging forever.
  ///
  /// Guarded on [pushedUpdatedAt] for the same reason as
  /// [markNotebookSynced]: a password change made while the request was in
  /// flight must not be overwritten by that request's response.
  Future<void> rebaseNotebookPasswordState(
    String id, {
    required int pushedUpdatedAt,
    required String? passwordHash,
    required String? passwordSalt,
    required int? passwordIterations,
    required String? passwordHashPrev,
  }) async {
    await (update(notebooks)..where(
          (t) =>
              t.id.equals(id) &
              t.updatedAt.equals(pushedUpdatedAt) &
              t.syncDirty.equals(true),
        ))
        .write(
          NotebooksCompanion(
            passwordHash: Value<String?>(passwordHash),
            passwordSalt: Value<String?>(passwordSalt),
            passwordIterations: Value<int?>(passwordIterations),
            passwordHashPrev: Value<String?>(passwordHashPrev),
          ),
        );
  }

  /// Marks a notebook dirty. Every local save funnels through here.
  Future<void> markNotebookDirty(String id) async {
    await (update(notebooks)..where((t) => t.id.equals(id))).write(
      const NotebooksCompanion(syncDirty: Value(true)),
    );
  }

  // ---- dump (recording) sync --------------------------------------------

  /// Recordings whose metadata the server has not accepted yet.
  ///
  /// The dirty flag means THIS device authored an edit (pulls never set
  /// it), so dirty remote-only rows push too — v1.38 made filing a
  /// device-authored edit on any row, and a dirty row that never pushes is
  /// wedged forever: the dirty-row guard skips every future pull for it.
  /// Clean remote-only rows still never push back a peer's own change.
  Future<List<DumpRow>> dumpsNeedingMetadataPush() =>
      (select(dumps)..where(
            // Null means "never touched by sync" => not dirty.
            (d) => d.syncDirty.equals(true),
          ))
          .get();

  /// Marks a recording's metadata as accepted by the server at [seq].
  ///
  /// Guarded on `updated_at` exactly like [markNotebookSynced]: an edit that
  /// landed while the push was in flight must stay dirty, or it is stranded
  /// unsynced until some unrelated save happens to touch the row again.
  Future<void> markDumpSynced(
    String id, {
    required int seq,
    required DateTime pushedUpdatedAt,
  }) async {
    await (update(dumps)
          ..where((d) => d.id.equals(id) & d.updatedAt.equals(pushedUpdatedAt)))
        .write(
          DumpsCompanion(
            syncDirty: const Value<bool?>(false),
            syncedSeq: Value(seq),
          ),
        );
  }

  /// Marks a recording's metadata dirty. Every local metadata edit funnels
  /// through here — a sync engine with no dirty-marking call sites passes
  /// its whole suite while pushing nothing.
  Future<void> markDumpDirty(String id) async {
    await (update(dumps)..where((d) => d.id.equals(id))).write(
      const DumpsCompanion(syncDirty: Value<bool?>(true)),
    );
  }

  /// One dump row, or null. Used by merge to see what is already here.
  Future<DumpRow?> getDumpRow(String id) =>
      (select(dumps)..where((d) => d.id.equals(id))).getSingleOrNull();

  /// Applies a recording's metadata that the server sent us.
  ///
  /// Never touches [Dumps.audioPath] on a row that already exists: the local
  /// file (or SAF locator) is this device's own property and a peer has no
  /// business renaming it. A row that does not exist yet is created
  /// remote-only with an EMPTY audio path — naming a file this device does
  /// not have would produce a playback error instead of an honest
  /// "download from server" affordance.
  ///
  /// Marked clean, not dirty: this content CAME from the server, so pushing
  /// it back would echo forever between the two devices.
  Future<void> applyRemoteDump({
    required String id,
    required String mode,
    required String title,
    required String? transcript,
    required String? meetingNotes,
    required int durationSeconds,
    required bool audioOnServer,
    required DateTime createdAt,
    required DateTime updatedAt,
    required int seq,
    // Summary fields are server-owned and travel server→client only. The
    // sentinel default distinguishes "the payload did not carry the key"
    // (an older server — keep whatever this device already holds; absence
    // is NOT an eraser, mirroring notebooks.ink handling) from "the server
    // explicitly sent null" (authoritative: no summary exists).
    Object? summary = absentSummaryField,
    Object? summaryModel = absentSummaryField,
    Object? summarizedAt = absentSummaryField,
    // Same sentinel rule: an older server that never sends the key must
    // not erase timings this device already holds.
    Object? transcriptTimings = absentSummaryField,
    // Same sentinel rule: an older server that never sends the key must
    // not erase the template choice this device already holds.
    Object? summaryTemplate = absentSummaryField,
    // Device-authored, but the same wire rule: an older server never sends
    // the key (leave the map alone); a present null is "no names".
    Object? speakerNames = absentSpeakerNamesField,
    // v1.19.0 server-authored fields, same absent-vs-null contract: an
    // older server never sends the keys (keep what we hold); a present null
    // is authoritative ('unknown language' / 'idle' / 'no error').
    Object? language = absentSummaryField,
    Object? translated = absentSummaryField,
    Object? summaryStatus = absentSummaryField,
    Object? summaryError = absentSummaryField,
    Object? summaryQueuePosition = absentSummaryField,
    // v1.38 filing: device-authored, but the same absent-vs-null wire rule
    // as notebooks — an older server never sends the key (keep the local
    // filing); a present null is an authoritative "unfiled".
    Object? folderId = absentFolderId,
    // v1.38 auto-file markers: server-authored, same contract as summary.
    Object? autoFiledAt = absentSummaryField,
    Object? autoFilePrevFolderId = absentSummaryField,
    Object? pinned = absentPinnedField,
  }) async {
    final Value<String?> folderIdValue = identical(folderId, absentFolderId)
        ? const Value<String?>.absent()
        : Value<String?>(folderId as String?);
    final Value<int?> autoFiledAtValue =
        identical(autoFiledAt, absentSummaryField)
        ? const Value<int?>.absent()
        : Value<int?>(autoFiledAt as int?);
    final Value<String?> autoFilePrevFolderIdValue =
        identical(autoFilePrevFolderId, absentSummaryField)
        ? const Value<String?>.absent()
        : Value<String?>(autoFilePrevFolderId as String?);
    final Value<String?> languageValue = identical(language, absentSummaryField)
        ? const Value<String?>.absent()
        : Value<String?>(language as String?);
    final Value<bool?> translatedValue =
        identical(translated, absentSummaryField)
        ? const Value<bool?>.absent()
        : Value<bool?>(_wireBool(translated));
    final Value<String?> summaryStatusValue =
        identical(summaryStatus, absentSummaryField)
        ? const Value<String?>.absent()
        : Value<String?>(summaryStatus as String?);
    final Value<String?> summaryErrorValue =
        identical(summaryError, absentSummaryField)
        ? const Value<String?>.absent()
        : Value<String?>(summaryError as String?);
    final Value<int?> summaryQueuePositionValue =
        identical(summaryQueuePosition, absentSummaryField)
        ? const Value<int?>.absent()
        : Value<int?>(summaryQueuePosition as int?);
    final Value<String?> speakerNamesValue =
        identical(speakerNames, absentSpeakerNamesField)
        ? const Value<String?>.absent()
        : Value<String?>(speakerNames as String?);
    final Value<String?> timingsValue =
        identical(transcriptTimings, absentSummaryField)
        ? const Value<String?>.absent()
        : Value<String?>(transcriptTimings as String?);
    final Value<String?> templateValue =
        identical(summaryTemplate, absentSummaryField)
        ? const Value<String?>.absent()
        : Value<String?>(summaryTemplate as String?);
    final Value<String?> summaryValue = identical(summary, absentSummaryField)
        ? const Value<String?>.absent()
        : Value<String?>(summary as String?);
    final Value<String?> summaryModelValue =
        identical(summaryModel, absentSummaryField)
        ? const Value<String?>.absent()
        : Value<String?>(summaryModel as String?);
    final Value<int?> summarizedAtValue =
        identical(summarizedAt, absentSummaryField)
        ? const Value<int?>.absent()
        : Value<int?>(summarizedAt as int?);
    final Value<bool?> pinnedValue = identical(pinned, absentPinnedField)
        ? const Value<bool?>.absent()
        : Value<bool?>(_wireBool(pinned));
    final DumpRow? existing = await getDumpRow(id);
    // Summary-in-progress: the server answered. When the incoming
    // summarized_at is at least as new as what this device asked for, the
    // pending marker is spent — clear it in the SAME write so the strip
    // disappears the instant the answer lands and a later re-open never
    // shows a stale one. An older summarized_at (a stale peer echo) leaves
    // the marker alone: the requested job has not finished yet.
    final int? requestedAt = existing?.summaryRequestedAt;
    final int? incomingSummarizedAt = summarizedAtValue.present
        ? summarizedAtValue.value
        : null;
    final bool summaryAnswered =
        requestedAt != null &&
        incomingSummarizedAt != null &&
        incomingSummarizedAt >= requestedAt;
    // v1.19.0: the server's own verdict outranks the local guess. A 'failed'
    // status ends the request too — the local heuristic must not keep the
    // strip saying 'in progress' over a failure the server already reported.
    final bool summaryFailedNow =
        summaryStatusValue.present && summaryStatusValue.value == 'failed';
    final Value<int?> summaryRequestedAtValue =
        summaryAnswered || summaryFailedNow
        ? const Value<int?>(null)
        : const Value<int?>.absent();
    // A successful summary (status null, summarized_at advanced past what we
    // hold) also spends the local 'dismissed' marker, so the red line comes
    // back on the NEXT failure rather than staying hidden forever.
    final bool summarySucceeded =
        summaryStatusValue.present &&
        summaryStatusValue.value == null &&
        incomingSummarizedAt != null &&
        (existing?.summarizedAt == null ||
            incomingSummarizedAt > existing!.summarizedAt!);
    // A NEW attempt (server says queued/running) spends it as well: if that
    // attempt fails, the user must see the fresh failure.
    final bool summaryAttemptStarted =
        summaryStatusValue.present &&
        (summaryStatusValue.value == 'queued' ||
            summaryStatusValue.value == 'running');
    final Value<int?> summaryErrorDismissedAtValue =
        summarySucceeded || summaryAnswered || summaryAttemptStarted
        ? const Value<int?>(null)
        : const Value<int?>.absent();
    if (existing == null) {
      // Re-creating a row the server still holds. If a COMPLETED local
      // deletion receipt is parked on this id, the server's copy has
      // outlived the local deletion — the user deleted here, the peer kept
      // it. The receipt's job (fencing mutations against a half-deleted
      // identity) ended when the deletion finished; left in place it makes
      // the resurrected row permanently un-downloadable ('Recording
      // identity is fenced' on all 43 of the Fold's stuck rows). Clear it
      // and let the fresh remote-only row start with a clean identity.
      // A NON-completed ticket is live in-flight work and stays: the fence
      // must win that race, and the pull is skipped by the dirty-row guard.
      await (delete(
        localDeletionTickets,
      )..where((t) => t.dumpId.equals(id) & t.state.equals('completed'))).go();
      await into(dumps).insert(
        DumpsCompanion.insert(
          id: id,
          createdAt: createdAt,
          updatedAt: updatedAt,
          mode: mode,
          durationSeconds: durationSeconds,
          title: title,
          transcript: Value(transcript),
          meetingNotes: Value(meetingNotes),
          // A remote recording that already carries transcript text IS
          // transcribed. Leaving this at the default made the list show
          // "Not transcribed" on 37 rows whose transcript was right there.
          transcriptionStatus: Value(
            (transcript ?? '').trim().isEmpty ? 'not_transcribed' : 'completed',
          ),
          // No bytes here. remoteOnly is what the UI branches on.
          audioPath: '',
          audioSizeBytes: 0,
          syncStatus: 'synced',
          remoteOnly: const Value<bool?>(true),
          audioOnServer: Value<bool?>(audioOnServer),
          summary: summaryValue,
          summaryModel: summaryModelValue,
          summarizedAt: summarizedAtValue,
          transcriptTimings: timingsValue,
          summaryTemplate: templateValue,
          speakerNames: speakerNamesValue,
          language: languageValue,
          translated: translatedValue,
          summaryStatus: summaryStatusValue,
          summaryError: summaryErrorValue,
          summaryQueuePosition: summaryQueuePositionValue,
          folderId: folderIdValue,
          autoFiledAt: autoFiledAtValue,
          autoFilePrevFolderId: autoFilePrevFolderIdValue,
          pinned: pinnedValue,
          syncedSeq: Value(seq),
        ),
        mode: InsertMode.insertOrReplace,
      );
      return;
    }
    // Existing row: update only the metadata columns. Whole-row replacement
    // here would wipe audioPath, transcription ownership columns and the
    // storage key, which is how a local recording loses its own audio.
    await (update(dumps)..where((d) => d.id.equals(id))).write(
      DumpsCompanion(
        title: Value(title),
        transcript: Value(transcript),
        meetingNotes: Value(meetingNotes),
        // Same rule on update: a peer finishing a transcript must flip this
        // row out of "not transcribed" here too.
        transcriptionStatus: (transcript ?? '').trim().isEmpty
            ? const Value.absent()
            : const Value('completed'),
        updatedAt: Value(updatedAt),
        audioOnServer: Value<bool?>(audioOnServer),
        summary: summaryValue,
        summaryModel: summaryModelValue,
        summarizedAt: summarizedAtValue,
        transcriptTimings: timingsValue,
        summaryTemplate: templateValue,
        speakerNames: speakerNamesValue,
        summaryRequestedAt: summaryRequestedAtValue,
        language: languageValue,
        translated: translatedValue,
        summaryStatus: summaryStatusValue,
        summaryError: summaryErrorValue,
        summaryQueuePosition: summaryQueuePositionValue,
        summaryErrorDismissedAt: summaryErrorDismissedAtValue,
        folderId: folderIdValue,
        autoFiledAt: autoFiledAtValue,
        autoFilePrevFolderId: autoFilePrevFolderIdValue,
        pinned: pinnedValue,
        syncDirty: const Value<bool?>(false),
        syncedSeq: Value(seq),
      ),
    );
  }

  /// The wire `translated` is 0/1 (SQLite integer) but a bool or null is
  /// accepted too; null reads as "not translated".
  static bool? _wireBool(Object? raw) {
    if (raw == null) return null;
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    return raw.toString() == '1' || raw.toString() == 'true';
  }

  /// Hides the 'Summary failed' line on THIS device (v1.19.0): stamps the
  /// local-only [Dumps.summaryErrorDismissedAt] with [now] (unix seconds).
  /// Not dirty, updated_at untouched — nothing here is the server's
  /// business. [applyRemoteDump] clears it again when the summary succeeds.
  Future<void> dismissSummaryError(String id, {DateTime? now}) async {
    final int dismissedAt =
        (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    await (update(dumps)..where((d) => d.id.equals(id))).write(
      DumpsCompanion(summaryErrorDismissedAt: Value<int?>(dismissedAt)),
    );
  }

  /// Sentinel distinguishing "payload had no summary keys" (older server —
  /// keep the stored values) from "server sent null" for [applyRemoteDump].
  static const Object absentSummaryField = Object();

  /// Sentinel distinguishing "payload had no `speaker_names` key" (older
  /// server — keep the stored map) from "present null" (cleared) for
  /// [applyRemoteDump].
  static const Object absentSpeakerNamesField = Object();

  /// Sentinel for the additive `pinned` wire field on all three item types.
  /// An older peer omits it, which must preserve the local pin.
  static const Object absentPinnedField = Object();

  /// Writes the speaker name map for one recording (spec §4): [names] null
  /// or empty clears the column. Bumps `updated_at` and marks the row dirty
  /// so the rename reaches the server and every other device. Never
  /// touches the transcript text.
  Future<DumpRow> updateSpeakerNames(
    String id,
    SpeakerNames? names, {
    DateTime? now,
  }) {
    return transaction(() async {
      final int count = await (update(dumps)..where((d) => d.id.equals(id)))
          .write(
            DumpsCompanion(
              speakerNames: Value<String?>(names?.encode()),
              updatedAt: Value((now ?? DateTime.now()).toUtc()),
            ),
          );
      if (count != 1) throw StateError('Dump not found: $id');
      await markDumpDirty(id);
      return (await getDump(id))!;
    });
  }

  /// Records the template the user just asked the server to summarize
  /// with, so the picker shows it as current while the summary is still
  /// being written (30-60 s). NOT marked dirty: the server already holds
  /// this value (the summarize POST wrote it) and a push here would race
  /// the worker's own publish. Does not bump updated_at for the same
  /// reason — the server's row time is authoritative for this field.
  ///
  /// Also stamps [Dumps.summaryRequestedAt] with [now] (unix seconds) so the
  /// UI can show "summary in progress" until a summary at least that new
  /// syncs down (see `summaryPending`). Local-only; never pushed.
  Future<void> recordRequestedSummaryTemplate(
    String id,
    String templateId, {
    DateTime? now,
  }) async {
    final int requestedAt =
        (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    await (update(dumps)..where((d) => d.id.equals(id))).write(
      DumpsCompanion(
        summaryTemplate: Value<String?>(templateId),
        summaryRequestedAt: Value<int?>(requestedAt),
        // A fresh request supersedes a dismissed failure: the strip shows
        // 'in progress' now and a new failure must be visible again.
        summaryErrorDismissedAt: const Value<int?>(null),
      ),
    );
  }

  /// Soft-deletes a recording because a peer deleted it.
  ///
  /// The tombstone is authoritative for metadata. Any audio this device
  /// downloaded is removed from the row, but the file itself is left to the
  /// storage layer's own cleanup — this method never deletes user audio
  /// directly.
  Future<void> applyRemoteDumpDeletion(String id) async {
    await (delete(dumps)..where((d) => d.id.equals(id))).go();
  }

  /// Writes a consistent, self-contained copy of this database to [target].
  ///
  /// Diagnostics for release builds: a phone's data dir is unreadable
  /// without `run-as` (debug only) or root, so the app writes its own copy
  /// somewhere `adb pull` can reach. `VACUUM INTO` snapshots the live
  /// connection including anything still in the WAL, which a plain file
  /// copy of `tangent.sqlite` would miss. Metadata only — audio bytes never
  /// live in this database. An existing file at [target] is replaced;
  /// SQLite refuses to vacuum into a non-empty file.
  Future<File> writeDiagnosticSnapshot(File target) async {
    if (target.existsSync()) target.deleteSync();
    target.parent.createSync(recursive: true);
    // Single quotes inside the path would end the SQL literal early.
    final escaped = target.path.replaceAll("'", "''");
    await customStatement("VACUUM INTO '$escaped'");
    return target;
  }

  /// Records that this device has downloaded a remote recording's audio.
  Future<void> attachDownloadedAudio(
    String id, {
    required String audioPath,
    required int audioSizeBytes,
  }) async {
    await (update(dumps)..where((d) => d.id.equals(id))).write(
      DumpsCompanion(
        audioPath: Value(audioPath),
        audioSizeBytes: Value(audioSizeBytes),
        remoteOnly: const Value<bool?>(false),
      ),
    );
  }

  /// Reverses [attachDownloadedAudio] after a failed download.
  ///
  /// A row holding an audio path with no binding is unplayable but LOOKS
  /// available, so a partial failure must put the row back to remote-only
  /// rather than leaving the user a recording that cannot open. Only the
  /// audio columns move; metadata and transcript are untouched.
  Future<void> clearDownloadedAudio(String id) async {
    await (update(dumps)..where((d) => d.id.equals(id))).write(
      const DumpsCompanion(
        audioPath: Value<String>(''),
        audioSizeBytes: Value<int>(0),
        remoteOnly: Value<bool?>(true),
      ),
    );
  }

  Future<void> recordTombstone({
    required String entityType,
    required String entityId,
  }) async {
    await into(syncTombstones).insert(
      SyncTombstonesCompanion.insert(
        entityType: entityType,
        entityId: entityId,
        deletedAt: DateTime.now().millisecondsSinceEpoch,
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<List<SyncTombstoneRow>> pendingTombstones() =>
      select(syncTombstones).get();

  /// One notebook row, or null. Used by merge to see what is already here.
  Future<NotebookRow?> getNotebookRow(String id) =>
      (select(notebooks)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> clearTombstone({
    required String entityType,
    required String entityId,
  }) async {
    await (delete(syncTombstones)..where(
          (t) => t.entityType.equals(entityType) & t.entityId.equals(entityId),
        ))
        .go();
  }

  /// Applies a notebook the server sent us.
  ///
  /// Marked clean, not dirty: this content CAME from the server, so pushing it
  /// straight back would echo every pulled change into a new change_log entry
  /// and the two devices would trade the same notebook forever.
  Future<void> applyRemoteNotebook({
    required String id,
    required String title,
    required int createdAt,
    required int updatedAt,
    required String docJson,
    required String inkJson,
    required int seq,
    String? ruling,
    String? lastPenStyle,
    Object? folderId = absentFolderId,
    Object? pinned = absentPinnedField,
    Object? passwordHash = absentPasswordMetadata,
    String? passwordSalt,
    int? passwordIterations,
    String? passwordHashPrev,
  }) async {
    // insertOrReplace rewrites the whole row, so a null ruling here would
    // erase a value this device already holds whenever the peer is an older
    // build that does not send one. Fall back to what is already stored.
    // folder_id gets the same treatment with a twist: null is MEANINGFUL
    // (it says "unfiled"), so absence is a sentinel rather than null.
    final NotebookRow? existing = await (select(
      notebooks,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final String? effectiveRuling = ruling ?? existing?.ruling;
    // The nib gets the ruling treatment: an older peer that has never heard
    // of pen memory sends nothing, and that absence must not erase the nib
    // this device already remembers.
    final String? effectivePenStyle = lastPenStyle ?? existing?.lastPenStyle;
    final String? effectiveFolderId = identical(folderId, absentFolderId)
        ? existing?.folderId
        : folderId as String?;
    final bool? effectivePinned = identical(pinned, absentPinnedField)
        ? existing?.pinned
        : _wireBool(pinned);
    final bool preservePassword = identical(
      passwordHash,
      absentPasswordMetadata,
    );
    final String? effectivePasswordHash = preservePassword
        ? existing?.passwordHash
        : passwordHash as String?;
    final String? effectivePasswordSalt = preservePassword
        ? existing?.passwordSalt
        : effectivePasswordHash == null
        ? null
        : passwordSalt;
    final int? effectivePasswordIterations = preservePassword
        ? existing?.passwordIterations
        : effectivePasswordHash == null
        ? null
        : passwordIterations;
    final String? effectivePasswordHashPrev = preservePassword
        ? existing?.passwordHashPrev
        : passwordHashPrev;

    await into(notebooks).insert(
      NotebooksCompanion.insert(
        id: id,
        title: title,
        createdAt: createdAt,
        updatedAt: updatedAt,
        docJson: docJson,
        inkJson: inkJson,
        ruling: Value<String?>(effectiveRuling),
        lastPenStyle: Value<String?>(effectivePenStyle),
        folderId: Value<String?>(effectiveFolderId),
        pinned: Value<bool?>(effectivePinned),
        passwordHash: Value<String?>(effectivePasswordHash),
        passwordSalt: Value<String?>(effectivePasswordSalt),
        passwordIterations: Value<int?>(effectivePasswordIterations),
        passwordHashPrev: Value<String?>(effectivePasswordHashPrev),
        syncDirty: const Value(false),
        syncedSeq: Value(seq),
        // An arriving upsert means the notebook lives; a copy sitting in
        // this device's trash from an earlier remote deletion returns to
        // the shelf rather than shadowing the resurrection.
        deletedAt: const Value<int?>(null),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  /// Sentinel distinguishing "caller sent nothing" from "caller sent null"
  /// for [applyRemoteNotebook]'s folderId: null MEANS unfiled there.
  static const Object absentFolderId = Object();

  /// A peer predating password metadata sent no verifier fields. Missing or a
  /// verifier transition that failed causal validation preserves protection.
  static const Object absentPasswordMetadata = Object();

  /// Removes a notebook the server says was deleted elsewhere.
  ///
  /// Into the TRASH, not oblivion: the deletion synced from another device,
  /// and the user has 7 days (Settings → Trash) to disagree with it.
  /// No tombstone is written: this deletion is already in the server's log, and
  /// recording it again would push it back as if it were local.
  Future<void> applyRemoteNotebookDeletion(String id) async {
    await (update(notebooks)..where((t) => t.id.equals(id))).write(
      NotebooksCompanion(
        deletedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  // ---- todos (To Do arc Phase 1) -----------------------------------------

  /// Sentinel distinguishing "the payload did not carry the key" from "the
  /// payload explicitly sent null" for [applyRemoteTodo]'s nullable fields.
  /// Same discipline as [absentSummaryField]: an older client whose payload
  /// is missing a key must not erase what this device already holds, while
  /// a present null is authoritative (an undated todo, an unchecked todo).
  static const Object absentTodoField = Object();

  static const String todoBoardBackfillPrefix = 'todo_kanban_backfill:';

  /// The migrated placement owed by a formerly-clean todo, or null when this
  /// row was not dirtied solely by the Kanban upgrade.
  Future<int?> pendingTodoBoardOrder(String id) async {
    final LocalSettingRow? marker =
        await (select(localSettings)
              ..where((s) => s.key.equals('$todoBoardBackfillPrefix$id')))
            .getSingleOrNull();
    return marker == null ? null : int.tryParse(marker.value);
  }

  /// Re-applies only the placement after a newer canonical server body lands.
  Future<void> restorePendingTodoBoardPlacement(
    String id, {
    required String updatedAt,
  }) async {
    final int? order = await pendingTodoBoardOrder(id);
    if (order == null) return;
    await (update(todos)..where((t) => t.id.equals(id))).write(
      TodosCompanion(
        columnId: const Value('todo-column-todo'),
        boardOrder: Value(order),
        updatedAt: Value(updatedAt),
        syncDirty: const Value(true),
      ),
    );
  }

  Future<void> completeTodoBoardBackfill(String id) async {
    await (delete(
      localSettings,
    )..where((s) => s.key.equals('$todoBoardBackfillPrefix$id'))).go();
  }

  /// One todo row, or null. Used by merge to see what is already here.
  Future<TodoRow?> getTodoRow(String id) =>
      (select(todos)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Todos with local edits the server has not confirmed. Soft-deleted rows
  /// stay IN: unlike notebooks the deletion is a field on the row, not a
  /// tombstone, so the delete itself has to travel as a dirty upsert.
  Future<List<TodoRow>> todosNeedingPush() =>
      (select(todos)..where((t) => t.syncDirty.equals(true))).get();

  /// Marks a todo as accepted by the server at [seq]. Guarded on
  /// `updated_at` exactly like [markNotebookSynced]: an edit that landed
  /// while the push was in flight must stay dirty.
  Future<void> markTodoSynced(
    String id, {
    required int seq,
    required String pushedUpdatedAt,
  }) async {
    await (update(todos)
          ..where((t) => t.id.equals(id) & t.updatedAt.equals(pushedUpdatedAt)))
        .write(
          TodosCompanion(syncDirty: const Value(false), syncedSeq: Value(seq)),
        );
  }

  /// Applies a todo the server sent us.
  ///
  /// Marked clean, not dirty: this content CAME from the server, so pushing
  /// it back would echo forever between devices. Absent nullable fields
  /// keep whatever this device already holds (see [absentTodoField]).
  Future<void> applyRemoteTodo({
    required String id,
    required String text,
    required String createdAt,
    required String updatedAt,
    required int seq,
    String? source,
    Object? doneAt = absentTodoField,
    Object? dueDate = absentTodoField,
    Object? dueTime = absentTodoField,
    Object? sourceRef = absentTodoField,
    Object? deletedAt = absentTodoField,
    Object? folderId = absentTodoField,
    Object? pinned = absentPinnedField,
    Object? columnId = absentTodoField,
    Object? boardOrder = absentTodoField,
  }) async {
    final TodoRow? existing = await getTodoRow(id);
    String? resolve(Object? incoming, String? held) =>
        identical(incoming, absentTodoField) ? held : incoming as String?;
    await into(todos).insert(
      TodosCompanion.insert(
        id: id,
        body: text,
        createdAt: createdAt,
        updatedAt: updatedAt,
        source: Value(source ?? existing?.source ?? 'manual'),
        doneAt: Value(resolve(doneAt, existing?.doneAt)),
        dueDate: Value(resolve(dueDate, existing?.dueDate)),
        dueTime: Value(
          identical(dueTime, absentTodoField)
              ? (identical(dueDate, absentTodoField)
                    ? existing?.dueTime
                    : dueDate == null
                    ? null
                    : existing?.dueTime ?? '09:00')
              : dueTime as String?,
        ),
        sourceRef: Value(resolve(sourceRef, existing?.sourceRef)),
        deletedAt: Value(resolve(deletedAt, existing?.deletedAt)),
        folderId: Value(resolve(folderId, existing?.folderId)),
        pinned: Value<bool?>(
          identical(pinned, absentPinnedField)
              ? existing?.pinned
              : _wireBool(pinned),
        ),
        columnId: Value(resolve(columnId, existing?.columnId)),
        boardOrder: Value(
          identical(boardOrder, absentTodoField)
              ? existing?.boardOrder ?? 0
              : (boardOrder as num?)?.toInt() ?? 0,
        ),
        // Local-only: a pull never carries it, so the held value survives.
        captureFingerprint: Value(existing?.captureFingerprint),
        syncDirty: const Value(false),
        syncedSeq: Value(seq),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<TodoColumnRow?> getTodoColumnRow(String id) =>
      (select(todoColumns)..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<List<TodoColumnRow>> todoColumnsNeedingPush() =>
      (select(todoColumns)..where((c) => c.syncDirty.equals(true))).get();

  Future<void> markTodoColumnSynced(
    String id, {
    required int seq,
    required String pushedUpdatedAt,
  }) async {
    await (update(todoColumns)
          ..where((c) => c.id.equals(id) & c.updatedAt.equals(pushedUpdatedAt)))
        .write(
          TodoColumnsCompanion(
            syncDirty: const Value(false),
            syncedSeq: Value(seq),
          ),
        );
  }

  Future<void> applyRemoteTodoColumn({
    required String id,
    required String name,
    required int sortOrder,
    required String createdAt,
    required String updatedAt,
    required int seq,
    Object? deletedAt = absentTodoField,
  }) async {
    final TodoColumnRow? existing = await getTodoColumnRow(id);
    if (existing != null && existing.updatedAt.compareTo(updatedAt) > 0) return;
    await into(todoColumns).insert(
      TodoColumnsCompanion.insert(
        id: id,
        name: name,
        sortOrder: sortOrder,
        createdAt: createdAt,
        updatedAt: updatedAt,
        deletedAt: Value(
          identical(deletedAt, absentTodoField)
              ? existing?.deletedAt
              : deletedAt as String?,
        ),
        syncDirty: const Value(false),
        syncedSeq: Value(seq),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  // ---- calendar events (v1.35.0) -----------------------------------------

  Future<CalendarEventRow?> getCalendarEventRow(String id) =>
      (select(calendarEvents)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Same contract as [todosNeedingPush]: soft-deleted rows stay in.
  Future<List<CalendarEventRow>> calendarEventsNeedingPush() =>
      (select(calendarEvents)..where((t) => t.syncDirty.equals(true))).get();

  Future<void> markCalendarEventSynced(
    String id, {
    required int seq,
    required String pushedUpdatedAt,
  }) async {
    await (update(calendarEvents)
          ..where((t) => t.id.equals(id) & t.updatedAt.equals(pushedUpdatedAt)))
        .write(
          CalendarEventsCompanion(
            syncDirty: const Value(false),
            syncedSeq: Value(seq),
          ),
        );
  }

  /// Applies a calendar event the server sent us — clean, not dirty (same
  /// reasoning as [applyRemoteTodo]). The `google*` fields are the ONLY
  /// way those columns ever get a value on a device; absent keys keep what
  /// is held. `capture_fingerprint` is local-only and never read here.
  Future<void> applyRemoteCalendarEvent({
    required String id,
    required String title,
    required String start,
    required String end,
    required bool allDay,
    required String timeZone,
    required bool needsDate,
    required String createdAt,
    required String updatedAt,
    required int seq,
    String? source,
    Object? sourceRef = absentTodoField,
    Object? deletedAt = absentTodoField,
    Object? googleEventId = absentTodoField,
    Object? googleHtmlLink = absentTodoField,
    Object? googleUpdated = absentTodoField,
  }) async {
    final CalendarEventRow? existing = await getCalendarEventRow(id);
    String? resolve(Object? incoming, String? held) =>
        identical(incoming, absentTodoField) ? held : incoming as String?;
    await into(calendarEvents).insert(
      CalendarEventsCompanion.insert(
        id: id,
        title: title,
        start: start,
        end: end,
        allDay: Value(allDay),
        timeZone: timeZone,
        needsDate: Value(needsDate),
        createdAt: createdAt,
        updatedAt: updatedAt,
        source: Value(source ?? existing?.source ?? 'voice'),
        sourceRef: Value(resolve(sourceRef, existing?.sourceRef)),
        deletedAt: Value(resolve(deletedAt, existing?.deletedAt)),
        googleEventId: Value(resolve(googleEventId, existing?.googleEventId)),
        googleHtmlLink: Value(
          resolve(googleHtmlLink, existing?.googleHtmlLink),
        ),
        googleUpdated: Value(resolve(googleUpdated, existing?.googleUpdated)),
        captureFingerprint: Value(existing?.captureFingerprint),
        syncDirty: const Value(false),
        syncedSeq: Value(seq),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }
  // ---- folders -----------------------------------------------------------

  /// Creates a folder and returns its id.
  Future<String> createFolder({required String name, String? id}) async {
    // UUID, not a clock reading: Windows ticks `microsecondsSinceEpoch` in
    // ~1 ms steps, so two folders created back-to-back collided on the
    // primary key (UNIQUE constraint failed: folders.id) in the full suite.
    // Two devices could do the same in the wild. The prefix stays so
    // existing ids and logs still read as folders.
    final String folderId = id ?? 'folder-${const Uuid().v4()}';
    await into(folders).insert(
      FoldersCompanion.insert(
        id: folderId,
        name: name,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        // Local creations are unsynced work until the server confirms them.
        syncDirty: const Value<bool?>(true),
      ),
    );
    return folderId;
  }

  Stream<List<Folder>> watchFolders() =>
      (select(folders)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Future<void> renameFolder({
    required String folderId,
    required String name,
  }) async {
    await (update(folders)..where((t) => t.id.equals(folderId))).write(
      FoldersCompanion(
        name: Value<String>(name),
        // A rename is a local edit the other devices have not heard.
        syncDirty: const Value<bool?>(true),
      ),
    );
  }

  /// Files a notebook, or unfiles it when [folderId] is null.
  Future<void> moveNotebookToFolder({
    required String notebookId,
    required String? folderId,
  }) async {
    await (update(notebooks)..where((t) => t.id.equals(notebookId))).write(
      NotebooksCompanion(
        folderId: Value<String?>(folderId),
        // Filing travels with the notebook payload, so a move must push.
        syncDirty: const Value(true),
      ),
    );
  }

  /// Pins or unpins a notebook as a normal synced metadata edit.
  Future<void> setNotebookPinned(
    String id,
    bool pinned, {
    DateTime? now,
  }) async {
    final int count = await (update(notebooks)..where((t) => t.id.equals(id)))
        .write(
          NotebooksCompanion(
            pinned: Value<bool?>(pinned),
            updatedAt: Value(
              (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
            ),
            syncDirty: const Value(true),
          ),
        );
    if (count != 1) throw StateError('Notebook not found: $id');
  }

  /// Files a recording or note, or unfiles it when [folderId] is null.
  ///
  /// v1.38: filing travels with the dump payload, so a move marks the row
  /// dirty and bumps `updated_at` (the newer-wins tiebreak on peers). A
  /// manual move is also the user taking control: it spends any auto-file
  /// markers, so the "Auto-filed · Undo" chip disappears.
  Future<void> moveDumpToFolder({
    required String dumpId,
    required String? folderId,
  }) async {
    await (update(dumps)..where((t) => t.id.equals(dumpId))).write(
      DumpsCompanion(
        folderId: Value<String?>(folderId),
        autoFiledAt: const Value<int?>(null),
        autoFilePrevFolderId: const Value<String?>(null),
        updatedAt: Value(DateTime.now().toUtc()),
        syncDirty: const Value<bool?>(true),
      ),
    );
  }

  /// Undoes a server auto-file: moves the recording back to where it was
  /// before the server filed it (almost always unfiled) and spends the
  /// markers. Marked dirty so the push carries the reverted filing, which
  /// is what retires the chip on the server and every other device.
  /// A no-op when the row is gone or was never auto-filed.
  Future<void> undoAutoFile(String dumpId) async {
    final DumpRow? row = await getDumpRow(dumpId);
    if (row == null || row.autoFiledAt == null) return;
    await (update(dumps)..where((t) => t.id.equals(dumpId))).write(
      DumpsCompanion(
        folderId: Value<String?>(row.autoFilePrevFolderId),
        autoFiledAt: const Value<int?>(null),
        autoFilePrevFolderId: const Value<String?>(null),
        updatedAt: Value(DateTime.now().toUtc()),
        syncDirty: const Value<bool?>(true),
      ),
    );
  }

  /// Pins or unpins a recording/note as a normal synced metadata edit.
  Future<void> setDumpPinned(String id, bool pinned, {DateTime? now}) async {
    await transaction(() async {
      final int count = await (update(dumps)..where((t) => t.id.equals(id)))
          .write(
            DumpsCompanion(
              pinned: Value<bool?>(pinned),
              updatedAt: Value((now ?? DateTime.now()).toUtc()),
            ),
          );
      if (count != 1) throw StateError('Dump not found: $id');
      await markDumpDirty(id);
    });
  }

  /// Renames a recording or note. Deliberately writes only the title, so a
  /// rename cannot disturb filing, sync state or transcription state.
  Future<void> renameDump({
    required String dumpId,
    required String title,
  }) async {
    await (update(dumps)..where((t) => t.id.equals(dumpId))).write(
      DumpsCompanion(title: Value<String>(title)),
    );
  }

  /// Deletes a folder and unfiles everything inside it.
  ///
  /// The contents are never deleted: a folder is a label, and removing a label
  /// must not destroy the work it was attached to. The tombstone rides the
  /// same feed as notebook deletions so the other devices drop the label too;
  /// the unfiled notebooks are marked dirty so their new (unfiled) state
  /// pushes with it.
  Future<void> deleteFolder(String folderId) async {
    await transaction(() async {
      await (update(
        notebooks,
      )..where((t) => t.folderId.equals(folderId))).write(
        const NotebooksCompanion(
          folderId: Value<String?>(null),
          syncDirty: Value(true),
        ),
      );
      // One folder holds both kinds, so both must be unfiled together.
      await (update(dumps)..where((t) => t.folderId.equals(folderId))).write(
        const DumpsCompanion(
          folderId: Value<String?>(null),
          syncDirty: Value<bool?>(true),
        ),
      );
      // v1.24.0: to-dos share the folder too (F1), so they unfile here as
      // well — dirty, so the unfiled state pushes with the tombstone.
      await (update(todos)..where((t) => t.folderId.equals(folderId))).write(
        TodosCompanion(
          folderId: const Value<String?>(null),
          updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
          syncDirty: const Value(true),
        ),
      );
      await (delete(folders)..where((t) => t.id.equals(folderId))).go();
      await recordTombstone(entityType: 'folder', entityId: folderId);
    });
  }

  // ---- folder sync -------------------------------------------------------

  /// Folders with local changes the server has not confirmed. Null reads as
  /// dirty: a folder that predates folder sync has never been pushed.
  Future<List<Folder>> foldersNeedingPush() => (select(
    folders,
  )..where((t) => t.syncDirty.equals(true) | t.syncDirty.isNull())).get();

  /// Marks a folder accepted by the server at [seq].
  Future<void> markFolderSynced(String id, {required int seq}) async {
    await (update(folders)..where((t) => t.id.equals(id))).write(
      FoldersCompanion(
        syncDirty: const Value<bool?>(false),
        syncedSeq: Value(seq),
      ),
    );
  }

  /// Applies a folder the server sent us. Clean, not dirty: echoing a pulled
  /// folder back would trade the same change between devices forever.
  Future<void> applyRemoteFolder({
    required String id,
    required String name,
    required int createdAt,
    required int seq,
  }) async {
    await into(folders).insert(
      FoldersCompanion.insert(
        id: id,
        name: name,
        createdAt: createdAt,
        syncDirty: const Value<bool?>(false),
        syncedSeq: Value(seq),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  /// Removes a folder the server says was deleted elsewhere, unfiling its
  /// contents WITHOUT marking them dirty — the peer that deleted the folder
  /// already pushed its own unfilings, and re-pushing ours would echo.
  Future<void> applyRemoteFolderDeletion(String id) async {
    await transaction(() async {
      await (update(notebooks)..where((t) => t.folderId.equals(id))).write(
        const NotebooksCompanion(folderId: Value<String?>(null)),
      );
      await (update(dumps)..where((t) => t.folderId.equals(id))).write(
        const DumpsCompanion(folderId: Value<String?>(null)),
      );
      await (delete(folders)..where((t) => t.id.equals(id))).go();
    });
  }

  // ---- tags (v33) --------------------------------------------------------

  /// The two kinds of thing a tag can sit on. Wire values, shared with the
  /// server's CHECK constraint.
  static const String tagTargetNotebook = 'notebook';
  static const String tagTargetDump = 'dump';
  static const Set<String> tagTargetTypes = <String>{
    tagTargetNotebook,
    tagTargetDump,
  };

  /// Longest tag name accepted locally. The row shows tags on ONE line, so a
  /// paragraph-length tag would only ever render as an ellipsis.
  static const int maxTagNameLength = 48;

  /// Deterministic assignment id: `ta-` + 40 hex of
  /// sha256(tagId NUL targetType NUL targetId). The server recomputes and
  /// enforces it, so the same tag on the same item is one row fleet-wide.
  static String tagAssignmentId(
    String tagId,
    String targetType,
    String targetId,
  ) {
    final Digest digest = sha256.convert(
      utf8.encode('$tagId\u0000$targetType\u0000$targetId'),
    );
    return 'ta-${digest.toString().substring(0, 40)}';
  }

  /// Trims and collapses inner whitespace; throws [TagNameException] for a
  /// blank or over-long name.
  static String normalizeTagName(String raw) {
    final String name = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty) throw const TagNameException('Tag name is empty');
    if (name.length > maxTagNameLength) {
      throw const TagNameException(
        'Tag name is longer than $maxTagNameLength characters',
      );
    }
    return name;
  }

  static void _checkTagTarget(String targetType) {
    if (!tagTargetTypes.contains(targetType)) {
      throw ArgumentError.value(targetType, 'targetType');
    }
  }

  /// Every tag, alphabetical (case-insensitive). The tag table is a short
  /// vocabulary, so streaming it whole is the lightweight projection.
  Stream<List<TagRow>> watchTags() =>
      (select(tags)..orderBy(<OrderClauseGenerator<$TagsTable>>[
            (t) => OrderingTerm.asc(t.name.collate(Collate.noCase)),
          ]))
          .watch();

  Future<List<TagRow>> allTags() => select(tags).get();

  /// The (target, tag) pairs for one target kind — two short text columns
  /// per row, joined to LIVE tags so an assignment whose tag is gone never
  /// renders. This is what the list screens watch instead of full rows.
  Stream<List<TagLink>> watchTagLinks(String targetType) {
    _checkTagTarget(targetType);
    return customSelect(
      'SELECT a.target_id AS target_id, a.tag_id AS tag_id '
      'FROM tag_assignments a JOIN tags t ON t.id = a.tag_id '
      'WHERE a.target_type = ?',
      variables: <Variable<Object>>[Variable<String>(targetType)],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        tagAssignments,
        tags,
      },
    ).watch().map(
      (List<QueryRow> rows) => <TagLink>[
        for (final QueryRow row in rows)
          (
            targetId: row.read<String>('target_id'),
            tagId: row.read<String>('tag_id'),
          ),
      ],
    );
  }

  /// How many items (notebooks and recordings together) carry [tagId]. The
  /// delete confirmation states it, so only targets the user can SEE here
  /// count: a trashed notebook (its assignment is kept for a restore), a
  /// permanently deleted recording (assignments are left in place) and a
  /// target not pulled yet all keep their rows but are not counted.
  Future<int> tagAssignmentCount(String tagId) async {
    final QueryRow row = await customSelect(
      'SELECT COUNT(*) AS c FROM tag_assignments a WHERE a.tag_id = ? AND ('
      "(a.target_type = 'notebook' AND EXISTS (SELECT 1 FROM notebooks n "
      'WHERE n.id = a.target_id AND n.deleted_at IS NULL)) OR '
      "(a.target_type = 'dump' AND EXISTS (SELECT 1 FROM dumps d "
      'WHERE d.id = a.target_id)))',
      variables: <Variable<Object>>[Variable<String>(tagId)],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        tagAssignments,
        notebooks,
        dumps,
      },
    ).getSingle();
    return row.read<int>('c');
  }

  Future<TagRow?> _tagByName(String name, {String? exceptId}) async {
    final String folded = name.toLowerCase();
    for (final TagRow row in await allTags()) {
      if (row.id != exceptId && row.name.toLowerCase() == folded) return row;
    }
    return null;
  }

  /// Creates a tag and returns its id — or returns the EXISTING tag's id when
  /// the name is already taken (case-insensitively), so "create inline" can
  /// never mint a duplicate on this device.
  Future<String> createTag(String rawName, {String? id, DateTime? now}) async {
    final String name = normalizeTagName(rawName);
    return transaction(() async {
      final TagRow? existing = await _tagByName(name);
      if (existing != null) return existing.id;
      final String tagId = id ?? 'tag-${const Uuid().v4()}';
      final int at = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
      await into(tags).insert(
        TagsCompanion.insert(
          id: tagId,
          name: name,
          createdAt: at,
          updatedAt: at,
          syncDirty: const Value<bool?>(true),
        ),
      );
      return tagId;
    });
  }

  /// Renames a tag everywhere it is used. Refuses a name another tag holds.
  Future<void> renameTag(String id, String rawName, {DateTime? now}) async {
    final String name = normalizeTagName(rawName);
    await transaction(() async {
      if (await _tagByName(name, exceptId: id) != null) {
        throw TagNameException('A tag named “$name” already exists');
      }
      final int count = await (update(tags)..where((t) => t.id.equals(id)))
          .write(
            TagsCompanion(
              name: Value<String>(name),
              updatedAt: Value(
                (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
              ),
              syncDirty: const Value<bool?>(true),
            ),
          );
      if (count != 1) throw StateError('Tag not found: $id');
    });
  }

  /// Deletes a tag and removes it from EVERY notebook and recording.
  ///
  /// One tombstone carries the whole cascade: the server tombstones the
  /// tag's assignments and every peer applying the tag deletion drops its
  /// own (see [applyRemoteTagDeletion]), so no per-assignment delete needs
  /// to travel. The targets themselves are never touched.
  Future<void> deleteTag(String id) async {
    await transaction(() async {
      await (delete(tagAssignments)..where((t) => t.tagId.equals(id))).go();
      final int count = await (delete(
        tags,
      )..where((t) => t.id.equals(id))).go();
      if (count == 0) return;
      await recordTombstone(entityType: 'tag', entityId: id);
    });
  }

  /// Puts [tagId] on one notebook or recording. Idempotent.
  Future<void> assignTag({
    required String tagId,
    required String targetType,
    required String targetId,
    DateTime? now,
  }) async {
    _checkTagTarget(targetType);
    final String id = tagAssignmentId(tagId, targetType, targetId);
    await transaction(() async {
      final TagRow? tag = await (select(
        tags,
      )..where((t) => t.id.equals(tagId))).getSingleOrNull();
      if (tag == null) throw StateError('Tag not found: $tagId');
      await into(tagAssignments).insert(
        TagAssignmentsCompanion.insert(
          id: id,
          tagId: tagId,
          targetType: targetType,
          targetId: targetId,
          createdAt: (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
          syncDirty: const Value<bool?>(true),
        ),
        mode: InsertMode.insertOrIgnore,
      );
      // Re-adding a tag removed earlier in the same offline stretch: the
      // undelivered removal must not push after (and undo) the re-add.
      await clearTombstone(entityType: 'tag_assignment', entityId: id);
    });
  }

  /// Takes [tagId] off one notebook or recording. A no-op when absent.
  Future<void> unassignTag({
    required String tagId,
    required String targetType,
    required String targetId,
  }) async {
    _checkTagTarget(targetType);
    final String id = tagAssignmentId(tagId, targetType, targetId);
    await transaction(() async {
      final int count = await (delete(
        tagAssignments,
      )..where((t) => t.id.equals(id))).go();
      if (count > 0) {
        await recordTombstone(entityType: 'tag_assignment', entityId: id);
      }
    });
  }

  // ---- tag sync ----------------------------------------------------------

  /// Tags with local changes the server has not confirmed (null = dirty).
  Future<List<TagRow>> tagsNeedingPush() => (select(
    tags,
  )..where((t) => t.syncDirty.equals(true) | t.syncDirty.isNull())).get();

  /// Marks a pushed tag clean — only if it was not renamed again while the
  /// push was in flight (same guard as notebooks).
  Future<void> markTagSynced(
    String id, {
    required int seq,
    required int pushedUpdatedAt,
  }) async {
    await (update(tags)
          ..where((t) => t.id.equals(id) & t.updatedAt.equals(pushedUpdatedAt)))
        .write(
          TagsCompanion(
            syncDirty: const Value<bool?>(false),
            syncedSeq: Value<int?>(seq),
          ),
        );
  }

  /// Dirty assignments whose tag still exists here. An assignment orphaned
  /// by a tag deletion is never pushed; the tag tombstone covers it.
  Future<List<TagAssignmentRow>> tagAssignmentsNeedingPush() {
    final query =
        select(tagAssignments).join(<Join<HasResultSet, dynamic>>[
          innerJoin(tags, tags.id.equalsExp(tagAssignments.tagId)),
        ])..where(
          tagAssignments.syncDirty.equals(true) |
              tagAssignments.syncDirty.isNull(),
        );
    return query.map((TypedResult row) => row.readTable(tagAssignments)).get();
  }

  Future<void> markTagAssignmentSynced(String id, {required int seq}) async {
    await (update(tagAssignments)..where((t) => t.id.equals(id))).write(
      TagAssignmentsCompanion(
        syncDirty: const Value<bool?>(false),
        syncedSeq: Value<int?>(seq),
      ),
    );
  }

  Future<bool> _hasPendingTombstone(String entityType, String entityId) async =>
      (await (select(syncTombstones)..where(
            (t) =>
                t.entityType.equals(entityType) & t.entityId.equals(entityId),
          ))
          .getSingleOrNull()) !=
      null;

  /// Applies a tag the server sent. Clean, never dirty (no echo). A local
  /// unpushed rename wins and pushes next; a local unpushed DELETE wins too —
  /// resurrecting the tag here would undo what the user just did.
  Future<void> applyRemoteTag({
    required String id,
    required String name,
    required int createdAt,
    required int updatedAt,
    required int seq,
  }) async {
    await transaction(() async {
      if (await _hasPendingTombstone('tag', id)) return;
      final TagRow? local = await (select(
        tags,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (local != null && local.syncDirty != false) return;
      await into(tags).insert(
        TagsCompanion.insert(
          id: id,
          name: name,
          createdAt: createdAt,
          updatedAt: updatedAt,
          syncDirty: const Value<bool?>(false),
          syncedSeq: Value<int?>(seq),
        ),
        mode: InsertMode.insertOrReplace,
      );
    });
  }

  /// A peer deleted a tag: drop it and every assignment of it, dirty or not.
  /// No tombstone — the deletion is already in the server's log.
  Future<void> applyRemoteTagDeletion(String id) async {
    await transaction(() async {
      await (delete(tagAssignments)..where((t) => t.tagId.equals(id))).go();
      await (delete(tags)..where((t) => t.id.equals(id))).go();
    });
  }

  /// Applies an assignment the server sent. A pending local removal of the
  /// same assignment wins (it pushes next). A tag ABSENT here means the
  /// assignment is already dead: the feed is seq-ordered, so its tag upsert
  /// always lands first unless this device deleted the tag — and once that
  /// deletion has pushed, no tombstone is left to say so, and the server's
  /// delete is this device's own (never echoed) to clean up after an orphan.
  Future<void> applyRemoteTagAssignment({
    required String id,
    required String tagId,
    required String targetType,
    required String targetId,
    required int createdAt,
    required int seq,
  }) async {
    if (!tagTargetTypes.contains(targetType)) return;
    await transaction(() async {
      if (await _hasPendingTombstone('tag_assignment', id)) return;
      final TagRow? tag = await (select(
        tags,
      )..where((t) => t.id.equals(tagId))).getSingleOrNull();
      if (tag == null) return;
      await into(tagAssignments).insert(
        TagAssignmentsCompanion.insert(
          id: id,
          tagId: tagId,
          targetType: targetType,
          targetId: targetId,
          createdAt: createdAt,
          syncDirty: const Value<bool?>(false),
          syncedSeq: Value<int?>(seq),
        ),
        mode: InsertMode.insertOrReplace,
      );
    });
  }

  /// A peer removed an assignment. A local unpushed re-add wins.
  Future<void> applyRemoteTagAssignmentDeletion(String id) async {
    await (delete(
      tagAssignments,
    )..where((t) => t.id.equals(id) & (t.syncDirty.equals(false)))).go();
  }

  // ---- notebook trash ----------------------------------------------------

  /// How long a trashed notebook survives before [purgeExpiredTrash] drops it.
  static const Duration trashRetention = Duration(days: 7);

  /// Moves a notebook to the trash instead of deleting it.
  ///
  /// The row keeps everything — content, filing, sync state — so a restore
  /// is a single column write. Trashed rows are invisible to the live list
  /// and to push (a trashed notebook's tombstone travels instead).
  Future<void> trashNotebook(String id) async {
    await (update(notebooks)..where((t) => t.id.equals(id))).write(
      NotebooksCompanion(
        deletedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// Brings a trashed notebook back, dirty so the restore pushes: the other
  /// devices deleted it when the tombstone arrived, and only a push tells
  /// them it lives again.
  Future<void> restoreNotebook(String id) async {
    await transaction(() async {
      await (update(notebooks)..where((t) => t.id.equals(id))).write(
        const NotebooksCompanion(
          deletedAt: Value<int?>(null),
          syncDirty: Value(true),
        ),
      );
      // A restore must also cancel any still-undelivered tombstone, or the
      // next sync would push the deletion straight after the resurrection.
      await clearTombstone(entityType: 'notebook', entityId: id);
    });
  }

  /// Everything currently in the trash, newest deletion first.
  Future<List<NotebookRow>> trashedNotebooks() =>
      (select(notebooks)
            ..where((t) => t.deletedAt.isNotNull())
            ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]))
          .get();

  /// Drops every trashed notebook older than [trashRetention]. Returns how
  /// many were purged. Called at startup; the Settings screen states the
  /// 7-day window so the emptying is a promise, not a surprise.
  Future<int> purgeExpiredTrash({DateTime? now}) async {
    final int cutoff = (now ?? DateTime.now())
        .subtract(trashRetention)
        .millisecondsSinceEpoch;
    return (delete(notebooks)..where(
          (t) =>
              t.deletedAt.isNotNull() &
              t.deletedAt.isSmallerOrEqualValue(cutoff),
        ))
        .go();
  }

  Future<void> _createStorageCatalog(Migrator m) async {
    await m.createTable(storageLocations);
    await m.createTable(storageCatalogStates);
    await m.createTable(recordingBindings);
    await m.createTable(captureReservations);
    await m.createTable(localDeletionBatches);
    await m.createTable(localDeletionTickets);
    await initializeStorageCatalogRows();
  }

  Future<void> initializeStorageCatalogRows() async {
    await customStatement(
      'INSERT OR IGNORE INTO storage_catalog_state(id) VALUES(1)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS capture_state_idx ON capture_reservations(state)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS deletion_state_idx ON local_deletion_tickets(state)',
    );
  }

  Future<void> _createFtsInfrastructure() async {
    await customStatement(
      '''CREATE VIRTUAL TABLE IF NOT EXISTS dumps_fts USING fts5(
        title, transcript, content="dumps", content_rowid="rowid"
      )''',
    );
    await _createFtsTriggers();
  }

  Future<void> _replaceFtsTriggers() async {
    await customStatement('DROP TRIGGER IF EXISTS dumps_ai');
    await customStatement('DROP TRIGGER IF EXISTS dumps_ad');
    await customStatement('DROP TRIGGER IF EXISTS dumps_au');
    await _createFtsTriggers();
  }

  Future<void> _createFtsTriggers() async {
    await customStatement('''CREATE TRIGGER dumps_ai AFTER INSERT ON dumps BEGIN
        INSERT INTO dumps_fts(rowid, title, transcript)
        VALUES (new.rowid, new.title, new.transcript);
      END''');
    await customStatement('''CREATE TRIGGER dumps_ad AFTER DELETE ON dumps BEGIN
        INSERT INTO dumps_fts("dumps_fts", rowid, title, transcript)
        VALUES ('delete', old.rowid, old.title, old.transcript);
      END''');
    await customStatement('''CREATE TRIGGER dumps_au AFTER UPDATE ON dumps BEGIN
        INSERT INTO dumps_fts("dumps_fts", rowid, title, transcript)
        VALUES ('delete', old.rowid, old.title, old.transcript);
        INSERT INTO dumps_fts(rowid, title, transcript)
        VALUES (new.rowid, new.title, new.transcript);
      END''');
  }

  /// Atomic catalog commit boundary, also used to reconcile uncertain acknowledgements.
  Future<T> commitStorageCatalog<T>(Future<T> Function() action) =>
      transaction(action);

  /// Compare-and-install only. Callers must reread SQLite even after an uncertain
  /// acknowledgement; the candidate in memory is never durable authority.
  Future<void> freezeLegacyAnchor(String anchorJson) => transaction(() async {
    await (update(storageCatalogStates)..where(
          (s) =>
              s.id.equals(1) &
              s.legacyAnchorJson.isNull() &
              s.bootstrapVersion.equals(0),
        ))
        .write(
          StorageCatalogStatesCompanion(legacyAnchorJson: Value(anchorJson)),
        );
  });

  /// Spend a storage location's one-shot legacy-restore authorization.
  ///
  /// Legacy restore adopts files that pre-date this build's catalog. It is a
  /// migration, not a steady state: once a location's adoption sweep has
  /// completed with nothing left unsettled, the flag must come down or the
  /// sweep re-enumerates the user's folder on every single launch forever.
  /// Callers must only reach here after a fully settled sweep — a partial
  /// success has to stay authorized so the next launch retries.
  Future<void> completeLegacyRestore(String locationId) => transaction(
    () async {
      await (update(storageLocations)..where((l) => l.id.equals(locationId)))
          .write(const StorageLocationsCompanion(legacyRestore: Value(false)));
    },
  );

  /// Resolve only persisted original ownership, never a current default.
  @override
  Future<BoundRecording?> boundRecording(String id) => transaction(() async {
    final row = await (select(
      recordingBindings,
    )..where((b) => b.dumpId.equals(id))).getSingleOrNull();
    if (row == null || !row.resolved || row.locationId == null) return null;
    final location = await (select(
      storageLocations,
    )..where((l) => l.id.equals(row.locationId!))).getSingleOrNull();
    if (location == null) return null;
    final binding = (
      key: (dumpId: row.dumpId, incarnation: row.incarnation),
      location: (
        id: location.id,
        label: location.label,
        directory: StorageCodec.decodeDirectory(location.directoryJson),
      ),
      audio: StorageCodec.decodeAudio(row.audioJson),
      metadataName: row.metadataName,
    );
    StorageCodec.encodeBinding(binding);
    return binding;
  });

  Never _storageFault(ProblemCode code, String message) =>
      throw StorageFault((code: code, message: message));
  Future<LocalDeletionTicketRow?> _deletionFence(String id) => (select(
    localDeletionTickets,
  )..where((t) => t.dumpId.equals(id))).getSingleOrNull();

  /// One-time heal for receipts orphaned by the resurrection bug.
  ///
  /// A COMPLETED deletion receipt is retirement history for an identity
  /// that no longer exists locally. If a dump row with that id EXISTS, the
  /// server resurrected the recording after the local deletion — before the
  /// apply-site learned to clear the receipt, that left a zombie: a listed,
  /// playable-looking row every download refuses with 'Recording identity
  /// is fenced'. Deleting the stale receipt returns ownership to the live
  /// row. Pending (non-completed) tickets are live work and are never
  /// touched. Idempotent by construction; returns the number healed.
  Future<int> repairResurrectedRetirements() => transaction(() async {
    final stale = await customSelect(
      'SELECT t.dump_id AS dump_id FROM local_deletion_tickets t '
      "WHERE t.state = 'completed' "
      'AND EXISTS (SELECT 1 FROM dumps d WHERE d.id = t.dump_id)',
      readsFrom: {localDeletionTickets, dumps},
    ).get();
    for (final row in stale) {
      await (delete(localDeletionTickets)..where(
            (t) =>
                t.dumpId.equals(row.data['dump_id'] as String) &
                t.state.equals('completed'),
          ))
          .go();
    }
    return stale.length;
  });
  @override
  Future<bool> isRetired(String id) async =>
      (await _deletionFence(id))?.state == 'completed';
  @override
  Future<bool> mutationAllowed(RecordingKey key) => transaction(() async {
    StorageCodec.encodeKey(key);
    if (await _deletionFence(key.dumpId) != null) return false;
    return await getDump(key.dumpId) != null &&
        (await boundRecording(key.dumpId))?.key == key;
  });
  @override
  Future<void> bindRecording(BoundRecording binding) => transaction(() async {
    StorageCodec.encodeBinding(binding);
    final id = binding.key.dumpId;
    final fence = await _deletionFence(id);
    if (fence != null) {
      _storageFault(
        fence.state == 'completed' ? ProblemCode.retired : ProblemCode.fenced,
        'Recording identity is fenced',
      );
    }
    final row = await getDump(id);
    if (row == null || row.audioPath != binding.audio.value) {
      _storageFault(ProblemCode.conflict, 'Original audio identity differs');
    }
    final location = await (select(
      storageLocations,
    )..where((l) => l.id.equals(binding.location.id))).getSingleOrNull();
    if (location == null ||
        location.directoryJson !=
            StorageCodec.encodeDirectory(binding.location.directory) ||
        location.label != binding.location.label) {
      _storageFault(
        ProblemCode.conflict,
        'Location is not the persisted capability',
      );
    }
    final prior = await (select(
      recordingBindings,
    )..where((b) => b.dumpId.equals(id))).getSingleOrNull();
    if (prior != null) {
      if (prior.incarnation != binding.key.incarnation ||
          StorageCodec.decodeAudio(prior.audioJson) != binding.audio ||
          prior.metadataName != binding.metadataName ||
          (prior.resolved && await boundRecording(id) != binding)) {
        _storageFault(ProblemCode.conflict, 'Binding is immutable');
      }
      if (prior.resolved) return;
      await (update(
        recordingBindings,
      )..where((b) => b.dumpId.equals(id))).write(
        RecordingBindingsCompanion(
          locationId: Value(binding.location.id),
          resolved: const Value(true),
        ),
      );
    } else {
      await into(recordingBindings).insert(
        RecordingBindingsCompanion.insert(
          dumpId: id,
          incarnation: binding.key.incarnation,
          locationId: Value(binding.location.id),
          audioJson: StorageCodec.encodeAudio(binding.audio),
          metadataName: binding.metadataName,
          resolved: const Value(true),
        ),
      );
    }
  });
  DeletionTicket _decodeTicket(LocalDeletionTicketRow row) {
    final problems = row.problemJson == null
        ? <String, dynamic>{}
        : jsonDecode(row.problemJson!) as Map<String, dynamic>;
    ComponentResult component(String name, String state) {
      final raw = problems[name] as Map<String, dynamic>?;
      return (
        state: ComponentState.values.byName(state),
        problem: raw == null
            ? null
            : (
                code: ProblemCode.values.byName(raw['code'] as String),
                message: raw['message'] as String,
              ),
      );
    }

    final binding = StorageCodec.decodeBinding(row.bindingJson);
    if (binding.key != (dumpId: row.dumpId, incarnation: row.incarnation)) {
      _storageFault(ProblemCode.invalid, 'Ticket identity mismatch');
    }
    return (
      id: row.ticketId,
      operationId: row.operationId,
      binding: binding,
      audio: component('audio', row.audioState),
      metadata: component('metadata', row.metadataState),
      state: TicketState.values.byName(row.state),
    );
  }

  /// Task5 final row/binding/journal transaction; allows acknowledgment-loss tests.
  Future<T> commitOwnedCapture<T>(Future<T> Function() action) =>
      transaction(action);

  /// Every retained capture journal owns staging cleanup, even after row commit.
  Future<bool> hasCaptureJournal(String id) async =>
      await (select(
        captureReservations,
      )..where((r) => r.dumpId.equals(id))).getSingleOrNull() !=
      null;

  @override
  Future<Outcome<DeletionTicket>> claimLocalDeletion(
    String operationId,
    DeleteTarget target,
  ) => transaction(() async {
    StorageCodec.validateLiteralId(operationId);
    final binding = target.binding;
    if (binding == null) {
      return const Fail((
        code: ProblemCode.unresolved,
        message: 'No confirmed binding',
      ));
    }
    final encoded = StorageCodec.encodeBinding(binding);
    if (target.id != binding.key.dumpId) {
      return const Fail((
        code: ProblemCode.invalid,
        message: 'Target identity differs',
      ));
    }
    final prior = await _deletionFence(target.id);
    if (prior != null) {
      if (prior.bindingJson != encoded ||
          (prior.operationId != operationId &&
              (target.retryTicketId != prior.ticketId ||
                  prior.state == 'completed'))) {
        return const Fail((
          code: ProblemCode.conflict,
          message: 'Different deletion already owns this identity',
        ));
      }
      if (prior.state == 'completed') return Ok(_decodeTicket(prior));
    }
    if (prior == null && target.retryTicketId != null) {
      return const Fail((
        code: ProblemCode.conflict,
        message: 'Retry ticket missing',
      ));
    }
    if (await hasCaptureJournal(target.id)) {
      return const Fail((
        code: ProblemCode.busy,
        message: 'Owned staging cleanup is pending',
      ));
    }
    final row = await getDump(target.id);
    if (row == null) {
      return const Fail((
        code: ProblemCode.absent,
        message: 'Recording missing',
      ));
    }
    if (await boundRecording(target.id) != binding) {
      return const Fail((
        code: ProblemCode.wrongIncarnation,
        message: 'Confirmed binding changed',
      ));
    }
    if (![
          'not_transcribed',
          'completed',
          'failed',
          'not_applicable',
        ].contains(row.transcriptionStatus) ||
        row.syncStatus == 'syncing' ||
        (row.transcriptionError?.startsWith('sidecar_sync_pending:') ??
            false)) {
      return const Fail((
        code: ProblemCode.busy,
        message: 'Recording has durable pending work',
      ));
    }
    if (prior != null) return Ok(_decodeTicket(prior));
    final id = const Uuid().v4();
    await into(localDeletionTickets).insert(
      LocalDeletionTicketsCompanion.insert(
        dumpId: target.id,
        incarnation: binding.key.incarnation,
        ticketId: id,
        operationId: operationId,
        bindingJson: encoded,
        audioState: 'pending',
        metadataState: 'pending',
        state: 'pending',
      ),
    );
    return Ok(_decodeTicket((await _deletionFence(target.id))!));
  });
  Future<LocalDeletionTicketRow> _ticketById(String id) async {
    final row = await (select(
      localDeletionTickets,
    )..where((t) => t.ticketId.equals(id))).getSingleOrNull();
    if (row == null) {
      _storageFault(ProblemCode.invalid, 'Deletion ticket missing');
    }
    return row;
  }

  bool _gone(String state) => state == 'removed' || state == 'absent';
  @override
  Future<void> recordDeletionComponent(
    String ticketId,
    RecordingComponent component,
    ComponentResult result,
  ) => transaction(() async {
    final row = await _ticketById(ticketId);
    if (row.state == 'completed') return;
    final previous = component == RecordingComponent.audio
        ? row.audioState
        : row.metadataState;
    if (_gone(previous)) return;
    final problems = row.problemJson == null
        ? <String, dynamic>{}
        : jsonDecode(row.problemJson!) as Map<String, dynamic>;
    if (result.problem == null) {
      problems.remove(component.name);
    } else {
      problems[component.name] = {
        'code': result.problem!.code.name,
        'message': result.problem!.message,
      };
    }
    final audio = component == RecordingComponent.audio
        ? result.state.name
        : row.audioState;
    final metadata = component == RecordingComponent.metadata
        ? result.state.name
        : row.metadataState;
    await (update(
      localDeletionTickets,
    )..where((t) => t.ticketId.equals(ticketId))).write(
      LocalDeletionTicketsCompanion(
        audioState: Value(audio),
        metadataState: Value(metadata),
        state: Value(
          [audio, metadata].any((s) => s == 'failed' || s == 'unknown')
              ? 'failed'
              : 'pending',
        ),
        problemJson: Value(problems.isEmpty ? null : jsonEncode(problems)),
      ),
    );
  });
  @override
  Future<void> finishLocalDeletion(String ticketId) => transaction(() async {
    final ticket = await _ticketById(ticketId);
    if (ticket.state == 'completed') return;
    if (!_gone(ticket.audioState) || !_gone(ticket.metadataState)) {
      _storageFault(ProblemCode.busy, 'Both components must be proven gone');
    }
    if (await hasCaptureJournal(ticket.dumpId)) {
      _storageFault(ProblemCode.busy, 'Owned staging cleanup is pending');
    }
    final binding = StorageCodec.decodeBinding(ticket.bindingJson);
    if (await boundRecording(ticket.dumpId) != binding) {
      _storageFault(
        ProblemCode.wrongIncarnation,
        'Ticket no longer owns binding',
      );
    }
    await (delete(
      syncQueue,
    )..where((q) => q.dumpId.equals(ticket.dumpId))).go();
    await (delete(recordingBindings)..where(
          (b) =>
              b.dumpId.equals(ticket.dumpId) &
              b.incarnation.equals(ticket.incarnation),
        ))
        .go();
    await (delete(dumps)..where((d) => d.id.equals(ticket.dumpId))).go();
    await (update(
      localDeletionTickets,
    )..where((t) => t.ticketId.equals(ticketId))).write(
      const LocalDeletionTicketsCompanion(
        state: Value('completed'),
        problemJson: Value(null),
      ),
    );
  });

  /// Read immutable deletion ownership, including completed replay receipts.
  Future<DeletionTicket?> deletionTicketById(String ticketId) async {
    final row = await (select(
      localDeletionTickets,
    )..where((t) => t.ticketId.equals(ticketId))).getSingleOrNull();
    return row == null ? null : _decodeTicket(row);
  }

  @override
  Future<List<DeletionTicket>> pendingLocalDeletions() async =>
      (await (select(
            localDeletionTickets,
          )..where((t) => t.state.isNotValue('completed'))).get())
          .map(_decodeTicket)
          .toList();

  /// Check storage identity inside the same transaction as each legacy CAS.
  Future<void> _requireMutationKey(String id, RecordingKey storageKey) async {
    StorageCodec.encodeKey(storageKey);
    if (id != storageKey.dumpId) {
      _storageFault(
        ProblemCode.wrongIncarnation,
        'Mutation ID differs from captured key',
      );
    }
    final fence = await _deletionFence(id);
    if (fence != null) {
      _storageFault(
        fence.state == 'completed' ? ProblemCode.retired : ProblemCode.fenced,
        'Recording identity is fenced',
      );
    }
    if ((await boundRecording(id))?.key != storageKey ||
        await getDump(id) == null) {
      _storageFault(
        ProblemCode.wrongIncarnation,
        'Captured recording identity is no longer current',
      );
    }
  }

  /// Fetch dumps, newest first, with pagination.
  Future<List<DumpRow>> listDumps({int limit = 50, int offset = 0}) {
    return (select(dumps)
          ..orderBy([(d) => OrderingTerm.desc(d.createdAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  /// Reactive stream of all dumps, newest first.
  /// Emits whenever any row in [dumps] changes.
  Stream<List<DumpRow>> watchAllDumps() {
    return (select(
      dumps,
    )..orderBy([(d) => OrderingTerm.desc(d.createdAt)])).watch();
  }

  /// Reactive stream for one dump without retaining or rescanning the table.
  Stream<DumpRow?> watchDump(String id) =>
      (select(dumps)..where((d) => d.id.equals(id))).watchSingleOrNull();

  /// Live ranked candidates. Presentation applies filters after this cap.
  @override
  Stream<List<DumpRow>> watchSearchDumps(String query, {int limit = 100}) {
    final escaped = query.replaceAll('"', '""');
    return customSelect(
      'SELECT d.* FROM dumps d '
      'JOIN dumps_fts f ON d.rowid = f.rowid '
      'WHERE dumps_fts MATCH ? '
      'ORDER BY rank LIMIT ?',
      variables: [Variable.withString('"$escaped"'), Variable.withInt(limit)],
      readsFrom: {dumps},
    ).map((row) => dumps.map(row.data)).watch();
  }

  /// Match evidence for the same candidates [watchSearchDumps] ranks
  /// (spec §2 A1): the FTS5 snippet with `<b>` markers, the per-row
  /// occurrence count on the TRANSCRIPT (counted in Dart — FTS5 has no
  /// per-row occurrence function), and whether the title matched. Keyed
  /// by dump id so presentation can join it to whichever row list it
  /// already holds. Empty for a blank query.
  @override
  Stream<Map<String, DumpSearchMatch>> watchSearchDumpMatches(
    String query, {
    int limit = 100,
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Stream.value(const {});
    final escaped = trimmed.replaceAll('"', '""');
    return customSelect(
      'SELECT d.id AS id, d.transcript AS transcript, '
      "snippet(dumps_fts, 0, '<b>', '</b>', '…', 12) AS title_snippet, "
      "snippet(dumps_fts, 1, '<b>', '</b>', '…', 12) AS body_snippet "
      'FROM dumps d '
      'JOIN dumps_fts f ON d.rowid = f.rowid '
      'WHERE dumps_fts MATCH ? '
      'ORDER BY rank LIMIT ?',
      variables: [Variable.withString('"$escaped"'), Variable.withInt(limit)],
      readsFrom: {dumps},
    ).watch().map((rows) {
      final out = <String, DumpSearchMatch>{};
      for (final row in rows) {
        final titleSnippet = row.read<String>('title_snippet');
        final bodySnippet = row.read<String>('body_snippet');
        final titleMatched = titleSnippet.contains('<b>');
        out[row.read<String>('id')] = DumpSearchMatch(
          snippet: titleMatched ? titleSnippet : bodySnippet,
          matchCount: countTranscriptMatches(
            row.readNullable<String>('transcript') ?? '',
            trimmed,
          ),
          titleMatched: titleMatched,
        );
      }
      return out;
    });
  }

  /// The source for the Name-speakers sheet's tap-to-fill chips (speaker
  /// name map spec §4): the names in `speaker_names` across recordings,
  /// newest `updated_at` first, flattened in map order, de-duplicated,
  /// minus [exclude] (the open recording's own current names), at most
  /// [limit]. Read-only.
  @override
  Future<List<String>> recentSpeakerNamesForSuggestions({
    int limit = 8,
    Iterable<String> exclude = const <String>[],
  }) async {
    final rows = await customSelect(
      'SELECT speaker_names FROM dumps '
      'WHERE speaker_names IS NOT NULL '
      'ORDER BY updated_at DESC LIMIT 50',
      readsFrom: {dumps},
    ).get();
    final Set<String> skip = exclude.toSet();
    final List<String> out = <String>[];
    for (final row in rows) {
      final SpeakerNames names = SpeakerNames.decode(
        row.read<String?>('speaker_names'),
      );
      for (final String name in names.names) {
        if (skip.contains(name) || out.contains(name)) continue;
        out.add(name);
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  /// Search across title and transcript using FTS5.
  Future<List<DumpRow>> searchDumps(String query, {int limit = 50}) {
    final escaped = query.replaceAll('"', '""');
    return customSelect(
      'SELECT d.* FROM dumps d '
      'JOIN dumps_fts f ON d.rowid = f.rowid '
      'WHERE dumps_fts MATCH ? '
      'ORDER BY rank LIMIT ?',
      variables: [Variable.withString('"$escaped"'), Variable.withInt(limit)],
      readsFrom: {dumps},
    ).map((row) => dumps.map(row.data)).get();
  }

  /// Find a dump by id.
  Future<DumpRow?> getDump(String id) =>
      (select(dumps)..where((d) => d.id.equals(id))).getSingleOrNull();

  /// Updates only the editable title columns, preserving transcription state.
  Future<DumpRow> updateDumpTitle(
    String id, {
    required RecordingKey storageKey,
    required String title,
    required DateTime now,
  }) {
    return transaction(() async {
      await _requireMutationKey(id, storageKey);
      final count = await (update(dumps)..where((d) => d.id.equals(id))).write(
        DumpsCompanion(title: Value(title), updatedAt: Value(now.toUtc())),
      );
      if (count != 1) throw StateError('Dump not found: $id');
      // Metadata edits sync. Without this the engine has no dirty rows and
      // pushes nothing while every one of its tests passes.
      await markDumpDirty(id);
      return (await getDump(id))!;
    });
  }

  /// Updates meeting notes only when they were derived from the current
  /// title and durable transcript revision, preserving every transcription
  /// ownership column.
  Future<DumpRow> updateDumpMeetingNotes(
    String id, {
    required RecordingKey storageKey,
    required String expectedTitle,
    required String expectedTranscript,
    required int expectedTranscriptionAttempt,
    required String? expectedTranscriptionRequestId,
    required String meetingNotes,
    required DateTime now,
  }) {
    return transaction(() async {
      await _requireMutationKey(id, storageKey);
      final count =
          await (update(dumps)..where((d) {
                final requestIdMatches = expectedTranscriptionRequestId == null
                    ? d.transcriptionRequestId.isNull()
                    : d.transcriptionRequestId.equals(
                        expectedTranscriptionRequestId,
                      );
                return d.id.equals(id) &
                    d.title.equals(expectedTitle) &
                    d.transcript.equals(expectedTranscript) &
                    d.transcriptionAttempt.equals(
                      expectedTranscriptionAttempt,
                    ) &
                    requestIdMatches;
              }))
              .write(
                DumpsCompanion(
                  meetingNotes: Value(meetingNotes),
                  updatedAt: Value(now.toUtc()),
                ),
              );
      if (count != 1) {
        throw StateError(
          'Dump title or transcript revision changed while editing notes: $id',
        );
      }
      await markDumpDirty(id);
      return (await getDump(id))!;
    });
  }

  /// Saves a manual transcript edit only against the exact completed
  /// transcription revision the editor opened. A newer attempt or result wins.
  Future<DumpRow> updateDumpTranscript(
    String id, {
    required RecordingKey storageKey,
    required String expectedTranscript,
    required int expectedTranscriptionAttempt,
    required String? expectedTranscriptionRequestId,
    required String transcript,
    required DateTime now,
  }) {
    if (transcript.trim().isEmpty) {
      throw ArgumentError.value(transcript, 'transcript', 'must not be blank');
    }
    return transaction(() async {
      await _requireMutationKey(id, storageKey);
      final current = await getDump(id);
      final priorError = errorAfterSidecarSync(current?.transcriptionError);
      final count =
          await (update(dumps)..where((d) {
                final requestIdMatches = expectedTranscriptionRequestId == null
                    ? d.transcriptionRequestId.isNull()
                    : d.transcriptionRequestId.equals(
                        expectedTranscriptionRequestId,
                      );
                return d.id.equals(id) &
                    d.transcriptionStatus.isIn([
                      TranscriptionStatus.completed.wireValue,
                      TranscriptionStatus.failed.wireValue,
                      // Text notes never transcribe; their body edits go
                      // through the same guarded manual-edit path.
                      TranscriptionStatus.notApplicable.wireValue,
                    ]) &
                    d.transcript.equals(expectedTranscript) &
                    d.transcriptionAttempt.equals(
                      expectedTranscriptionAttempt,
                    ) &
                    requestIdMatches;
              }))
              .write(
                DumpsCompanion(
                  transcript: Value(transcript),
                  transcriptionError: Value(
                    'sidecar_sync_pending: manual_edit:${jsonEncode({'error': priorError, 'revision': const Uuid().v4()})}',
                  ),
                  updatedAt: Value(now.toUtc()),
                ),
              );
      if (count != 1) {
        throw StateError('Transcript revision changed while editing: $id');
      }
      await markDumpDirty(id);
      return (await getDump(id))!;
    });
  }

  /// Manual-edit markers retain a failed attempt's original diagnostic.
  static String? errorAfterSidecarSync(String? error) {
    const prefix = 'sidecar_sync_pending: manual_edit:';
    if (error?.startsWith(prefix) ?? false) {
      final payload = jsonDecode(error!.substring(prefix.length));
      return payload is Map ? payload['error'] as String? : payload as String?;
    }
    return (error?.startsWith('sidecar_sync_pending:') ?? false) ? null : error;
  }

  /// Starts a new durable transcription attempt before any network I/O.
  Future<DumpRow> beginTranscriptionAttempt(
    String id, {
    required RecordingKey storageKey,
    required String requestId,
    required DateTime now,
  }) {
    return transaction(() async {
      await _requireMutationKey(id, storageKey);
      final current = await getDump(id);
      if (current == null) throw StateError('Dump not found: $id');
      final currentStatus = TranscriptionStatus.fromWire(
        current.transcriptionStatus,
      );
      if (currentStatus == TranscriptionStatus.notApplicable) {
        throw StateError('Transcription is not applicable: $id');
      }
      final sidecarPending =
          currentStatus.isTerminal &&
          (current.transcriptionError?.startsWith('sidecar_sync_pending:') ??
              false);
      if (currentStatus.isInProgress || sidecarPending) {
        throw StateError('Transcription already in progress: $id');
      }
      final timestamp = now.toUtc();
      final nextAttempt = current.transcriptionAttempt + 1;
      await (update(dumps)..where((d) => d.id.equals(id))).write(
        DumpsCompanion(
          updatedAt: Value(timestamp),
          transcriptionStatus: Value(TranscriptionStatus.uploading.wireValue),
          transcriptionRequestId: Value(requestId),
          transcriptionJobId: const Value(null),
          transcriptionAttempt: Value(nextAttempt),
          transcriptionStartedAt: Value(timestamp),
          transcriptionUpdatedAt: Value(timestamp),
          transcriptionCompletedAt: const Value(null),
          transcriptionError: const Value(null),
        ),
      );
      return (await getDump(id))!;
    });
  }

  /// Updates an attempt only if it is still the latest attempt for the dump.
  Future<bool> updateTranscriptionStatus(
    String id, {
    required RecordingKey storageKey,
    required int attempt,
    required String requestId,
    required TranscriptionStatus status,
    required DateTime now,
    String? jobId,
    String? error,
  }) => transaction(() async {
    await _requireMutationKey(id, storageKey);
    final timestamp = now.toUtc();
    final allowedSourceStatuses = switch (status) {
      TranscriptionStatus.notTranscribed ||
      TranscriptionStatus.notApplicable => const <String>['__never__'],
      TranscriptionStatus.uploading => <String>[
        TranscriptionStatus.uploading.wireValue,
      ],
      TranscriptionStatus.queued => <String>[
        TranscriptionStatus.uploading.wireValue,
        TranscriptionStatus.queued.wireValue,
      ],
      TranscriptionStatus.running => <String>[
        TranscriptionStatus.uploading.wireValue,
        TranscriptionStatus.queued.wireValue,
        TranscriptionStatus.running.wireValue,
      ],
      TranscriptionStatus.completed || TranscriptionStatus.failed => <String>[
        TranscriptionStatus.uploading.wireValue,
        TranscriptionStatus.queued.wireValue,
        TranscriptionStatus.running.wireValue,
      ],
    };
    final count =
        await (update(dumps)..where(
              (d) =>
                  d.id.equals(id) &
                  d.transcriptionAttempt.equals(attempt) &
                  d.transcriptionRequestId.equals(requestId) &
                  d.transcriptionStatus.isIn(allowedSourceStatuses),
            ))
            .write(
              DumpsCompanion(
                updatedAt: Value(timestamp),
                transcriptionStatus: Value(status.wireValue),
                transcriptionJobId: jobId == null
                    ? const Value.absent()
                    : Value(jobId),
                transcriptionUpdatedAt: Value(timestamp),
                transcriptionCompletedAt: status.isTerminal
                    ? Value(timestamp)
                    : const Value.absent(),
                transcriptionError: Value(error),
              ),
            );
    return count == 1;
  });

  /// Commits transcript output only for the current attempt.
  Future<bool> completeTranscriptionAttempt(
    String id, {
    required RecordingKey storageKey,
    required int attempt,
    required String requestId,
    required String transcript,
    String? meetingNotes,
    required DateTime now,
    String? sidecarError,
  }) => transaction(() async {
    // Read and mutate under the same SQLite transaction. A replacement must
    // never write a snapshot of notes over an explicit regeneration.
    await _requireMutationKey(id, storageKey);
    final current = await getDump(id);
    final preserveNotes = current?.transcript?.trim().isNotEmpty ?? false;
    final timestamp = now.toUtc();
    final count =
        await (update(dumps)..where(
              (d) =>
                  d.id.equals(id) &
                  d.transcriptionAttempt.equals(attempt) &
                  d.transcriptionRequestId.equals(requestId) &
                  (d.transcriptionStatus.equals(
                        TranscriptionStatus.uploading.wireValue,
                      ) |
                      d.transcriptionStatus.equals(
                        TranscriptionStatus.queued.wireValue,
                      ) |
                      d.transcriptionStatus.equals(
                        TranscriptionStatus.running.wireValue,
                      )),
            ))
            .write(
              DumpsCompanion(
                updatedAt: Value(timestamp),
                transcript: Value(transcript),
                meetingNotes: preserveNotes
                    ? const Value.absent()
                    : Value(meetingNotes),
                transcriptionStatus: Value(
                  TranscriptionStatus.completed.wireValue,
                ),
                transcriptionUpdatedAt: Value(timestamp),
                transcriptionCompletedAt: Value(timestamp),
                transcriptionError: Value(sidecarError),
              ),
            );
    return count == 1;
  });

  /// Updates the sidecar repair marker only for the winning completed attempt.
  Future<bool> updateTranscriptionSidecarError(
    String id, {
    required RecordingKey storageKey,
    required int attempt,
    required String? requestId,
    required String? error,
    required DateTime now,
    String? expectedTranscript,
    String? expectedError,
  }) => transaction(() async {
    await _requireMutationKey(id, storageKey);
    final timestamp = now.toUtc();
    final count =
        await (update(dumps)..where(
              (d) =>
                  d.id.equals(id) &
                  d.transcriptionAttempt.equals(attempt) &
                  (requestId == null
                      ? d.transcriptionRequestId.isNull()
                      : d.transcriptionRequestId.equals(requestId)) &
                  d.transcriptionStatus.isIn([
                    'completed',
                    'failed',
                    'not_applicable',
                  ]) &
                  (expectedTranscript == null
                      ? const Constant(true)
                      : d.transcript.equals(expectedTranscript)) &
                  (expectedError == null
                      ? const Constant(true)
                      : d.transcriptionError.equals(expectedError)),
            ))
            .write(
              DumpsCompanion(
                updatedAt: Value(timestamp),
                transcriptionUpdatedAt: Value(timestamp),
                transcriptionError: Value(error),
              ),
            );
    return count == 1;
  });

  /// Rows whose latest attempt needs network or sidecar reconciliation.
  Future<List<DumpRow>> dumpsNeedingTranscriptionRecovery() =>
      _transcriptionRecoveryQuery().get();

  /// Observe commits even after their initiating route/coordinator disappears.
  Stream<List<DumpRow>> watchDumpsNeedingTranscriptionRecovery() =>
      _transcriptionRecoveryQuery().watch();

  Selectable<DumpRow> _transcriptionRecoveryQuery() {
    return (select(dumps)
      ..where(
        (d) =>
            d.transcriptionStatus.isIn([
              TranscriptionStatus.uploading.wireValue,
              TranscriptionStatus.queued.wireValue,
              TranscriptionStatus.running.wireValue,
            ]) |
            (d.transcriptionStatus.isIn([
                  'completed',
                  'failed',
                  'not_applicable',
                ]) &
                d.transcriptionError.like('sidecar_sync_pending:%')),
      )
      ..orderBy([(d) => OrderingTerm.asc(d.transcriptionStartedAt)]));
  }

  /// Update only the sync fields for a dump.
  Future<void> updateSyncStatus(
    String id,
    SyncStatus status, {
    required RecordingKey storageKey,
    int? attempts,
    String? lastError,
  }) => transaction(() async {
    await _requireMutationKey(id, storageKey);
    await (update(dumps)..where((d) => d.id.equals(id))).write(
      DumpsCompanion(
        syncStatus: Value(status.wireValue),
        syncAttempts: attempts != null ? Value(attempts) : const Value.absent(),
        lastSyncError: lastError != null
            ? Value(lastError)
            : const Value.absent(),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
  });

  /// Find all dumps that need uploading. Excludes synced rows, local-only
  /// rows, and meeting recordings, which are intentionally kept private.
  Future<List<DumpRow>> dumpsNeedingUpload({int maxAttempts = 5}) {
    return customSelect(
      'SELECT * FROM dumps '
      "WHERE sync_status NOT IN ('synced', 'local_only') "
      "AND mode != 'meeting' "
      'AND sync_attempts < ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withInt(maxAttempts)],
      readsFrom: {dumps},
    ).map((row) => dumps.map(row.data)).get();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'tangent.sqlite'));
    return NativeDatabase.createInBackground(file, setup: configureSqlite);
  });
}

/// Per-connection SQLite setup, shared by the app and every background
/// isolate (WorkManager sync, the daily reminder) that opens the SAME
/// file. Two connections with no busy handler fail INSTANTLY with
/// `database is locked (code 5)` the moment their writes overlap — which
/// is how a reminder task colliding with a sync push turned into
/// "Recording failed" on the Fold (v1.29.0). `busy_timeout` makes the
/// loser wait instead of throwing; WAL lets readers and the writer
/// proceed together, so the wait is rare and short.
void configureSqlite(Database db) {
  db.execute('PRAGMA busy_timeout = 5000');
  db.execute('PRAGMA journal_mode = WAL');
}
