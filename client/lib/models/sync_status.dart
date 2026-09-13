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
}