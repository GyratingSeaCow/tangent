// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_db.dart';

// ignore_for_file: type=lint
class $DumpsTable extends Dumps with TableInfo<$DumpsTable, DumpRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DumpsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _modeMeta = const VerificationMeta('mode');
  @override
  late final GeneratedColumn<String> mode = GeneratedColumn<String>(
      'mode', aliasedName, false,
      additionalChecks:
          GeneratedColumn.checkTextLength(minTextLength: 1, maxTextLength: 20),
      type: DriftSqlType.string,
      requiredDuringInsert: true);
  static const VerificationMeta _durationSecondsMeta =
      const VerificationMeta('durationSeconds');
  @override
  late final GeneratedColumn<int> durationSeconds = GeneratedColumn<int>(
      'duration_seconds', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      additionalChecks:
          GeneratedColumn.checkTextLength(minTextLength: 1, maxTextLength: 500),
      type: DriftSqlType.string,
      requiredDuringInsert: true);
  static const VerificationMeta _transcriptMeta =
      const VerificationMeta('transcript');
  @override
  late final GeneratedColumn<String> transcript = GeneratedColumn<String>(
      'transcript', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _meetingNotesMeta =
      const VerificationMeta('meetingNotes');
  @override
  late final GeneratedColumn<String> meetingNotes = GeneratedColumn<String>(
      'meeting_notes', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _audioPathMeta =
      const VerificationMeta('audioPath');
  @override
  late final GeneratedColumn<String> audioPath = GeneratedColumn<String>(
      'audio_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _audioSizeBytesMeta =
      const VerificationMeta('audioSizeBytes');
  @override
  late final GeneratedColumn<int> audioSizeBytes = GeneratedColumn<int>(
      'audio_size_bytes', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _syncStatusMeta =
      const VerificationMeta('syncStatus');
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
      'sync_status', aliasedName, false,
      additionalChecks:
          GeneratedColumn.checkTextLength(minTextLength: 1, maxTextLength: 20),
      type: DriftSqlType.string,
      requiredDuringInsert: true);
  static const VerificationMeta _syncAttemptsMeta =
      const VerificationMeta('syncAttempts');
  @override
  late final GeneratedColumn<int> syncAttempts = GeneratedColumn<int>(
      'sync_attempts', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastSyncErrorMeta =
      const VerificationMeta('lastSyncError');
  @override
  late final GeneratedColumn<String> lastSyncError = GeneratedColumn<String>(
      'last_sync_error', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _transcriptionStatusMeta =
      const VerificationMeta('transcriptionStatus');
  @override
  late final GeneratedColumn<String> transcriptionStatus =
      GeneratedColumn<String>('transcription_status', aliasedName, false,
          type: DriftSqlType.string,
          requiredDuringInsert: false,
          defaultValue: Constant(TranscriptionStatus.notTranscribed.wireValue));
  static const VerificationMeta _transcriptionRequestIdMeta =
      const VerificationMeta('transcriptionRequestId');
  @override
  late final GeneratedColumn<String> transcriptionRequestId =
      GeneratedColumn<String>('transcription_request_id', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _transcriptionJobIdMeta =
      const VerificationMeta('transcriptionJobId');
  @override
  late final GeneratedColumn<String> transcriptionJobId =
      GeneratedColumn<String>('transcription_job_id', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _transcriptionAttemptMeta =
      const VerificationMeta('transcriptionAttempt');
  @override
  late final GeneratedColumn<int> transcriptionAttempt = GeneratedColumn<int>(
      'transcription_attempt', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _transcriptionStartedAtMeta =
      const VerificationMeta('transcriptionStartedAt');
  @override
  late final GeneratedColumn<DateTime> transcriptionStartedAt =
      GeneratedColumn<DateTime>('transcription_started_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _transcriptionUpdatedAtMeta =
      const VerificationMeta('transcriptionUpdatedAt');
  @override
  late final GeneratedColumn<DateTime> transcriptionUpdatedAt =
      GeneratedColumn<DateTime>('transcription_updated_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _transcriptionCompletedAtMeta =
      const VerificationMeta('transcriptionCompletedAt');
  @override
  late final GeneratedColumn<DateTime> transcriptionCompletedAt =
      GeneratedColumn<DateTime>('transcription_completed_at', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _transcriptionErrorMeta =
      const VerificationMeta('transcriptionError');
  @override
  late final GeneratedColumn<String> transcriptionError =
      GeneratedColumn<String>('transcription_error', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        createdAt,
        updatedAt,
        mode,
        durationSeconds,
        title,
        transcript,
        meetingNotes,
        audioPath,
        audioSizeBytes,
        syncStatus,
        syncAttempts,
        lastSyncError,
        transcriptionStatus,
        transcriptionRequestId,
        transcriptionJobId,
        transcriptionAttempt,
        transcriptionStartedAt,
        transcriptionUpdatedAt,
        transcriptionCompletedAt,
        transcriptionError
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'dumps';
  @override
  VerificationContext validateIntegrity(Insertable<DumpRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('mode')) {
      context.handle(
          _modeMeta, mode.isAcceptableOrUnknown(data['mode']!, _modeMeta));
    } else if (isInserting) {
      context.missing(_modeMeta);
    }
    if (data.containsKey('duration_seconds')) {
      context.handle(
          _durationSecondsMeta,
          durationSeconds.isAcceptableOrUnknown(
              data['duration_seconds']!, _durationSecondsMeta));
    } else if (isInserting) {
      context.missing(_durationSecondsMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('transcript')) {
      context.handle(
          _transcriptMeta,
          transcript.isAcceptableOrUnknown(
              data['transcript']!, _transcriptMeta));
    }
    if (data.containsKey('meeting_notes')) {
      context.handle(
          _meetingNotesMeta,
          meetingNotes.isAcceptableOrUnknown(
              data['meeting_notes']!, _meetingNotesMeta));
    }
    if (data.containsKey('audio_path')) {
      context.handle(_audioPathMeta,
          audioPath.isAcceptableOrUnknown(data['audio_path']!, _audioPathMeta));
    } else if (isInserting) {
      context.missing(_audioPathMeta);
    }
    if (data.containsKey('audio_size_bytes')) {
      context.handle(
          _audioSizeBytesMeta,
          audioSizeBytes.isAcceptableOrUnknown(
              data['audio_size_bytes']!, _audioSizeBytesMeta));
    } else if (isInserting) {
      context.missing(_audioSizeBytesMeta);
    }
    if (data.containsKey('sync_status')) {
      context.handle(
          _syncStatusMeta,
          syncStatus.isAcceptableOrUnknown(
              data['sync_status']!, _syncStatusMeta));
    } else if (isInserting) {
      context.missing(_syncStatusMeta);
    }
    if (data.containsKey('sync_attempts')) {
      context.handle(
          _syncAttemptsMeta,
          syncAttempts.isAcceptableOrUnknown(
              data['sync_attempts']!, _syncAttemptsMeta));
    }
    if (data.containsKey('last_sync_error')) {
      context.handle(
          _lastSyncErrorMeta,
          lastSyncError.isAcceptableOrUnknown(
              data['last_sync_error']!, _lastSyncErrorMeta));
    }
    if (data.containsKey('transcription_status')) {
      context.handle(
          _transcriptionStatusMeta,
          transcriptionStatus.isAcceptableOrUnknown(
              data['transcription_status']!, _transcriptionStatusMeta));
    }
    if (data.containsKey('transcription_request_id')) {
      context.handle(
          _transcriptionRequestIdMeta,
          transcriptionRequestId.isAcceptableOrUnknown(
              data['transcription_request_id']!, _transcriptionRequestIdMeta));
    }
    if (data.containsKey('transcription_job_id')) {
      context.handle(
          _transcriptionJobIdMeta,
          transcriptionJobId.isAcceptableOrUnknown(
              data['transcription_job_id']!, _transcriptionJobIdMeta));
    }
    if (data.containsKey('transcription_attempt')) {
      context.handle(
          _transcriptionAttemptMeta,
          transcriptionAttempt.isAcceptableOrUnknown(
              data['transcription_attempt']!, _transcriptionAttemptMeta));
    }
    if (data.containsKey('transcription_started_at')) {
      context.handle(
          _transcriptionStartedAtMeta,
          transcriptionStartedAt.isAcceptableOrUnknown(
              data['transcription_started_at']!, _transcriptionStartedAtMeta));
    }
    if (data.containsKey('transcription_updated_at')) {
      context.handle(
          _transcriptionUpdatedAtMeta,
          transcriptionUpdatedAt.isAcceptableOrUnknown(
              data['transcription_updated_at']!, _transcriptionUpdatedAtMeta));
    }
    if (data.containsKey('transcription_completed_at')) {
      context.handle(
          _transcriptionCompletedAtMeta,
          transcriptionCompletedAt.isAcceptableOrUnknown(
              data['transcription_completed_at']!,
              _transcriptionCompletedAtMeta));
    }
    if (data.containsKey('transcription_error')) {
      context.handle(
          _transcriptionErrorMeta,
          transcriptionError.isAcceptableOrUnknown(
              data['transcription_error']!, _transcriptionErrorMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DumpRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DumpRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
      mode: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}mode'])!,
      durationSeconds: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}duration_seconds'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      transcript: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}transcript']),
      meetingNotes: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}meeting_notes']),
      audioPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}audio_path'])!,
      audioSizeBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}audio_size_bytes'])!,
      syncStatus: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}sync_status'])!,
      syncAttempts: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sync_attempts'])!,
      lastSyncError: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}last_sync_error']),
      transcriptionStatus: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}transcription_status'])!,
      transcriptionRequestId: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}transcription_request_id']),
      transcriptionJobId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}transcription_job_id']),
      transcriptionAttempt: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}transcription_attempt'])!,
      transcriptionStartedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime,
          data['${effectivePrefix}transcription_started_at']),
      transcriptionUpdatedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime,
          data['${effectivePrefix}transcription_updated_at']),
      transcriptionCompletedAt: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime,
          data['${effectivePrefix}transcription_completed_at']),
      transcriptionError: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}transcription_error']),
    );
  }

  @override
  $DumpsTable createAlias(String alias) {
    return $DumpsTable(attachedDatabase, alias);
  }
}

