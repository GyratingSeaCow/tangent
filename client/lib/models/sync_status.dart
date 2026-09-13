// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:json_annotation/json_annotation.dart';

/// Sync state of a local dump against the server.
enum SyncStatus {
  @JsonValue('local_only')
  localOnly,
  @JsonValue('pending')
  pending,
  @JsonValue('syncing')
  syncing,
  @JsonValue('synced')
  synced,
  @JsonValue('failed')
  failed;

  /// Wire format used by the Tangent server API.
  String get wireValue => switch (this) {
        SyncStatus.localOnly => 'local_only',
        SyncStatus.pending => 'pending',
        SyncStatus.syncing => 'syncing',
        SyncStatus.synced => 'synced',
        SyncStatus.failed => 'failed',
      };

  static SyncStatus fromWire(String value) {
    return values.firstWhere(
      (s) => s.wireValue == value,
      orElse: () => throw ArgumentError('Unknown SyncStatus: $value'),
    );
  }

  bool get needsUpload =>
      this != SyncStatus.synced && this != SyncStatus.syncing;

  String get displayName => switch (this) {
        SyncStatus.localOnly => 'Local only',
        SyncStatus.pending => 'Pending',
        SyncStatus.syncing => 'Syncing…',
        SyncStatus.synced => 'Synced',
        SyncStatus.failed => 'Failed',
      };
}

/// Extension that re-exports [SyncStatus.fromWire] so callers can use
/// the more discoverable `SyncStatusX.fromWire` form.
extension SyncStatusX on SyncStatus {
  static SyncStatus fromWire(String value) => SyncStatus.fromWire(value);
}