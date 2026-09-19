// SPDX-License-Identifier: AGPL-3.0-or-later
/// Wire types and merge rules for multi-device sync.
///
/// The server owns one monotonically increasing sequence and stamps every
/// accepted change with it. A client remembers the highest sequence it has
/// applied and asks "what changed after N?". That is a CHECKPOINT, not a
/// clock: it is assigned by a single authority, so the devices never have to
/// agree on the time.
///
/// Merge lives here, on the client, deliberately. The server stores document
/// bodies opaquely and never has to understand ink, so a change to the
/// document format does not require a server deploy.
library;

import 'package:flutter/foundation.dart';

/// What a change did to an entity.
enum SyncOp {
  upsert,
  delete;

  static SyncOp parse(String raw) =>
      raw == 'delete' ? SyncOp.delete : SyncOp.upsert;

  String get wire => name;
}

/// One change as it arrives from the server.
@immutable
class RemoteChange {
  const RemoteChange({
    required this.seq,
    required this.entityType,
    required this.entityId,
    required this.op,
    required this.payload,
    required this.deviceId,
  });

  factory RemoteChange.fromJson(Map<String, dynamic> json) => RemoteChange(
        seq: (json['seq'] as num?)?.toInt() ?? 0,
        entityType: json['entity_type'] as String? ?? '',
        entityId: json['entity_id'] as String? ?? '',
        op: SyncOp.parse(json['op'] as String? ?? 'upsert'),
        payload: json['payload'] as Map<String, dynamic>?,
        deviceId: json['device_id'] as String?,
      );

  final int seq;
  final String entityType;
  final String entityId;
  final SyncOp op;

  /// Null for a delete: a tombstone carries no body, so replaying one can
  /// never resurrect content.
  final Map<String, dynamic>? payload;
  final String? deviceId;
}

/// One page of pulled changes.
@immutable
class SyncPullPage {
  const SyncPullPage({
    required this.changes,
    required this.headSeq,
    required this.hasMore,
  });

  final List<RemoteChange> changes;

  /// The checkpoint to store once every change in this page has been applied.
  final int headSeq;

  /// True when more changes remain past this page.
  final bool hasMore;
}

/// The server's verdict on one pushed entity.
@immutable
class PushResult {
  const PushResult({
    required this.entityId,
    required this.entityType,
    required this.seq,
    required this.applied,
    this.reason,
  });

  factory PushResult.fromJson(Map<String, dynamic> json) => PushResult(
        entityId: json['entity_id'] as String? ?? '',
        entityType: json['entity_type'] as String? ?? '',
        seq: (json['seq'] as num?)?.toInt() ?? 0,
        applied: json['status'] == 'applied',
        reason: json['reason'] as String?,
      );

  final String entityId;
  final String entityType;
  final int seq;
  final bool applied;
  final String? reason;
}

/// What to do with an incoming change, given the local copy.
enum MergeDecision {
  /// Take the server's version.
  accept,

  /// Keep the local version; it is newer and still unsynced.
  keepLocal,

  /// Both sides changed. Keep both, renaming the incoming one.
  fork,
}

/// Decides how one incoming change meets the local row.
///
/// Last-write-wins on `updatedAt` was rejected in the design for good reason:
/// at whole-notebook granularity it silently destroys a page of handwriting
/// when another device saves a title edit a second later. So a genuine
/// conflict — both sides edited since the last sync — FORKS instead. A user
/// who finds two notebooks can merge them by hand; a user whose ink vanished
/// has no recourse at all.
///
/// [localDirty] is the crux: a clean local row has no unsynced work, so
/// accepting the server's copy cannot lose anything.
MergeDecision decideMerge({
  required bool localExists,
  required bool localDirty,
  required int localUpdatedAt,
  required int remoteUpdatedAt,
}) {
  if (!localExists) return MergeDecision.accept;
  if (!localDirty) {
    // No local work at risk. Accept even when the remote copy is older: it is
    // still a state some device deliberately saved, and the alternative is a
    // device that silently never converges.
    return MergeDecision.accept;
  }
  // Dirty locally AND changed remotely. Identical timestamps are treated as
  // the same save arriving back, not as a conflict.
  if (remoteUpdatedAt == localUpdatedAt) return MergeDecision.keepLocal;
  return MergeDecision.fork;
}

/// Title for the forked copy of a conflicted notebook.
///
/// Names the losing side rather than silently overwriting, so the conflict is
/// visible in the list instead of being something the user discovers later by
/// noticing their work is gone.
String forkedTitle(String title, String deviceLabel) =>
    '$title (conflict from $deviceLabel)';
