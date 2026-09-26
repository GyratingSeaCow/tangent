// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'dump.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$DumpImpl _$$DumpImplFromJson(Map<String, dynamic> json) => _$DumpImpl(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      mode: $enumDecode(_$DumpModeEnumMap, json['mode']),
      durationSeconds: (json['durationSeconds'] as num).toInt(),
      title: json['title'] as String,
      transcript: json['transcript'] as String?,
      audioPath: json['audio_path'] as String,
      audioSizeBytes: (json['audio_size_bytes'] as num).toInt(),
      syncStatus: $enumDecode(_$SyncStatusEnumMap, json['sync_status']),
      syncAttempts: (json['sync_attempts'] as num?)?.toInt() ?? 0,
      lastSyncError: json['last_sync_error'] as String?,
      summary: json['summary'] as String?,
      summaryModel: json['summary_model'] as String?,
      summarizedAt: json['summarized_at'] == null
          ? null
          : DateTime.parse(json['summarized_at'] as String),
      transcriptTimings: json['transcript_timings'] as String?,
    );

Map<String, dynamic> _$$DumpImplToJson(_$DumpImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'createdAt': instance.createdAt.toIso8601String(),
      'updatedAt': instance.updatedAt.toIso8601String(),
      'mode': _$DumpModeEnumMap[instance.mode]!,
      'durationSeconds': instance.durationSeconds,
      'title': instance.title,
      'transcript': instance.transcript,
      'audio_path': instance.audioPath,
      'audio_size_bytes': instance.audioSizeBytes,
      'sync_status': _$SyncStatusEnumMap[instance.syncStatus]!,
      'sync_attempts': instance.syncAttempts,
      'last_sync_error': instance.lastSyncError,
      'summary': instance.summary,
      'summary_model': instance.summaryModel,
      'summarized_at': instance.summarizedAt?.toIso8601String(),
      'transcript_timings': instance.transcriptTimings,
    };

const _$DumpModeEnumMap = {
  DumpMode.brainDump: 'brain_dump',
  DumpMode.meeting: 'meeting',
  DumpMode.textNote: 'text_note',
};

const _$SyncStatusEnumMap = {
  SyncStatus.localOnly: 'local_only',
  SyncStatus.pending: 'pending',
  SyncStatus.syncing: 'syncing',
  SyncStatus.synced: 'synced',
  SyncStatus.failed: 'failed',
};
