// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/sync_status.dart';
import '../models/transcription_status.dart';
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
  TextColumn get folderId => text().nullable()();

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

  @override
  Set<Column> get primaryKey => {id};
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
  Set<Column> get primaryKey => {id};
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
  ],
)
class LocalDb extends _$LocalDb implements StorageDatabaseOperations {
  LocalDb() : super(_openConnection());

  LocalDb.forTesting(super.executor);

  @override
  int get schemaVersion => 18;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createFtsInfrastructure();
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
              final List<QueryRow> columns =
                  await customSelect('PRAGMA table_info(dumps)').get();
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
            final List<QueryRow> notebookColumns =
                await customSelect('PRAGMA table_info(notebooks)').get();
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
            final List<QueryRow> rulingColumns =
                await customSelect('PRAGMA table_info(notebooks)').get();
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
            final List<QueryRow> dumpColumns =
                await customSelect('PRAGMA table_info(dumps)').get();
            final Set<String> names = <String>{
              for (final QueryRow row in dumpColumns)
                row.data['name'] as String,
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
            final List<QueryRow> repairColumns =
                await customSelect('PRAGMA table_info(dumps)').get();
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
            final List<QueryRow> folderColumns =
                await customSelect('PRAGMA table_info(folders)').get();
            final Set<String> present = <String>{
              for (final QueryRow row in folderColumns)
                row.data['name'] as String,
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
            final List<QueryRow> nbColumns =
                await customSelect('PRAGMA table_info(notebooks)').get();
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
              for (final QueryRow row
                  in await customSelect('PRAGMA table_info(notebooks)').get())
                row.data['name'] as String,
            };
            if (nbColumns.containsAll(
              const <String>['folder_id', 'sync_dirty', 'deleted_at'],
            )) {
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
            ).get())
                .isNotEmpty;
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
            final List<QueryRow> penColumns =
                await customSelect('PRAGMA table_info(notebooks)').get();
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
              for (final QueryRow row
                  in await customSelect('PRAGMA table_info(dumps)').get())
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
              for (final QueryRow row
                  in await customSelect('PRAGMA table_info(dumps)').get())
                row.data['name'] as String,
            };
            if (dumpCols.isNotEmpty &&
                !dumpCols.contains('transcript_timings')) {
              await m.addColumn(dumps, dumps.transcriptTimings);
            }
          }
        },
      );

  // ---- multi-device sync -------------------------------------------------

  /// This device's sync identity, created on first use.
  ///
  /// [newDeviceId] is supplied by the caller rather than generated here so the
  /// id is testable and so identity generation lives with the rest of the sync
  /// policy instead of in the data layer.
  Future<SyncStateRow> syncState({required String newDeviceId}) async {
    final SyncStateRow? existing = await (select(syncStates)
          ..where((t) => t.id.equals(1)))
        .getSingleOrNull();
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
      ])
        TableUpdate.onTable(table),
    });
  }

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
      await (delete(inkIndexEntries)
            ..where((t) => t.notebookId.equals(notebookId)))
          .go();
      for (final InkIndexEntriesCompanion row in rows) {
        await into(inkIndexEntries).insert(row);
      }
    });
  }

  /// Drops a notebook's mirrored index rows (its `ink_index` delete arrived —
  /// the notebook was purged server-side, so its words must stop matching).
  Future<void> applyRemoteInkIndexDeletion(String notebookId) async {
    await (delete(inkIndexEntries)
          ..where((t) => t.notebookId.equals(notebookId)))
        .go();
  }

  /// Notebooks with local edits the server has not confirmed. Trashed rows
  /// stay out: their tombstone travels instead, and pushing a trashed body
  /// would resurrect it on the peer.
  Future<List<NotebookRow>> notebooksNeedingPush() => (select(notebooks)
        ..where((t) => t.syncDirty.equals(true) & t.deletedAt.isNull()))
      .get();

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
      NotebooksCompanion(syncDirty: const Value(false), syncedSeq: Value(seq)),
    );
  }

  /// Marks a notebook dirty. Every local save funnels through here.
  Future<void> markNotebookDirty(String id) async {
    await (update(notebooks)..where((t) => t.id.equals(id)))
        .write(const NotebooksCompanion(syncDirty: Value(true)));
  }

  // ---- dump (recording) sync --------------------------------------------

  /// Recordings whose metadata the server has not accepted yet.
  ///
  /// Remote-only rows are excluded: this device holds no authoritative copy
  /// of them, so pushing one back would echo the peer's own change.
  Future<List<DumpRow>> dumpsNeedingMetadataPush() => (select(dumps)
        ..where(
          // Null means "never touched by sync" => not dirty, not remote.
          (d) =>
              d.syncDirty.equals(true) &
              (d.remoteOnly.equals(false) | d.remoteOnly.isNull()),
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
          ..where(
            (d) => d.id.equals(id) & d.updatedAt.equals(pushedUpdatedAt),
          ))
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
    await (update(dumps)..where((d) => d.id.equals(id)))
        .write(const DumpsCompanion(syncDirty: Value<bool?>(true)));
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
  }) async {
    final Value<String?> timingsValue =
        identical(transcriptTimings, absentSummaryField)
            ? const Value<String?>.absent()
            : Value<String?>(transcriptTimings as String?);
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
    final DumpRow? existing = await getDumpRow(id);
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
      await (delete(localDeletionTickets)
            ..where((t) => t.dumpId.equals(id) & t.state.equals('completed')))
          .go();
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
        syncDirty: const Value<bool?>(false),
        syncedSeq: Value(seq),
      ),
    );
  }

  /// Sentinel distinguishing "payload had no summary keys" (older server —
  /// keep the stored values) from "server sent null" for [applyRemoteDump].
  static const Object absentSummaryField = Object();

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
    await (delete(syncTombstones)
          ..where(
            (t) =>
                t.entityType.equals(entityType) & t.entityId.equals(entityId),
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
  }) async {
    // insertOrReplace rewrites the whole row, so a null ruling here would
    // erase a value this device already holds whenever the peer is an older
    // build that does not send one. Fall back to what is already stored.
    // folder_id gets the same treatment with a twist: null is MEANINGFUL
    // (it says "unfiled"), so absence is a sentinel rather than null.
    final NotebookRow? existing = await (select(notebooks)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    final String? effectiveRuling = ruling ?? existing?.ruling;
    // The nib gets the ruling treatment: an older peer that has never heard
    // of pen memory sends nothing, and that absence must not erase the nib
    // this device already remembers.
    final String? effectivePenStyle = lastPenStyle ?? existing?.lastPenStyle;
    final String? effectiveFolderId = identical(folderId, absentFolderId)
        ? existing?.folderId
        : folderId as String?;

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

  // ---- folders -----------------------------------------------------------

  /// Creates a folder and returns its id.
  Future<String> createFolder({required String name, String? id}) async {
    final String folderId =
        id ?? 'folder-${DateTime.now().microsecondsSinceEpoch}';
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

  /// Files a recording or note, or unfiles it when [folderId] is null.
  Future<void> moveDumpToFolder({
    required String dumpId,
    required String? folderId,
  }) async {
    await (update(dumps)..where((t) => t.id.equals(dumpId)))
        .write(DumpsCompanion(folderId: Value<String?>(folderId)));
  }

  /// Renames a recording or note. Deliberately writes only the title, so a
  /// rename cannot disturb filing, sync state or transcription state.
  Future<void> renameDump({
    required String dumpId,
    required String title,
  }) async {
    await (update(dumps)..where((t) => t.id.equals(dumpId)))
        .write(DumpsCompanion(title: Value<String>(title)));
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
      await (update(notebooks)..where((t) => t.folderId.equals(folderId)))
          .write(
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
      await (delete(folders)..where((t) => t.id.equals(folderId))).go();
      await recordTombstone(entityType: 'folder', entityId: folderId);
    });
  }

  // ---- folder sync -------------------------------------------------------

  /// Folders with local changes the server has not confirmed. Null reads as
  /// dirty: a folder that predates folder sync has never been pushed.
  Future<List<Folder>> foldersNeedingPush() => (select(folders)
        ..where((t) => t.syncDirty.equals(true) | t.syncDirty.isNull()))
      .get();

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
      await (update(notebooks)..where((t) => t.folderId.equals(id)))
          .write(const NotebooksCompanion(folderId: Value<String?>(null)));
      await (update(dumps)..where((t) => t.folderId.equals(id)))
          .write(const DumpsCompanion(folderId: Value<String?>(null)));
      await (delete(folders)..where((t) => t.id.equals(id))).go();
    });
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
  Future<List<NotebookRow>> trashedNotebooks() => (select(notebooks)
        ..where((t) => t.deletedAt.isNotNull())
        ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]))
      .get();

  /// Drops every trashed notebook older than [trashRetention]. Returns how
  /// many were purged. Called at startup; the Settings screen states the
  /// 7-day window so the emptying is a promise, not a surprise.
  Future<int> purgeExpiredTrash({DateTime? now}) async {
    final int cutoff =
        (now ?? DateTime.now()).subtract(trashRetention).millisecondsSinceEpoch;
    return (delete(notebooks)
          ..where(
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
    await customStatement(
      '''CREATE TRIGGER dumps_ai AFTER INSERT ON dumps BEGIN
        INSERT INTO dumps_fts(rowid, title, transcript)
        VALUES (new.rowid, new.title, new.transcript);
      END''',
    );
    await customStatement(
      '''CREATE TRIGGER dumps_ad AFTER DELETE ON dumps BEGIN
        INSERT INTO dumps_fts("dumps_fts", rowid, title, transcript)
        VALUES ('delete', old.rowid, old.title, old.transcript);
      END''',
    );
    await customStatement(
      '''CREATE TRIGGER dumps_au AFTER UPDATE ON dumps BEGIN
        INSERT INTO dumps_fts("dumps_fts", rowid, title, transcript)
        VALUES ('delete', old.rowid, old.title, old.transcript);
        INSERT INTO dumps_fts(rowid, title, transcript)
        VALUES (new.rowid, new.title, new.transcript);
      END''',
    );
  }

  /// Atomic catalog commit boundary, also used to reconcile uncertain acknowledgements.
  Future<T> commitStorageCatalog<T>(Future<T> Function() action) =>
      transaction(action);

  /// Compare-and-install only. Callers must reread SQLite even after an uncertain
  /// acknowledgement; the candidate in memory is never durable authority.
  Future<void> freezeLegacyAnchor(String anchorJson) => transaction(() async {
        await (update(storageCatalogStates)
              ..where(
                (s) =>
                    s.id.equals(1) &
                    s.legacyAnchorJson.isNull() &
                    s.bootstrapVersion.equals(0),
              ))
            .write(
          StorageCatalogStatesCompanion(
            legacyAnchorJson: Value(anchorJson),
          ),
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
  Future<void> completeLegacyRestore(String locationId) =>
      transaction(() async {
        await (update(storageLocations)..where((l) => l.id.equals(locationId)))
            .write(
          const StorageLocationsCompanion(legacyRestore: Value(false)),
        );
      });

  /// Resolve only persisted original ownership, never a current default.
  @override
  Future<BoundRecording?> boundRecording(String id) => transaction(() async {
        final row = await (select(recordingBindings)
              ..where((b) => b.dumpId.equals(id)))
            .getSingleOrNull();
        if (row == null || !row.resolved || row.locationId == null) return null;
        final location = await (select(storageLocations)
              ..where((l) => l.id.equals(row.locationId!)))
            .getSingleOrNull();
        if (location == null) return null;
        final binding = (
          key: (dumpId: row.dumpId, incarnation: row.incarnation),
          location: (
            id: location.id,
            label: location.label,
            directory: StorageCodec.decodeDirectory(location.directoryJson)
          ),
          audio: StorageCodec.decodeAudio(row.audioJson),
          metadataName: row.metadataName,
        );
        StorageCodec.encodeBinding(binding);
        return binding;
      });

  Never _storageFault(ProblemCode code, String message) =>
      throw StorageFault((code: code, message: message));
  Future<LocalDeletionTicketRow?> _deletionFence(String id) =>
      (select(localDeletionTickets)..where((t) => t.dumpId.equals(id)))
          .getSingleOrNull();

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
          await (delete(localDeletionTickets)
                ..where(
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
            fence.state == 'completed'
                ? ProblemCode.retired
                : ProblemCode.fenced,
            'Recording identity is fenced',
          );
        }
        final row = await getDump(id);
        if (row == null || row.audioPath != binding.audio.value) {
          _storageFault(
            ProblemCode.conflict,
            'Original audio identity differs',
          );
        }
        final location = await (select(storageLocations)
              ..where((l) => l.id.equals(binding.location.id)))
            .getSingleOrNull();
        if (location == null ||
            location.directoryJson !=
                StorageCodec.encodeDirectory(binding.location.directory) ||
            location.label != binding.location.label) {
          _storageFault(
            ProblemCode.conflict,
            'Location is not the persisted capability',
          );
        }
        final prior = await (select(recordingBindings)
              ..where((b) => b.dumpId.equals(id)))
            .getSingleOrNull();
        if (prior != null) {
          if (prior.incarnation != binding.key.incarnation ||
              StorageCodec.decodeAudio(prior.audioJson) != binding.audio ||
              prior.metadataName != binding.metadataName ||
              (prior.resolved && await boundRecording(id) != binding)) {
            _storageFault(ProblemCode.conflict, 'Binding is immutable');
          }
          if (prior.resolved) return;
          await (update(recordingBindings)..where((b) => b.dumpId.equals(id)))
              .write(
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
                message: raw['message'] as String
              )
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
      state: TicketState.values.byName(row.state)
    );
  }

  /// Task5 final row/binding/journal transaction; allows acknowledgment-loss tests.
  Future<T> commitOwnedCapture<T>(Future<T> Function() action) =>
      transaction(action);

  /// Every retained capture journal owns staging cleanup, even after row commit.
  Future<bool> hasCaptureJournal(String id) async =>
      await (select(captureReservations)..where((r) => r.dumpId.equals(id)))
          .getSingleOrNull() !=
      null;

  @override
  Future<Outcome<DeletionTicket>> claimLocalDeletion(
    String operationId,
    DeleteTarget target,
  ) =>
      transaction(() async {
        StorageCodec.validateLiteralId(operationId);
        final binding = target.binding;
        if (binding == null) {
          return const Fail(
            (code: ProblemCode.unresolved, message: 'No confirmed binding'),
          );
        }
        final encoded = StorageCodec.encodeBinding(binding);
        if (target.id != binding.key.dumpId) {
          return const Fail(
            (code: ProblemCode.invalid, message: 'Target identity differs'),
          );
        }
        final prior = await _deletionFence(target.id);
        if (prior != null) {
          if (prior.bindingJson != encoded ||
              (prior.operationId != operationId &&
                  (target.retryTicketId != prior.ticketId ||
                      prior.state == 'completed'))) {
            return const Fail(
              (
                code: ProblemCode.conflict,
                message: 'Different deletion already owns this identity'
              ),
            );
          }
          if (prior.state == 'completed') return Ok(_decodeTicket(prior));
        }
        if (prior == null && target.retryTicketId != null) {
          return const Fail(
            (code: ProblemCode.conflict, message: 'Retry ticket missing'),
          );
        }
        if (await hasCaptureJournal(target.id)) {
          return const Fail(
            (
              code: ProblemCode.busy,
              message: 'Owned staging cleanup is pending'
            ),
          );
        }
        final row = await getDump(target.id);
        if (row == null) {
          return const Fail(
            (code: ProblemCode.absent, message: 'Recording missing'),
          );
        }
        if (await boundRecording(target.id) != binding) {
          return const Fail(
            (
              code: ProblemCode.wrongIncarnation,
              message: 'Confirmed binding changed'
            ),
          );
        }
        if (!['not_transcribed', 'completed', 'failed', 'not_applicable']
                .contains(row.transcriptionStatus) ||
            row.syncStatus == 'syncing' ||
            (row.transcriptionError?.startsWith('sidecar_sync_pending:') ??
                false)) {
          return const Fail(
            (
              code: ProblemCode.busy,
              message: 'Recording has durable pending work'
            ),
          );
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
    final row = await (select(localDeletionTickets)
          ..where((t) => t.ticketId.equals(id)))
        .getSingleOrNull();
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
  ) =>
      transaction(() async {
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
        await (update(localDeletionTickets)
              ..where((t) => t.ticketId.equals(ticketId)))
            .write(
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
          _storageFault(
            ProblemCode.busy,
            'Both components must be proven gone',
          );
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
        await (delete(syncQueue)..where((q) => q.dumpId.equals(ticket.dumpId)))
            .go();
        await (delete(recordingBindings)
              ..where(
                (b) =>
                    b.dumpId.equals(ticket.dumpId) &
                    b.incarnation.equals(ticket.incarnation),
              ))
            .go();
        await (delete(dumps)..where((d) => d.id.equals(ticket.dumpId))).go();
        await (update(localDeletionTickets)
              ..where((t) => t.ticketId.equals(ticketId)))
            .write(
          const LocalDeletionTicketsCompanion(
            state: Value('completed'),
            problemJson: Value(null),
          ),
        );
      });

  /// Read immutable deletion ownership, including completed replay receipts.
  Future<DeletionTicket?> deletionTicketById(String ticketId) async {
    final row = await (select(localDeletionTickets)
          ..where((t) => t.ticketId.equals(ticketId)))
        .getSingleOrNull();
    return row == null ? null : _decodeTicket(row);
  }

  @override
  Future<List<DeletionTicket>> pendingLocalDeletions() async =>
      (await (select(localDeletionTickets)
                ..where((t) => t.state.isNotValue('completed')))
              .get())
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
    return (select(dumps)..orderBy([(d) => OrderingTerm.desc(d.createdAt)]))
        .watch();
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
      variables: [
        Variable.withString('"$escaped"'),
        Variable.withInt(limit),
      ],
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
      variables: [
        Variable.withString('"$escaped"'),
        Variable.withInt(limit),
      ],
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

  /// Search across title and transcript using FTS5.
  Future<List<DumpRow>> searchDumps(String query, {int limit = 50}) {
    final escaped = query.replaceAll('"', '""');
    return customSelect(
      'SELECT d.* FROM dumps d '
      'JOIN dumps_fts f ON d.rowid = f.rowid '
      'WHERE dumps_fts MATCH ? '
      'ORDER BY rank LIMIT ?',
      variables: [
        Variable.withString('"$escaped"'),
        Variable.withInt(limit),
      ],
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
        DumpsCompanion(
          title: Value(title),
          updatedAt: Value(now.toUtc()),
        ),
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
      final count = await (update(dumps)
            ..where(
              (d) {
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
              },
            ))
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
      final count = await (update(dumps)
            ..where(
              (d) {
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
              },
            ))
          .write(
        DumpsCompanion(
          transcript: Value(transcript),
          transcriptionError:
              Value('sidecar_sync_pending: manual_edit:${jsonEncode({
                'error': priorError,
                'revision': const Uuid().v4(),
              })}'),
          updatedAt: Value(now.toUtc()),
        ),
      );
      if (count != 1) {
        throw StateError(
          'Transcript revision changed while editing: $id',
        );
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
      final currentStatus =
          TranscriptionStatus.fromWire(current.transcriptionStatus);
      if (currentStatus == TranscriptionStatus.notApplicable) {
        throw StateError('Transcription is not applicable: $id');
      }
      final sidecarPending = currentStatus.isTerminal &&
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
  }) =>
      transaction(() async {
        await _requireMutationKey(id, storageKey);
        final timestamp = now.toUtc();
        final allowedSourceStatuses = switch (status) {
          TranscriptionStatus.notTranscribed ||
          TranscriptionStatus.notApplicable =>
            const <String>['__never__'],
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
          TranscriptionStatus.completed ||
          TranscriptionStatus.failed =>
            <String>[
              TranscriptionStatus.uploading.wireValue,
              TranscriptionStatus.queued.wireValue,
              TranscriptionStatus.running.wireValue,
            ],
        };
        final count = await (update(dumps)
              ..where(
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
            transcriptionJobId:
                jobId == null ? const Value.absent() : Value(jobId),
            transcriptionUpdatedAt: Value(timestamp),
            transcriptionCompletedAt:
                status.isTerminal ? Value(timestamp) : const Value.absent(),
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
  }) =>
      transaction(() async {
        // Read and mutate under the same SQLite transaction. A replacement must
        // never write a snapshot of notes over an explicit regeneration.
        await _requireMutationKey(id, storageKey);
        final current = await getDump(id);
        final preserveNotes = current?.transcript?.trim().isNotEmpty ?? false;
        final timestamp = now.toUtc();
        final count = await (update(dumps)
              ..where(
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
            meetingNotes:
                preserveNotes ? const Value.absent() : Value(meetingNotes),
            transcriptionStatus: Value(TranscriptionStatus.completed.wireValue),
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
  }) =>
      transaction(() async {
        await _requireMutationKey(id, storageKey);
        final timestamp = now.toUtc();
        final count = await (update(dumps)
              ..where(
                (d) =>
                    d.id.equals(id) &
                    d.transcriptionAttempt.equals(attempt) &
                    (requestId == null
                        ? d.transcriptionRequestId.isNull()
                        : d.transcriptionRequestId.equals(requestId)) &
                    d.transcriptionStatus
                        .isIn(['completed', 'failed', 'not_applicable']) &
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
            (d.transcriptionStatus
                    .isIn(['completed', 'failed', 'not_applicable']) &
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
  }) =>
      transaction(() async {
        await _requireMutationKey(id, storageKey);
        await (update(dumps)..where((d) => d.id.equals(id))).write(
          DumpsCompanion(
            syncStatus: Value(status.wireValue),
            syncAttempts:
                attempts != null ? Value(attempts) : const Value.absent(),
            lastSyncError:
                lastError != null ? Value(lastError) : const Value.absent(),
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
      variables: [
        Variable.withInt(maxAttempts),
      ],
      readsFrom: {dumps},
    ).map((row) => dumps.map(row.data)).get();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'tangent.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
