// SPDX-License-Identifier: AGPL-3.0-or-later
/// Auto-sync: edits reach the server without the sync button.
///
/// The button stays (it is the only way to force a pull), but day-to-day the
/// user should never need it: writing, renaming, filing, or deleting should
/// push on its own a moment later.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/services/auto_sync_coordinator.dart';

void main() {
  late LocalDb db;
  late int syncCalls;
  late AutoSyncCoordinator coordinator;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    syncCalls = 0;
  });

  tearDown(() async {
    coordinator.dispose();
    await db.close();
  });

  AutoSyncCoordinator build({Duration? debounce}) => AutoSyncCoordinator(
        db: db,
        syncNow: () async => syncCalls++,
        debounce: debounce ?? const Duration(milliseconds: 40),
      );

  Future<void> settle() async =>
      Future<void>.delayed(const Duration(milliseconds: 120));

  test('a local edit triggers exactly one sync after the quiet period',
      () async {
    coordinator = build()..start();

    await db.into(db.notebooks).insert(
          NotebooksCompanion.insert(
            id: 'nb-1',
            title: 'T',
            createdAt: 1,
            updatedAt: 2,
            docJson: '{}',
            inkJson: '{}',
          ),
        );
    await settle();

    expect(syncCalls, 1);
  });

  test('a burst of edits coalesces into one sync', () async {
    // Handwriting saves fire constantly; syncing every stroke would hammer
    // the server and drain the battery. The quiet period restarts with each
    // write, so one pause gets one sync.
    coordinator = build()..start();

    for (int i = 0; i < 5; i++) {
      await db.into(db.notebooks).insert(
            NotebooksCompanion.insert(
              id: 'nb-$i',
              title: 'T$i',
              createdAt: 1,
              updatedAt: 2,
              docJson: '{}',
              inkJson: '{}',
            ),
          );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await settle();

    expect(syncCalls, 1);
  });

  test('clean writes do not trigger a sync', () async {
    // The engine's own bookkeeping (marking rows synced, applying pulled
    // changes) also fires table updates. Syncing in response would loop:
    // sync -> mark clean -> table update -> sync. Only dirty work counts.
    coordinator = build()..start();

    await db.into(db.notebooks).insert(
          NotebooksCompanion.insert(
            id: 'nb-clean',
            title: 'T',
            createdAt: 1,
            updatedAt: 2,
            docJson: '{}',
            inkJson: '{}',
            syncDirty: const Value(false),
          ),
        );
    await settle();

    expect(syncCalls, 0);
  });

  test('a deletion (tombstone) triggers a sync', () async {
    coordinator = build()..start();
    await db.into(db.notebooks).insert(
          NotebooksCompanion.insert(
            id: 'nb-del',
            title: 'T',
            createdAt: 1,
            updatedAt: 2,
            docJson: '{}',
            inkJson: '{}',
            syncDirty: const Value(false),
          ),
        );
    await settle();
    final int before = syncCalls;

    await db.trashNotebook('nb-del');
    await db.recordTombstone(entityType: 'notebook', entityId: 'nb-del');
    await settle();

    expect(syncCalls, before + 1);
  });

  test('a folder change triggers a sync', () async {
    coordinator = build()..start();

    await db.createFolder(name: 'Field Notes');
    await settle();

    expect(syncCalls, greaterThanOrEqualTo(1));
  });

  test('nothing fires after dispose', () async {
    coordinator = build()..start();
    coordinator.dispose();

    await db.createFolder(name: 'After');
    await settle();

    expect(syncCalls, 0);
    // tearDown disposes again; that must be safe.
    coordinator = build();
  });
}
