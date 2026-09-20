// SPDX-License-Identifier: AGPL-3.0-or-later
/// Syncs local edits to the server without the user pressing anything.
///
/// The sync button used to be the only way changes left the device, which
/// meant filing, renaming, and deleting silently stayed local until the user
/// remembered to press it (or the 30-minute background pass ran). This
/// coordinator watches the synced tables and pushes a moment after the user
/// stops making changes.
///
/// Three design points keep it from misbehaving:
///
/// * **Debounce, not throttle.** Handwriting autosaves in bursts; the quiet
///   period restarts on every write so a drawing session becomes one sync at
///   the end, not a sync per stroke.
/// * **Dirty work only.** The engine's own writes (marking rows clean,
///   applying pulled changes) fire the same table updates. Syncing on those
///   would loop forever: sync -> mark clean -> update -> sync. Before firing,
///   the coordinator asks the database whether anything actually needs to
///   push; the engine's bookkeeping never does.
/// * **The engine stays the arbiter.** syncNow() already refuses reentrant
///   cycles, handles offline, and reports errors. This class never bypasses
///   it — worst case an extra call is a cheap no-op.
library;

import 'dart:async';

import 'package:drift/drift.dart';

import '../data/local_db.dart';

class AutoSyncCoordinator {
  AutoSyncCoordinator({
    required LocalDb db,
    required Future<void> Function() syncNow,
    this.debounce = const Duration(seconds: 3),
  })  : _db = db,
        _syncNow = syncNow;

  final LocalDb _db;
  final Future<void> Function() _syncNow;

  /// How long the tables must stay quiet before a sync fires.
  final Duration debounce;

  StreamSubscription<void>? _subscription;
  Timer? _timer;
  bool _disposed = false;

  /// Begins watching. Idempotent; calling twice does not double-subscribe.
  void start() {
    if (_disposed || _subscription != null) return;
    _subscription = _db
        .tableUpdates(
          TableUpdateQuery.onAllTables(<TableInfo<Table, dynamic>>[
            _db.notebooks,
            _db.dumps,
            _db.folders,
            _db.syncTombstones,
          ]),
        )
        .listen((_) => _schedule());
  }

  void _schedule() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(debounce, _fireIfDirty);
  }

  Future<void> _fireIfDirty() async {
    if (_disposed) return;
    // Ask the database, not the event: the update stream cannot say whether
    // the write was the user's (dirty) or the engine's own bookkeeping
    // (clean), and syncing on bookkeeping would loop.
    final bool dirty = (await _db.notebooksNeedingPush()).isNotEmpty ||
        (await _db.dumpsNeedingMetadataPush()).isNotEmpty ||
        (await _db.foldersNeedingPush()).isNotEmpty ||
        (await _db.pendingTombstones()).isNotEmpty;
    if (!dirty || _disposed) return;
    await _syncNow();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
  }
}
