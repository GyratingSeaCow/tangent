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
  ],
)
class LocalDb extends _$LocalDb implements StorageDatabaseOperations {
  LocalDb() : super(_openConnection());

  LocalDb.forTesting(super.executor);

  @override
  int get schemaVersion => 8;

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
        },
      );

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
    await (update(folders)..where((t) => t.id.equals(folderId)))
        .write(FoldersCompanion(name: Value<String>(name)));
  }

  /// Files a notebook, or unfiles it when [folderId] is null.
  Future<void> moveNotebookToFolder({
    required String notebookId,
    required String? folderId,
  }) async {
    await (update(notebooks)..where((t) => t.id.equals(notebookId))).write(
      NotebooksCompanion(folderId: Value<String?>(folderId)),
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
  /// must not destroy the work it was attached to.
  Future<void> deleteFolder(String folderId) async {
    await transaction(() async {
      await (update(notebooks)..where((t) => t.folderId.equals(folderId)))
          .write(const NotebooksCompanion(folderId: Value<String?>(null)));
      // One folder holds both kinds, so both must be unfiled together.
      await (update(dumps)..where((t) => t.folderId.equals(folderId)))
          .write(const DumpsCompanion(folderId: Value<String?>(null)));
      await (delete(folders)..where((t) => t.id.equals(folderId))).go();
    });
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
            .write(const StorageLocationsCompanion(legacyRestore: Value(false)));
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
