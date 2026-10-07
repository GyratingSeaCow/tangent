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
/// The `device_id` the server writes on changes it authors itself —
/// transcription results, summaries, timings backfills. Mirrors
/// `SERVER_DEVICE_ID` in `server/app/api/dumps.py`.
const String serverDeviceId = 'server';

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
    this.canonicalPayload,
  });

  factory PushResult.fromJson(Map<String, dynamic> json) => PushResult(
    entityId: json['entity_id'] as String? ?? '',
    entityType: json['entity_type'] as String? ?? '',
    seq: (json['seq'] as num?)?.toInt() ?? 0,
    applied: json['status'] == 'applied',
    reason: json['reason'] as String?,
    canonicalPayload: json['canonical_payload'] as Map<String, dynamic>?,
  );

  final String entityId;
  final String entityType;
  final int seq;
  final bool applied;
  final String? reason;

  /// Server-held fields that let a rejected dirty row repair malformed local
  /// verifier metadata before retrying its still-dirty body.
  final Map<String, dynamic>? canonicalPayload;
}

/// What to do with an incoming change, given the local copy.
enum MergeDecision {
  /// Take the server's version.
  accept,

  /// Keep the local version; it is at least as new and still unsynced.
  keepLocal,
}

/// Decides how one incoming change meets the local row.
///
/// A clean local row has no unsynced work, so the server's copy is accepted.
/// On 2026-10-07 Jeff explicitly chose whole-notebook last-write-wins after
/// conflict copies caused mass duplication: the client payload's `updated_at`
/// replaces forking. A strictly newer remote notebook deliberately discards
/// the losing device edit, including ink; legacy conflict copies remain
/// ordinary notebooks for manual cleanup. The server stamps its own row time,
/// but republishes the client's `updated_at`, so this compares peer wall clocks
/// and clock skew can decide the winner.
///
/// Known limitation (pre-existing with forks): if two dirty devices both pull
/// before either pushes, their sequential pushes make both local rows clean;
/// each can then accept the other's payload, swapping contents into a stable
/// split until the next edit. This decision does not fix that crossover.
MergeDecision decideMerge({
  required bool localExists,
  required bool localDirty,
  required int localUpdatedAt,
  required int remoteUpdatedAt,
}) {
  if (!localExists || !localDirty) return MergeDecision.accept;
  return remoteUpdatedAt > localUpdatedAt
      ? MergeDecision.accept
      : MergeDecision.keepLocal;
}