class DumpRow extends DataClass implements Insertable<DumpRow> {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String mode;
  final int durationSeconds;
  final String title;
  final String? transcript;
  final String? meetingNotes;
  final String audioPath;
  final int audioSizeBytes;
  final String syncStatus;
  final int syncAttempts;
  final String? lastSyncError;
  final String transcriptionStatus;
  final String? transcriptionRequestId;
  final String? transcriptionJobId;
  final int transcriptionAttempt;
  final DateTime? transcriptionStartedAt;
  final DateTime? transcriptionUpdatedAt;
  final DateTime? transcriptionCompletedAt;
  final String? transcriptionError;
  const DumpRow(
      {required this.id,
      required this.createdAt,
      required this.updatedAt,
      required this.mode,
      required this.durationSeconds,
      required this.title,
      this.transcript,
      this.meetingNotes,
      required this.audioPath,
      required this.audioSizeBytes,
      required this.syncStatus,
      required this.syncAttempts,
      this.lastSyncError,
      required this.transcriptionStatus,
      this.transcriptionRequestId,
      this.transcriptionJobId,
      required this.transcriptionAttempt,
      this.transcriptionStartedAt,
      this.transcriptionUpdatedAt,
      this.transcriptionCompletedAt,
      this.transcriptionError});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['mode'] = Variable<String>(mode);
    map['duration_seconds'] = Variable<int>(durationSeconds);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || transcript != null) {
      map['transcript'] = Variable<String>(transcript);
    }
    if (!nullToAbsent || meetingNotes != null) {
      map['meeting_notes'] = Variable<String>(meetingNotes);
    }
    map['audio_path'] = Variable<String>(audioPath);
    map['audio_size_bytes'] = Variable<int>(audioSizeBytes);
    map['sync_status'] = Variable<String>(syncStatus);
    map['sync_attempts'] = Variable<int>(syncAttempts);
    if (!nullToAbsent || lastSyncError != null) {
      map['last_sync_error'] = Variable<String>(lastSyncError);
    }
    map['transcription_status'] = Variable<String>(transcriptionStatus);
    if (!nullToAbsent || transcriptionRequestId != null) {
      map['transcription_request_id'] =
          Variable<String>(transcriptionRequestId);
    }
    if (!nullToAbsent || transcriptionJobId != null) {
      map['transcription_job_id'] = Variable<String>(transcriptionJobId);
    }
    map['transcription_attempt'] = Variable<int>(transcriptionAttempt);
    if (!nullToAbsent || transcriptionStartedAt != null) {
      map['transcription_started_at'] =
          Variable<DateTime>(transcriptionStartedAt);
    }
    if (!nullToAbsent || transcriptionUpdatedAt != null) {
      map['transcription_updated_at'] =
          Variable<DateTime>(transcriptionUpdatedAt);
    }
    if (!nullToAbsent || transcriptionCompletedAt != null) {
      map['transcription_completed_at'] =
          Variable<DateTime>(transcriptionCompletedAt);
    }
    if (!nullToAbsent || transcriptionError != null) {
      map['transcription_error'] = Variable<String>(transcriptionError);
    }
    return map;
  }

  DumpsCompanion toCompanion(bool nullToAbsent) {
    return DumpsCompanion(
      id: Value(id),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      mode: Value(mode),
      durationSeconds: Value(durationSeconds),
      title: Value(title),
      transcript: transcript == null && nullToAbsent
          ? const Value.absent()
          : Value(transcript),
      meetingNotes: meetingNotes == null && nullToAbsent
          ? const Value.absent()
          : Value(meetingNotes),
      audioPath: Value(audioPath),
      audioSizeBytes: Value(audioSizeBytes),
      syncStatus: Value(syncStatus),
      syncAttempts: Value(syncAttempts),
      lastSyncError: lastSyncError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncError),
      transcriptionStatus: Value(transcriptionStatus),
      transcriptionRequestId: transcriptionRequestId == null && nullToAbsent
          ? const Value.absent()
          : Value(transcriptionRequestId),
      transcriptionJobId: transcriptionJobId == null && nullToAbsent
          ? const Value.absent()
          : Value(transcriptionJobId),
      transcriptionAttempt: Value(transcriptionAttempt),
      transcriptionStartedAt: transcriptionStartedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(transcriptionStartedAt),
      transcriptionUpdatedAt: transcriptionUpdatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(transcriptionUpdatedAt),
      transcriptionCompletedAt: transcriptionCompletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(transcriptionCompletedAt),
      transcriptionError: transcriptionError == null && nullToAbsent
          ? const Value.absent()
          : Value(transcriptionError),
    );
  }

  factory DumpRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DumpRow(
      id: serializer.fromJson<String>(json['id']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      mode: serializer.fromJson<String>(json['mode']),
      durationSeconds: serializer.fromJson<int>(json['durationSeconds']),
      title: serializer.fromJson<String>(json['title']),
      transcript: serializer.fromJson<String?>(json['transcript']),
      meetingNotes: serializer.fromJson<String?>(json['meetingNotes']),
      audioPath: serializer.fromJson<String>(json['audioPath']),
      audioSizeBytes: serializer.fromJson<int>(json['audioSizeBytes']),
      syncStatus: serializer.fromJson<String>(json['syncStatus']),
      syncAttempts: serializer.fromJson<int>(json['syncAttempts']),
      lastSyncError: serializer.fromJson<String?>(json['lastSyncError']),
      transcriptionStatus:
          serializer.fromJson<String>(json['transcriptionStatus']),
      transcriptionRequestId:
          serializer.fromJson<String?>(json['transcriptionRequestId']),
      transcriptionJobId:
          serializer.fromJson<String?>(json['transcriptionJobId']),
      transcriptionAttempt:
          serializer.fromJson<int>(json['transcriptionAttempt']),
      transcriptionStartedAt:
          serializer.fromJson<DateTime?>(json['transcriptionStartedAt']),
      transcriptionUpdatedAt:
          serializer.fromJson<DateTime?>(json['transcriptionUpdatedAt']),
      transcriptionCompletedAt:
          serializer.fromJson<DateTime?>(json['transcriptionCompletedAt']),
      transcriptionError:
          serializer.fromJson<String?>(json['transcriptionError']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'mode': serializer.toJson<String>(mode),
      'durationSeconds': serializer.toJson<int>(durationSeconds),
      'title': serializer.toJson<String>(title),
      'transcript': serializer.toJson<String?>(transcript),
      'meetingNotes': serializer.toJson<String?>(meetingNotes),
      'audioPath': serializer.toJson<String>(audioPath),
      'audioSizeBytes': serializer.toJson<int>(audioSizeBytes),
      'syncStatus': serializer.toJson<String>(syncStatus),
      'syncAttempts': serializer.toJson<int>(syncAttempts),
      'lastSyncError': serializer.toJson<String?>(lastSyncError),
      'transcriptionStatus': serializer.toJson<String>(transcriptionStatus),
      'transcriptionRequestId':
          serializer.toJson<String?>(transcriptionRequestId),
      'transcriptionJobId': serializer.toJson<String?>(transcriptionJobId),
      'transcriptionAttempt': serializer.toJson<int>(transcriptionAttempt),
      'transcriptionStartedAt':
          serializer.toJson<DateTime?>(transcriptionStartedAt),
      'transcriptionUpdatedAt':
          serializer.toJson<DateTime?>(transcriptionUpdatedAt),
      'transcriptionCompletedAt':
          serializer.toJson<DateTime?>(transcriptionCompletedAt),
      'transcriptionError': serializer.toJson<String?>(transcriptionError),
    };
  }

  DumpRow copyWith(
          {String? id,
          DateTime? createdAt,
          DateTime? updatedAt,
          String? mode,
          int? durationSeconds,
          String? title,
          Value<String?> transcript = const Value.absent(),
          Value<String?> meetingNotes = const Value.absent(),
          String? audioPath,
          int? audioSizeBytes,
          String? syncStatus,
          int? syncAttempts,
          Value<String?> lastSyncError = const Value.absent(),
          String? transcriptionStatus,
          Value<String?> transcriptionRequestId = const Value.absent(),
          Value<String?> transcriptionJobId = const Value.absent(),
          int? transcriptionAttempt,
          Value<DateTime?> transcriptionStartedAt = const Value.absent(),
          Value<DateTime?> transcriptionUpdatedAt = const Value.absent(),
          Value<DateTime?> transcriptionCompletedAt = const Value.absent(),
          Value<String?> transcriptionError = const Value.absent()}) =>
      DumpRow(
        id: id ?? this.id,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        mode: mode ?? this.mode,
        durationSeconds: durationSeconds ?? this.durationSeconds,
        title: title ?? this.title,
        transcript: transcript.present ? transcript.value : this.transcript,
        meetingNotes:
            meetingNotes.present ? meetingNotes.value : this.meetingNotes,
        audioPath: audioPath ?? this.audioPath,
        audioSizeBytes: audioSizeBytes ?? this.audioSizeBytes,
        syncStatus: syncStatus ?? this.syncStatus,
        syncAttempts: syncAttempts ?? this.syncAttempts,
        lastSyncError:
            lastSyncError.present ? lastSyncError.value : this.lastSyncError,
        transcriptionStatus: transcriptionStatus ?? this.transcriptionStatus,
        transcriptionRequestId: transcriptionRequestId.present
            ? transcriptionRequestId.value
            : this.transcriptionRequestId,
        transcriptionJobId: transcriptionJobId.present
            ? transcriptionJobId.value
            : this.transcriptionJobId,
        transcriptionAttempt: transcriptionAttempt ?? this.transcriptionAttempt,
        transcriptionStartedAt: transcriptionStartedAt.present
            ? transcriptionStartedAt.value
            : this.transcriptionStartedAt,
        transcriptionUpdatedAt: transcriptionUpdatedAt.present
            ? transcriptionUpdatedAt.value
            : this.transcriptionUpdatedAt,
        transcriptionCompletedAt: transcriptionCompletedAt.present
            ? transcriptionCompletedAt.value
            : this.transcriptionCompletedAt,
        transcriptionError: transcriptionError.present
            ? transcriptionError.value
            : this.transcriptionError,
      );
  DumpRow copyWithCompanion(DumpsCompanion data) {
    return DumpRow(
      id: data.id.present ? data.id.value : this.id,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      mode: data.mode.present ? data.mode.value : this.mode,
      durationSeconds: data.durationSeconds.present
          ? data.durationSeconds.value
          : this.durationSeconds,
      title: data.title.present ? data.title.value : this.title,
      transcript:
          data.transcript.present ? data.transcript.value : this.transcript,
      meetingNotes: data.meetingNotes.present
          ? data.meetingNotes.value
          : this.meetingNotes,
      audioPath: data.audioPath.present ? data.audioPath.value : this.audioPath,
      audioSizeBytes: data.audioSizeBytes.present
          ? data.audioSizeBytes.value
          : this.audioSizeBytes,
      syncStatus:
          data.syncStatus.present ? data.syncStatus.value : this.syncStatus,
      syncAttempts: data.syncAttempts.present
          ? data.syncAttempts.value
          : this.syncAttempts,
      lastSyncError: data.lastSyncError.present
          ? data.lastSyncError.value
          : this.lastSyncError,
      transcriptionStatus: data.transcriptionStatus.present
          ? data.transcriptionStatus.value
          : this.transcriptionStatus,
      transcriptionRequestId: data.transcriptionRequestId.present
          ? data.transcriptionRequestId.value
          : this.transcriptionRequestId,
      transcriptionJobId: data.transcriptionJobId.present
          ? data.transcriptionJobId.value
          : this.transcriptionJobId,
      transcriptionAttempt: data.transcriptionAttempt.present
          ? data.transcriptionAttempt.value
          : this.transcriptionAttempt,
      transcriptionStartedAt: data.transcriptionStartedAt.present
          ? data.transcriptionStartedAt.value
          : this.transcriptionStartedAt,
      transcriptionUpdatedAt: data.transcriptionUpdatedAt.present
          ? data.transcriptionUpdatedAt.value
          : this.transcriptionUpdatedAt,
      transcriptionCompletedAt: data.transcriptionCompletedAt.present
          ? data.transcriptionCompletedAt.value
          : this.transcriptionCompletedAt,
      transcriptionError: data.transcriptionError.present
          ? data.transcriptionError.value
          : this.transcriptionError,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DumpRow(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('mode: $mode, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('title: $title, ')
          ..write('transcript: $transcript, ')
          ..write('meetingNotes: $meetingNotes, ')
          ..write('audioPath: $audioPath, ')
          ..write('audioSizeBytes: $audioSizeBytes, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('syncAttempts: $syncAttempts, ')
          ..write('lastSyncError: $lastSyncError, ')
          ..write('transcriptionStatus: $transcriptionStatus, ')
          ..write('transcriptionRequestId: $transcriptionRequestId, ')
          ..write('transcriptionJobId: $transcriptionJobId, ')
          ..write('transcriptionAttempt: $transcriptionAttempt, ')
          ..write('transcriptionStartedAt: $transcriptionStartedAt, ')
          ..write('transcriptionUpdatedAt: $transcriptionUpdatedAt, ')
          ..write('transcriptionCompletedAt: $transcriptionCompletedAt, ')
          ..write('transcriptionError: $transcriptionError')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
        id,
        createdAt,
        updatedAt,
        mode,
        durationSeconds,
        title,
        transcript,
        meetingNotes,
        audioPath,
        audioSizeBytes,
        syncStatus,
        syncAttempts,
        lastSyncError,
        transcriptionStatus,
        transcriptionRequestId,
        transcriptionJobId,
        transcriptionAttempt,
        transcriptionStartedAt,
        transcriptionUpdatedAt,
        transcriptionCompletedAt,
        transcriptionError
      ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DumpRow &&
          other.id == this.id &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.mode == this.mode &&
          other.durationSeconds == this.durationSeconds &&
          other.title == this.title &&
          other.transcript == this.transcript &&
          other.meetingNotes == this.meetingNotes &&
          other.audioPath == this.audioPath &&
          other.audioSizeBytes == this.audioSizeBytes &&
          other.syncStatus == this.syncStatus &&
          other.syncAttempts == this.syncAttempts &&
          other.lastSyncError == this.lastSyncError &&
          other.transcriptionStatus == this.transcriptionStatus &&
          other.transcriptionRequestId == this.transcriptionRequestId &&
          other.transcriptionJobId == this.transcriptionJobId &&
          other.transcriptionAttempt == this.transcriptionAttempt &&
          other.transcriptionStartedAt == this.transcriptionStartedAt &&
          other.transcriptionUpdatedAt == this.transcriptionUpdatedAt &&
          other.transcriptionCompletedAt == this.transcriptionCompletedAt &&
          other.transcriptionError == this.transcriptionError);
}

class DumpsCompanion extends UpdateCompanion<DumpRow> {
  final Value<String> id;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<String> mode;
  final Value<int> durationSeconds;
  final Value<String> title;
  final Value<String?> transcript;
  final Value<String?> meetingNotes;
  final Value<String> audioPath;
  final Value<int> audioSizeBytes;
  final Value<String> syncStatus;
  final Value<int> syncAttempts;
  final Value<String?> lastSyncError;
  final Value<String> transcriptionStatus;
  final Value<String?> transcriptionRequestId;
  final Value<String?> transcriptionJobId;
  final Value<int> transcriptionAttempt;
  final Value<DateTime?> transcriptionStartedAt;
  final Value<DateTime?> transcriptionUpdatedAt;
  final Value<DateTime?> transcriptionCompletedAt;
  final Value<String?> transcriptionError;
  final Value<int> rowid;
  const DumpsCompanion({
    this.id = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.mode = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.title = const Value.absent(),
    this.transcript = const Value.absent(),
    this.meetingNotes = const Value.absent(),
    this.audioPath = const Value.absent(),
    this.audioSizeBytes = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.syncAttempts = const Value.absent(),
    this.lastSyncError = const Value.absent(),
    this.transcriptionStatus = const Value.absent(),
    this.transcriptionRequestId = const Value.absent(),
    this.transcriptionJobId = const Value.absent(),
    this.transcriptionAttempt = const Value.absent(),
    this.transcriptionStartedAt = const Value.absent(),
    this.transcriptionUpdatedAt = const Value.absent(),
    this.transcriptionCompletedAt = const Value.absent(),
    this.transcriptionError = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DumpsCompanion.insert({
    required String id,
    required DateTime createdAt,
    required DateTime updatedAt,
    required String mode,
    required int durationSeconds,
    required String title,
    this.transcript = const Value.absent(),
    this.meetingNotes = const Value.absent(),
    required String audioPath,
    required int audioSizeBytes,
    required String syncStatus,
    this.syncAttempts = const Value.absent(),
    this.lastSyncError = const Value.absent(),
    this.transcriptionStatus = const Value.absent(),
    this.transcriptionRequestId = const Value.absent(),
    this.transcriptionJobId = const Value.absent(),
    this.transcriptionAttempt = const Value.absent(),
    this.transcriptionStartedAt = const Value.absent(),
    this.transcriptionUpdatedAt = const Value.absent(),
    this.transcriptionCompletedAt = const Value.absent(),
    this.transcriptionError = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        createdAt = Value(createdAt),
        updatedAt = Value(updatedAt),
        mode = Value(mode),
        durationSeconds = Value(durationSeconds),
        title = Value(title),
        audioPath = Value(audioPath),
        audioSizeBytes = Value(audioSizeBytes),
        syncStatus = Value(syncStatus);
  static Insertable<DumpRow> custom({
    Expression<String>? id,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<String>? mode,
    Expression<int>? durationSeconds,
    Expression<String>? title,
    Expression<String>? transcript,
    Expression<String>? meetingNotes,
    Expression<String>? audioPath,
    Expression<int>? audioSizeBytes,
    Expression<String>? syncStatus,
    Expression<int>? syncAttempts,
    Expression<String>? lastSyncError,
    Expression<String>? transcriptionStatus,
    Expression<String>? transcriptionRequestId,
    Expression<String>? transcriptionJobId,
    Expression<int>? transcriptionAttempt,
    Expression<DateTime>? transcriptionStartedAt,
    Expression<DateTime>? transcriptionUpdatedAt,
    Expression<DateTime>? transcriptionCompletedAt,
    Expression<String>? transcriptionError,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (mode != null) 'mode': mode,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
      if (title != null) 'title': title,
      if (transcript != null) 'transcript': transcript,
      if (meetingNotes != null) 'meeting_notes': meetingNotes,
      if (audioPath != null) 'audio_path': audioPath,
      if (audioSizeBytes != null) 'audio_size_bytes': audioSizeBytes,
      if (syncStatus != null) 'sync_status': syncStatus,
      if (syncAttempts != null) 'sync_attempts': syncAttempts,
      if (lastSyncError != null) 'last_sync_error': lastSyncError,
      if (transcriptionStatus != null)
        'transcription_status': transcriptionStatus,
      if (transcriptionRequestId != null)
        'transcription_request_id': transcriptionRequestId,
      if (transcriptionJobId != null)
        'transcription_job_id': transcriptionJobId,
      if (transcriptionAttempt != null)
        'transcription_attempt': transcriptionAttempt,
      if (transcriptionStartedAt != null)
        'transcription_started_at': transcriptionStartedAt,
      if (transcriptionUpdatedAt != null)
        'transcription_updated_at': transcriptionUpdatedAt,
      if (transcriptionCompletedAt != null)
        'transcription_completed_at': transcriptionCompletedAt,
      if (transcriptionError != null) 'transcription_error': transcriptionError,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DumpsCompanion copyWith(
      {Value<String>? id,
      Value<DateTime>? createdAt,
      Value<DateTime>? updatedAt,
      Value<String>? mode,
      Value<int>? durationSeconds,
      Value<String>? title,
      Value<String?>? transcript,
      Value<String?>? meetingNotes,
      Value<String>? audioPath,
      Value<int>? audioSizeBytes,
      Value<String>? syncStatus,
      Value<int>? syncAttempts,
      Value<String?>? lastSyncError,
      Value<String>? transcriptionStatus,
      Value<String?>? transcriptionRequestId,
      Value<String?>? transcriptionJobId,
      Value<int>? transcriptionAttempt,
      Value<DateTime?>? transcriptionStartedAt,
      Value<DateTime?>? transcriptionUpdatedAt,
      Value<DateTime?>? transcriptionCompletedAt,
      Value<String?>? transcriptionError,
      Value<int>? rowid}) {
    return DumpsCompanion(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      mode: mode ?? this.mode,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      title: title ?? this.title,
      transcript: transcript ?? this.transcript,
      meetingNotes: meetingNotes ?? this.meetingNotes,
      audioPath: audioPath ?? this.audioPath,
      audioSizeBytes: audioSizeBytes ?? this.audioSizeBytes,
      syncStatus: syncStatus ?? this.syncStatus,
      syncAttempts: syncAttempts ?? this.syncAttempts,
      lastSyncError: lastSyncError ?? this.lastSyncError,
      transcriptionStatus: transcriptionStatus ?? this.transcriptionStatus,
      transcriptionRequestId:
          transcriptionRequestId ?? this.transcriptionRequestId,
      transcriptionJobId: transcriptionJobId ?? this.transcriptionJobId,
      transcriptionAttempt: transcriptionAttempt ?? this.transcriptionAttempt,
      transcriptionStartedAt:
          transcriptionStartedAt ?? this.transcriptionStartedAt,
      transcriptionUpdatedAt:
          transcriptionUpdatedAt ?? this.transcriptionUpdatedAt,
      transcriptionCompletedAt:
          transcriptionCompletedAt ?? this.transcriptionCompletedAt,
      transcriptionError: transcriptionError ?? this.transcriptionError,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (mode.present) {
      map['mode'] = Variable<String>(mode.value);
    }
    if (durationSeconds.present) {
      map['duration_seconds'] = Variable<int>(durationSeconds.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (transcript.present) {
      map['transcript'] = Variable<String>(transcript.value);
    }
    if (meetingNotes.present) {
      map['meeting_notes'] = Variable<String>(meetingNotes.value);
    }
    if (audioPath.present) {
      map['audio_path'] = Variable<String>(audioPath.value);
    }
    if (audioSizeBytes.present) {
      map['audio_size_bytes'] = Variable<int>(audioSizeBytes.value);
    }
    if (syncStatus.present) {
      map['sync_status'] = Variable<String>(syncStatus.value);
    }
    if (syncAttempts.present) {
      map['sync_attempts'] = Variable<int>(syncAttempts.value);
    }
    if (lastSyncError.present) {
      map['last_sync_error'] = Variable<String>(lastSyncError.value);
    }
    if (transcriptionStatus.present) {
      map['transcription_status'] = Variable<String>(transcriptionStatus.value);
    }
    if (transcriptionRequestId.present) {
      map['transcription_request_id'] =
          Variable<String>(transcriptionRequestId.value);
    }
    if (transcriptionJobId.present) {
      map['transcription_job_id'] = Variable<String>(transcriptionJobId.value);
    }
    if (transcriptionAttempt.present) {
      map['transcription_attempt'] = Variable<int>(transcriptionAttempt.value);
    }
    if (transcriptionStartedAt.present) {
      map['transcription_started_at'] =
          Variable<DateTime>(transcriptionStartedAt.value);
    }
    if (transcriptionUpdatedAt.present) {
      map['transcription_updated_at'] =
          Variable<DateTime>(transcriptionUpdatedAt.value);
    }
    if (transcriptionCompletedAt.present) {
      map['transcription_completed_at'] =
          Variable<DateTime>(transcriptionCompletedAt.value);
    }
    if (transcriptionError.present) {
      map['transcription_error'] = Variable<String>(transcriptionError.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DumpsCompanion(')
          ..write('id: $id, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('mode: $mode, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('title: $title, ')
          ..write('transcript: $transcript, ')
          ..write('meetingNotes: $meetingNotes, ')
          ..write('audioPath: $audioPath, ')
          ..write('audioSizeBytes: $audioSizeBytes, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('syncAttempts: $syncAttempts, ')
          ..write('lastSyncError: $lastSyncError, ')
          ..write('transcriptionStatus: $transcriptionStatus, ')
          ..write('transcriptionRequestId: $transcriptionRequestId, ')
          ..write('transcriptionJobId: $transcriptionJobId, ')
          ..write('transcriptionAttempt: $transcriptionAttempt, ')
          ..write('transcriptionStartedAt: $transcriptionStartedAt, ')
          ..write('transcriptionUpdatedAt: $transcriptionUpdatedAt, ')
          ..write('transcriptionCompletedAt: $transcriptionCompletedAt, ')
          ..write('transcriptionError: $transcriptionError, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncQueueTable extends SyncQueue
    with TableInfo<$SyncQueueTable, SyncQueueRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncQueueTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _dumpIdMeta = const VerificationMeta('dumpId');
  @override
  late final GeneratedColumn<String> dumpId = GeneratedColumn<String>(
      'dump_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: true,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'REFERENCES dumps (id) ON DELETE CASCADE'));
  static const VerificationMeta _queuedAtMeta =
      const VerificationMeta('queuedAt');
  @override
  late final GeneratedColumn<DateTime> queuedAt = GeneratedColumn<DateTime>(
      'queued_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, dumpId, queuedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_queue';
  @override
  VerificationContext validateIntegrity(Insertable<SyncQueueRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('dump_id')) {
      context.handle(_dumpIdMeta,
          dumpId.isAcceptableOrUnknown(data['dump_id']!, _dumpIdMeta));
    } else if (isInserting) {
      context.missing(_dumpIdMeta);
    }
    if (data.containsKey('queued_at')) {
      context.handle(_queuedAtMeta,
          queuedAt.isAcceptableOrUnknown(data['queued_at']!, _queuedAtMeta));
    } else if (isInserting) {
      context.missing(_queuedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncQueueRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncQueueRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      dumpId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}dump_id'])!,
      queuedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}queued_at'])!,
    );
  }

  @override
  $SyncQueueTable createAlias(String alias) {
    return $SyncQueueTable(attachedDatabase, alias);
  }
}

class SyncQueueRow extends DataClass implements Insertable<SyncQueueRow> {
  final int id;
  final String dumpId;
  final DateTime queuedAt;
  const SyncQueueRow(
      {required this.id, required this.dumpId, required this.queuedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['dump_id'] = Variable<String>(dumpId);
    map['queued_at'] = Variable<DateTime>(queuedAt);
    return map;
  }

  SyncQueueCompanion toCompanion(bool nullToAbsent) {
    return SyncQueueCompanion(
      id: Value(id),
      dumpId: Value(dumpId),
      queuedAt: Value(queuedAt),
    );
  }

  factory SyncQueueRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncQueueRow(
      id: serializer.fromJson<int>(json['id']),
      dumpId: serializer.fromJson<String>(json['dumpId']),
      queuedAt: serializer.fromJson<DateTime>(json['queuedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'dumpId': serializer.toJson<String>(dumpId),
      'queuedAt': serializer.toJson<DateTime>(queuedAt),
    };
  }

  SyncQueueRow copyWith({int? id, String? dumpId, DateTime? queuedAt}) =>
      SyncQueueRow(
        id: id ?? this.id,
        dumpId: dumpId ?? this.dumpId,
        queuedAt: queuedAt ?? this.queuedAt,
      );
  SyncQueueRow copyWithCompanion(SyncQueueCompanion data) {
    return SyncQueueRow(
      id: data.id.present ? data.id.value : this.id,
      dumpId: data.dumpId.present ? data.dumpId.value : this.dumpId,
      queuedAt: data.queuedAt.present ? data.queuedAt.value : this.queuedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncQueueRow(')
          ..write('id: $id, ')
          ..write('dumpId: $dumpId, ')
          ..write('queuedAt: $queuedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, dumpId, queuedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncQueueRow &&
          other.id == this.id &&
          other.dumpId == this.dumpId &&
          other.queuedAt == this.queuedAt);
}

class SyncQueueCompanion extends UpdateCompanion<SyncQueueRow> {
  final Value<int> id;
  final Value<String> dumpId;
  final Value<DateTime> queuedAt;
  const SyncQueueCompanion({
    this.id = const Value.absent(),
    this.dumpId = const Value.absent(),
    this.queuedAt = const Value.absent(),
  });
  SyncQueueCompanion.insert({
    this.id = const Value.absent(),
    required String dumpId,
    required DateTime queuedAt,
  })  : dumpId = Value(dumpId),
        queuedAt = Value(queuedAt);
  static Insertable<SyncQueueRow> custom({
    Expression<int>? id,
    Expression<String>? dumpId,
    Expression<DateTime>? queuedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (dumpId != null) 'dump_id': dumpId,
      if (queuedAt != null) 'queued_at': queuedAt,
    });
  }

  SyncQueueCompanion copyWith(
      {Value<int>? id, Value<String>? dumpId, Value<DateTime>? queuedAt}) {
    return SyncQueueCompanion(
      id: id ?? this.id,
      dumpId: dumpId ?? this.dumpId,
      queuedAt: queuedAt ?? this.queuedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (dumpId.present) {
      map['dump_id'] = Variable<String>(dumpId.value);
    }
    if (queuedAt.present) {
      map['queued_at'] = Variable<DateTime>(queuedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncQueueCompanion(')
          ..write('id: $id, ')
          ..write('dumpId: $dumpId, ')
          ..write('queuedAt: $queuedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$LocalDb extends GeneratedDatabase {
  _$LocalDb(QueryExecutor e) : super(e);
  $LocalDbManager get managers => $LocalDbManager(this);
  late final $DumpsTable dumps = $DumpsTable(this);
  late final $SyncQueueTable syncQueue = $SyncQueueTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [dumps, syncQueue];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules(
        [
          WritePropagation(
            on: TableUpdateQuery.onTableName('dumps',
                limitUpdateKind: UpdateKind.delete),
            result: [
              TableUpdate('sync_queue', kind: UpdateKind.delete),
            ],
          ),
        ],
      );
}

typedef $$DumpsTableCreateCompanionBuilder = DumpsCompanion Function({
  required String id,
  required DateTime createdAt,
  required DateTime updatedAt,
  required String mode,
  required int durationSeconds,
  required String title,
  Value<String?> transcript,
  Value<String?> meetingNotes,
  required String audioPath,
  required int audioSizeBytes,
  required String syncStatus,
  Value<int> syncAttempts,
  Value<String?> lastSyncError,
  Value<String> transcriptionStatus,
  Value<String?> transcriptionRequestId,
  Value<String?> transcriptionJobId,
  Value<int> transcriptionAttempt,
  Value<DateTime?> transcriptionStartedAt,
  Value<DateTime?> transcriptionUpdatedAt,
  Value<DateTime?> transcriptionCompletedAt,
  Value<String?> transcriptionError,
  Value<int> rowid,
});
typedef $$DumpsTableUpdateCompanionBuilder = DumpsCompanion Function({
  Value<String> id,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<String> mode,
  Value<int> durationSeconds,
  Value<String> title,
  Value<String?> transcript,
  Value<String?> meetingNotes,
  Value<String> audioPath,
  Value<int> audioSizeBytes,
  Value<String> syncStatus,
  Value<int> syncAttempts,
  Value<String?> lastSyncError,
  Value<String> transcriptionStatus,
  Value<String?> transcriptionRequestId,
  Value<String?> transcriptionJobId,
  Value<int> transcriptionAttempt,
  Value<DateTime?> transcriptionStartedAt,
  Value<DateTime?> transcriptionUpdatedAt,
  Value<DateTime?> transcriptionCompletedAt,
  Value<String?> transcriptionError,
  Value<int> rowid,
});

final class $$DumpsTableReferences
    extends BaseReferences<_$LocalDb, $DumpsTable, DumpRow> {
  $$DumpsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$SyncQueueTable, List<SyncQueueRow>>
      _syncQueueRefsTable(_$LocalDb db) => MultiTypedResultKey.fromTable(
          db.syncQueue,
          aliasName: $_aliasNameGenerator(db.dumps.id, db.syncQueue.dumpId));

  $$SyncQueueTableProcessedTableManager get syncQueueRefs {
    final manager = $$SyncQueueTableTableManager($_db, $_db.syncQueue)
        .filter((f) => f.dumpId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_syncQueueRefsTable($_db));
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$DumpsTableFilterComposer extends Composer<_$LocalDb, $DumpsTable> {
  $$DumpsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mode => $composableBuilder(
      column: $table.mode, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durationSeconds => $composableBuilder(
      column: $table.durationSeconds,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get transcript => $composableBuilder(
      column: $table.transcript, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get meetingNotes => $composableBuilder(
      column: $table.meetingNotes, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get audioPath => $composableBuilder(
      column: $table.audioPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get audioSizeBytes => $composableBuilder(
      column: $table.audioSizeBytes,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get syncAttempts => $composableBuilder(
      column: $table.syncAttempts, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get lastSyncError => $composableBuilder(
      column: $table.lastSyncError, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get transcriptionStatus => $composableBuilder(
      column: $table.transcriptionStatus,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get transcriptionRequestId => $composableBuilder(
      column: $table.transcriptionRequestId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get transcriptionJobId => $composableBuilder(
      column: $table.transcriptionJobId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get transcriptionAttempt => $composableBuilder(
      column: $table.transcriptionAttempt,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get transcriptionStartedAt => $composableBuilder(
      column: $table.transcriptionStartedAt,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get transcriptionUpdatedAt => $composableBuilder(
      column: $table.transcriptionUpdatedAt,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get transcriptionCompletedAt => $composableBuilder(
      column: $table.transcriptionCompletedAt,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get transcriptionError => $composableBuilder(
      column: $table.transcriptionError,
      builder: (column) => ColumnFilters(column));

  Expression<bool> syncQueueRefs(
      Expression<bool> Function($$SyncQueueTableFilterComposer f) f) {
    final $$SyncQueueTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.syncQueue,
        getReferencedColumn: (t) => t.dumpId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncQueueTableFilterComposer(
              $db: $db,
              $table: $db.syncQueue,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$DumpsTableOrderingComposer extends Composer<_$LocalDb, $DumpsTable> {
  $$DumpsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mode => $composableBuilder(
      column: $table.mode, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durationSeconds => $composableBuilder(
      column: $table.durationSeconds,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get transcript => $composableBuilder(
      column: $table.transcript, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get meetingNotes => $composableBuilder(
      column: $table.meetingNotes,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get audioPath => $composableBuilder(
      column: $table.audioPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get audioSizeBytes => $composableBuilder(
      column: $table.audioSizeBytes,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get syncAttempts => $composableBuilder(
      column: $table.syncAttempts,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get lastSyncError => $composableBuilder(
      column: $table.lastSyncError,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get transcriptionStatus => $composableBuilder(
      column: $table.transcriptionStatus,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get transcriptionRequestId => $composableBuilder(
      column: $table.transcriptionRequestId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get transcriptionJobId => $composableBuilder(
      column: $table.transcriptionJobId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get transcriptionAttempt => $composableBuilder(
      column: $table.transcriptionAttempt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get transcriptionStartedAt => $composableBuilder(
      column: $table.transcriptionStartedAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get transcriptionUpdatedAt => $composableBuilder(
      column: $table.transcriptionUpdatedAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get transcriptionCompletedAt => $composableBuilder(
      column: $table.transcriptionCompletedAt,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get transcriptionError => $composableBuilder(
      column: $table.transcriptionError,
      builder: (column) => ColumnOrderings(column));
}

class $$DumpsTableAnnotationComposer extends Composer<_$LocalDb, $DumpsTable> {
  $$DumpsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get mode =>
      $composableBuilder(column: $table.mode, builder: (column) => column);

  GeneratedColumn<int> get durationSeconds => $composableBuilder(
      column: $table.durationSeconds, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get transcript => $composableBuilder(
      column: $table.transcript, builder: (column) => column);

  GeneratedColumn<String> get meetingNotes => $composableBuilder(
      column: $table.meetingNotes, builder: (column) => column);

  GeneratedColumn<String> get audioPath =>
      $composableBuilder(column: $table.audioPath, builder: (column) => column);

  GeneratedColumn<int> get audioSizeBytes => $composableBuilder(
      column: $table.audioSizeBytes, builder: (column) => column);

  GeneratedColumn<String> get syncStatus => $composableBuilder(
      column: $table.syncStatus, builder: (column) => column);

  GeneratedColumn<int> get syncAttempts => $composableBuilder(
      column: $table.syncAttempts, builder: (column) => column);

  GeneratedColumn<String> get lastSyncError => $composableBuilder(
      column: $table.lastSyncError, builder: (column) => column);

  GeneratedColumn<String> get transcriptionStatus => $composableBuilder(
      column: $table.transcriptionStatus, builder: (column) => column);

  GeneratedColumn<String> get transcriptionRequestId => $composableBuilder(
      column: $table.transcriptionRequestId, builder: (column) => column);

  GeneratedColumn<String> get transcriptionJobId => $composableBuilder(
      column: $table.transcriptionJobId, builder: (column) => column);

  GeneratedColumn<int> get transcriptionAttempt => $composableBuilder(
      column: $table.transcriptionAttempt, builder: (column) => column);

  GeneratedColumn<DateTime> get transcriptionStartedAt => $composableBuilder(
      column: $table.transcriptionStartedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get transcriptionUpdatedAt => $composableBuilder(
      column: $table.transcriptionUpdatedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get transcriptionCompletedAt => $composableBuilder(
      column: $table.transcriptionCompletedAt, builder: (column) => column);

  GeneratedColumn<String> get transcriptionError => $composableBuilder(
      column: $table.transcriptionError, builder: (column) => column);

  Expression<T> syncQueueRefs<T extends Object>(
      Expression<T> Function($$SyncQueueTableAnnotationComposer a) f) {
    final $$SyncQueueTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.id,
        referencedTable: $db.syncQueue,
        getReferencedColumn: (t) => t.dumpId,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$SyncQueueTableAnnotationComposer(
              $db: $db,
              $table: $db.syncQueue,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return f(composer);
  }
}

class $$DumpsTableTableManager extends RootTableManager<
    _$LocalDb,
    $DumpsTable,
    DumpRow,
    $$DumpsTableFilterComposer,
    $$DumpsTableOrderingComposer,
    $$DumpsTableAnnotationComposer,
    $$DumpsTableCreateCompanionBuilder,
    $$DumpsTableUpdateCompanionBuilder,
    (DumpRow, $$DumpsTableReferences),
    DumpRow,
    PrefetchHooks Function({bool syncQueueRefs})> {
  $$DumpsTableTableManager(_$LocalDb db, $DumpsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DumpsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DumpsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DumpsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<String> mode = const Value.absent(),
            Value<int> durationSeconds = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String?> transcript = const Value.absent(),
            Value<String?> meetingNotes = const Value.absent(),
            Value<String> audioPath = const Value.absent(),
            Value<int> audioSizeBytes = const Value.absent(),
            Value<String> syncStatus = const Value.absent(),
            Value<int> syncAttempts = const Value.absent(),
            Value<String?> lastSyncError = const Value.absent(),
            Value<String> transcriptionStatus = const Value.absent(),
            Value<String?> transcriptionRequestId = const Value.absent(),
            Value<String?> transcriptionJobId = const Value.absent(),
            Value<int> transcriptionAttempt = const Value.absent(),
            Value<DateTime?> transcriptionStartedAt = const Value.absent(),
            Value<DateTime?> transcriptionUpdatedAt = const Value.absent(),
            Value<DateTime?> transcriptionCompletedAt = const Value.absent(),
            Value<String?> transcriptionError = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DumpsCompanion(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            mode: mode,
            durationSeconds: durationSeconds,
            title: title,
            transcript: transcript,
            meetingNotes: meetingNotes,
            audioPath: audioPath,
            audioSizeBytes: audioSizeBytes,
            syncStatus: syncStatus,
            syncAttempts: syncAttempts,
            lastSyncError: lastSyncError,
            transcriptionStatus: transcriptionStatus,
            transcriptionRequestId: transcriptionRequestId,
            transcriptionJobId: transcriptionJobId,
            transcriptionAttempt: transcriptionAttempt,
            transcriptionStartedAt: transcriptionStartedAt,
            transcriptionUpdatedAt: transcriptionUpdatedAt,
            transcriptionCompletedAt: transcriptionCompletedAt,
            transcriptionError: transcriptionError,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required DateTime createdAt,
            required DateTime updatedAt,
            required String mode,
            required int durationSeconds,
            required String title,
            Value<String?> transcript = const Value.absent(),
            Value<String?> meetingNotes = const Value.absent(),
            required String audioPath,
            required int audioSizeBytes,
            required String syncStatus,
            Value<int> syncAttempts = const Value.absent(),
            Value<String?> lastSyncError = const Value.absent(),
            Value<String> transcriptionStatus = const Value.absent(),
            Value<String?> transcriptionRequestId = const Value.absent(),
            Value<String?> transcriptionJobId = const Value.absent(),
            Value<int> transcriptionAttempt = const Value.absent(),
            Value<DateTime?> transcriptionStartedAt = const Value.absent(),
            Value<DateTime?> transcriptionUpdatedAt = const Value.absent(),
            Value<DateTime?> transcriptionCompletedAt = const Value.absent(),
            Value<String?> transcriptionError = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              DumpsCompanion.insert(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            mode: mode,
            durationSeconds: durationSeconds,
            title: title,
            transcript: transcript,
            meetingNotes: meetingNotes,
            audioPath: audioPath,
            audioSizeBytes: audioSizeBytes,
            syncStatus: syncStatus,
            syncAttempts: syncAttempts,
            lastSyncError: lastSyncError,
            transcriptionStatus: transcriptionStatus,
            transcriptionRequestId: transcriptionRequestId,
            transcriptionJobId: transcriptionJobId,
            transcriptionAttempt: transcriptionAttempt,
            transcriptionStartedAt: transcriptionStartedAt,
            transcriptionUpdatedAt: transcriptionUpdatedAt,
            transcriptionCompletedAt: transcriptionCompletedAt,
            transcriptionError: transcriptionError,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) =>
                  (e.readTable(table), $$DumpsTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({syncQueueRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (syncQueueRefs) db.syncQueue],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (syncQueueRefs)
                    await $_getPrefetchedData<DumpRow, $DumpsTable,
                            SyncQueueRow>(
                        currentTable: table,
                        referencedTable:
                            $$DumpsTableReferences._syncQueueRefsTable(db),
                        managerFromTypedResult: (p0) =>
                            $$DumpsTableReferences(db, table, p0).syncQueueRefs,
                        referencedItemsForCurrentItem: (item,
                                referencedItems) =>
                            referencedItems.where((e) => e.dumpId == item.id),
                        typedResults: items)
                ];
              },
            );
          },
        ));
}

typedef $$DumpsTableProcessedTableManager = ProcessedTableManager<
    _$LocalDb,
    $DumpsTable,
    DumpRow,
    $$DumpsTableFilterComposer,
    $$DumpsTableOrderingComposer,
    $$DumpsTableAnnotationComposer,
    $$DumpsTableCreateCompanionBuilder,
    $$DumpsTableUpdateCompanionBuilder,
    (DumpRow, $$DumpsTableReferences),
    DumpRow,
    PrefetchHooks Function({bool syncQueueRefs})>;
typedef $$SyncQueueTableCreateCompanionBuilder = SyncQueueCompanion Function({
  Value<int> id,
  required String dumpId,
  required DateTime queuedAt,
});
typedef $$SyncQueueTableUpdateCompanionBuilder = SyncQueueCompanion Function({
  Value<int> id,
  Value<String> dumpId,
  Value<DateTime> queuedAt,
});

final class $$SyncQueueTableReferences
    extends BaseReferences<_$LocalDb, $SyncQueueTable, SyncQueueRow> {
  $$SyncQueueTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $DumpsTable _dumpIdTable(_$LocalDb db) => db.dumps
      .createAlias($_aliasNameGenerator(db.syncQueue.dumpId, db.dumps.id));

  $$DumpsTableProcessedTableManager get dumpId {
    final $_column = $_itemColumn<String>('dump_id')!;

    final manager = $$DumpsTableTableManager($_db, $_db.dumps)
        .filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_dumpIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
        manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$SyncQueueTableFilterComposer
    extends Composer<_$LocalDb, $SyncQueueTable> {
  $$SyncQueueTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get queuedAt => $composableBuilder(
      column: $table.queuedAt, builder: (column) => ColumnFilters(column));

  $$DumpsTableFilterComposer get dumpId {
    final $$DumpsTableFilterComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.dumpId,
        referencedTable: $db.dumps,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$DumpsTableFilterComposer(
              $db: $db,
              $table: $db.dumps,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$SyncQueueTableOrderingComposer
    extends Composer<_$LocalDb, $SyncQueueTable> {
  $$SyncQueueTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get queuedAt => $composableBuilder(
      column: $table.queuedAt, builder: (column) => ColumnOrderings(column));

  $$DumpsTableOrderingComposer get dumpId {
    final $$DumpsTableOrderingComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.dumpId,
        referencedTable: $db.dumps,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$DumpsTableOrderingComposer(
              $db: $db,
              $table: $db.dumps,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$SyncQueueTableAnnotationComposer
    extends Composer<_$LocalDb, $SyncQueueTable> {
  $$SyncQueueTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<DateTime> get queuedAt =>
      $composableBuilder(column: $table.queuedAt, builder: (column) => column);

  $$DumpsTableAnnotationComposer get dumpId {
    final $$DumpsTableAnnotationComposer composer = $composerBuilder(
        composer: this,
        getCurrentColumn: (t) => t.dumpId,
        referencedTable: $db.dumps,
        getReferencedColumn: (t) => t.id,
        builder: (joinBuilder,
                {$addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer}) =>
            $$DumpsTableAnnotationComposer(
              $db: $db,
              $table: $db.dumps,
              $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
              joinBuilder: joinBuilder,
              $removeJoinBuilderFromRootComposer:
                  $removeJoinBuilderFromRootComposer,
            ));
    return composer;
  }
}

class $$SyncQueueTableTableManager extends RootTableManager<
    _$LocalDb,
    $SyncQueueTable,
    SyncQueueRow,
    $$SyncQueueTableFilterComposer,
    $$SyncQueueTableOrderingComposer,
    $$SyncQueueTableAnnotationComposer,
    $$SyncQueueTableCreateCompanionBuilder,
    $$SyncQueueTableUpdateCompanionBuilder,
    (SyncQueueRow, $$SyncQueueTableReferences),
    SyncQueueRow,
    PrefetchHooks Function({bool dumpId})> {
  $$SyncQueueTableTableManager(_$LocalDb db, $SyncQueueTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncQueueTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncQueueTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncQueueTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> dumpId = const Value.absent(),
            Value<DateTime> queuedAt = const Value.absent(),
          }) =>
              SyncQueueCompanion(
            id: id,
            dumpId: dumpId,
            queuedAt: queuedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String dumpId,
            required DateTime queuedAt,
          }) =>
              SyncQueueCompanion.insert(
            id: id,
            dumpId: dumpId,
            queuedAt: queuedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (
                    e.readTable(table),
                    $$SyncQueueTableReferences(db, table, e)
                  ))
              .toList(),
          prefetchHooksCallback: ({dumpId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins: <
                  T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic>>(state) {
                if (dumpId) {
                  state = state.withJoin(
                    currentTable: table,
                    currentColumn: table.dumpId,
                    referencedTable:
                        $$SyncQueueTableReferences._dumpIdTable(db),
                    referencedColumn:
                        $$SyncQueueTableReferences._dumpIdTable(db).id,
                  ) as T;
                }

                return state;
              },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ));
}

typedef $$SyncQueueTableProcessedTableManager = ProcessedTableManager<
    _$LocalDb,
    $SyncQueueTable,
    SyncQueueRow,
    $$SyncQueueTableFilterComposer,
    $$SyncQueueTableOrderingComposer,
    $$SyncQueueTableAnnotationComposer,
    $$SyncQueueTableCreateCompanionBuilder,
    $$SyncQueueTableUpdateCompanionBuilder,
    (SyncQueueRow, $$SyncQueueTableReferences),
    SyncQueueRow,
    PrefetchHooks Function({bool dumpId})>;

class $LocalDbManager {
  final _$LocalDb _db;
  $LocalDbManager(this._db);
  $$DumpsTableTableManager get dumps =>
      $$DumpsTableTableManager(_db, _db.dumps);
  $$SyncQueueTableTableManager get syncQueue =>
      $$SyncQueueTableTableManager(_db, _db.syncQueue);
}
