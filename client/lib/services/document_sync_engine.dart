// SPDX-License-Identifier: AGPL-3.0-or-later
/// Two-way document sync against the user's own server.
///
/// Scope, from the design: notebooks and text notes sync; AUDIO DOES NOT.
/// Audio stays on the device that recorded it and moves only on explicit
/// request. This engine therefore moves kilobytes of JSON, which is why it is
/// allowed to run on cellular while bulk audio backup is not.
///
/// Distinct from [SyncEngine], which is one-way opt-in audio backup. The two
/// are deliberately not merged: they answer to different settings, different
/// network rules, and different failure consequences.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/local_db.dart';
import '../models/sync_change.dart';
import 'connectivity_service.dart';
import 'transcription_client.dart';

/// How a sync attempt ended, for the UI to report honestly.
enum SyncOutcome { success, offline, failed, alreadyRunning }

@immutable
class SyncReport {
  const SyncReport({
    required this.outcome,
    this.pulled = 0,
    this.pushed = 0,
    this.conflicts = 0,
    this.error,
  });

  final SyncOutcome outcome;
  final int pulled;
  final int pushed;
  final int conflicts;
  final String? error;

  bool get isSuccess => outcome == SyncOutcome.success;
}

/// Pulls remote changes, merges them, then pushes local ones.
///
/// Pull BEFORE push, always. Pushing first would send a local edit that the
/// merge step might have forked, so the server would record a change the user
/// never actually resolved.
class DocumentSyncEngine extends ChangeNotifier {
  DocumentSyncEngine({
    required LocalDb Function() db,
    required TranscriptionClient Function() client,
    required ConnectivityService connectivity,
    required Future<String> Function() deviceLabel,
    required String newDeviceId,
  })  : _dbFactory = db,
        _client = client,
        _connectivity = connectivity,
        _deviceLabel = deviceLabel,
        _newDeviceId = newDeviceId;

  /// Resolved on first use, not at construction. Building this engine must
  /// not open a database: it is created whenever a screen with a sync button
  /// is built, including in tests that deliberately provide no database at
  /// all, and an eager handle turns rendering a button into a hard failure.
  final LocalDb Function() _dbFactory;
  LocalDb? _resolvedDb;
  LocalDb get _db => _resolvedDb ??= _dbFactory();

  /// Resolved per call: the server URL and token can change under the user
  /// (re-pairing, a new token), and a captured client would keep talking to
  /// the old one.
  final TranscriptionClient Function() _client;
  final ConnectivityService _connectivity;
  /// Resolved asynchronously on first registration: the real Android model
  /// comes from a platform channel, which cannot be read synchronously while
  /// building a provider.
  final Future<String> Function() _deviceLabel;
  final String _newDeviceId;

  bool _syncing = false;
  bool _disposed = false;
  DateTime? _lastSync;
  String? _lastError;
  int _lastConflicts = 0;

  bool get isSyncing => _syncing;
  DateTime? get lastSync => _lastSync;
  String? get lastError => _lastError;

  /// Conflicts from the most recent sync, so the UI can say so plainly rather
  /// than leaving forked notebooks to be discovered by accident.
  int get lastConflicts => _lastConflicts;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Runs one full sync cycle.
  ///
  /// Reentrancy is refused rather than queued: the 30-minute timer and the
  /// sync button can fire together, and two concurrent cycles would race on
  /// the same checkpoint.
  Future<SyncReport> syncNow() async {
    if (_syncing || _disposed) {
      return const SyncReport(outcome: SyncOutcome.alreadyRunning);
    }
    _syncing = true;
    _lastError = null;
    _notify();

    int pulled = 0;
    int pushed = 0;
    int conflicts = 0;
    try {
      final ConnectivityStatus status = await _connectivity.currentStatus();
      if (!status.isOnline) {
        return const SyncReport(outcome: SyncOutcome.offline);
      }
      // Deliberately NOT gated on wifiOnlySync. That setting governs bulk
      // audio upload; document sync is kilobytes of JSON and the user asked
      // for it to work everywhere.

      final SyncStateRow state = await _db.syncState(newDeviceId: _newDeviceId);
      final TranscriptionClient client = _client();

      // A device that cannot name itself is a cosmetic problem: the server
      // keys on the id, and the label is only there so a human can tell the
      // tablet from the phone. Letting it throw would turn that into no sync
      // at all.
      String label;
      try {
        label = await _deviceLabel();
      } catch (_) {
        label = 'Android device';
      }

      await client.registerDevice(
        deviceId: state.deviceId,
        displayName: label,
        platform: 'android',
      );

      // --- pull ---
      int since = state.lastPulledSeq;
      bool more = true;
      while (more && !_disposed) {
        final SyncPullPage page = await client.pullChanges(
          deviceId: state.deviceId,
          sinceSeq: since,
        );
        for (final RemoteChange change in page.changes) {
          final bool forked = await _applyRemote(change);
          if (forked) conflicts++;
          pulled++;
        }
        // Advance only after the whole page landed: a crash mid-page must
        // re-fetch it, never skip it.
        await _db.recordPullCheckpoint(page.headSeq);
        since = page.headSeq;
        more = page.hasMore;
      }

      // --- push ---
      if (!_disposed) {
        pushed = await _pushLocal(client, state.deviceId);
      }

      if (!_disposed) _lastSync = DateTime.now();
      _lastConflicts = conflicts;
      return SyncReport(
        outcome: SyncOutcome.success,
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
      );
    } catch (error) {
      _lastError = error.toString();
      return SyncReport(
        outcome: SyncOutcome.failed,
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
        error: error.toString(),
      );
    } finally {
      _syncing = false;
      _notify();
    }
  }

