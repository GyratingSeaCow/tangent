// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../screens/home/home_screen.dart' show localDbProvider;
import 'local_db.dart';

/// Local persistence for voice-captured calendar events (v1.35.0).
///
/// [TodoRepository]'s shape, deliberately: every write stamps `updated_at`
/// and dirties the row; deletion is SOFT (the card's Undo needs the row back
/// verbatim and the deletion travels to peers as a dirty upsert). Google
/// owns editing — the only local writes after capture are Undo/restore.
class CalendarEventRepository {
  CalendarEventRepository({
    required LocalDb db,
    String Function()? idFactory,
    DateTime Function()? now,
  })  : _db = db,
        _idFactory = idFactory ?? (() => const Uuid().v4()),
        _now = now ?? DateTime.now;

  final LocalDb _db;
  final String Function() _idFactory;
  final DateTime Function() _now;

  String _stamp() => _now().toUtc().toIso8601String();

  /// Every event captured from [sourceRef], live OR soft-deleted, oldest
  /// first — the idempotency oracle for capture (an Undone dump stays
  /// undone across re-transcriptions).
  Future<List<CalendarEventRow>> eventsFromSource(String sourceRef) =>
      (_db.select(_db.calendarEvents)
            ..where((t) => t.sourceRef.equals(sourceRef))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .get();

  /// The LIVE events captured from [sourceRef] — the detail screen's
  /// "Added to your calendar" card. Empty after Undo, which hides the card.
  Stream<List<CalendarEventRow>> watchEventsFromSource(String sourceRef) =>
      (_db.select(_db.calendarEvents)
            ..where(
              (t) => t.sourceRef.equals(sourceRef) & t.deletedAt.isNull(),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch();

  Future<CalendarEventRow> add({
    required String title,
    required String start,
    required String end,
    required bool allDay,
    required String timeZone,
    required bool needsDate,
    required String sourceRef,
    String? captureFingerprint,
  }) async {
    final String timestamp = _stamp();
    final String id = _idFactory();
    await _db.into(_db.calendarEvents).insert(
          CalendarEventsCompanion.insert(
            id: id,
            title: title,
            start: start,
            end: end,
            allDay: Value(allDay),
            timeZone: timeZone,
            needsDate: Value(needsDate),
            createdAt: timestamp,
            updatedAt: timestamp,
            sourceRef: Value(sourceRef),
            captureFingerprint: Value(captureFingerprint),
            syncDirty: const Value(true),
          ),
        );
    return (await _db.getCalendarEventRow(id))!;
  }

  /// Stamps the LOCAL-ONLY fingerprint on every row of [sourceRef] without
  /// touching `updated_at` or the dirty flag (the column never syncs).
  Future<void> setCaptureFingerprint(
    String sourceRef,
    String fingerprint,
  ) async {
    await (_db.update(_db.calendarEvents)
          ..where((t) => t.sourceRef.equals(sourceRef)))
        .write(CalendarEventsCompanion(captureFingerprint: Value(fingerprint)));
  }

  /// Soft-deletes every live event from [sourceRef] (the card's Undo). The
  /// server worker sees `deleted_at` and removes them from Google.
  Future<int> softDeleteFromSource(String sourceRef) async {
    final List<CalendarEventRow> rows = await (_db.select(_db.calendarEvents)
          ..where((t) => t.sourceRef.equals(sourceRef) & t.deletedAt.isNull()))
        .get();
    for (final CalendarEventRow row in rows) {
      await softDelete(row.id);
    }
    return rows.length;
  }

  Future<void> softDelete(String id) async {
    await _write(id, CalendarEventsCompanion(deletedAt: Value(_stamp())));
  }

  Future<void> restore(String id) async {
    await _write(id, const CalendarEventsCompanion(deletedAt: Value(null)));
  }

  Future<void> _write(String id, CalendarEventsCompanion changes) async {
    await (_db.update(_db.calendarEvents)..where((t) => t.id.equals(id))).write(
      changes.copyWith(
        updatedAt: Value(_stamp()),
        syncDirty: const Value(true),
      ),
    );
  }
}

final calendarEventRepositoryProvider = Provider<CalendarEventRepository>(
  (ref) => CalendarEventRepository(db: ref.watch(localDbProvider)),
);
