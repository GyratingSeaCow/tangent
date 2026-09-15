// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart';

// These additive tables deliberately have no cascading relationship to Dumps.
// Binding/receipt relations are checked transactionally by the storage owners.
@DataClassName('StorageLocationRow')
class StorageLocations extends Table {
  @override
  String get tableName => 'storage_locations';
  TextColumn get id => text()();
  TextColumn get canonicalKey => text().unique()();
  TextColumn get directoryJson => text()();
  TextColumn get label => text()();
  BoolColumn get legacyRestore =>
      boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('StorageCatalogStateRow')
class StorageCatalogStates extends Table {
  @override
  String get tableName => 'storage_catalog_state';
  IntColumn get id => integer()();
  TextColumn get defaultLocationId => text().nullable()();
  IntColumn get revision => integer().withDefault(const Constant(0))();
  IntColumn get bootstrapVersion => integer().withDefault(const Constant(0))();
  TextColumn get legacyAnchorJson => text().nullable()();
  TextColumn get candidateJson => text().nullable()();
  @override
  Set<Column> get primaryKey => {id};
  @override
  List<String> get customConstraints => ['CHECK (id = 1)'];
}

@DataClassName('RecordingBindingRow')
class RecordingBindings extends Table {
  @override
  String get tableName => 'recording_bindings';
  TextColumn get dumpId => text()();
  TextColumn get incarnation => text()();
  TextColumn get locationId => text().nullable()();
  TextColumn get audioJson => text()();
  TextColumn get metadataName => text()();
  TextColumn get legacyAnchorJson => text().nullable()();
  BoolColumn get resolved => boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {dumpId};
}

@DataClassName('CaptureReservationRow')
class CaptureReservations extends Table {
  @override
  String get tableName => 'capture_reservations';
  TextColumn get reservationId => text()();
  TextColumn get dumpId => text().unique()();
  TextColumn get incarnation => text()();
  TextColumn get locationId => text()();
  TextColumn get stagingPath => text()();
  TextColumn get mode => text()();
  IntColumn get startedAt => integer()();
  TextColumn get state => text()();
  TextColumn get processEpoch => text()();
  TextColumn get publicationJson => text().nullable()();
  @override
  Set<Column> get primaryKey => {reservationId};
}

@DataClassName('LocalDeletionBatchRow')
class LocalDeletionBatches extends Table {
  @override
  String get tableName => 'local_deletion_batches';
  TextColumn get operationId => text()();
  TextColumn get payloadJson => text()();
  TextColumn get resultsJson => text()();
  TextColumn get state => text()();
  @override
  Set<Column> get primaryKey => {operationId};
}

@DataClassName('LocalDeletionTicketRow')
class LocalDeletionTickets extends Table {
  @override
  String get tableName => 'local_deletion_tickets';
  TextColumn get dumpId => text()();
  TextColumn get incarnation => text()();
  TextColumn get ticketId => text().unique()();
  TextColumn get operationId => text()();
  TextColumn get bindingJson => text()();
  TextColumn get audioState => text()();
  TextColumn get metadataState => text()();
  TextColumn get state => text()();
  TextColumn get problemJson => text().nullable()();
  @override
  Set<Column> get primaryKey => {dumpId};
}
