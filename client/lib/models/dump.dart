// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:freezed_annotation/freezed_annotation.dart';

import 'dump_mode.dart';
import 'sync_status.dart';

part 'dump.freezed.dart';
part 'dump.g.dart';

@freezed
class Dump with _$Dump {
  @JsonKey(name: 'mode')
  const factory Dump({
    required String id,
    required DateTime createdAt,
    required DateTime updatedAt,
    required DumpMode mode,
    required int durationSeconds,
    required String title,
    String? transcript,
    @JsonKey(name: 'audio_path') required String audioPath,
    @JsonKey(name: 'audio_size_bytes') required int audioSizeBytes,
    @JsonKey(name: 'sync_status') required SyncStatus syncStatus,
    @JsonKey(name: 'sync_attempts') @Default(0) int syncAttempts,
    @JsonKey(name: 'last_sync_error') String? lastSyncError,
    /// Server-generated AI summary (markdown sections). Null until the
    /// server has summarized this recording; never written by the client.
    String? summary,
    /// The model stem that produced [summary]; null with it.
    @JsonKey(name: 'summary_model') String? summaryModel,
    /// When the server generated [summary]; null with it.
    @JsonKey(name: 'summarized_at') DateTime? summarizedAt,
    /// Word-level timings JSON (server-owned, see transcript_timings.dart).
    /// Null until a transcription with timings has completed.
    @JsonKey(name: 'transcript_timings') String? transcriptTimings,
  }) = _Dump;

  factory Dump.fromJson(Map<String, dynamic> json) => _$DumpFromJson(json);
}