  /// Applies one incoming change. Returns true when it forked a conflict.
  Future<bool> _applyRemote(RemoteChange change) async {
    if (change.entityType != 'notebook') return false;

    if (change.op == SyncOp.delete) {
      await _db.applyRemoteNotebookDeletion(change.entityId);
      return false;
    }

    final Map<String, dynamic> payload = change.payload ?? const {};
    final NotebookRow? local = await _db.getNotebookRow(change.entityId);
    final int remoteUpdatedAt = (payload['updated_at'] as num?)?.toInt() ?? 0;

    final MergeDecision decision = decideMerge(
      localExists: local != null,
      localDirty: local?.syncDirty ?? false,
      localUpdatedAt: local?.updatedAt ?? 0,
      remoteUpdatedAt: remoteUpdatedAt,
    );

    switch (decision) {
      case MergeDecision.keepLocal:
        return false;
      case MergeDecision.accept:
        await _writeRemote(change.entityId, payload, change.seq);
        return false;
      case MergeDecision.fork:
        // Both sides edited. The incoming copy lands beside the local one
        // under a conflict name; nothing is overwritten and nothing is lost.
        await _writeRemote(
          '${change.entityId}-conflict-${change.seq}',
          <String, dynamic>{
            ...payload,
            'title': forkedTitle(
              payload['title'] as String? ?? 'Notebook',
              change.deviceId ?? 'another device',
            ),
          },
          change.seq,
        );
        return true;
    }
  }

  Future<void> _writeRemote(
    String id,
    Map<String, dynamic> payload,
    int seq,
  ) async {
    final Object? doc = payload['doc'];
    final Object? ink = payload['ink'];
    await _db.applyRemoteNotebook(
      id: id,
      title: payload['title'] as String? ?? 'Notebook',
      createdAt: (payload['created_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      updatedAt: (payload['updated_at'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      // Bodies travel as JSON text. Encoding a decoded map back to a string
      // keeps the column's contract regardless of what the transport handed
      // us.
      docJson: doc is String ? doc : jsonEncode(doc ?? const {}),
      inkJson: ink is String ? ink : jsonEncode(ink ?? const {}),
      // Absent means the peer is an older build that does not know about
      // ruling. Passing null through would erase a ruling this device already
      // has, so a missing value leaves the local one alone.
      ruling: payload.containsKey('ruling')
          ? payload['ruling'] as String?
          : null,
      seq: seq,
    );
  }

  Future<int> _pushLocal(TranscriptionClient client, String deviceId) async {
    final List<NotebookRow> dirty = await _db.notebooksNeedingPush();
    final List<SyncTombstoneRow> tombstones = await _db.pendingTombstones();
    if (dirty.isEmpty && tombstones.isEmpty) return 0;

    final List<Map<String, dynamic>> changes = <Map<String, dynamic>>[
      for (final NotebookRow row in dirty)
        <String, dynamic>{
          'entity_type': 'notebook',
          'entity_id': row.id,
          'op': 'upsert',
          'payload': <String, dynamic>{
            'title': row.title,
            'created_at': row.createdAt,
            'updated_at': row.updatedAt,
            'doc': row.docJson,
            'ink': row.inkJson,
            'ruling': row.ruling,
          },
        },
      for (final SyncTombstoneRow stone in tombstones)
        <String, dynamic>{
          'entity_type': stone.entityType,
          'entity_id': stone.entityId,
          'op': 'delete',
        },
    ];

    final List<PushResult> results = await client.pushChanges(
      deviceId: deviceId,
      changes: changes,
    );

    final Map<String, int> pushedUpdatedAt = <String, int>{
      for (final NotebookRow row in dirty) row.id: row.updatedAt,
    };

    int accepted = 0;
    for (final PushResult result in results) {
      // A rejected entity stays dirty and retries next cycle. Clearing the
      // flag on a rejection would lose the edit silently.
      if (!result.applied) continue;
      accepted++;
      final int? was = pushedUpdatedAt[result.entityId];
      if (was != null) {
        await _db.markNotebookSynced(
          result.entityId,
          seq: result.seq,
          pushedUpdatedAt: was,
        );
      } else {
        await _db.clearTombstone(
          entityType: result.entityType,
          entityId: result.entityId,
        );
      }
    }
    return accepted;
  }
}
