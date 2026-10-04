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
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modeMeta = const VerificationMeta('mode');
  @override
  late final GeneratedColumn<String> mode = GeneratedColumn<String>(
    'mode',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 20,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationSecondsMeta = const VerificationMeta(
    'durationSeconds',
  );
  @override
  late final GeneratedColumn<int> durationSeconds = GeneratedColumn<int>(
    'duration_seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 500,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _transcriptMeta = const VerificationMeta(
    'transcript',
  );
  @override
  late final GeneratedColumn<String> transcript = GeneratedColumn<String>(
    'transcript',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _meetingNotesMeta = const VerificationMeta(
    'meetingNotes',
  );
  @override
  late final GeneratedColumn<String> meetingNotes = GeneratedColumn<String>(
    'meeting_notes',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _audioPathMeta = const VerificationMeta(
    'audioPath',
  );
  @override
  late final GeneratedColumn<String> audioPath = GeneratedColumn<String>(
    'audio_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _audioSizeBytesMeta = const VerificationMeta(
    'audioSizeBytes',
  );
  @override
  late final GeneratedColumn<int> audioSizeBytes = GeneratedColumn<int>(
    'audio_size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _syncStatusMeta = const VerificationMeta(
    'syncStatus',
  );
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
    'sync_status',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 20,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _syncAttemptsMeta = const VerificationMeta(
    'syncAttempts',
  );
  @override
  late final GeneratedColumn<int> syncAttempts = GeneratedColumn<int>(
    'sync_attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastSyncErrorMeta = const VerificationMeta(
    'lastSyncError',
  );
  @override
  late final GeneratedColumn<String> lastSyncError = GeneratedColumn<String>(
    'last_sync_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _transcriptionStatusMeta =
      const VerificationMeta('transcriptionStatus');
  @override
  late final GeneratedColumn<String> transcriptionStatus =
      GeneratedColumn<String>(
        'transcription_status',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: Constant(TranscriptionStatus.notTranscribed.wireValue),
      );
  static const VerificationMeta _transcriptionRequestIdMeta =
      const VerificationMeta('transcriptionRequestId');
  @override
  late final GeneratedColumn<String> transcriptionRequestId =
      GeneratedColumn<String>(
        'transcription_request_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _transcriptionJobIdMeta =
      const VerificationMeta('transcriptionJobId');
  @override
  late final GeneratedColumn<String> transcriptionJobId =
      GeneratedColumn<String>(
        'transcription_job_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _transcriptionAttemptMeta =
      const VerificationMeta('transcriptionAttempt');
  @override
  late final GeneratedColumn<int> transcriptionAttempt = GeneratedColumn<int>(
    'transcription_attempt',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _transcriptionStartedAtMeta =
      const VerificationMeta('transcriptionStartedAt');
  @override
  late final GeneratedColumn<DateTime> transcriptionStartedAt =
      GeneratedColumn<DateTime>(
        'transcription_started_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _transcriptionUpdatedAtMeta =
      const VerificationMeta('transcriptionUpdatedAt');
  @override
  late final GeneratedColumn<DateTime> transcriptionUpdatedAt =
      GeneratedColumn<DateTime>(
        'transcription_updated_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _transcriptionCompletedAtMeta =
      const VerificationMeta('transcriptionCompletedAt');
  @override
  late final GeneratedColumn<DateTime> transcriptionCompletedAt =
      GeneratedColumn<DateTime>(
        'transcription_completed_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _transcriptionErrorMeta =
      const VerificationMeta('transcriptionError');
  @override
  late final GeneratedColumn<String> transcriptionError =
      GeneratedColumn<String>(
        'transcription_error',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _folderIdMeta = const VerificationMeta(
    'folderId',
  );
  @override
  late final GeneratedColumn<String> folderId = GeneratedColumn<String>(
    'folder_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _autoFiledAtMeta = const VerificationMeta(
    'autoFiledAt',
  );
  @override
  late final GeneratedColumn<int> autoFiledAt = GeneratedColumn<int>(
    'auto_filed_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _autoFilePrevFolderIdMeta =
      const VerificationMeta('autoFilePrevFolderId');
  @override
  late final GeneratedColumn<String> autoFilePrevFolderId =
      GeneratedColumn<String>(
        'auto_file_prev_folder_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _syncDirtyMeta = const VerificationMeta(
    'syncDirty',
  );
  @override
  late final GeneratedColumn<bool> syncDirty = GeneratedColumn<bool>(
    'sync_dirty',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("sync_dirty" IN (0, 1))',
    ),
  );
  static const VerificationMeta _syncedSeqMeta = const VerificationMeta(
    'syncedSeq',
  );
  @override
  late final GeneratedColumn<int> syncedSeq = GeneratedColumn<int>(
    'synced_seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _remoteOnlyMeta = const VerificationMeta(
    'remoteOnly',
  );
  @override
  late final GeneratedColumn<bool> remoteOnly = GeneratedColumn<bool>(
    'remote_only',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("remote_only" IN (0, 1))',
    ),
  );
  static const VerificationMeta _audioOnServerMeta = const VerificationMeta(
    'audioOnServer',
  );
  @override
  late final GeneratedColumn<bool> audioOnServer = GeneratedColumn<bool>(
    'audio_on_server',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("audio_on_server" IN (0, 1))',
    ),
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryModelMeta = const VerificationMeta(
    'summaryModel',
  );
  @override
  late final GeneratedColumn<String> summaryModel = GeneratedColumn<String>(
    'summary_model',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summarizedAtMeta = const VerificationMeta(
    'summarizedAt',
  );
  @override
  late final GeneratedColumn<int> summarizedAt = GeneratedColumn<int>(
    'summarized_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _transcriptTimingsMeta = const VerificationMeta(
    'transcriptTimings',
  );
  @override
  late final GeneratedColumn<String> transcriptTimings =
      GeneratedColumn<String>(
        'transcript_timings',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _summaryTemplateMeta = const VerificationMeta(
    'summaryTemplate',
  );
  @override
  late final GeneratedColumn<String> summaryTemplate = GeneratedColumn<String>(
    'summary_template',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _speakerNamesMeta = const VerificationMeta(
    'speakerNames',
  );
  @override
  late final GeneratedColumn<String> speakerNames = GeneratedColumn<String>(
    'speaker_names',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryRequestedAtMeta =
      const VerificationMeta('summaryRequestedAt');
  @override
  late final GeneratedColumn<int> summaryRequestedAt = GeneratedColumn<int>(
    'summary_requested_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _languageMeta = const VerificationMeta(
    'language',
  );
  @override
  late final GeneratedColumn<String> language = GeneratedColumn<String>(
    'language',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _translatedMeta = const VerificationMeta(
    'translated',
  );
  @override
  late final GeneratedColumn<bool> translated = GeneratedColumn<bool>(
    'translated',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("translated" IN (0, 1))',
    ),
  );
  static const VerificationMeta _summaryStatusMeta = const VerificationMeta(
    'summaryStatus',
  );
  @override
  late final GeneratedColumn<String> summaryStatus = GeneratedColumn<String>(
    'summary_status',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryErrorMeta = const VerificationMeta(
    'summaryError',
  );
  @override
  late final GeneratedColumn<String> summaryError = GeneratedColumn<String>(
    'summary_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryQueuePositionMeta =
      const VerificationMeta('summaryQueuePosition');
  @override
  late final GeneratedColumn<int> summaryQueuePosition = GeneratedColumn<int>(
    'summary_queue_position',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryErrorDismissedAtMeta =
      const VerificationMeta('summaryErrorDismissedAt');
  @override
  late final GeneratedColumn<int> summaryErrorDismissedAt =
      GeneratedColumn<int>(
        'summary_error_dismissed_at',
        aliasedName,
        true,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  @override
  late final GeneratedColumn<bool> pinned = GeneratedColumn<bool>(
    'pinned',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pinned" IN (0, 1))',
    ),
  );
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
    transcriptionError,
    folderId,
    autoFiledAt,
    autoFilePrevFolderId,
    syncDirty,
    syncedSeq,
    remoteOnly,
    audioOnServer,
    summary,
    summaryModel,
    summarizedAt,
    transcriptTimings,
    summaryTemplate,
    speakerNames,
    summaryRequestedAt,
    language,
    translated,
    summaryStatus,
    summaryError,
    summaryQueuePosition,
    summaryErrorDismissedAt,
    pinned,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'dumps';
  @override
  VerificationContext validateIntegrity(
    Insertable<DumpRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('mode')) {
      context.handle(
        _modeMeta,
        mode.isAcceptableOrUnknown(data['mode']!, _modeMeta),
      );
    } else if (isInserting) {
      context.missing(_modeMeta);
    }
    if (data.containsKey('duration_seconds')) {
      context.handle(
        _durationSecondsMeta,
        durationSeconds.isAcceptableOrUnknown(
          data['duration_seconds']!,
          _durationSecondsMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_durationSecondsMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('transcript')) {
      context.handle(
        _transcriptMeta,
        transcript.isAcceptableOrUnknown(data['transcript']!, _transcriptMeta),
      );
    }
    if (data.containsKey('meeting_notes')) {
      context.handle(
        _meetingNotesMeta,
        meetingNotes.isAcceptableOrUnknown(
          data['meeting_notes']!,
          _meetingNotesMeta,
        ),
      );
    }
    if (data.containsKey('audio_path')) {
      context.handle(
        _audioPathMeta,
        audioPath.isAcceptableOrUnknown(data['audio_path']!, _audioPathMeta),
      );
    } else if (isInserting) {
      context.missing(_audioPathMeta);
    }
    if (data.containsKey('audio_size_bytes')) {
      context.handle(
        _audioSizeBytesMeta,
        audioSizeBytes.isAcceptableOrUnknown(
          data['audio_size_bytes']!,
          _audioSizeBytesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_audioSizeBytesMeta);
    }
    if (data.containsKey('sync_status')) {
      context.handle(
        _syncStatusMeta,
        syncStatus.isAcceptableOrUnknown(data['sync_status']!, _syncStatusMeta),
      );
    } else if (isInserting) {
      context.missing(_syncStatusMeta);
    }
    if (data.containsKey('sync_attempts')) {
      context.handle(
        _syncAttemptsMeta,
        syncAttempts.isAcceptableOrUnknown(
          data['sync_attempts']!,
          _syncAttemptsMeta,
        ),
      );
    }
    if (data.containsKey('last_sync_error')) {
      context.handle(
        _lastSyncErrorMeta,
        lastSyncError.isAcceptableOrUnknown(
          data['last_sync_error']!,
          _lastSyncErrorMeta,
        ),
      );
    }
    if (data.containsKey('transcription_status')) {
      context.handle(
        _transcriptionStatusMeta,
        transcriptionStatus.isAcceptableOrUnknown(
          data['transcription_status']!,
          _transcriptionStatusMeta,
        ),
      );
    }
    if (data.containsKey('transcription_request_id')) {
      context.handle(
        _transcriptionRequestIdMeta,
        transcriptionRequestId.isAcceptableOrUnknown(
          data['transcription_request_id']!,
          _transcriptionRequestIdMeta,
        ),
      );
    }
    if (data.containsKey('transcription_job_id')) {
      context.handle(
        _transcriptionJobIdMeta,
        transcriptionJobId.isAcceptableOrUnknown(
          data['transcription_job_id']!,
          _transcriptionJobIdMeta,
        ),
      );
    }
    if (data.containsKey('transcription_attempt')) {
      context.handle(
        _transcriptionAttemptMeta,
        transcriptionAttempt.isAcceptableOrUnknown(
          data['transcription_attempt']!,
          _transcriptionAttemptMeta,
        ),
      );
    }
    if (data.containsKey('transcription_started_at')) {
      context.handle(
        _transcriptionStartedAtMeta,
        transcriptionStartedAt.isAcceptableOrUnknown(
          data['transcription_started_at']!,
          _transcriptionStartedAtMeta,
        ),
      );
    }
    if (data.containsKey('transcription_updated_at')) {
      context.handle(
        _transcriptionUpdatedAtMeta,
        transcriptionUpdatedAt.isAcceptableOrUnknown(
          data['transcription_updated_at']!,
          _transcriptionUpdatedAtMeta,
        ),
      );
    }
    if (data.containsKey('transcription_completed_at')) {
      context.handle(
        _transcriptionCompletedAtMeta,
        transcriptionCompletedAt.isAcceptableOrUnknown(
          data['transcription_completed_at']!,
          _transcriptionCompletedAtMeta,
        ),
      );
    }
    if (data.containsKey('transcription_error')) {
      context.handle(
        _transcriptionErrorMeta,
        transcriptionError.isAcceptableOrUnknown(
          data['transcription_error']!,
          _transcriptionErrorMeta,
        ),
      );
    }
    if (data.containsKey('folder_id')) {
      context.handle(
        _folderIdMeta,
        folderId.isAcceptableOrUnknown(data['folder_id']!, _folderIdMeta),
      );
    }
    if (data.containsKey('auto_filed_at')) {
      context.handle(
        _autoFiledAtMeta,
        autoFiledAt.isAcceptableOrUnknown(
          data['auto_filed_at']!,
          _autoFiledAtMeta,
        ),
      );
    }
    if (data.containsKey('auto_file_prev_folder_id')) {
      context.handle(
        _autoFilePrevFolderIdMeta,
        autoFilePrevFolderId.isAcceptableOrUnknown(
          data['auto_file_prev_folder_id']!,
          _autoFilePrevFolderIdMeta,
        ),
      );
    }
    if (data.containsKey('sync_dirty')) {
      context.handle(
        _syncDirtyMeta,
        syncDirty.isAcceptableOrUnknown(data['sync_dirty']!, _syncDirtyMeta),
      );
    }
    if (data.containsKey('synced_seq')) {
      context.handle(
        _syncedSeqMeta,
        syncedSeq.isAcceptableOrUnknown(data['synced_seq']!, _syncedSeqMeta),
      );
    }
    if (data.containsKey('remote_only')) {
      context.handle(
        _remoteOnlyMeta,
        remoteOnly.isAcceptableOrUnknown(data['remote_only']!, _remoteOnlyMeta),
      );
    }
    if (data.containsKey('audio_on_server')) {
      context.handle(
        _audioOnServerMeta,
        audioOnServer.isAcceptableOrUnknown(
          data['audio_on_server']!,
          _audioOnServerMeta,
        ),
      );
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    }
    if (data.containsKey('summary_model')) {
      context.handle(
        _summaryModelMeta,
        summaryModel.isAcceptableOrUnknown(
          data['summary_model']!,
          _summaryModelMeta,
        ),
      );
    }
    if (data.containsKey('summarized_at')) {
      context.handle(
        _summarizedAtMeta,
        summarizedAt.isAcceptableOrUnknown(
          data['summarized_at']!,
          _summarizedAtMeta,
        ),
      );
    }
    if (data.containsKey('transcript_timings')) {
      context.handle(
        _transcriptTimingsMeta,
        transcriptTimings.isAcceptableOrUnknown(
          data['transcript_timings']!,
          _transcriptTimingsMeta,
        ),
      );
    }
    if (data.containsKey('summary_template')) {
      context.handle(
        _summaryTemplateMeta,
        summaryTemplate.isAcceptableOrUnknown(
          data['summary_template']!,
          _summaryTemplateMeta,
        ),
      );
    }
    if (data.containsKey('speaker_names')) {
      context.handle(
        _speakerNamesMeta,
        speakerNames.isAcceptableOrUnknown(
          data['speaker_names']!,
          _speakerNamesMeta,
        ),
      );
    }
    if (data.containsKey('summary_requested_at')) {
      context.handle(
        _summaryRequestedAtMeta,
        summaryRequestedAt.isAcceptableOrUnknown(
          data['summary_requested_at']!,
          _summaryRequestedAtMeta,
        ),
      );
    }
    if (data.containsKey('language')) {
      context.handle(
        _languageMeta,
        language.isAcceptableOrUnknown(data['language']!, _languageMeta),
      );
    }
    if (data.containsKey('translated')) {
      context.handle(
        _translatedMeta,
        translated.isAcceptableOrUnknown(data['translated']!, _translatedMeta),
      );
    }
    if (data.containsKey('summary_status')) {
      context.handle(
        _summaryStatusMeta,
        summaryStatus.isAcceptableOrUnknown(
          data['summary_status']!,
          _summaryStatusMeta,
        ),
      );
    }
    if (data.containsKey('summary_error')) {
      context.handle(
        _summaryErrorMeta,
        summaryError.isAcceptableOrUnknown(
          data['summary_error']!,
          _summaryErrorMeta,
        ),
      );
    }
    if (data.containsKey('summary_queue_position')) {
      context.handle(
        _summaryQueuePositionMeta,
        summaryQueuePosition.isAcceptableOrUnknown(
          data['summary_queue_position']!,
          _summaryQueuePositionMeta,
        ),
      );
    }
    if (data.containsKey('summary_error_dismissed_at')) {
      context.handle(
        _summaryErrorDismissedAtMeta,
        summaryErrorDismissedAt.isAcceptableOrUnknown(
          data['summary_error_dismissed_at']!,
          _summaryErrorDismissedAtMeta,
        ),
      );
    }
    if (data.containsKey('pinned')) {
      context.handle(
        _pinnedMeta,
        pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DumpRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DumpRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      mode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mode'],
      )!,
      durationSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_seconds'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      transcript: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}transcript'],
      ),
      meetingNotes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}meeting_notes'],
      ),
      audioPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}audio_path'],
      )!,
      audioSizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}audio_size_bytes'],
      )!,
      syncStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sync_status'],
      )!,
      syncAttempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sync_attempts'],
      )!,
      lastSyncError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_sync_error'],
      ),
      transcriptionStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}transcription_status'],
      )!,
      transcriptionRequestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}transcription_request_id'],
      ),
      transcriptionJobId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}transcription_job_id'],
      ),
      transcriptionAttempt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}transcription_attempt'],
      )!,
      transcriptionStartedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}transcription_started_at'],
      ),
      transcriptionUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}transcription_updated_at'],
      ),
      transcriptionCompletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}transcription_completed_at'],
      ),
      transcriptionError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}transcription_error'],
      ),
      folderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder_id'],
      ),
      autoFiledAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}auto_filed_at'],
      ),
      autoFilePrevFolderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}auto_file_prev_folder_id'],
      ),
      syncDirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}sync_dirty'],
      ),
      syncedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_seq'],
      ),
      remoteOnly: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}remote_only'],
      ),
      audioOnServer: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}audio_on_server'],
      ),
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      ),
      summaryModel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary_model'],
      ),
      summarizedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}summarized_at'],
      ),
      transcriptTimings: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}transcript_timings'],
      ),
      summaryTemplate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary_template'],
      ),
      speakerNames: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}speaker_names'],
      ),
      summaryRequestedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}summary_requested_at'],
      ),
      language: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}language'],
      ),
      translated: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}translated'],
      ),
      summaryStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary_status'],
      ),
      summaryError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary_error'],
      ),
      summaryQueuePosition: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}summary_queue_position'],
      ),
      summaryErrorDismissedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}summary_error_dismissed_at'],
      ),
      pinned: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pinned'],
      ),
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

  /// Which folder this recording or note is filed in, or null when unfiled.
  /// Same metadata approach as notebooks: filing never moves the audio file.
  /// v1.38: filing travels with the dump payload (null means unfiled), so a
  /// move syncs across devices exactly like a notebook or to-do filing.
  final String? folderId;

  /// v1.38 auto-file (server-authored, server→client only): unix seconds
  /// when the SERVER filed this capture after transcription, and the filing
  /// it replaced (null = it was unfiled). While [autoFiledAt] is set the
  /// card shows the `Auto-filed to … · Undo` chip; an undo or any manual
  /// re-file clears both here and, via the pushed filing, on the server.
  final int? autoFiledAt;
  final String? autoFilePrevFolderId;

  /// Sync state, mirroring the notebook columns. [syncDirty] means this row
  /// has local metadata edits the server has not accepted yet; [syncedSeq]
  /// is the change_log checkpoint the server assigned when it did.
  /// Nullable so adding these columns does not force every existing
  /// construction site (141 of them, nearly all tests) to name a value that
  /// is only meaningful to the sync engine. Null reads as "not dirty",
  /// exactly how every row behaved before recording sync existed.
  final bool? syncDirty;
  final int? syncedSeq;

  /// True when this row arrived from another device and its audio (if any)
  /// has not been downloaded here. The audio lives on the server; the user
  /// fetches it explicitly. A remote row keeps [audioPath] empty rather than
  /// naming a file this device does not have.
  final bool? remoteOnly;

  /// True when the SERVER holds this recording's audio, so a device without
  /// the bytes can offer to download them. Comes from the peer's payload,
  /// not from anything local.
  final bool? audioOnServer;

  /// Server-generated AI summary (markdown sections), or null when none has
  /// been generated. These three columns flow server→client ONLY: they
  /// arrive inside pulled dump payloads, the client never writes its own
  /// values and never pushes them (the server ignores client-sent summary
  /// keys anyway). Nullable because every dump predating v17 has none.
  final String? summary;

  /// The exact GGUF model stem that produced [summary]; null with it.
  final String? summaryModel;

  /// Unix seconds when the server generated [summary]; null with it.
  final int? summarizedAt;

  /// Word-level transcript timings (JSON, see transcript_timings.dart),
  /// server-owned and server→client only like the summary columns. Null
  /// until a transcription with timings completes; the server nulls it
  /// when a re-transcription starts so stale timings never outlive their
  /// transcript. Backs "tap a word, hear that moment".
  final String? transcriptTimings;

  /// The summary template id the server last summarized this dump with
  /// ('meeting', 'brain_dump', 'lecture', 'actions_only', 'custom'), or null
  /// when the server has only ever applied the mode default. Server-owned
  /// and server→client only like the summary columns: the client chooses a
  /// template by POSTing /v1/dumps/{id}/summarize and the server persists
  /// it, so the client never writes or pushes this column itself.
  final String? summaryTemplate;

  /// Per-recording speaker name map (v1.17.0, spec §1): the JSON object
  /// `{"Speaker 1":"Jeff"}` as text, or null when no speaker is named.
  /// Device-authored — it rides the push payload next to [title] and
  /// competes on [updatedAt] like every other user edit. The transcript
  /// text keeps its raw `## Speaker N` labels; surfaces render through
  /// the map (`renderSpeakerNames`).
  final String? speakerNames;

  /// Unix seconds when THIS device last asked the server to (re)summarize
  /// (the summarize POST returned 202). LOCAL-ONLY: never pushed, never
  /// read from a pull. Drives the "summary in progress" strip: pending
  /// while newer than [summarizedAt] and under ten minutes old, cleared
  /// by [LocalDb.applyRemoteDump] the moment a summary at least that new
  /// syncs down. Null when nothing was ever requested from here.
  final int? summaryRequestedAt;

  /// ISO 639-1 code Whisper detected for the audio (v1.19.0 Part A), e.g.
  /// 'es'; null until the first transcription lands. SERVER-authored: only
  /// ever set from a pull, never in the push payload.
  final String? language;

  /// True when the stored transcript is an English TRANSLATION of the audio
  /// (the job ran with `translate`). Server-authored like [language]; null
  /// reads as false (the column is nullable so the generated row class does
  /// not force every constructor to name it; the wire value is 0/1).
  final bool? translated;

  /// Server-side summary job state (v1.19.0 Part B): 'queued', 'running',
  /// 'failed', or null for idle/done. Server-authored, pull only.
  final String? summaryStatus;

  /// Short human reason when [summaryStatus] is 'failed'. Server-authored.
  final String? summaryError;

  /// 1-based place in the server's summary queue, only while 'queued'.
  /// Server-authored.
  final int? summaryQueuePosition;

  /// Unix seconds when the user dismissed the 'Summary failed' line on THIS
  /// device. LOCAL-ONLY: never pushed, never read from a pull. Cleared by
  /// [LocalDb.applyRemoteDump] when the summary succeeds or a new attempt
  /// starts, so the line returns on the next failure.
  final int? summaryErrorDismissedAt;

  /// User pin. Nullable so every pre-v30 row keeps the old unpinned
  /// appearance without a rewrite; null reads exactly like false.
  final bool? pinned;
  const DumpRow({
    required this.id,
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
    this.transcriptionError,
    this.folderId,
    this.autoFiledAt,
    this.autoFilePrevFolderId,
    this.syncDirty,
    this.syncedSeq,
    this.remoteOnly,
    this.audioOnServer,
    this.summary,
    this.summaryModel,
    this.summarizedAt,
    this.transcriptTimings,
    this.summaryTemplate,
    this.speakerNames,
    this.summaryRequestedAt,
    this.language,
    this.translated,
    this.summaryStatus,
    this.summaryError,
    this.summaryQueuePosition,
    this.summaryErrorDismissedAt,
    this.pinned,
  });
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
      map['transcription_request_id'] = Variable<String>(
        transcriptionRequestId,
      );
    }
    if (!nullToAbsent || transcriptionJobId != null) {
      map['transcription_job_id'] = Variable<String>(transcriptionJobId);
    }
    map['transcription_attempt'] = Variable<int>(transcriptionAttempt);
    if (!nullToAbsent || transcriptionStartedAt != null) {
      map['transcription_started_at'] = Variable<DateTime>(
        transcriptionStartedAt,
      );
    }
    if (!nullToAbsent || transcriptionUpdatedAt != null) {
      map['transcription_updated_at'] = Variable<DateTime>(
        transcriptionUpdatedAt,
      );
    }
    if (!nullToAbsent || transcriptionCompletedAt != null) {
      map['transcription_completed_at'] = Variable<DateTime>(
        transcriptionCompletedAt,
      );
    }
    if (!nullToAbsent || transcriptionError != null) {
      map['transcription_error'] = Variable<String>(transcriptionError);
    }
    if (!nullToAbsent || folderId != null) {
      map['folder_id'] = Variable<String>(folderId);
    }
    if (!nullToAbsent || autoFiledAt != null) {
      map['auto_filed_at'] = Variable<int>(autoFiledAt);
    }
    if (!nullToAbsent || autoFilePrevFolderId != null) {
      map['auto_file_prev_folder_id'] = Variable<String>(autoFilePrevFolderId);
    }
    if (!nullToAbsent || syncDirty != null) {
      map['sync_dirty'] = Variable<bool>(syncDirty);
    }
    if (!nullToAbsent || syncedSeq != null) {
      map['synced_seq'] = Variable<int>(syncedSeq);
    }
    if (!nullToAbsent || remoteOnly != null) {
      map['remote_only'] = Variable<bool>(remoteOnly);
    }
    if (!nullToAbsent || audioOnServer != null) {
      map['audio_on_server'] = Variable<bool>(audioOnServer);
    }
    if (!nullToAbsent || summary != null) {
      map['summary'] = Variable<String>(summary);
    }
    if (!nullToAbsent || summaryModel != null) {
      map['summary_model'] = Variable<String>(summaryModel);
    }
    if (!nullToAbsent || summarizedAt != null) {
      map['summarized_at'] = Variable<int>(summarizedAt);
    }
    if (!nullToAbsent || transcriptTimings != null) {
      map['transcript_timings'] = Variable<String>(transcriptTimings);
    }
    if (!nullToAbsent || summaryTemplate != null) {
      map['summary_template'] = Variable<String>(summaryTemplate);
    }
    if (!nullToAbsent || speakerNames != null) {
      map['speaker_names'] = Variable<String>(speakerNames);
    }
    if (!nullToAbsent || summaryRequestedAt != null) {
      map['summary_requested_at'] = Variable<int>(summaryRequestedAt);
    }
    if (!nullToAbsent || language != null) {
      map['language'] = Variable<String>(language);
    }
    if (!nullToAbsent || translated != null) {
      map['translated'] = Variable<bool>(translated);
    }
    if (!nullToAbsent || summaryStatus != null) {
      map['summary_status'] = Variable<String>(summaryStatus);
    }
    if (!nullToAbsent || summaryError != null) {
      map['summary_error'] = Variable<String>(summaryError);
    }
    if (!nullToAbsent || summaryQueuePosition != null) {
      map['summary_queue_position'] = Variable<int>(summaryQueuePosition);
    }
    if (!nullToAbsent || summaryErrorDismissedAt != null) {
      map['summary_error_dismissed_at'] = Variable<int>(
        summaryErrorDismissedAt,
      );
    }
    if (!nullToAbsent || pinned != null) {
      map['pinned'] = Variable<bool>(pinned);
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
      folderId: folderId == null && nullToAbsent
          ? const Value.absent()
          : Value(folderId),
      autoFiledAt: autoFiledAt == null && nullToAbsent
          ? const Value.absent()
          : Value(autoFiledAt),
      autoFilePrevFolderId: autoFilePrevFolderId == null && nullToAbsent
          ? const Value.absent()
          : Value(autoFilePrevFolderId),
      syncDirty: syncDirty == null && nullToAbsent
          ? const Value.absent()
          : Value(syncDirty),
      syncedSeq: syncedSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(syncedSeq),
      remoteOnly: remoteOnly == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteOnly),
      audioOnServer: audioOnServer == null && nullToAbsent
          ? const Value.absent()
          : Value(audioOnServer),
      summary: summary == null && nullToAbsent
          ? const Value.absent()
          : Value(summary),
      summaryModel: summaryModel == null && nullToAbsent
          ? const Value.absent()
          : Value(summaryModel),
      summarizedAt: summarizedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(summarizedAt),
      transcriptTimings: transcriptTimings == null && nullToAbsent
          ? const Value.absent()
          : Value(transcriptTimings),
      summaryTemplate: summaryTemplate == null && nullToAbsent
          ? const Value.absent()
          : Value(summaryTemplate),
      speakerNames: speakerNames == null && nullToAbsent
          ? const Value.absent()
          : Value(speakerNames),
      summaryRequestedAt: summaryRequestedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(summaryRequestedAt),
      language: language == null && nullToAbsent
          ? const Value.absent()
          : Value(language),
      translated: translated == null && nullToAbsent
          ? const Value.absent()
          : Value(translated),
      summaryStatus: summaryStatus == null && nullToAbsent
          ? const Value.absent()
          : Value(summaryStatus),
      summaryError: summaryError == null && nullToAbsent
          ? const Value.absent()
          : Value(summaryError),
      summaryQueuePosition: summaryQueuePosition == null && nullToAbsent
          ? const Value.absent()
          : Value(summaryQueuePosition),
      summaryErrorDismissedAt: summaryErrorDismissedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(summaryErrorDismissedAt),
      pinned: pinned == null && nullToAbsent
          ? const Value.absent()
          : Value(pinned),
    );
  }

  factory DumpRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
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
      transcriptionStatus: serializer.fromJson<String>(
        json['transcriptionStatus'],
      ),
      transcriptionRequestId: serializer.fromJson<String?>(
        json['transcriptionRequestId'],
      ),
      transcriptionJobId: serializer.fromJson<String?>(
        json['transcriptionJobId'],
      ),
      transcriptionAttempt: serializer.fromJson<int>(
        json['transcriptionAttempt'],
      ),
      transcriptionStartedAt: serializer.fromJson<DateTime?>(
        json['transcriptionStartedAt'],
      ),
      transcriptionUpdatedAt: serializer.fromJson<DateTime?>(
        json['transcriptionUpdatedAt'],
      ),
      transcriptionCompletedAt: serializer.fromJson<DateTime?>(
        json['transcriptionCompletedAt'],
      ),
      transcriptionError: serializer.fromJson<String?>(
        json['transcriptionError'],
      ),
      folderId: serializer.fromJson<String?>(json['folderId']),
      autoFiledAt: serializer.fromJson<int?>(json['autoFiledAt']),
      autoFilePrevFolderId: serializer.fromJson<String?>(
        json['autoFilePrevFolderId'],
      ),
      syncDirty: serializer.fromJson<bool?>(json['syncDirty']),
      syncedSeq: serializer.fromJson<int?>(json['syncedSeq']),
      remoteOnly: serializer.fromJson<bool?>(json['remoteOnly']),
      audioOnServer: serializer.fromJson<bool?>(json['audioOnServer']),
      summary: serializer.fromJson<String?>(json['summary']),
      summaryModel: serializer.fromJson<String?>(json['summaryModel']),
      summarizedAt: serializer.fromJson<int?>(json['summarizedAt']),
      transcriptTimings: serializer.fromJson<String?>(
        json['transcriptTimings'],
      ),
      summaryTemplate: serializer.fromJson<String?>(json['summaryTemplate']),
      speakerNames: serializer.fromJson<String?>(json['speakerNames']),
      summaryRequestedAt: serializer.fromJson<int?>(json['summaryRequestedAt']),
      language: serializer.fromJson<String?>(json['language']),
      translated: serializer.fromJson<bool?>(json['translated']),
      summaryStatus: serializer.fromJson<String?>(json['summaryStatus']),
      summaryError: serializer.fromJson<String?>(json['summaryError']),
      summaryQueuePosition: serializer.fromJson<int?>(
        json['summaryQueuePosition'],
      ),
      summaryErrorDismissedAt: serializer.fromJson<int?>(
        json['summaryErrorDismissedAt'],
      ),
      pinned: serializer.fromJson<bool?>(json['pinned']),
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
      'transcriptionRequestId': serializer.toJson<String?>(
        transcriptionRequestId,
      ),
      'transcriptionJobId': serializer.toJson<String?>(transcriptionJobId),
      'transcriptionAttempt': serializer.toJson<int>(transcriptionAttempt),
      'transcriptionStartedAt': serializer.toJson<DateTime?>(
        transcriptionStartedAt,
      ),
      'transcriptionUpdatedAt': serializer.toJson<DateTime?>(
        transcriptionUpdatedAt,
      ),
      'transcriptionCompletedAt': serializer.toJson<DateTime?>(
        transcriptionCompletedAt,
      ),
      'transcriptionError': serializer.toJson<String?>(transcriptionError),
      'folderId': serializer.toJson<String?>(folderId),
      'autoFiledAt': serializer.toJson<int?>(autoFiledAt),
      'autoFilePrevFolderId': serializer.toJson<String?>(autoFilePrevFolderId),
      'syncDirty': serializer.toJson<bool?>(syncDirty),
      'syncedSeq': serializer.toJson<int?>(syncedSeq),
      'remoteOnly': serializer.toJson<bool?>(remoteOnly),
      'audioOnServer': serializer.toJson<bool?>(audioOnServer),
      'summary': serializer.toJson<String?>(summary),
      'summaryModel': serializer.toJson<String?>(summaryModel),
      'summarizedAt': serializer.toJson<int?>(summarizedAt),
      'transcriptTimings': serializer.toJson<String?>(transcriptTimings),
      'summaryTemplate': serializer.toJson<String?>(summaryTemplate),
      'speakerNames': serializer.toJson<String?>(speakerNames),
      'summaryRequestedAt': serializer.toJson<int?>(summaryRequestedAt),
      'language': serializer.toJson<String?>(language),
      'translated': serializer.toJson<bool?>(translated),
      'summaryStatus': serializer.toJson<String?>(summaryStatus),
      'summaryError': serializer.toJson<String?>(summaryError),
      'summaryQueuePosition': serializer.toJson<int?>(summaryQueuePosition),
      'summaryErrorDismissedAt': serializer.toJson<int?>(
        summaryErrorDismissedAt,
      ),
      'pinned': serializer.toJson<bool?>(pinned),
    };
  }

  DumpRow copyWith({
    String? id,
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
    Value<String?> transcriptionError = const Value.absent(),
    Value<String?> folderId = const Value.absent(),
    Value<int?> autoFiledAt = const Value.absent(),
    Value<String?> autoFilePrevFolderId = const Value.absent(),
    Value<bool?> syncDirty = const Value.absent(),
    Value<int?> syncedSeq = const Value.absent(),
    Value<bool?> remoteOnly = const Value.absent(),
    Value<bool?> audioOnServer = const Value.absent(),
    Value<String?> summary = const Value.absent(),
    Value<String?> summaryModel = const Value.absent(),
    Value<int?> summarizedAt = const Value.absent(),
    Value<String?> transcriptTimings = const Value.absent(),
    Value<String?> summaryTemplate = const Value.absent(),
    Value<String?> speakerNames = const Value.absent(),
    Value<int?> summaryRequestedAt = const Value.absent(),
    Value<String?> language = const Value.absent(),
    Value<bool?> translated = const Value.absent(),
    Value<String?> summaryStatus = const Value.absent(),
    Value<String?> summaryError = const Value.absent(),
    Value<int?> summaryQueuePosition = const Value.absent(),
    Value<int?> summaryErrorDismissedAt = const Value.absent(),
    Value<bool?> pinned = const Value.absent(),
  }) => DumpRow(
    id: id ?? this.id,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    mode: mode ?? this.mode,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    title: title ?? this.title,
    transcript: transcript.present ? transcript.value : this.transcript,
    meetingNotes: meetingNotes.present ? meetingNotes.value : this.meetingNotes,
    audioPath: audioPath ?? this.audioPath,
    audioSizeBytes: audioSizeBytes ?? this.audioSizeBytes,
    syncStatus: syncStatus ?? this.syncStatus,
    syncAttempts: syncAttempts ?? this.syncAttempts,
    lastSyncError: lastSyncError.present
        ? lastSyncError.value
        : this.lastSyncError,
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
    folderId: folderId.present ? folderId.value : this.folderId,
    autoFiledAt: autoFiledAt.present ? autoFiledAt.value : this.autoFiledAt,
    autoFilePrevFolderId: autoFilePrevFolderId.present
        ? autoFilePrevFolderId.value
        : this.autoFilePrevFolderId,
    syncDirty: syncDirty.present ? syncDirty.value : this.syncDirty,
    syncedSeq: syncedSeq.present ? syncedSeq.value : this.syncedSeq,
    remoteOnly: remoteOnly.present ? remoteOnly.value : this.remoteOnly,
    audioOnServer: audioOnServer.present
        ? audioOnServer.value
        : this.audioOnServer,
    summary: summary.present ? summary.value : this.summary,
    summaryModel: summaryModel.present ? summaryModel.value : this.summaryModel,
    summarizedAt: summarizedAt.present ? summarizedAt.value : this.summarizedAt,
    transcriptTimings: transcriptTimings.present
        ? transcriptTimings.value
        : this.transcriptTimings,
    summaryTemplate: summaryTemplate.present
        ? summaryTemplate.value
        : this.summaryTemplate,
    speakerNames: speakerNames.present ? speakerNames.value : this.speakerNames,
    summaryRequestedAt: summaryRequestedAt.present
        ? summaryRequestedAt.value
        : this.summaryRequestedAt,
    language: language.present ? language.value : this.language,
    translated: translated.present ? translated.value : this.translated,
    summaryStatus: summaryStatus.present
        ? summaryStatus.value
        : this.summaryStatus,
    summaryError: summaryError.present ? summaryError.value : this.summaryError,
    summaryQueuePosition: summaryQueuePosition.present
        ? summaryQueuePosition.value
        : this.summaryQueuePosition,
    summaryErrorDismissedAt: summaryErrorDismissedAt.present
        ? summaryErrorDismissedAt.value
        : this.summaryErrorDismissedAt,
    pinned: pinned.present ? pinned.value : this.pinned,
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
      transcript: data.transcript.present
          ? data.transcript.value
          : this.transcript,
      meetingNotes: data.meetingNotes.present
          ? data.meetingNotes.value
          : this.meetingNotes,
      audioPath: data.audioPath.present ? data.audioPath.value : this.audioPath,
      audioSizeBytes: data.audioSizeBytes.present
          ? data.audioSizeBytes.value
          : this.audioSizeBytes,
      syncStatus: data.syncStatus.present
          ? data.syncStatus.value
          : this.syncStatus,
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
      folderId: data.folderId.present ? data.folderId.value : this.folderId,
      autoFiledAt: data.autoFiledAt.present
          ? data.autoFiledAt.value
          : this.autoFiledAt,
      autoFilePrevFolderId: data.autoFilePrevFolderId.present
          ? data.autoFilePrevFolderId.value
          : this.autoFilePrevFolderId,
      syncDirty: data.syncDirty.present ? data.syncDirty.value : this.syncDirty,
      syncedSeq: data.syncedSeq.present ? data.syncedSeq.value : this.syncedSeq,
      remoteOnly: data.remoteOnly.present
          ? data.remoteOnly.value
          : this.remoteOnly,
      audioOnServer: data.audioOnServer.present
          ? data.audioOnServer.value
          : this.audioOnServer,
      summary: data.summary.present ? data.summary.value : this.summary,
      summaryModel: data.summaryModel.present
          ? data.summaryModel.value
          : this.summaryModel,
      summarizedAt: data.summarizedAt.present
          ? data.summarizedAt.value
          : this.summarizedAt,
      transcriptTimings: data.transcriptTimings.present
          ? data.transcriptTimings.value
          : this.transcriptTimings,
      summaryTemplate: data.summaryTemplate.present
          ? data.summaryTemplate.value
          : this.summaryTemplate,
      speakerNames: data.speakerNames.present
          ? data.speakerNames.value
          : this.speakerNames,
      summaryRequestedAt: data.summaryRequestedAt.present
          ? data.summaryRequestedAt.value
          : this.summaryRequestedAt,
      language: data.language.present ? data.language.value : this.language,
      translated: data.translated.present
          ? data.translated.value
          : this.translated,
      summaryStatus: data.summaryStatus.present
          ? data.summaryStatus.value
          : this.summaryStatus,
      summaryError: data.summaryError.present
          ? data.summaryError.value
          : this.summaryError,
      summaryQueuePosition: data.summaryQueuePosition.present
          ? data.summaryQueuePosition.value
          : this.summaryQueuePosition,
      summaryErrorDismissedAt: data.summaryErrorDismissedAt.present
          ? data.summaryErrorDismissedAt.value
          : this.summaryErrorDismissedAt,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
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
          ..write('transcriptionError: $transcriptionError, ')
          ..write('folderId: $folderId, ')
          ..write('autoFiledAt: $autoFiledAt, ')
          ..write('autoFilePrevFolderId: $autoFilePrevFolderId, ')
          ..write('syncDirty: $syncDirty, ')
          ..write('syncedSeq: $syncedSeq, ')
          ..write('remoteOnly: $remoteOnly, ')
          ..write('audioOnServer: $audioOnServer, ')
          ..write('summary: $summary, ')
          ..write('summaryModel: $summaryModel, ')
          ..write('summarizedAt: $summarizedAt, ')
          ..write('transcriptTimings: $transcriptTimings, ')
          ..write('summaryTemplate: $summaryTemplate, ')
          ..write('speakerNames: $speakerNames, ')
          ..write('summaryRequestedAt: $summaryRequestedAt, ')
          ..write('language: $language, ')
          ..write('translated: $translated, ')
          ..write('summaryStatus: $summaryStatus, ')
          ..write('summaryError: $summaryError, ')
          ..write('summaryQueuePosition: $summaryQueuePosition, ')
          ..write('summaryErrorDismissedAt: $summaryErrorDismissedAt, ')
          ..write('pinned: $pinned')
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
    transcriptionError,
    folderId,
    autoFiledAt,
    autoFilePrevFolderId,
    syncDirty,
    syncedSeq,
    remoteOnly,
    audioOnServer,
    summary,
    summaryModel,
    summarizedAt,
    transcriptTimings,
    summaryTemplate,
    speakerNames,
    summaryRequestedAt,
    language,
    translated,
    summaryStatus,
    summaryError,
    summaryQueuePosition,
    summaryErrorDismissedAt,
    pinned,
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
          other.transcriptionError == this.transcriptionError &&
          other.folderId == this.folderId &&
          other.autoFiledAt == this.autoFiledAt &&
          other.autoFilePrevFolderId == this.autoFilePrevFolderId &&
          other.syncDirty == this.syncDirty &&
          other.syncedSeq == this.syncedSeq &&
          other.remoteOnly == this.remoteOnly &&
          other.audioOnServer == this.audioOnServer &&
          other.summary == this.summary &&
          other.summaryModel == this.summaryModel &&
          other.summarizedAt == this.summarizedAt &&
          other.transcriptTimings == this.transcriptTimings &&
          other.summaryTemplate == this.summaryTemplate &&
          other.speakerNames == this.speakerNames &&
          other.summaryRequestedAt == this.summaryRequestedAt &&
          other.language == this.language &&
          other.translated == this.translated &&
          other.summaryStatus == this.summaryStatus &&
          other.summaryError == this.summaryError &&
          other.summaryQueuePosition == this.summaryQueuePosition &&
          other.summaryErrorDismissedAt == this.summaryErrorDismissedAt &&
          other.pinned == this.pinned);
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
  final Value<String?> folderId;
  final Value<int?> autoFiledAt;
  final Value<String?> autoFilePrevFolderId;
  final Value<bool?> syncDirty;
  final Value<int?> syncedSeq;
  final Value<bool?> remoteOnly;
  final Value<bool?> audioOnServer;
  final Value<String?> summary;
  final Value<String?> summaryModel;
  final Value<int?> summarizedAt;
  final Value<String?> transcriptTimings;
  final Value<String?> summaryTemplate;
  final Value<String?> speakerNames;
  final Value<int?> summaryRequestedAt;
  final Value<String?> language;
  final Value<bool?> translated;
  final Value<String?> summaryStatus;
  final Value<String?> summaryError;
  final Value<int?> summaryQueuePosition;
  final Value<int?> summaryErrorDismissedAt;
  final Value<bool?> pinned;
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
    this.folderId = const Value.absent(),
    this.autoFiledAt = const Value.absent(),
    this.autoFilePrevFolderId = const Value.absent(),
    this.syncDirty = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.remoteOnly = const Value.absent(),
    this.audioOnServer = const Value.absent(),
    this.summary = const Value.absent(),
    this.summaryModel = const Value.absent(),
    this.summarizedAt = const Value.absent(),
    this.transcriptTimings = const Value.absent(),
    this.summaryTemplate = const Value.absent(),
    this.speakerNames = const Value.absent(),
    this.summaryRequestedAt = const Value.absent(),
    this.language = const Value.absent(),
    this.translated = const Value.absent(),
    this.summaryStatus = const Value.absent(),
    this.summaryError = const Value.absent(),
    this.summaryQueuePosition = const Value.absent(),
    this.summaryErrorDismissedAt = const Value.absent(),
    this.pinned = const Value.absent(),
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
    this.folderId = const Value.absent(),
    this.autoFiledAt = const Value.absent(),
    this.autoFilePrevFolderId = const Value.absent(),
    this.syncDirty = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.remoteOnly = const Value.absent(),
    this.audioOnServer = const Value.absent(),
    this.summary = const Value.absent(),
    this.summaryModel = const Value.absent(),
    this.summarizedAt = const Value.absent(),
    this.transcriptTimings = const Value.absent(),
    this.summaryTemplate = const Value.absent(),
    this.speakerNames = const Value.absent(),
    this.summaryRequestedAt = const Value.absent(),
    this.language = const Value.absent(),
    this.translated = const Value.absent(),
    this.summaryStatus = const Value.absent(),
    this.summaryError = const Value.absent(),
    this.summaryQueuePosition = const Value.absent(),
    this.summaryErrorDismissedAt = const Value.absent(),
    this.pinned = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
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
    Expression<String>? folderId,
    Expression<int>? autoFiledAt,
    Expression<String>? autoFilePrevFolderId,
    Expression<bool>? syncDirty,
    Expression<int>? syncedSeq,
    Expression<bool>? remoteOnly,
    Expression<bool>? audioOnServer,
    Expression<String>? summary,
    Expression<String>? summaryModel,
    Expression<int>? summarizedAt,
    Expression<String>? transcriptTimings,
    Expression<String>? summaryTemplate,
    Expression<String>? speakerNames,
    Expression<int>? summaryRequestedAt,
    Expression<String>? language,
    Expression<bool>? translated,
    Expression<String>? summaryStatus,
    Expression<String>? summaryError,
    Expression<int>? summaryQueuePosition,
    Expression<int>? summaryErrorDismissedAt,
    Expression<bool>? pinned,
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
      if (folderId != null) 'folder_id': folderId,
      if (autoFiledAt != null) 'auto_filed_at': autoFiledAt,
      if (autoFilePrevFolderId != null)
        'auto_file_prev_folder_id': autoFilePrevFolderId,
      if (syncDirty != null) 'sync_dirty': syncDirty,
      if (syncedSeq != null) 'synced_seq': syncedSeq,
      if (remoteOnly != null) 'remote_only': remoteOnly,
      if (audioOnServer != null) 'audio_on_server': audioOnServer,
      if (summary != null) 'summary': summary,
      if (summaryModel != null) 'summary_model': summaryModel,
      if (summarizedAt != null) 'summarized_at': summarizedAt,
      if (transcriptTimings != null) 'transcript_timings': transcriptTimings,
      if (summaryTemplate != null) 'summary_template': summaryTemplate,
      if (speakerNames != null) 'speaker_names': speakerNames,
      if (summaryRequestedAt != null)
        'summary_requested_at': summaryRequestedAt,
      if (language != null) 'language': language,
      if (translated != null) 'translated': translated,
      if (summaryStatus != null) 'summary_status': summaryStatus,
      if (summaryError != null) 'summary_error': summaryError,
      if (summaryQueuePosition != null)
        'summary_queue_position': summaryQueuePosition,
      if (summaryErrorDismissedAt != null)
        'summary_error_dismissed_at': summaryErrorDismissedAt,
      if (pinned != null) 'pinned': pinned,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DumpsCompanion copyWith({
    Value<String>? id,
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
    Value<String?>? folderId,
    Value<int?>? autoFiledAt,
    Value<String?>? autoFilePrevFolderId,
    Value<bool?>? syncDirty,
    Value<int?>? syncedSeq,
    Value<bool?>? remoteOnly,
    Value<bool?>? audioOnServer,
    Value<String?>? summary,
    Value<String?>? summaryModel,
    Value<int?>? summarizedAt,
    Value<String?>? transcriptTimings,
    Value<String?>? summaryTemplate,
    Value<String?>? speakerNames,
    Value<int?>? summaryRequestedAt,
    Value<String?>? language,
    Value<bool?>? translated,
    Value<String?>? summaryStatus,
    Value<String?>? summaryError,
    Value<int?>? summaryQueuePosition,
    Value<int?>? summaryErrorDismissedAt,
    Value<bool?>? pinned,
    Value<int>? rowid,
  }) {
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
      folderId: folderId ?? this.folderId,
      autoFiledAt: autoFiledAt ?? this.autoFiledAt,
      autoFilePrevFolderId: autoFilePrevFolderId ?? this.autoFilePrevFolderId,
      syncDirty: syncDirty ?? this.syncDirty,
      syncedSeq: syncedSeq ?? this.syncedSeq,
      remoteOnly: remoteOnly ?? this.remoteOnly,
      audioOnServer: audioOnServer ?? this.audioOnServer,
      summary: summary ?? this.summary,
      summaryModel: summaryModel ?? this.summaryModel,
      summarizedAt: summarizedAt ?? this.summarizedAt,
      transcriptTimings: transcriptTimings ?? this.transcriptTimings,
      summaryTemplate: summaryTemplate ?? this.summaryTemplate,
      speakerNames: speakerNames ?? this.speakerNames,
      summaryRequestedAt: summaryRequestedAt ?? this.summaryRequestedAt,
      language: language ?? this.language,
      translated: translated ?? this.translated,
      summaryStatus: summaryStatus ?? this.summaryStatus,
      summaryError: summaryError ?? this.summaryError,
      summaryQueuePosition: summaryQueuePosition ?? this.summaryQueuePosition,
      summaryErrorDismissedAt:
          summaryErrorDismissedAt ?? this.summaryErrorDismissedAt,
      pinned: pinned ?? this.pinned,
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
      map['transcription_request_id'] = Variable<String>(
        transcriptionRequestId.value,
      );
    }
    if (transcriptionJobId.present) {
      map['transcription_job_id'] = Variable<String>(transcriptionJobId.value);
    }
    if (transcriptionAttempt.present) {
      map['transcription_attempt'] = Variable<int>(transcriptionAttempt.value);
    }
    if (transcriptionStartedAt.present) {
      map['transcription_started_at'] = Variable<DateTime>(
        transcriptionStartedAt.value,
      );
    }
    if (transcriptionUpdatedAt.present) {
      map['transcription_updated_at'] = Variable<DateTime>(
        transcriptionUpdatedAt.value,
      );
    }
    if (transcriptionCompletedAt.present) {
      map['transcription_completed_at'] = Variable<DateTime>(
        transcriptionCompletedAt.value,
      );
    }
    if (transcriptionError.present) {
      map['transcription_error'] = Variable<String>(transcriptionError.value);
    }
    if (folderId.present) {
      map['folder_id'] = Variable<String>(folderId.value);
    }
    if (autoFiledAt.present) {
      map['auto_filed_at'] = Variable<int>(autoFiledAt.value);
    }
    if (autoFilePrevFolderId.present) {
      map['auto_file_prev_folder_id'] = Variable<String>(
        autoFilePrevFolderId.value,
      );
    }
    if (syncDirty.present) {
      map['sync_dirty'] = Variable<bool>(syncDirty.value);
    }
    if (syncedSeq.present) {
      map['synced_seq'] = Variable<int>(syncedSeq.value);
    }
    if (remoteOnly.present) {
      map['remote_only'] = Variable<bool>(remoteOnly.value);
    }
    if (audioOnServer.present) {
      map['audio_on_server'] = Variable<bool>(audioOnServer.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (summaryModel.present) {
      map['summary_model'] = Variable<String>(summaryModel.value);
    }
    if (summarizedAt.present) {
      map['summarized_at'] = Variable<int>(summarizedAt.value);
    }
    if (transcriptTimings.present) {
      map['transcript_timings'] = Variable<String>(transcriptTimings.value);
    }
    if (summaryTemplate.present) {
      map['summary_template'] = Variable<String>(summaryTemplate.value);
    }
    if (speakerNames.present) {
      map['speaker_names'] = Variable<String>(speakerNames.value);
    }
    if (summaryRequestedAt.present) {
      map['summary_requested_at'] = Variable<int>(summaryRequestedAt.value);
    }
    if (language.present) {
      map['language'] = Variable<String>(language.value);
    }
    if (translated.present) {
      map['translated'] = Variable<bool>(translated.value);
    }
    if (summaryStatus.present) {
      map['summary_status'] = Variable<String>(summaryStatus.value);
    }
    if (summaryError.present) {
      map['summary_error'] = Variable<String>(summaryError.value);
    }
    if (summaryQueuePosition.present) {
      map['summary_queue_position'] = Variable<int>(summaryQueuePosition.value);
    }
    if (summaryErrorDismissedAt.present) {
      map['summary_error_dismissed_at'] = Variable<int>(
        summaryErrorDismissedAt.value,
      );
    }
    if (pinned.present) {
      map['pinned'] = Variable<bool>(pinned.value);
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
          ..write('folderId: $folderId, ')
          ..write('autoFiledAt: $autoFiledAt, ')
          ..write('autoFilePrevFolderId: $autoFilePrevFolderId, ')
          ..write('syncDirty: $syncDirty, ')
          ..write('syncedSeq: $syncedSeq, ')
          ..write('remoteOnly: $remoteOnly, ')
          ..write('audioOnServer: $audioOnServer, ')
          ..write('summary: $summary, ')
          ..write('summaryModel: $summaryModel, ')
          ..write('summarizedAt: $summarizedAt, ')
          ..write('transcriptTimings: $transcriptTimings, ')
          ..write('summaryTemplate: $summaryTemplate, ')
          ..write('speakerNames: $speakerNames, ')
          ..write('summaryRequestedAt: $summaryRequestedAt, ')
          ..write('language: $language, ')
          ..write('translated: $translated, ')
          ..write('summaryStatus: $summaryStatus, ')
          ..write('summaryError: $summaryError, ')
          ..write('summaryQueuePosition: $summaryQueuePosition, ')
          ..write('summaryErrorDismissedAt: $summaryErrorDismissedAt, ')
          ..write('pinned: $pinned, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FoldersTable extends Folders with TableInfo<$FoldersTable, Folder> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FoldersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _syncDirtyMeta = const VerificationMeta(
    'syncDirty',
  );
  @override
  late final GeneratedColumn<bool> syncDirty = GeneratedColumn<bool>(
    'sync_dirty',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("sync_dirty" IN (0, 1))',
    ),
  );
  static const VerificationMeta _syncedSeqMeta = const VerificationMeta(
    'syncedSeq',
  );
  @override
  late final GeneratedColumn<int> syncedSeq = GeneratedColumn<int>(
    'synced_seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    createdAt,
    syncDirty,
    syncedSeq,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'folders';
  @override
  VerificationContext validateIntegrity(
    Insertable<Folder> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('sync_dirty')) {
      context.handle(
        _syncDirtyMeta,
        syncDirty.isAcceptableOrUnknown(data['sync_dirty']!, _syncDirtyMeta),
      );
    }
    if (data.containsKey('synced_seq')) {
      context.handle(
        _syncedSeqMeta,
        syncedSeq.isAcceptableOrUnknown(data['synced_seq']!, _syncedSeqMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Folder map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Folder(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      syncDirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}sync_dirty'],
      ),
      syncedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_seq'],
      ),
    );
  }

  @override
  $FoldersTable createAlias(String alias) {
    return $FoldersTable(attachedDatabase, alias);
  }
}

class Folder extends DataClass implements Insertable<Folder> {
  final String id;
  final String name;
  final int createdAt;

  /// Sync state, mirroring notebooks. Folders sync by ID only: same-named
  /// folders created independently on two devices stay separate (user
  /// decision). Nullable, and null reads as dirty for the same reason
  /// notebooks default dirty: a folder that existed before folder sync has
  /// never been pushed.
  final bool? syncDirty;
  final int? syncedSeq;
  const Folder({
    required this.id,
    required this.name,
    required this.createdAt,
    this.syncDirty,
    this.syncedSeq,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || syncDirty != null) {
      map['sync_dirty'] = Variable<bool>(syncDirty);
    }
    if (!nullToAbsent || syncedSeq != null) {
      map['synced_seq'] = Variable<int>(syncedSeq);
    }
    return map;
  }

  FoldersCompanion toCompanion(bool nullToAbsent) {
    return FoldersCompanion(
      id: Value(id),
      name: Value(name),
      createdAt: Value(createdAt),
      syncDirty: syncDirty == null && nullToAbsent
          ? const Value.absent()
          : Value(syncDirty),
      syncedSeq: syncedSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(syncedSeq),
    );
  }

  factory Folder.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Folder(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      syncDirty: serializer.fromJson<bool?>(json['syncDirty']),
      syncedSeq: serializer.fromJson<int?>(json['syncedSeq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'createdAt': serializer.toJson<int>(createdAt),
      'syncDirty': serializer.toJson<bool?>(syncDirty),
      'syncedSeq': serializer.toJson<int?>(syncedSeq),
    };
  }

  Folder copyWith({
    String? id,
    String? name,
    int? createdAt,
    Value<bool?> syncDirty = const Value.absent(),
    Value<int?> syncedSeq = const Value.absent(),
  }) => Folder(
    id: id ?? this.id,
    name: name ?? this.name,
    createdAt: createdAt ?? this.createdAt,
    syncDirty: syncDirty.present ? syncDirty.value : this.syncDirty,
    syncedSeq: syncedSeq.present ? syncedSeq.value : this.syncedSeq,
  );
  Folder copyWithCompanion(FoldersCompanion data) {
    return Folder(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      syncDirty: data.syncDirty.present ? data.syncDirty.value : this.syncDirty,
      syncedSeq: data.syncedSeq.present ? data.syncedSeq.value : this.syncedSeq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Folder(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncDirty: $syncDirty, ')
          ..write('syncedSeq: $syncedSeq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, createdAt, syncDirty, syncedSeq);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Folder &&
          other.id == this.id &&
          other.name == this.name &&
          other.createdAt == this.createdAt &&
          other.syncDirty == this.syncDirty &&
          other.syncedSeq == this.syncedSeq);
}

class FoldersCompanion extends UpdateCompanion<Folder> {
  final Value<String> id;
  final Value<String> name;
  final Value<int> createdAt;
  final Value<bool?> syncDirty;
  final Value<int?> syncedSeq;
  final Value<int> rowid;
  const FoldersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.syncDirty = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FoldersCompanion.insert({
    required String id,
    required String name,
    required int createdAt,
    this.syncDirty = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       createdAt = Value(createdAt);
  static Insertable<Folder> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? createdAt,
    Expression<bool>? syncDirty,
    Expression<int>? syncedSeq,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (createdAt != null) 'created_at': createdAt,
      if (syncDirty != null) 'sync_dirty': syncDirty,
      if (syncedSeq != null) 'synced_seq': syncedSeq,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FoldersCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int>? createdAt,
    Value<bool?>? syncDirty,
    Value<int?>? syncedSeq,
    Value<int>? rowid,
  }) {
    return FoldersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      syncDirty: syncDirty ?? this.syncDirty,
      syncedSeq: syncedSeq ?? this.syncedSeq,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (syncDirty.present) {
      map['sync_dirty'] = Variable<bool>(syncDirty.value);
    }
    if (syncedSeq.present) {
      map['synced_seq'] = Variable<int>(syncedSeq.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FoldersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('createdAt: $createdAt, ')
          ..write('syncDirty: $syncDirty, ')
          ..write('syncedSeq: $syncedSeq, ')
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
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _dumpIdMeta = const VerificationMeta('dumpId');
  @override
  late final GeneratedColumn<String> dumpId = GeneratedColumn<String>(
    'dump_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES dumps (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _queuedAtMeta = const VerificationMeta(
    'queuedAt',
  );
  @override
  late final GeneratedColumn<DateTime> queuedAt = GeneratedColumn<DateTime>(
    'queued_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, dumpId, queuedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_queue';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncQueueRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('dump_id')) {
      context.handle(
        _dumpIdMeta,
        dumpId.isAcceptableOrUnknown(data['dump_id']!, _dumpIdMeta),
      );
    } else if (isInserting) {
      context.missing(_dumpIdMeta);
    }
    if (data.containsKey('queued_at')) {
      context.handle(
        _queuedAtMeta,
        queuedAt.isAcceptableOrUnknown(data['queued_at']!, _queuedAtMeta),
      );
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
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      dumpId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dump_id'],
      )!,
      queuedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}queued_at'],
      )!,
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
  const SyncQueueRow({
    required this.id,
    required this.dumpId,
    required this.queuedAt,
  });
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

  factory SyncQueueRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
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
  }) : dumpId = Value(dumpId),
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

  SyncQueueCompanion copyWith({
    Value<int>? id,
    Value<String>? dumpId,
    Value<DateTime>? queuedAt,
  }) {
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

class $StorageLocationsTable extends StorageLocations
    with TableInfo<$StorageLocationsTable, StorageLocationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StorageLocationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _canonicalKeyMeta = const VerificationMeta(
    'canonicalKey',
  );
  @override
  late final GeneratedColumn<String> canonicalKey = GeneratedColumn<String>(
    'canonical_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _directoryJsonMeta = const VerificationMeta(
    'directoryJson',
  );
  @override
  late final GeneratedColumn<String> directoryJson = GeneratedColumn<String>(
    'directory_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _labelMeta = const VerificationMeta('label');
  @override
  late final GeneratedColumn<String> label = GeneratedColumn<String>(
    'label',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _legacyRestoreMeta = const VerificationMeta(
    'legacyRestore',
  );
  @override
  late final GeneratedColumn<bool> legacyRestore = GeneratedColumn<bool>(
    'legacy_restore',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("legacy_restore" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    canonicalKey,
    directoryJson,
    label,
    legacyRestore,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'storage_locations';
  @override
  VerificationContext validateIntegrity(
    Insertable<StorageLocationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('canonical_key')) {
      context.handle(
        _canonicalKeyMeta,
        canonicalKey.isAcceptableOrUnknown(
          data['canonical_key']!,
          _canonicalKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_canonicalKeyMeta);
    }
    if (data.containsKey('directory_json')) {
      context.handle(
        _directoryJsonMeta,
        directoryJson.isAcceptableOrUnknown(
          data['directory_json']!,
          _directoryJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_directoryJsonMeta);
    }
    if (data.containsKey('label')) {
      context.handle(
        _labelMeta,
        label.isAcceptableOrUnknown(data['label']!, _labelMeta),
      );
    } else if (isInserting) {
      context.missing(_labelMeta);
    }
    if (data.containsKey('legacy_restore')) {
      context.handle(
        _legacyRestoreMeta,
        legacyRestore.isAcceptableOrUnknown(
          data['legacy_restore']!,
          _legacyRestoreMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StorageLocationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StorageLocationRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      canonicalKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}canonical_key'],
      )!,
      directoryJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}directory_json'],
      )!,
      label: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}label'],
      )!,
      legacyRestore: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}legacy_restore'],
      )!,
    );
  }

  @override
  $StorageLocationsTable createAlias(String alias) {
    return $StorageLocationsTable(attachedDatabase, alias);
  }
}

class StorageLocationRow extends DataClass
    implements Insertable<StorageLocationRow> {
  final String id;
  final String canonicalKey;
  final String directoryJson;
  final String label;
  final bool legacyRestore;
  const StorageLocationRow({
    required this.id,
    required this.canonicalKey,
    required this.directoryJson,
    required this.label,
    required this.legacyRestore,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['canonical_key'] = Variable<String>(canonicalKey);
    map['directory_json'] = Variable<String>(directoryJson);
    map['label'] = Variable<String>(label);
    map['legacy_restore'] = Variable<bool>(legacyRestore);
    return map;
  }

  StorageLocationsCompanion toCompanion(bool nullToAbsent) {
    return StorageLocationsCompanion(
      id: Value(id),
      canonicalKey: Value(canonicalKey),
      directoryJson: Value(directoryJson),
      label: Value(label),
      legacyRestore: Value(legacyRestore),
    );
  }

  factory StorageLocationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StorageLocationRow(
      id: serializer.fromJson<String>(json['id']),
      canonicalKey: serializer.fromJson<String>(json['canonicalKey']),
      directoryJson: serializer.fromJson<String>(json['directoryJson']),
      label: serializer.fromJson<String>(json['label']),
      legacyRestore: serializer.fromJson<bool>(json['legacyRestore']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'canonicalKey': serializer.toJson<String>(canonicalKey),
      'directoryJson': serializer.toJson<String>(directoryJson),
      'label': serializer.toJson<String>(label),
      'legacyRestore': serializer.toJson<bool>(legacyRestore),
    };
  }

  StorageLocationRow copyWith({
    String? id,
    String? canonicalKey,
    String? directoryJson,
    String? label,
    bool? legacyRestore,
  }) => StorageLocationRow(
    id: id ?? this.id,
    canonicalKey: canonicalKey ?? this.canonicalKey,
    directoryJson: directoryJson ?? this.directoryJson,
    label: label ?? this.label,
    legacyRestore: legacyRestore ?? this.legacyRestore,
  );
  StorageLocationRow copyWithCompanion(StorageLocationsCompanion data) {
    return StorageLocationRow(
      id: data.id.present ? data.id.value : this.id,
      canonicalKey: data.canonicalKey.present
          ? data.canonicalKey.value
          : this.canonicalKey,
      directoryJson: data.directoryJson.present
          ? data.directoryJson.value
          : this.directoryJson,
      label: data.label.present ? data.label.value : this.label,
      legacyRestore: data.legacyRestore.present
          ? data.legacyRestore.value
          : this.legacyRestore,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StorageLocationRow(')
          ..write('id: $id, ')
          ..write('canonicalKey: $canonicalKey, ')
          ..write('directoryJson: $directoryJson, ')
          ..write('label: $label, ')
          ..write('legacyRestore: $legacyRestore')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, canonicalKey, directoryJson, label, legacyRestore);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StorageLocationRow &&
          other.id == this.id &&
          other.canonicalKey == this.canonicalKey &&
          other.directoryJson == this.directoryJson &&
          other.label == this.label &&
          other.legacyRestore == this.legacyRestore);
}

class StorageLocationsCompanion extends UpdateCompanion<StorageLocationRow> {
  final Value<String> id;
  final Value<String> canonicalKey;
  final Value<String> directoryJson;
  final Value<String> label;
  final Value<bool> legacyRestore;
  final Value<int> rowid;
  const StorageLocationsCompanion({
    this.id = const Value.absent(),
    this.canonicalKey = const Value.absent(),
    this.directoryJson = const Value.absent(),
    this.label = const Value.absent(),
    this.legacyRestore = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StorageLocationsCompanion.insert({
    required String id,
    required String canonicalKey,
    required String directoryJson,
    required String label,
    this.legacyRestore = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       canonicalKey = Value(canonicalKey),
       directoryJson = Value(directoryJson),
       label = Value(label);
  static Insertable<StorageLocationRow> custom({
    Expression<String>? id,
    Expression<String>? canonicalKey,
    Expression<String>? directoryJson,
    Expression<String>? label,
    Expression<bool>? legacyRestore,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (canonicalKey != null) 'canonical_key': canonicalKey,
      if (directoryJson != null) 'directory_json': directoryJson,
      if (label != null) 'label': label,
      if (legacyRestore != null) 'legacy_restore': legacyRestore,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StorageLocationsCompanion copyWith({
    Value<String>? id,
    Value<String>? canonicalKey,
    Value<String>? directoryJson,
    Value<String>? label,
    Value<bool>? legacyRestore,
    Value<int>? rowid,
  }) {
    return StorageLocationsCompanion(
      id: id ?? this.id,
      canonicalKey: canonicalKey ?? this.canonicalKey,
      directoryJson: directoryJson ?? this.directoryJson,
      label: label ?? this.label,
      legacyRestore: legacyRestore ?? this.legacyRestore,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (canonicalKey.present) {
      map['canonical_key'] = Variable<String>(canonicalKey.value);
    }
    if (directoryJson.present) {
      map['directory_json'] = Variable<String>(directoryJson.value);
    }
    if (label.present) {
      map['label'] = Variable<String>(label.value);
    }
    if (legacyRestore.present) {
      map['legacy_restore'] = Variable<bool>(legacyRestore.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StorageLocationsCompanion(')
          ..write('id: $id, ')
          ..write('canonicalKey: $canonicalKey, ')
          ..write('directoryJson: $directoryJson, ')
          ..write('label: $label, ')
          ..write('legacyRestore: $legacyRestore, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StorageCatalogStatesTable extends StorageCatalogStates
    with TableInfo<$StorageCatalogStatesTable, StorageCatalogStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StorageCatalogStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _defaultLocationIdMeta = const VerificationMeta(
    'defaultLocationId',
  );
  @override
  late final GeneratedColumn<String> defaultLocationId =
      GeneratedColumn<String>(
        'default_location_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _revisionMeta = const VerificationMeta(
    'revision',
  );
  @override
  late final GeneratedColumn<int> revision = GeneratedColumn<int>(
    'revision',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _bootstrapVersionMeta = const VerificationMeta(
    'bootstrapVersion',
  );
  @override
  late final GeneratedColumn<int> bootstrapVersion = GeneratedColumn<int>(
    'bootstrap_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _legacyAnchorJsonMeta = const VerificationMeta(
    'legacyAnchorJson',
  );
  @override
  late final GeneratedColumn<String> legacyAnchorJson = GeneratedColumn<String>(
    'legacy_anchor_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _candidateJsonMeta = const VerificationMeta(
    'candidateJson',
  );
  @override
  late final GeneratedColumn<String> candidateJson = GeneratedColumn<String>(
    'candidate_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    defaultLocationId,
    revision,
    bootstrapVersion,
    legacyAnchorJson,
    candidateJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'storage_catalog_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<StorageCatalogStateRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('default_location_id')) {
      context.handle(
        _defaultLocationIdMeta,
        defaultLocationId.isAcceptableOrUnknown(
          data['default_location_id']!,
          _defaultLocationIdMeta,
        ),
      );
    }
    if (data.containsKey('revision')) {
      context.handle(
        _revisionMeta,
        revision.isAcceptableOrUnknown(data['revision']!, _revisionMeta),
      );
    }
    if (data.containsKey('bootstrap_version')) {
      context.handle(
        _bootstrapVersionMeta,
        bootstrapVersion.isAcceptableOrUnknown(
          data['bootstrap_version']!,
          _bootstrapVersionMeta,
        ),
      );
    }
    if (data.containsKey('legacy_anchor_json')) {
      context.handle(
        _legacyAnchorJsonMeta,
        legacyAnchorJson.isAcceptableOrUnknown(
          data['legacy_anchor_json']!,
          _legacyAnchorJsonMeta,
        ),
      );
    }
    if (data.containsKey('candidate_json')) {
      context.handle(
        _candidateJsonMeta,
        candidateJson.isAcceptableOrUnknown(
          data['candidate_json']!,
          _candidateJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StorageCatalogStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StorageCatalogStateRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      defaultLocationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}default_location_id'],
      ),
      revision: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}revision'],
      )!,
      bootstrapVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bootstrap_version'],
      )!,
      legacyAnchorJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}legacy_anchor_json'],
      ),
      candidateJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}candidate_json'],
      ),
    );
  }

  @override
  $StorageCatalogStatesTable createAlias(String alias) {
    return $StorageCatalogStatesTable(attachedDatabase, alias);
  }
}

class StorageCatalogStateRow extends DataClass
    implements Insertable<StorageCatalogStateRow> {
  final int id;
  final String? defaultLocationId;
  final int revision;
  final int bootstrapVersion;
  final String? legacyAnchorJson;
  final String? candidateJson;
  const StorageCatalogStateRow({
    required this.id,
    this.defaultLocationId,
    required this.revision,
    required this.bootstrapVersion,
    this.legacyAnchorJson,
    this.candidateJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || defaultLocationId != null) {
      map['default_location_id'] = Variable<String>(defaultLocationId);
    }
    map['revision'] = Variable<int>(revision);
    map['bootstrap_version'] = Variable<int>(bootstrapVersion);
    if (!nullToAbsent || legacyAnchorJson != null) {
      map['legacy_anchor_json'] = Variable<String>(legacyAnchorJson);
    }
    if (!nullToAbsent || candidateJson != null) {
      map['candidate_json'] = Variable<String>(candidateJson);
    }
    return map;
  }

  StorageCatalogStatesCompanion toCompanion(bool nullToAbsent) {
    return StorageCatalogStatesCompanion(
      id: Value(id),
      defaultLocationId: defaultLocationId == null && nullToAbsent
          ? const Value.absent()
          : Value(defaultLocationId),
      revision: Value(revision),
      bootstrapVersion: Value(bootstrapVersion),
      legacyAnchorJson: legacyAnchorJson == null && nullToAbsent
          ? const Value.absent()
          : Value(legacyAnchorJson),
      candidateJson: candidateJson == null && nullToAbsent
          ? const Value.absent()
          : Value(candidateJson),
    );
  }

  factory StorageCatalogStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StorageCatalogStateRow(
      id: serializer.fromJson<int>(json['id']),
      defaultLocationId: serializer.fromJson<String?>(
        json['defaultLocationId'],
      ),
      revision: serializer.fromJson<int>(json['revision']),
      bootstrapVersion: serializer.fromJson<int>(json['bootstrapVersion']),
      legacyAnchorJson: serializer.fromJson<String?>(json['legacyAnchorJson']),
      candidateJson: serializer.fromJson<String?>(json['candidateJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'defaultLocationId': serializer.toJson<String?>(defaultLocationId),
      'revision': serializer.toJson<int>(revision),
      'bootstrapVersion': serializer.toJson<int>(bootstrapVersion),
      'legacyAnchorJson': serializer.toJson<String?>(legacyAnchorJson),
      'candidateJson': serializer.toJson<String?>(candidateJson),
    };
  }

  StorageCatalogStateRow copyWith({
    int? id,
    Value<String?> defaultLocationId = const Value.absent(),
    int? revision,
    int? bootstrapVersion,
    Value<String?> legacyAnchorJson = const Value.absent(),
    Value<String?> candidateJson = const Value.absent(),
  }) => StorageCatalogStateRow(
    id: id ?? this.id,
    defaultLocationId: defaultLocationId.present
        ? defaultLocationId.value
        : this.defaultLocationId,
    revision: revision ?? this.revision,
    bootstrapVersion: bootstrapVersion ?? this.bootstrapVersion,
    legacyAnchorJson: legacyAnchorJson.present
        ? legacyAnchorJson.value
        : this.legacyAnchorJson,
    candidateJson: candidateJson.present
        ? candidateJson.value
        : this.candidateJson,
  );
  StorageCatalogStateRow copyWithCompanion(StorageCatalogStatesCompanion data) {
    return StorageCatalogStateRow(
      id: data.id.present ? data.id.value : this.id,
      defaultLocationId: data.defaultLocationId.present
          ? data.defaultLocationId.value
          : this.defaultLocationId,
      revision: data.revision.present ? data.revision.value : this.revision,
      bootstrapVersion: data.bootstrapVersion.present
          ? data.bootstrapVersion.value
          : this.bootstrapVersion,
      legacyAnchorJson: data.legacyAnchorJson.present
          ? data.legacyAnchorJson.value
          : this.legacyAnchorJson,
      candidateJson: data.candidateJson.present
          ? data.candidateJson.value
          : this.candidateJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StorageCatalogStateRow(')
          ..write('id: $id, ')
          ..write('defaultLocationId: $defaultLocationId, ')
          ..write('revision: $revision, ')
          ..write('bootstrapVersion: $bootstrapVersion, ')
          ..write('legacyAnchorJson: $legacyAnchorJson, ')
          ..write('candidateJson: $candidateJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    defaultLocationId,
    revision,
    bootstrapVersion,
    legacyAnchorJson,
    candidateJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StorageCatalogStateRow &&
          other.id == this.id &&
          other.defaultLocationId == this.defaultLocationId &&
          other.revision == this.revision &&
          other.bootstrapVersion == this.bootstrapVersion &&
          other.legacyAnchorJson == this.legacyAnchorJson &&
          other.candidateJson == this.candidateJson);
}

class StorageCatalogStatesCompanion
    extends UpdateCompanion<StorageCatalogStateRow> {
  final Value<int> id;
  final Value<String?> defaultLocationId;
  final Value<int> revision;
  final Value<int> bootstrapVersion;
  final Value<String?> legacyAnchorJson;
  final Value<String?> candidateJson;
  const StorageCatalogStatesCompanion({
    this.id = const Value.absent(),
    this.defaultLocationId = const Value.absent(),
    this.revision = const Value.absent(),
    this.bootstrapVersion = const Value.absent(),
    this.legacyAnchorJson = const Value.absent(),
    this.candidateJson = const Value.absent(),
  });
  StorageCatalogStatesCompanion.insert({
    this.id = const Value.absent(),
    this.defaultLocationId = const Value.absent(),
    this.revision = const Value.absent(),
    this.bootstrapVersion = const Value.absent(),
    this.legacyAnchorJson = const Value.absent(),
    this.candidateJson = const Value.absent(),
  });
  static Insertable<StorageCatalogStateRow> custom({
    Expression<int>? id,
    Expression<String>? defaultLocationId,
    Expression<int>? revision,
    Expression<int>? bootstrapVersion,
    Expression<String>? legacyAnchorJson,
    Expression<String>? candidateJson,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (defaultLocationId != null) 'default_location_id': defaultLocationId,
      if (revision != null) 'revision': revision,
      if (bootstrapVersion != null) 'bootstrap_version': bootstrapVersion,
      if (legacyAnchorJson != null) 'legacy_anchor_json': legacyAnchorJson,
      if (candidateJson != null) 'candidate_json': candidateJson,
    });
  }

  StorageCatalogStatesCompanion copyWith({
    Value<int>? id,
    Value<String?>? defaultLocationId,
    Value<int>? revision,
    Value<int>? bootstrapVersion,
    Value<String?>? legacyAnchorJson,
    Value<String?>? candidateJson,
  }) {
    return StorageCatalogStatesCompanion(
      id: id ?? this.id,
      defaultLocationId: defaultLocationId ?? this.defaultLocationId,
      revision: revision ?? this.revision,
      bootstrapVersion: bootstrapVersion ?? this.bootstrapVersion,
      legacyAnchorJson: legacyAnchorJson ?? this.legacyAnchorJson,
      candidateJson: candidateJson ?? this.candidateJson,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (defaultLocationId.present) {
      map['default_location_id'] = Variable<String>(defaultLocationId.value);
    }
    if (revision.present) {
      map['revision'] = Variable<int>(revision.value);
    }
    if (bootstrapVersion.present) {
      map['bootstrap_version'] = Variable<int>(bootstrapVersion.value);
    }
    if (legacyAnchorJson.present) {
      map['legacy_anchor_json'] = Variable<String>(legacyAnchorJson.value);
    }
    if (candidateJson.present) {
      map['candidate_json'] = Variable<String>(candidateJson.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StorageCatalogStatesCompanion(')
          ..write('id: $id, ')
          ..write('defaultLocationId: $defaultLocationId, ')
          ..write('revision: $revision, ')
          ..write('bootstrapVersion: $bootstrapVersion, ')
          ..write('legacyAnchorJson: $legacyAnchorJson, ')
          ..write('candidateJson: $candidateJson')
          ..write(')'))
        .toString();
  }
}

class $RecordingBindingsTable extends RecordingBindings
    with TableInfo<$RecordingBindingsTable, RecordingBindingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecordingBindingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _dumpIdMeta = const VerificationMeta('dumpId');
  @override
  late final GeneratedColumn<String> dumpId = GeneratedColumn<String>(
    'dump_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _incarnationMeta = const VerificationMeta(
    'incarnation',
  );
  @override
  late final GeneratedColumn<String> incarnation = GeneratedColumn<String>(
    'incarnation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _locationIdMeta = const VerificationMeta(
    'locationId',
  );
  @override
  late final GeneratedColumn<String> locationId = GeneratedColumn<String>(
    'location_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _audioJsonMeta = const VerificationMeta(
    'audioJson',
  );
  @override
  late final GeneratedColumn<String> audioJson = GeneratedColumn<String>(
    'audio_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _metadataNameMeta = const VerificationMeta(
    'metadataName',
  );
  @override
  late final GeneratedColumn<String> metadataName = GeneratedColumn<String>(
    'metadata_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _legacyAnchorJsonMeta = const VerificationMeta(
    'legacyAnchorJson',
  );
  @override
  late final GeneratedColumn<String> legacyAnchorJson = GeneratedColumn<String>(
    'legacy_anchor_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resolvedMeta = const VerificationMeta(
    'resolved',
  );
  @override
  late final GeneratedColumn<bool> resolved = GeneratedColumn<bool>(
    'resolved',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("resolved" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    dumpId,
    incarnation,
    locationId,
    audioJson,
    metadataName,
    legacyAnchorJson,
    resolved,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recording_bindings';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecordingBindingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('dump_id')) {
      context.handle(
        _dumpIdMeta,
        dumpId.isAcceptableOrUnknown(data['dump_id']!, _dumpIdMeta),
      );
    } else if (isInserting) {
      context.missing(_dumpIdMeta);
    }
    if (data.containsKey('incarnation')) {
      context.handle(
        _incarnationMeta,
        incarnation.isAcceptableOrUnknown(
          data['incarnation']!,
          _incarnationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_incarnationMeta);
    }
    if (data.containsKey('location_id')) {
      context.handle(
        _locationIdMeta,
        locationId.isAcceptableOrUnknown(data['location_id']!, _locationIdMeta),
      );
    }
    if (data.containsKey('audio_json')) {
      context.handle(
        _audioJsonMeta,
        audioJson.isAcceptableOrUnknown(data['audio_json']!, _audioJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_audioJsonMeta);
    }
    if (data.containsKey('metadata_name')) {
      context.handle(
        _metadataNameMeta,
        metadataName.isAcceptableOrUnknown(
          data['metadata_name']!,
          _metadataNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_metadataNameMeta);
    }
    if (data.containsKey('legacy_anchor_json')) {
      context.handle(
        _legacyAnchorJsonMeta,
        legacyAnchorJson.isAcceptableOrUnknown(
          data['legacy_anchor_json']!,
          _legacyAnchorJsonMeta,
        ),
      );
    }
    if (data.containsKey('resolved')) {
      context.handle(
        _resolvedMeta,
        resolved.isAcceptableOrUnknown(data['resolved']!, _resolvedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {dumpId};
  @override
  RecordingBindingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecordingBindingRow(
      dumpId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dump_id'],
      )!,
      incarnation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}incarnation'],
      )!,
      locationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location_id'],
      ),
      audioJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}audio_json'],
      )!,
      metadataName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metadata_name'],
      )!,
      legacyAnchorJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}legacy_anchor_json'],
      ),
      resolved: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}resolved'],
      )!,
    );
  }

  @override
  $RecordingBindingsTable createAlias(String alias) {
    return $RecordingBindingsTable(attachedDatabase, alias);
  }
}

class RecordingBindingRow extends DataClass
    implements Insertable<RecordingBindingRow> {
  final String dumpId;
  final String incarnation;
  final String? locationId;
  final String audioJson;
  final String metadataName;
  final String? legacyAnchorJson;
  final bool resolved;
  const RecordingBindingRow({
    required this.dumpId,
    required this.incarnation,
    this.locationId,
    required this.audioJson,
    required this.metadataName,
    this.legacyAnchorJson,
    required this.resolved,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['dump_id'] = Variable<String>(dumpId);
    map['incarnation'] = Variable<String>(incarnation);
    if (!nullToAbsent || locationId != null) {
      map['location_id'] = Variable<String>(locationId);
    }
    map['audio_json'] = Variable<String>(audioJson);
    map['metadata_name'] = Variable<String>(metadataName);
    if (!nullToAbsent || legacyAnchorJson != null) {
      map['legacy_anchor_json'] = Variable<String>(legacyAnchorJson);
    }
    map['resolved'] = Variable<bool>(resolved);
    return map;
  }

  RecordingBindingsCompanion toCompanion(bool nullToAbsent) {
    return RecordingBindingsCompanion(
      dumpId: Value(dumpId),
      incarnation: Value(incarnation),
      locationId: locationId == null && nullToAbsent
          ? const Value.absent()
          : Value(locationId),
      audioJson: Value(audioJson),
      metadataName: Value(metadataName),
      legacyAnchorJson: legacyAnchorJson == null && nullToAbsent
          ? const Value.absent()
          : Value(legacyAnchorJson),
      resolved: Value(resolved),
    );
  }

  factory RecordingBindingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecordingBindingRow(
      dumpId: serializer.fromJson<String>(json['dumpId']),
      incarnation: serializer.fromJson<String>(json['incarnation']),
      locationId: serializer.fromJson<String?>(json['locationId']),
      audioJson: serializer.fromJson<String>(json['audioJson']),
      metadataName: serializer.fromJson<String>(json['metadataName']),
      legacyAnchorJson: serializer.fromJson<String?>(json['legacyAnchorJson']),
      resolved: serializer.fromJson<bool>(json['resolved']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'dumpId': serializer.toJson<String>(dumpId),
      'incarnation': serializer.toJson<String>(incarnation),
      'locationId': serializer.toJson<String?>(locationId),
      'audioJson': serializer.toJson<String>(audioJson),
      'metadataName': serializer.toJson<String>(metadataName),
      'legacyAnchorJson': serializer.toJson<String?>(legacyAnchorJson),
      'resolved': serializer.toJson<bool>(resolved),
    };
  }

  RecordingBindingRow copyWith({
    String? dumpId,
    String? incarnation,
    Value<String?> locationId = const Value.absent(),
    String? audioJson,
    String? metadataName,
    Value<String?> legacyAnchorJson = const Value.absent(),
    bool? resolved,
  }) => RecordingBindingRow(
    dumpId: dumpId ?? this.dumpId,
    incarnation: incarnation ?? this.incarnation,
    locationId: locationId.present ? locationId.value : this.locationId,
    audioJson: audioJson ?? this.audioJson,
    metadataName: metadataName ?? this.metadataName,
    legacyAnchorJson: legacyAnchorJson.present
        ? legacyAnchorJson.value
        : this.legacyAnchorJson,
    resolved: resolved ?? this.resolved,
  );
  RecordingBindingRow copyWithCompanion(RecordingBindingsCompanion data) {
    return RecordingBindingRow(
      dumpId: data.dumpId.present ? data.dumpId.value : this.dumpId,
      incarnation: data.incarnation.present
          ? data.incarnation.value
          : this.incarnation,
      locationId: data.locationId.present
          ? data.locationId.value
          : this.locationId,
      audioJson: data.audioJson.present ? data.audioJson.value : this.audioJson,
      metadataName: data.metadataName.present
          ? data.metadataName.value
          : this.metadataName,
      legacyAnchorJson: data.legacyAnchorJson.present
          ? data.legacyAnchorJson.value
          : this.legacyAnchorJson,
      resolved: data.resolved.present ? data.resolved.value : this.resolved,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecordingBindingRow(')
          ..write('dumpId: $dumpId, ')
          ..write('incarnation: $incarnation, ')
          ..write('locationId: $locationId, ')
          ..write('audioJson: $audioJson, ')
          ..write('metadataName: $metadataName, ')
          ..write('legacyAnchorJson: $legacyAnchorJson, ')
          ..write('resolved: $resolved')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    dumpId,
    incarnation,
    locationId,
    audioJson,
    metadataName,
    legacyAnchorJson,
    resolved,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecordingBindingRow &&
          other.dumpId == this.dumpId &&
          other.incarnation == this.incarnation &&
          other.locationId == this.locationId &&
          other.audioJson == this.audioJson &&
          other.metadataName == this.metadataName &&
          other.legacyAnchorJson == this.legacyAnchorJson &&
          other.resolved == this.resolved);
}

class RecordingBindingsCompanion extends UpdateCompanion<RecordingBindingRow> {
  final Value<String> dumpId;
  final Value<String> incarnation;
  final Value<String?> locationId;
  final Value<String> audioJson;
  final Value<String> metadataName;
  final Value<String?> legacyAnchorJson;
  final Value<bool> resolved;
  final Value<int> rowid;
  const RecordingBindingsCompanion({
    this.dumpId = const Value.absent(),
    this.incarnation = const Value.absent(),
    this.locationId = const Value.absent(),
    this.audioJson = const Value.absent(),
    this.metadataName = const Value.absent(),
    this.legacyAnchorJson = const Value.absent(),
    this.resolved = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RecordingBindingsCompanion.insert({
    required String dumpId,
    required String incarnation,
    this.locationId = const Value.absent(),
    required String audioJson,
    required String metadataName,
    this.legacyAnchorJson = const Value.absent(),
    this.resolved = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : dumpId = Value(dumpId),
       incarnation = Value(incarnation),
       audioJson = Value(audioJson),
       metadataName = Value(metadataName);
  static Insertable<RecordingBindingRow> custom({
    Expression<String>? dumpId,
    Expression<String>? incarnation,
    Expression<String>? locationId,
    Expression<String>? audioJson,
    Expression<String>? metadataName,
    Expression<String>? legacyAnchorJson,
    Expression<bool>? resolved,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (dumpId != null) 'dump_id': dumpId,
      if (incarnation != null) 'incarnation': incarnation,
      if (locationId != null) 'location_id': locationId,
      if (audioJson != null) 'audio_json': audioJson,
      if (metadataName != null) 'metadata_name': metadataName,
      if (legacyAnchorJson != null) 'legacy_anchor_json': legacyAnchorJson,
      if (resolved != null) 'resolved': resolved,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RecordingBindingsCompanion copyWith({
    Value<String>? dumpId,
    Value<String>? incarnation,
    Value<String?>? locationId,
    Value<String>? audioJson,
    Value<String>? metadataName,
    Value<String?>? legacyAnchorJson,
    Value<bool>? resolved,
    Value<int>? rowid,
  }) {
    return RecordingBindingsCompanion(
      dumpId: dumpId ?? this.dumpId,
      incarnation: incarnation ?? this.incarnation,
      locationId: locationId ?? this.locationId,
      audioJson: audioJson ?? this.audioJson,
      metadataName: metadataName ?? this.metadataName,
      legacyAnchorJson: legacyAnchorJson ?? this.legacyAnchorJson,
      resolved: resolved ?? this.resolved,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (dumpId.present) {
      map['dump_id'] = Variable<String>(dumpId.value);
    }
    if (incarnation.present) {
      map['incarnation'] = Variable<String>(incarnation.value);
    }
    if (locationId.present) {
      map['location_id'] = Variable<String>(locationId.value);
    }
    if (audioJson.present) {
      map['audio_json'] = Variable<String>(audioJson.value);
    }
    if (metadataName.present) {
      map['metadata_name'] = Variable<String>(metadataName.value);
    }
    if (legacyAnchorJson.present) {
      map['legacy_anchor_json'] = Variable<String>(legacyAnchorJson.value);
    }
    if (resolved.present) {
      map['resolved'] = Variable<bool>(resolved.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecordingBindingsCompanion(')
          ..write('dumpId: $dumpId, ')
          ..write('incarnation: $incarnation, ')
          ..write('locationId: $locationId, ')
          ..write('audioJson: $audioJson, ')
          ..write('metadataName: $metadataName, ')
          ..write('legacyAnchorJson: $legacyAnchorJson, ')
          ..write('resolved: $resolved, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CaptureReservationsTable extends CaptureReservations
    with TableInfo<$CaptureReservationsTable, CaptureReservationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CaptureReservationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _reservationIdMeta = const VerificationMeta(
    'reservationId',
  );
  @override
  late final GeneratedColumn<String> reservationId = GeneratedColumn<String>(
    'reservation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dumpIdMeta = const VerificationMeta('dumpId');
  @override
  late final GeneratedColumn<String> dumpId = GeneratedColumn<String>(
    'dump_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _incarnationMeta = const VerificationMeta(
    'incarnation',
  );
  @override
  late final GeneratedColumn<String> incarnation = GeneratedColumn<String>(
    'incarnation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _locationIdMeta = const VerificationMeta(
    'locationId',
  );
  @override
  late final GeneratedColumn<String> locationId = GeneratedColumn<String>(
    'location_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stagingPathMeta = const VerificationMeta(
    'stagingPath',
  );
  @override
  late final GeneratedColumn<String> stagingPath = GeneratedColumn<String>(
    'staging_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modeMeta = const VerificationMeta('mode');
  @override
  late final GeneratedColumn<String> mode = GeneratedColumn<String>(
    'mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<int> startedAt = GeneratedColumn<int>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _processEpochMeta = const VerificationMeta(
    'processEpoch',
  );
  @override
  late final GeneratedColumn<String> processEpoch = GeneratedColumn<String>(
    'process_epoch',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _publicationJsonMeta = const VerificationMeta(
    'publicationJson',
  );
  @override
  late final GeneratedColumn<String> publicationJson = GeneratedColumn<String>(
    'publication_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    reservationId,
    dumpId,
    incarnation,
    locationId,
    stagingPath,
    mode,
    startedAt,
    state,
    processEpoch,
    publicationJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'capture_reservations';
  @override
  VerificationContext validateIntegrity(
    Insertable<CaptureReservationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('reservation_id')) {
      context.handle(
        _reservationIdMeta,
        reservationId.isAcceptableOrUnknown(
          data['reservation_id']!,
          _reservationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_reservationIdMeta);
    }
    if (data.containsKey('dump_id')) {
      context.handle(
        _dumpIdMeta,
        dumpId.isAcceptableOrUnknown(data['dump_id']!, _dumpIdMeta),
      );
    } else if (isInserting) {
      context.missing(_dumpIdMeta);
    }
    if (data.containsKey('incarnation')) {
      context.handle(
        _incarnationMeta,
        incarnation.isAcceptableOrUnknown(
          data['incarnation']!,
          _incarnationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_incarnationMeta);
    }
    if (data.containsKey('location_id')) {
      context.handle(
        _locationIdMeta,
        locationId.isAcceptableOrUnknown(data['location_id']!, _locationIdMeta),
      );
    } else if (isInserting) {
      context.missing(_locationIdMeta);
    }
    if (data.containsKey('staging_path')) {
      context.handle(
        _stagingPathMeta,
        stagingPath.isAcceptableOrUnknown(
          data['staging_path']!,
          _stagingPathMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_stagingPathMeta);
    }
    if (data.containsKey('mode')) {
      context.handle(
        _modeMeta,
        mode.isAcceptableOrUnknown(data['mode']!, _modeMeta),
      );
    } else if (isInserting) {
      context.missing(_modeMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('process_epoch')) {
      context.handle(
        _processEpochMeta,
        processEpoch.isAcceptableOrUnknown(
          data['process_epoch']!,
          _processEpochMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_processEpochMeta);
    }
    if (data.containsKey('publication_json')) {
      context.handle(
        _publicationJsonMeta,
        publicationJson.isAcceptableOrUnknown(
          data['publication_json']!,
          _publicationJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {reservationId};
  @override
  CaptureReservationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CaptureReservationRow(
      reservationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reservation_id'],
      )!,
      dumpId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dump_id'],
      )!,
      incarnation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}incarnation'],
      )!,
      locationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location_id'],
      )!,
      stagingPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}staging_path'],
      )!,
      mode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mode'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}started_at'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      processEpoch: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}process_epoch'],
      )!,
      publicationJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}publication_json'],
      ),
    );
  }

  @override
  $CaptureReservationsTable createAlias(String alias) {
    return $CaptureReservationsTable(attachedDatabase, alias);
  }
}

class CaptureReservationRow extends DataClass
    implements Insertable<CaptureReservationRow> {
  final String reservationId;
  final String dumpId;
  final String incarnation;
  final String locationId;
  final String stagingPath;
  final String mode;
  final int startedAt;
  final String state;
  final String processEpoch;
  final String? publicationJson;
  const CaptureReservationRow({
    required this.reservationId,
    required this.dumpId,
    required this.incarnation,
    required this.locationId,
    required this.stagingPath,
    required this.mode,
    required this.startedAt,
    required this.state,
    required this.processEpoch,
    this.publicationJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['reservation_id'] = Variable<String>(reservationId);
    map['dump_id'] = Variable<String>(dumpId);
    map['incarnation'] = Variable<String>(incarnation);
    map['location_id'] = Variable<String>(locationId);
    map['staging_path'] = Variable<String>(stagingPath);
    map['mode'] = Variable<String>(mode);
    map['started_at'] = Variable<int>(startedAt);
    map['state'] = Variable<String>(state);
    map['process_epoch'] = Variable<String>(processEpoch);
    if (!nullToAbsent || publicationJson != null) {
      map['publication_json'] = Variable<String>(publicationJson);
    }
    return map;
  }

  CaptureReservationsCompanion toCompanion(bool nullToAbsent) {
    return CaptureReservationsCompanion(
      reservationId: Value(reservationId),
      dumpId: Value(dumpId),
      incarnation: Value(incarnation),
      locationId: Value(locationId),
      stagingPath: Value(stagingPath),
      mode: Value(mode),
      startedAt: Value(startedAt),
      state: Value(state),
      processEpoch: Value(processEpoch),
      publicationJson: publicationJson == null && nullToAbsent
          ? const Value.absent()
          : Value(publicationJson),
    );
  }

  factory CaptureReservationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CaptureReservationRow(
      reservationId: serializer.fromJson<String>(json['reservationId']),
      dumpId: serializer.fromJson<String>(json['dumpId']),
      incarnation: serializer.fromJson<String>(json['incarnation']),
      locationId: serializer.fromJson<String>(json['locationId']),
      stagingPath: serializer.fromJson<String>(json['stagingPath']),
      mode: serializer.fromJson<String>(json['mode']),
      startedAt: serializer.fromJson<int>(json['startedAt']),
      state: serializer.fromJson<String>(json['state']),
      processEpoch: serializer.fromJson<String>(json['processEpoch']),
      publicationJson: serializer.fromJson<String?>(json['publicationJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'reservationId': serializer.toJson<String>(reservationId),
      'dumpId': serializer.toJson<String>(dumpId),
      'incarnation': serializer.toJson<String>(incarnation),
      'locationId': serializer.toJson<String>(locationId),
      'stagingPath': serializer.toJson<String>(stagingPath),
      'mode': serializer.toJson<String>(mode),
      'startedAt': serializer.toJson<int>(startedAt),
      'state': serializer.toJson<String>(state),
      'processEpoch': serializer.toJson<String>(processEpoch),
      'publicationJson': serializer.toJson<String?>(publicationJson),
    };
  }

  CaptureReservationRow copyWith({
    String? reservationId,
    String? dumpId,
    String? incarnation,
    String? locationId,
    String? stagingPath,
    String? mode,
    int? startedAt,
    String? state,
    String? processEpoch,
    Value<String?> publicationJson = const Value.absent(),
  }) => CaptureReservationRow(
    reservationId: reservationId ?? this.reservationId,
    dumpId: dumpId ?? this.dumpId,
    incarnation: incarnation ?? this.incarnation,
    locationId: locationId ?? this.locationId,
    stagingPath: stagingPath ?? this.stagingPath,
    mode: mode ?? this.mode,
    startedAt: startedAt ?? this.startedAt,
    state: state ?? this.state,
    processEpoch: processEpoch ?? this.processEpoch,
    publicationJson: publicationJson.present
        ? publicationJson.value
        : this.publicationJson,
  );
  CaptureReservationRow copyWithCompanion(CaptureReservationsCompanion data) {
    return CaptureReservationRow(
      reservationId: data.reservationId.present
          ? data.reservationId.value
          : this.reservationId,
      dumpId: data.dumpId.present ? data.dumpId.value : this.dumpId,
      incarnation: data.incarnation.present
          ? data.incarnation.value
          : this.incarnation,
      locationId: data.locationId.present
          ? data.locationId.value
          : this.locationId,
      stagingPath: data.stagingPath.present
          ? data.stagingPath.value
          : this.stagingPath,
      mode: data.mode.present ? data.mode.value : this.mode,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      state: data.state.present ? data.state.value : this.state,
      processEpoch: data.processEpoch.present
          ? data.processEpoch.value
          : this.processEpoch,
      publicationJson: data.publicationJson.present
          ? data.publicationJson.value
          : this.publicationJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CaptureReservationRow(')
          ..write('reservationId: $reservationId, ')
          ..write('dumpId: $dumpId, ')
          ..write('incarnation: $incarnation, ')
          ..write('locationId: $locationId, ')
          ..write('stagingPath: $stagingPath, ')
          ..write('mode: $mode, ')
          ..write('startedAt: $startedAt, ')
          ..write('state: $state, ')
          ..write('processEpoch: $processEpoch, ')
          ..write('publicationJson: $publicationJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    reservationId,
    dumpId,
    incarnation,
    locationId,
    stagingPath,
    mode,
    startedAt,
    state,
    processEpoch,
    publicationJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CaptureReservationRow &&
          other.reservationId == this.reservationId &&
          other.dumpId == this.dumpId &&
          other.incarnation == this.incarnation &&
          other.locationId == this.locationId &&
          other.stagingPath == this.stagingPath &&
          other.mode == this.mode &&
          other.startedAt == this.startedAt &&
          other.state == this.state &&
          other.processEpoch == this.processEpoch &&
          other.publicationJson == this.publicationJson);
}

class CaptureReservationsCompanion
    extends UpdateCompanion<CaptureReservationRow> {
  final Value<String> reservationId;
  final Value<String> dumpId;
  final Value<String> incarnation;
  final Value<String> locationId;
  final Value<String> stagingPath;
  final Value<String> mode;
  final Value<int> startedAt;
  final Value<String> state;
  final Value<String> processEpoch;
  final Value<String?> publicationJson;
  final Value<int> rowid;
  const CaptureReservationsCompanion({
    this.reservationId = const Value.absent(),
    this.dumpId = const Value.absent(),
    this.incarnation = const Value.absent(),
    this.locationId = const Value.absent(),
    this.stagingPath = const Value.absent(),
    this.mode = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.state = const Value.absent(),
    this.processEpoch = const Value.absent(),
    this.publicationJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CaptureReservationsCompanion.insert({
    required String reservationId,
    required String dumpId,
    required String incarnation,
    required String locationId,
    required String stagingPath,
    required String mode,
    required int startedAt,
    required String state,
    required String processEpoch,
    this.publicationJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : reservationId = Value(reservationId),
       dumpId = Value(dumpId),
       incarnation = Value(incarnation),
       locationId = Value(locationId),
       stagingPath = Value(stagingPath),
       mode = Value(mode),
       startedAt = Value(startedAt),
       state = Value(state),
       processEpoch = Value(processEpoch);
  static Insertable<CaptureReservationRow> custom({
    Expression<String>? reservationId,
    Expression<String>? dumpId,
    Expression<String>? incarnation,
    Expression<String>? locationId,
    Expression<String>? stagingPath,
    Expression<String>? mode,
    Expression<int>? startedAt,
    Expression<String>? state,
    Expression<String>? processEpoch,
    Expression<String>? publicationJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (reservationId != null) 'reservation_id': reservationId,
      if (dumpId != null) 'dump_id': dumpId,
      if (incarnation != null) 'incarnation': incarnation,
      if (locationId != null) 'location_id': locationId,
      if (stagingPath != null) 'staging_path': stagingPath,
      if (mode != null) 'mode': mode,
      if (startedAt != null) 'started_at': startedAt,
      if (state != null) 'state': state,
      if (processEpoch != null) 'process_epoch': processEpoch,
      if (publicationJson != null) 'publication_json': publicationJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CaptureReservationsCompanion copyWith({
    Value<String>? reservationId,
    Value<String>? dumpId,
    Value<String>? incarnation,
    Value<String>? locationId,
    Value<String>? stagingPath,
    Value<String>? mode,
    Value<int>? startedAt,
    Value<String>? state,
    Value<String>? processEpoch,
    Value<String?>? publicationJson,
    Value<int>? rowid,
  }) {
    return CaptureReservationsCompanion(
      reservationId: reservationId ?? this.reservationId,
      dumpId: dumpId ?? this.dumpId,
      incarnation: incarnation ?? this.incarnation,
      locationId: locationId ?? this.locationId,
      stagingPath: stagingPath ?? this.stagingPath,
      mode: mode ?? this.mode,
      startedAt: startedAt ?? this.startedAt,
      state: state ?? this.state,
      processEpoch: processEpoch ?? this.processEpoch,
      publicationJson: publicationJson ?? this.publicationJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (reservationId.present) {
      map['reservation_id'] = Variable<String>(reservationId.value);
    }
    if (dumpId.present) {
      map['dump_id'] = Variable<String>(dumpId.value);
    }
    if (incarnation.present) {
      map['incarnation'] = Variable<String>(incarnation.value);
    }
    if (locationId.present) {
      map['location_id'] = Variable<String>(locationId.value);
    }
    if (stagingPath.present) {
      map['staging_path'] = Variable<String>(stagingPath.value);
    }
    if (mode.present) {
      map['mode'] = Variable<String>(mode.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<int>(startedAt.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (processEpoch.present) {
      map['process_epoch'] = Variable<String>(processEpoch.value);
    }
    if (publicationJson.present) {
      map['publication_json'] = Variable<String>(publicationJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CaptureReservationsCompanion(')
          ..write('reservationId: $reservationId, ')
          ..write('dumpId: $dumpId, ')
          ..write('incarnation: $incarnation, ')
          ..write('locationId: $locationId, ')
          ..write('stagingPath: $stagingPath, ')
          ..write('mode: $mode, ')
          ..write('startedAt: $startedAt, ')
          ..write('state: $state, ')
          ..write('processEpoch: $processEpoch, ')
          ..write('publicationJson: $publicationJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalDeletionBatchesTable extends LocalDeletionBatches
    with TableInfo<$LocalDeletionBatchesTable, LocalDeletionBatchRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalDeletionBatchesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _operationIdMeta = const VerificationMeta(
    'operationId',
  );
  @override
  late final GeneratedColumn<String> operationId = GeneratedColumn<String>(
    'operation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _resultsJsonMeta = const VerificationMeta(
    'resultsJson',
  );
  @override
  late final GeneratedColumn<String> resultsJson = GeneratedColumn<String>(
    'results_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    operationId,
    payloadJson,
    resultsJson,
    state,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_deletion_batches';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalDeletionBatchRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('operation_id')) {
      context.handle(
        _operationIdMeta,
        operationId.isAcceptableOrUnknown(
          data['operation_id']!,
          _operationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationIdMeta);
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('results_json')) {
      context.handle(
        _resultsJsonMeta,
        resultsJson.isAcceptableOrUnknown(
          data['results_json']!,
          _resultsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_resultsJsonMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {operationId};
  @override
  LocalDeletionBatchRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalDeletionBatchRow(
      operationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_id'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      resultsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}results_json'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
    );
  }

  @override
  $LocalDeletionBatchesTable createAlias(String alias) {
    return $LocalDeletionBatchesTable(attachedDatabase, alias);
  }
}

class LocalDeletionBatchRow extends DataClass
    implements Insertable<LocalDeletionBatchRow> {
  final String operationId;
  final String payloadJson;
  final String resultsJson;
  final String state;
  const LocalDeletionBatchRow({
    required this.operationId,
    required this.payloadJson,
    required this.resultsJson,
    required this.state,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['operation_id'] = Variable<String>(operationId);
    map['payload_json'] = Variable<String>(payloadJson);
    map['results_json'] = Variable<String>(resultsJson);
    map['state'] = Variable<String>(state);
    return map;
  }

  LocalDeletionBatchesCompanion toCompanion(bool nullToAbsent) {
    return LocalDeletionBatchesCompanion(
      operationId: Value(operationId),
      payloadJson: Value(payloadJson),
      resultsJson: Value(resultsJson),
      state: Value(state),
    );
  }

  factory LocalDeletionBatchRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalDeletionBatchRow(
      operationId: serializer.fromJson<String>(json['operationId']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      resultsJson: serializer.fromJson<String>(json['resultsJson']),
      state: serializer.fromJson<String>(json['state']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'operationId': serializer.toJson<String>(operationId),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'resultsJson': serializer.toJson<String>(resultsJson),
      'state': serializer.toJson<String>(state),
    };
  }

  LocalDeletionBatchRow copyWith({
    String? operationId,
    String? payloadJson,
    String? resultsJson,
    String? state,
  }) => LocalDeletionBatchRow(
    operationId: operationId ?? this.operationId,
    payloadJson: payloadJson ?? this.payloadJson,
    resultsJson: resultsJson ?? this.resultsJson,
    state: state ?? this.state,
  );
  LocalDeletionBatchRow copyWithCompanion(LocalDeletionBatchesCompanion data) {
    return LocalDeletionBatchRow(
      operationId: data.operationId.present
          ? data.operationId.value
          : this.operationId,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      resultsJson: data.resultsJson.present
          ? data.resultsJson.value
          : this.resultsJson,
      state: data.state.present ? data.state.value : this.state,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalDeletionBatchRow(')
          ..write('operationId: $operationId, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('resultsJson: $resultsJson, ')
          ..write('state: $state')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(operationId, payloadJson, resultsJson, state);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalDeletionBatchRow &&
          other.operationId == this.operationId &&
          other.payloadJson == this.payloadJson &&
          other.resultsJson == this.resultsJson &&
          other.state == this.state);
}

class LocalDeletionBatchesCompanion
    extends UpdateCompanion<LocalDeletionBatchRow> {
  final Value<String> operationId;
  final Value<String> payloadJson;
  final Value<String> resultsJson;
  final Value<String> state;
  final Value<int> rowid;
  const LocalDeletionBatchesCompanion({
    this.operationId = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.resultsJson = const Value.absent(),
    this.state = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalDeletionBatchesCompanion.insert({
    required String operationId,
    required String payloadJson,
    required String resultsJson,
    required String state,
    this.rowid = const Value.absent(),
  }) : operationId = Value(operationId),
       payloadJson = Value(payloadJson),
       resultsJson = Value(resultsJson),
       state = Value(state);
  static Insertable<LocalDeletionBatchRow> custom({
    Expression<String>? operationId,
    Expression<String>? payloadJson,
    Expression<String>? resultsJson,
    Expression<String>? state,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (operationId != null) 'operation_id': operationId,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (resultsJson != null) 'results_json': resultsJson,
      if (state != null) 'state': state,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalDeletionBatchesCompanion copyWith({
    Value<String>? operationId,
    Value<String>? payloadJson,
    Value<String>? resultsJson,
    Value<String>? state,
    Value<int>? rowid,
  }) {
    return LocalDeletionBatchesCompanion(
      operationId: operationId ?? this.operationId,
      payloadJson: payloadJson ?? this.payloadJson,
      resultsJson: resultsJson ?? this.resultsJson,
      state: state ?? this.state,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (operationId.present) {
      map['operation_id'] = Variable<String>(operationId.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (resultsJson.present) {
      map['results_json'] = Variable<String>(resultsJson.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalDeletionBatchesCompanion(')
          ..write('operationId: $operationId, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('resultsJson: $resultsJson, ')
          ..write('state: $state, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalDeletionTicketsTable extends LocalDeletionTickets
    with TableInfo<$LocalDeletionTicketsTable, LocalDeletionTicketRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalDeletionTicketsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _dumpIdMeta = const VerificationMeta('dumpId');
  @override
  late final GeneratedColumn<String> dumpId = GeneratedColumn<String>(
    'dump_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _incarnationMeta = const VerificationMeta(
    'incarnation',
  );
  @override
  late final GeneratedColumn<String> incarnation = GeneratedColumn<String>(
    'incarnation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ticketIdMeta = const VerificationMeta(
    'ticketId',
  );
  @override
  late final GeneratedColumn<String> ticketId = GeneratedColumn<String>(
    'ticket_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _operationIdMeta = const VerificationMeta(
    'operationId',
  );
  @override
  late final GeneratedColumn<String> operationId = GeneratedColumn<String>(
    'operation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bindingJsonMeta = const VerificationMeta(
    'bindingJson',
  );
  @override
  late final GeneratedColumn<String> bindingJson = GeneratedColumn<String>(
    'binding_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _audioStateMeta = const VerificationMeta(
    'audioState',
  );
  @override
  late final GeneratedColumn<String> audioState = GeneratedColumn<String>(
    'audio_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _metadataStateMeta = const VerificationMeta(
    'metadataState',
  );
  @override
  late final GeneratedColumn<String> metadataState = GeneratedColumn<String>(
    'metadata_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _problemJsonMeta = const VerificationMeta(
    'problemJson',
  );
  @override
  late final GeneratedColumn<String> problemJson = GeneratedColumn<String>(
    'problem_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    dumpId,
    incarnation,
    ticketId,
    operationId,
    bindingJson,
    audioState,
    metadataState,
    state,
    problemJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_deletion_tickets';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalDeletionTicketRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('dump_id')) {
      context.handle(
        _dumpIdMeta,
        dumpId.isAcceptableOrUnknown(data['dump_id']!, _dumpIdMeta),
      );
    } else if (isInserting) {
      context.missing(_dumpIdMeta);
    }
    if (data.containsKey('incarnation')) {
      context.handle(
        _incarnationMeta,
        incarnation.isAcceptableOrUnknown(
          data['incarnation']!,
          _incarnationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_incarnationMeta);
    }
    if (data.containsKey('ticket_id')) {
      context.handle(
        _ticketIdMeta,
        ticketId.isAcceptableOrUnknown(data['ticket_id']!, _ticketIdMeta),
      );
    } else if (isInserting) {
      context.missing(_ticketIdMeta);
    }
    if (data.containsKey('operation_id')) {
      context.handle(
        _operationIdMeta,
        operationId.isAcceptableOrUnknown(
          data['operation_id']!,
          _operationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationIdMeta);
    }
    if (data.containsKey('binding_json')) {
      context.handle(
        _bindingJsonMeta,
        bindingJson.isAcceptableOrUnknown(
          data['binding_json']!,
          _bindingJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_bindingJsonMeta);
    }
    if (data.containsKey('audio_state')) {
      context.handle(
        _audioStateMeta,
        audioState.isAcceptableOrUnknown(data['audio_state']!, _audioStateMeta),
      );
    } else if (isInserting) {
      context.missing(_audioStateMeta);
    }
    if (data.containsKey('metadata_state')) {
      context.handle(
        _metadataStateMeta,
        metadataState.isAcceptableOrUnknown(
          data['metadata_state']!,
          _metadataStateMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_metadataStateMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('problem_json')) {
      context.handle(
        _problemJsonMeta,
        problemJson.isAcceptableOrUnknown(
          data['problem_json']!,
          _problemJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {dumpId};
  @override
  LocalDeletionTicketRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalDeletionTicketRow(
      dumpId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dump_id'],
      )!,
      incarnation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}incarnation'],
      )!,
      ticketId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ticket_id'],
      )!,
      operationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_id'],
      )!,
      bindingJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}binding_json'],
      )!,
      audioState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}audio_state'],
      )!,
      metadataState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metadata_state'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      problemJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}problem_json'],
      ),
    );
  }

  @override
  $LocalDeletionTicketsTable createAlias(String alias) {
    return $LocalDeletionTicketsTable(attachedDatabase, alias);
  }
}

class LocalDeletionTicketRow extends DataClass
    implements Insertable<LocalDeletionTicketRow> {
  final String dumpId;
  final String incarnation;
  final String ticketId;
  final String operationId;
  final String bindingJson;
  final String audioState;
  final String metadataState;
  final String state;
  final String? problemJson;
  const LocalDeletionTicketRow({
    required this.dumpId,
    required this.incarnation,
    required this.ticketId,
    required this.operationId,
    required this.bindingJson,
    required this.audioState,
    required this.metadataState,
    required this.state,
    this.problemJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['dump_id'] = Variable<String>(dumpId);
    map['incarnation'] = Variable<String>(incarnation);
    map['ticket_id'] = Variable<String>(ticketId);
    map['operation_id'] = Variable<String>(operationId);
    map['binding_json'] = Variable<String>(bindingJson);
    map['audio_state'] = Variable<String>(audioState);
    map['metadata_state'] = Variable<String>(metadataState);
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || problemJson != null) {
      map['problem_json'] = Variable<String>(problemJson);
    }
    return map;
  }

  LocalDeletionTicketsCompanion toCompanion(bool nullToAbsent) {
    return LocalDeletionTicketsCompanion(
      dumpId: Value(dumpId),
      incarnation: Value(incarnation),
      ticketId: Value(ticketId),
      operationId: Value(operationId),
      bindingJson: Value(bindingJson),
      audioState: Value(audioState),
      metadataState: Value(metadataState),
      state: Value(state),
      problemJson: problemJson == null && nullToAbsent
          ? const Value.absent()
          : Value(problemJson),
    );
  }

  factory LocalDeletionTicketRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalDeletionTicketRow(
      dumpId: serializer.fromJson<String>(json['dumpId']),
      incarnation: serializer.fromJson<String>(json['incarnation']),
      ticketId: serializer.fromJson<String>(json['ticketId']),
      operationId: serializer.fromJson<String>(json['operationId']),
      bindingJson: serializer.fromJson<String>(json['bindingJson']),
      audioState: serializer.fromJson<String>(json['audioState']),
      metadataState: serializer.fromJson<String>(json['metadataState']),
      state: serializer.fromJson<String>(json['state']),
      problemJson: serializer.fromJson<String?>(json['problemJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'dumpId': serializer.toJson<String>(dumpId),
      'incarnation': serializer.toJson<String>(incarnation),
      'ticketId': serializer.toJson<String>(ticketId),
      'operationId': serializer.toJson<String>(operationId),
      'bindingJson': serializer.toJson<String>(bindingJson),
      'audioState': serializer.toJson<String>(audioState),
      'metadataState': serializer.toJson<String>(metadataState),
      'state': serializer.toJson<String>(state),
      'problemJson': serializer.toJson<String?>(problemJson),
    };
  }

  LocalDeletionTicketRow copyWith({
    String? dumpId,
    String? incarnation,
    String? ticketId,
    String? operationId,
    String? bindingJson,
    String? audioState,
    String? metadataState,
    String? state,
    Value<String?> problemJson = const Value.absent(),
  }) => LocalDeletionTicketRow(
    dumpId: dumpId ?? this.dumpId,
    incarnation: incarnation ?? this.incarnation,
    ticketId: ticketId ?? this.ticketId,
    operationId: operationId ?? this.operationId,
    bindingJson: bindingJson ?? this.bindingJson,
    audioState: audioState ?? this.audioState,
    metadataState: metadataState ?? this.metadataState,
    state: state ?? this.state,
    problemJson: problemJson.present ? problemJson.value : this.problemJson,
  );
  LocalDeletionTicketRow copyWithCompanion(LocalDeletionTicketsCompanion data) {
    return LocalDeletionTicketRow(
      dumpId: data.dumpId.present ? data.dumpId.value : this.dumpId,
      incarnation: data.incarnation.present
          ? data.incarnation.value
          : this.incarnation,
      ticketId: data.ticketId.present ? data.ticketId.value : this.ticketId,
      operationId: data.operationId.present
          ? data.operationId.value
          : this.operationId,
      bindingJson: data.bindingJson.present
          ? data.bindingJson.value
          : this.bindingJson,
      audioState: data.audioState.present
          ? data.audioState.value
          : this.audioState,
      metadataState: data.metadataState.present
          ? data.metadataState.value
          : this.metadataState,
      state: data.state.present ? data.state.value : this.state,
      problemJson: data.problemJson.present
          ? data.problemJson.value
          : this.problemJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalDeletionTicketRow(')
          ..write('dumpId: $dumpId, ')
          ..write('incarnation: $incarnation, ')
          ..write('ticketId: $ticketId, ')
          ..write('operationId: $operationId, ')
          ..write('bindingJson: $bindingJson, ')
          ..write('audioState: $audioState, ')
          ..write('metadataState: $metadataState, ')
          ..write('state: $state, ')
          ..write('problemJson: $problemJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    dumpId,
    incarnation,
    ticketId,
    operationId,
    bindingJson,
    audioState,
    metadataState,
    state,
    problemJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalDeletionTicketRow &&
          other.dumpId == this.dumpId &&
          other.incarnation == this.incarnation &&
          other.ticketId == this.ticketId &&
          other.operationId == this.operationId &&
          other.bindingJson == this.bindingJson &&
          other.audioState == this.audioState &&
          other.metadataState == this.metadataState &&
          other.state == this.state &&
          other.problemJson == this.problemJson);
}

class LocalDeletionTicketsCompanion
    extends UpdateCompanion<LocalDeletionTicketRow> {
  final Value<String> dumpId;
  final Value<String> incarnation;
  final Value<String> ticketId;
  final Value<String> operationId;
  final Value<String> bindingJson;
  final Value<String> audioState;
  final Value<String> metadataState;
  final Value<String> state;
  final Value<String?> problemJson;
  final Value<int> rowid;
  const LocalDeletionTicketsCompanion({
    this.dumpId = const Value.absent(),
    this.incarnation = const Value.absent(),
    this.ticketId = const Value.absent(),
    this.operationId = const Value.absent(),
    this.bindingJson = const Value.absent(),
    this.audioState = const Value.absent(),
    this.metadataState = const Value.absent(),
    this.state = const Value.absent(),
    this.problemJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalDeletionTicketsCompanion.insert({
    required String dumpId,
    required String incarnation,
    required String ticketId,
    required String operationId,
    required String bindingJson,
    required String audioState,
    required String metadataState,
    required String state,
    this.problemJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : dumpId = Value(dumpId),
       incarnation = Value(incarnation),
       ticketId = Value(ticketId),
       operationId = Value(operationId),
       bindingJson = Value(bindingJson),
       audioState = Value(audioState),
       metadataState = Value(metadataState),
       state = Value(state);
  static Insertable<LocalDeletionTicketRow> custom({
    Expression<String>? dumpId,
    Expression<String>? incarnation,
    Expression<String>? ticketId,
    Expression<String>? operationId,
    Expression<String>? bindingJson,
    Expression<String>? audioState,
    Expression<String>? metadataState,
    Expression<String>? state,
    Expression<String>? problemJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (dumpId != null) 'dump_id': dumpId,
      if (incarnation != null) 'incarnation': incarnation,
      if (ticketId != null) 'ticket_id': ticketId,
      if (operationId != null) 'operation_id': operationId,
      if (bindingJson != null) 'binding_json': bindingJson,
      if (audioState != null) 'audio_state': audioState,
      if (metadataState != null) 'metadata_state': metadataState,
      if (state != null) 'state': state,
      if (problemJson != null) 'problem_json': problemJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalDeletionTicketsCompanion copyWith({
    Value<String>? dumpId,
    Value<String>? incarnation,
    Value<String>? ticketId,
    Value<String>? operationId,
    Value<String>? bindingJson,
    Value<String>? audioState,
    Value<String>? metadataState,
    Value<String>? state,
    Value<String?>? problemJson,
    Value<int>? rowid,
  }) {
    return LocalDeletionTicketsCompanion(
      dumpId: dumpId ?? this.dumpId,
      incarnation: incarnation ?? this.incarnation,
      ticketId: ticketId ?? this.ticketId,
      operationId: operationId ?? this.operationId,
      bindingJson: bindingJson ?? this.bindingJson,
      audioState: audioState ?? this.audioState,
      metadataState: metadataState ?? this.metadataState,
      state: state ?? this.state,
      problemJson: problemJson ?? this.problemJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (dumpId.present) {
      map['dump_id'] = Variable<String>(dumpId.value);
    }
    if (incarnation.present) {
      map['incarnation'] = Variable<String>(incarnation.value);
    }
    if (ticketId.present) {
      map['ticket_id'] = Variable<String>(ticketId.value);
    }
    if (operationId.present) {
      map['operation_id'] = Variable<String>(operationId.value);
    }
    if (bindingJson.present) {
      map['binding_json'] = Variable<String>(bindingJson.value);
    }
    if (audioState.present) {
      map['audio_state'] = Variable<String>(audioState.value);
    }
    if (metadataState.present) {
      map['metadata_state'] = Variable<String>(metadataState.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (problemJson.present) {
      map['problem_json'] = Variable<String>(problemJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalDeletionTicketsCompanion(')
          ..write('dumpId: $dumpId, ')
          ..write('incarnation: $incarnation, ')
          ..write('ticketId: $ticketId, ')
          ..write('operationId: $operationId, ')
          ..write('bindingJson: $bindingJson, ')
          ..write('audioState: $audioState, ')
          ..write('metadataState: $metadataState, ')
          ..write('state: $state, ')
          ..write('problemJson: $problemJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $NotebooksTable extends Notebooks
    with TableInfo<$NotebooksTable, NotebookRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $NotebooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _docJsonMeta = const VerificationMeta(
    'docJson',
  );
  @override
  late final GeneratedColumn<String> docJson = GeneratedColumn<String>(
    'doc_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _inkJsonMeta = const VerificationMeta(
    'inkJson',
  );
  @override
  late final GeneratedColumn<String> inkJson = GeneratedColumn<String>(
    'ink_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _folderIdMeta = const VerificationMeta(
    'folderId',
  );
  @override
  late final GeneratedColumn<String> folderId = GeneratedColumn<String>(
    'folder_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rulingMeta = const VerificationMeta('ruling');
  @override
  late final GeneratedColumn<String> ruling = GeneratedColumn<String>(
    'ruling',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastPenStyleMeta = const VerificationMeta(
    'lastPenStyle',
  );
  @override
  late final GeneratedColumn<String> lastPenStyle = GeneratedColumn<String>(
    'last_pen_style',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _passwordHashMeta = const VerificationMeta(
    'passwordHash',
  );
  @override
  late final GeneratedColumn<String> passwordHash = GeneratedColumn<String>(
    'password_hash',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _passwordSaltMeta = const VerificationMeta(
    'passwordSalt',
  );
  @override
  late final GeneratedColumn<String> passwordSalt = GeneratedColumn<String>(
    'password_salt',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _passwordIterationsMeta =
      const VerificationMeta('passwordIterations');
  @override
  late final GeneratedColumn<int> passwordIterations = GeneratedColumn<int>(
    'password_iterations',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _passwordHashPrevMeta = const VerificationMeta(
    'passwordHashPrev',
  );
  @override
  late final GeneratedColumn<String> passwordHashPrev = GeneratedColumn<String>(
    'password_hash_prev',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _syncDirtyMeta = const VerificationMeta(
    'syncDirty',
  );
  @override
  late final GeneratedColumn<bool> syncDirty = GeneratedColumn<bool>(
    'sync_dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("sync_dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _syncedSeqMeta = const VerificationMeta(
    'syncedSeq',
  );
  @override
  late final GeneratedColumn<int> syncedSeq = GeneratedColumn<int>(
    'synced_seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  @override
  late final GeneratedColumn<bool> pinned = GeneratedColumn<bool>(
    'pinned',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pinned" IN (0, 1))',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    createdAt,
    updatedAt,
    docJson,
    inkJson,
    folderId,
    ruling,
    lastPenStyle,
    passwordHash,
    passwordSalt,
    passwordIterations,
    passwordHashPrev,
    syncDirty,
    syncedSeq,
    deletedAt,
    pinned,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'notebooks';
  @override
  VerificationContext validateIntegrity(
    Insertable<NotebookRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('doc_json')) {
      context.handle(
        _docJsonMeta,
        docJson.isAcceptableOrUnknown(data['doc_json']!, _docJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_docJsonMeta);
    }
    if (data.containsKey('ink_json')) {
      context.handle(
        _inkJsonMeta,
        inkJson.isAcceptableOrUnknown(data['ink_json']!, _inkJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_inkJsonMeta);
    }
    if (data.containsKey('folder_id')) {
      context.handle(
        _folderIdMeta,
        folderId.isAcceptableOrUnknown(data['folder_id']!, _folderIdMeta),
      );
    }
    if (data.containsKey('ruling')) {
      context.handle(
        _rulingMeta,
        ruling.isAcceptableOrUnknown(data['ruling']!, _rulingMeta),
      );
    }
    if (data.containsKey('last_pen_style')) {
      context.handle(
        _lastPenStyleMeta,
        lastPenStyle.isAcceptableOrUnknown(
          data['last_pen_style']!,
          _lastPenStyleMeta,
        ),
      );
    }
    if (data.containsKey('password_hash')) {
      context.handle(
        _passwordHashMeta,
        passwordHash.isAcceptableOrUnknown(
          data['password_hash']!,
          _passwordHashMeta,
        ),
      );
    }
    if (data.containsKey('password_salt')) {
      context.handle(
        _passwordSaltMeta,
        passwordSalt.isAcceptableOrUnknown(
          data['password_salt']!,
          _passwordSaltMeta,
        ),
      );
    }
    if (data.containsKey('password_iterations')) {
      context.handle(
        _passwordIterationsMeta,
        passwordIterations.isAcceptableOrUnknown(
          data['password_iterations']!,
          _passwordIterationsMeta,
        ),
      );
    }
    if (data.containsKey('password_hash_prev')) {
      context.handle(
        _passwordHashPrevMeta,
        passwordHashPrev.isAcceptableOrUnknown(
          data['password_hash_prev']!,
          _passwordHashPrevMeta,
        ),
      );
    }
    if (data.containsKey('sync_dirty')) {
      context.handle(
        _syncDirtyMeta,
        syncDirty.isAcceptableOrUnknown(data['sync_dirty']!, _syncDirtyMeta),
      );
    }
    if (data.containsKey('synced_seq')) {
      context.handle(
        _syncedSeqMeta,
        syncedSeq.isAcceptableOrUnknown(data['synced_seq']!, _syncedSeqMeta),
      );
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('pinned')) {
      context.handle(
        _pinnedMeta,
        pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  NotebookRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return NotebookRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      docJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}doc_json'],
      )!,
      inkJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ink_json'],
      )!,
      folderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder_id'],
      ),
      ruling: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ruling'],
      ),
      lastPenStyle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_pen_style'],
      ),
      passwordHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}password_hash'],
      ),
      passwordSalt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}password_salt'],
      ),
      passwordIterations: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}password_iterations'],
      ),
      passwordHashPrev: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}password_hash_prev'],
      ),
      syncDirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}sync_dirty'],
      )!,
      syncedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_seq'],
      ),
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
      pinned: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pinned'],
      ),
    );
  }

  @override
  $NotebooksTable createAlias(String alias) {
    return $NotebooksTable(attachedDatabase, alias);
  }
}

class NotebookRow extends DataClass implements Insertable<NotebookRow> {
  final String id;
  final String title;

  /// Epoch milliseconds, stored as integers so the JSON payload columns and the
  /// timestamps read identically from raw SQL.
  final int createdAt;
  final int updatedAt;
  final String docJson;
  final String inkJson;

  /// Null means unfiled. Deliberately NOT a foreign key with cascade: a
  /// deleted folder must unfile its notebooks, never delete them.
  final String? folderId;

  /// How the page is ruled: 'blank', 'small', or 'medium'.
  ///
  /// Stored as the enum's NAME rather than its index, so reordering the enum
  /// cannot silently re-rule every existing notebook. Nullable because every
  /// notebook written before v10 has no value, and null reads as blank —
  /// which is exactly how those pages have always rendered.
  final String? ruling;

  /// The nib last used in this notebook: 'ballpoint' or 'fountain'.
  ///
  /// Same contract as [ruling]: stored as the enum's NAME, nullable because
  /// every notebook written before v16 has no value, and null reads as the
  /// fountain default. Per-notebook because the user keeps different
  /// notebooks in different pens and each must reopen with its own.
  final String? lastPenStyle;

  /// PBKDF2-HMAC-SHA256 verifier metadata. Password text is never stored.
  /// All three are nullable together: null hash means protection is off.
  final String? passwordHash;
  final String? passwordSalt;
  final int? passwordIterations;

  /// Previous verifier hash: proof for a transition and, after a clear, the
  /// durable tombstone that prevents a stale replica from restoring that hash.
  final String? passwordHashPrev;

  /// True when this notebook has local edits the server has not accepted.
  ///
  /// Set on every local save and cleared only by a push the server confirmed.
  /// Defaulting to TRUE matters: notebooks that already existed before sync
  /// arrived have never been pushed, so treating them as clean would leave a
  /// user's entire library invisible to their other devices forever.
  final bool syncDirty;

  /// The server sequence this row was last reconciled at, or null if never.
  /// Diagnostic: it makes "did this actually sync?" answerable from the data.
  final int? syncedSeq;

  /// Epoch ms when this notebook was moved to the trash; null means live.
  ///
  /// Deletion is a two-stage affair (user decision): a delete files the row
  /// here for 7 days before it is purged, so a deletion that synced from
  /// another device — or a slip of the finger — is recoverable from
  /// Settings → Trash.
  final int? deletedAt;

  /// User pin. Nullable for an additive, appearance-preserving migration.
  final bool? pinned;
  const NotebookRow({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.docJson,
    required this.inkJson,
    this.folderId,
    this.ruling,
    this.lastPenStyle,
    this.passwordHash,
    this.passwordSalt,
    this.passwordIterations,
    this.passwordHashPrev,
    required this.syncDirty,
    this.syncedSeq,
    this.deletedAt,
    this.pinned,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    map['doc_json'] = Variable<String>(docJson);
    map['ink_json'] = Variable<String>(inkJson);
    if (!nullToAbsent || folderId != null) {
      map['folder_id'] = Variable<String>(folderId);
    }
    if (!nullToAbsent || ruling != null) {
      map['ruling'] = Variable<String>(ruling);
    }
    if (!nullToAbsent || lastPenStyle != null) {
      map['last_pen_style'] = Variable<String>(lastPenStyle);
    }
    if (!nullToAbsent || passwordHash != null) {
      map['password_hash'] = Variable<String>(passwordHash);
    }
    if (!nullToAbsent || passwordSalt != null) {
      map['password_salt'] = Variable<String>(passwordSalt);
    }
    if (!nullToAbsent || passwordIterations != null) {
      map['password_iterations'] = Variable<int>(passwordIterations);
    }
    if (!nullToAbsent || passwordHashPrev != null) {
      map['password_hash_prev'] = Variable<String>(passwordHashPrev);
    }
    map['sync_dirty'] = Variable<bool>(syncDirty);
    if (!nullToAbsent || syncedSeq != null) {
      map['synced_seq'] = Variable<int>(syncedSeq);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    if (!nullToAbsent || pinned != null) {
      map['pinned'] = Variable<bool>(pinned);
    }
    return map;
  }

  NotebooksCompanion toCompanion(bool nullToAbsent) {
    return NotebooksCompanion(
      id: Value(id),
      title: Value(title),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      docJson: Value(docJson),
      inkJson: Value(inkJson),
      folderId: folderId == null && nullToAbsent
          ? const Value.absent()
          : Value(folderId),
      ruling: ruling == null && nullToAbsent
          ? const Value.absent()
          : Value(ruling),
      lastPenStyle: lastPenStyle == null && nullToAbsent
          ? const Value.absent()
          : Value(lastPenStyle),
      passwordHash: passwordHash == null && nullToAbsent
          ? const Value.absent()
          : Value(passwordHash),
      passwordSalt: passwordSalt == null && nullToAbsent
          ? const Value.absent()
          : Value(passwordSalt),
      passwordIterations: passwordIterations == null && nullToAbsent
          ? const Value.absent()
          : Value(passwordIterations),
      passwordHashPrev: passwordHashPrev == null && nullToAbsent
          ? const Value.absent()
          : Value(passwordHashPrev),
      syncDirty: Value(syncDirty),
      syncedSeq: syncedSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(syncedSeq),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      pinned: pinned == null && nullToAbsent
          ? const Value.absent()
          : Value(pinned),
    );
  }

  factory NotebookRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return NotebookRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      docJson: serializer.fromJson<String>(json['docJson']),
      inkJson: serializer.fromJson<String>(json['inkJson']),
      folderId: serializer.fromJson<String?>(json['folderId']),
      ruling: serializer.fromJson<String?>(json['ruling']),
      lastPenStyle: serializer.fromJson<String?>(json['lastPenStyle']),
      passwordHash: serializer.fromJson<String?>(json['passwordHash']),
      passwordSalt: serializer.fromJson<String?>(json['passwordSalt']),
      passwordIterations: serializer.fromJson<int?>(json['passwordIterations']),
      passwordHashPrev: serializer.fromJson<String?>(json['passwordHashPrev']),
      syncDirty: serializer.fromJson<bool>(json['syncDirty']),
      syncedSeq: serializer.fromJson<int?>(json['syncedSeq']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
      pinned: serializer.fromJson<bool?>(json['pinned']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'docJson': serializer.toJson<String>(docJson),
      'inkJson': serializer.toJson<String>(inkJson),
      'folderId': serializer.toJson<String?>(folderId),
      'ruling': serializer.toJson<String?>(ruling),
      'lastPenStyle': serializer.toJson<String?>(lastPenStyle),
      'passwordHash': serializer.toJson<String?>(passwordHash),
      'passwordSalt': serializer.toJson<String?>(passwordSalt),
      'passwordIterations': serializer.toJson<int?>(passwordIterations),
      'passwordHashPrev': serializer.toJson<String?>(passwordHashPrev),
      'syncDirty': serializer.toJson<bool>(syncDirty),
      'syncedSeq': serializer.toJson<int?>(syncedSeq),
      'deletedAt': serializer.toJson<int?>(deletedAt),
      'pinned': serializer.toJson<bool?>(pinned),
    };
  }

  NotebookRow copyWith({
    String? id,
    String? title,
    int? createdAt,
    int? updatedAt,
    String? docJson,
    String? inkJson,
    Value<String?> folderId = const Value.absent(),
    Value<String?> ruling = const Value.absent(),
    Value<String?> lastPenStyle = const Value.absent(),
    Value<String?> passwordHash = const Value.absent(),
    Value<String?> passwordSalt = const Value.absent(),
    Value<int?> passwordIterations = const Value.absent(),
    Value<String?> passwordHashPrev = const Value.absent(),
    bool? syncDirty,
    Value<int?> syncedSeq = const Value.absent(),
    Value<int?> deletedAt = const Value.absent(),
    Value<bool?> pinned = const Value.absent(),
  }) => NotebookRow(
    id: id ?? this.id,
    title: title ?? this.title,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    docJson: docJson ?? this.docJson,
    inkJson: inkJson ?? this.inkJson,
    folderId: folderId.present ? folderId.value : this.folderId,
    ruling: ruling.present ? ruling.value : this.ruling,
    lastPenStyle: lastPenStyle.present ? lastPenStyle.value : this.lastPenStyle,
    passwordHash: passwordHash.present ? passwordHash.value : this.passwordHash,
    passwordSalt: passwordSalt.present ? passwordSalt.value : this.passwordSalt,
    passwordIterations: passwordIterations.present
        ? passwordIterations.value
        : this.passwordIterations,
    passwordHashPrev: passwordHashPrev.present
        ? passwordHashPrev.value
        : this.passwordHashPrev,
    syncDirty: syncDirty ?? this.syncDirty,
    syncedSeq: syncedSeq.present ? syncedSeq.value : this.syncedSeq,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    pinned: pinned.present ? pinned.value : this.pinned,
  );
  NotebookRow copyWithCompanion(NotebooksCompanion data) {
    return NotebookRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      docJson: data.docJson.present ? data.docJson.value : this.docJson,
      inkJson: data.inkJson.present ? data.inkJson.value : this.inkJson,
      folderId: data.folderId.present ? data.folderId.value : this.folderId,
      ruling: data.ruling.present ? data.ruling.value : this.ruling,
      lastPenStyle: data.lastPenStyle.present
          ? data.lastPenStyle.value
          : this.lastPenStyle,
      passwordHash: data.passwordHash.present
          ? data.passwordHash.value
          : this.passwordHash,
      passwordSalt: data.passwordSalt.present
          ? data.passwordSalt.value
          : this.passwordSalt,
      passwordIterations: data.passwordIterations.present
          ? data.passwordIterations.value
          : this.passwordIterations,
      passwordHashPrev: data.passwordHashPrev.present
          ? data.passwordHashPrev.value
          : this.passwordHashPrev,
      syncDirty: data.syncDirty.present ? data.syncDirty.value : this.syncDirty,
      syncedSeq: data.syncedSeq.present ? data.syncedSeq.value : this.syncedSeq,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
    );
  }

  @override
  String toString() {
    return (StringBuffer('NotebookRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('docJson: $docJson, ')
          ..write('inkJson: $inkJson, ')
          ..write('folderId: $folderId, ')
          ..write('ruling: $ruling, ')
          ..write('lastPenStyle: $lastPenStyle, ')
          ..write('passwordHash: $passwordHash, ')
          ..write('passwordSalt: $passwordSalt, ')
          ..write('passwordIterations: $passwordIterations, ')
          ..write('passwordHashPrev: $passwordHashPrev, ')
          ..write('syncDirty: $syncDirty, ')
          ..write('syncedSeq: $syncedSeq, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('pinned: $pinned')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    createdAt,
    updatedAt,
    docJson,
    inkJson,
    folderId,
    ruling,
    lastPenStyle,
    passwordHash,
    passwordSalt,
    passwordIterations,
    passwordHashPrev,
    syncDirty,
    syncedSeq,
    deletedAt,
    pinned,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NotebookRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.docJson == this.docJson &&
          other.inkJson == this.inkJson &&
          other.folderId == this.folderId &&
          other.ruling == this.ruling &&
          other.lastPenStyle == this.lastPenStyle &&
          other.passwordHash == this.passwordHash &&
          other.passwordSalt == this.passwordSalt &&
          other.passwordIterations == this.passwordIterations &&
          other.passwordHashPrev == this.passwordHashPrev &&
          other.syncDirty == this.syncDirty &&
          other.syncedSeq == this.syncedSeq &&
          other.deletedAt == this.deletedAt &&
          other.pinned == this.pinned);
}

class NotebooksCompanion extends UpdateCompanion<NotebookRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<String> docJson;
  final Value<String> inkJson;
  final Value<String?> folderId;
  final Value<String?> ruling;
  final Value<String?> lastPenStyle;
  final Value<String?> passwordHash;
  final Value<String?> passwordSalt;
  final Value<int?> passwordIterations;
  final Value<String?> passwordHashPrev;
  final Value<bool> syncDirty;
  final Value<int?> syncedSeq;
  final Value<int?> deletedAt;
  final Value<bool?> pinned;
  final Value<int> rowid;
  const NotebooksCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.docJson = const Value.absent(),
    this.inkJson = const Value.absent(),
    this.folderId = const Value.absent(),
    this.ruling = const Value.absent(),
    this.lastPenStyle = const Value.absent(),
    this.passwordHash = const Value.absent(),
    this.passwordSalt = const Value.absent(),
    this.passwordIterations = const Value.absent(),
    this.passwordHashPrev = const Value.absent(),
    this.syncDirty = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.pinned = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  NotebooksCompanion.insert({
    required String id,
    required String title,
    required int createdAt,
    required int updatedAt,
    required String docJson,
    required String inkJson,
    this.folderId = const Value.absent(),
    this.ruling = const Value.absent(),
    this.lastPenStyle = const Value.absent(),
    this.passwordHash = const Value.absent(),
    this.passwordSalt = const Value.absent(),
    this.passwordIterations = const Value.absent(),
    this.passwordHashPrev = const Value.absent(),
    this.syncDirty = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.pinned = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt),
       docJson = Value(docJson),
       inkJson = Value(inkJson);
  static Insertable<NotebookRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<String>? docJson,
    Expression<String>? inkJson,
    Expression<String>? folderId,
    Expression<String>? ruling,
    Expression<String>? lastPenStyle,
    Expression<String>? passwordHash,
    Expression<String>? passwordSalt,
    Expression<int>? passwordIterations,
    Expression<String>? passwordHashPrev,
    Expression<bool>? syncDirty,
    Expression<int>? syncedSeq,
    Expression<int>? deletedAt,
    Expression<bool>? pinned,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (docJson != null) 'doc_json': docJson,
      if (inkJson != null) 'ink_json': inkJson,
      if (folderId != null) 'folder_id': folderId,
      if (ruling != null) 'ruling': ruling,
      if (lastPenStyle != null) 'last_pen_style': lastPenStyle,
      if (passwordHash != null) 'password_hash': passwordHash,
      if (passwordSalt != null) 'password_salt': passwordSalt,
      if (passwordIterations != null) 'password_iterations': passwordIterations,
      if (passwordHashPrev != null) 'password_hash_prev': passwordHashPrev,
      if (syncDirty != null) 'sync_dirty': syncDirty,
      if (syncedSeq != null) 'synced_seq': syncedSeq,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (pinned != null) 'pinned': pinned,
      if (rowid != null) 'rowid': rowid,
    });
  }

  NotebooksCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<String>? docJson,
    Value<String>? inkJson,
    Value<String?>? folderId,
    Value<String?>? ruling,
    Value<String?>? lastPenStyle,
    Value<String?>? passwordHash,
    Value<String?>? passwordSalt,
    Value<int?>? passwordIterations,
    Value<String?>? passwordHashPrev,
    Value<bool>? syncDirty,
    Value<int?>? syncedSeq,
    Value<int?>? deletedAt,
    Value<bool?>? pinned,
    Value<int>? rowid,
  }) {
    return NotebooksCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      docJson: docJson ?? this.docJson,
      inkJson: inkJson ?? this.inkJson,
      folderId: folderId ?? this.folderId,
      ruling: ruling ?? this.ruling,
      lastPenStyle: lastPenStyle ?? this.lastPenStyle,
      passwordHash: passwordHash ?? this.passwordHash,
      passwordSalt: passwordSalt ?? this.passwordSalt,
      passwordIterations: passwordIterations ?? this.passwordIterations,
      passwordHashPrev: passwordHashPrev ?? this.passwordHashPrev,
      syncDirty: syncDirty ?? this.syncDirty,
      syncedSeq: syncedSeq ?? this.syncedSeq,
      deletedAt: deletedAt ?? this.deletedAt,
      pinned: pinned ?? this.pinned,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (docJson.present) {
      map['doc_json'] = Variable<String>(docJson.value);
    }
    if (inkJson.present) {
      map['ink_json'] = Variable<String>(inkJson.value);
    }
    if (folderId.present) {
      map['folder_id'] = Variable<String>(folderId.value);
    }
    if (ruling.present) {
      map['ruling'] = Variable<String>(ruling.value);
    }
    if (lastPenStyle.present) {
      map['last_pen_style'] = Variable<String>(lastPenStyle.value);
    }
    if (passwordHash.present) {
      map['password_hash'] = Variable<String>(passwordHash.value);
    }
    if (passwordSalt.present) {
      map['password_salt'] = Variable<String>(passwordSalt.value);
    }
    if (passwordIterations.present) {
      map['password_iterations'] = Variable<int>(passwordIterations.value);
    }
    if (passwordHashPrev.present) {
      map['password_hash_prev'] = Variable<String>(passwordHashPrev.value);
    }
    if (syncDirty.present) {
      map['sync_dirty'] = Variable<bool>(syncDirty.value);
    }
    if (syncedSeq.present) {
      map['synced_seq'] = Variable<int>(syncedSeq.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (pinned.present) {
      map['pinned'] = Variable<bool>(pinned.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('NotebooksCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('docJson: $docJson, ')
          ..write('inkJson: $inkJson, ')
          ..write('folderId: $folderId, ')
          ..write('ruling: $ruling, ')
          ..write('lastPenStyle: $lastPenStyle, ')
          ..write('passwordHash: $passwordHash, ')
          ..write('passwordSalt: $passwordSalt, ')
          ..write('passwordIterations: $passwordIterations, ')
          ..write('passwordHashPrev: $passwordHashPrev, ')
          ..write('syncDirty: $syncDirty, ')
          ..write('syncedSeq: $syncedSeq, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('pinned: $pinned, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncTombstonesTable extends SyncTombstones
    with TableInfo<$SyncTombstonesTable, SyncTombstoneRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncTombstonesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _entityTypeMeta = const VerificationMeta(
    'entityType',
  );
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
    'entity_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [entityType, entityId, deletedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_tombstones';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncTombstoneRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('entity_type')) {
      context.handle(
        _entityTypeMeta,
        entityType.isAcceptableOrUnknown(data['entity_type']!, _entityTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_deletedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {entityType, entityId};
  @override
  SyncTombstoneRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncTombstoneRow(
      entityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_type'],
      )!,
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      )!,
    );
  }

  @override
  $SyncTombstonesTable createAlias(String alias) {
    return $SyncTombstonesTable(attachedDatabase, alias);
  }
}

class SyncTombstoneRow extends DataClass
    implements Insertable<SyncTombstoneRow> {
  /// 'notebook' or 'note'. Not an enum column: the server validates the
  /// vocabulary and a client that guesses wrong should fail loudly there.
  final String entityType;
  final String entityId;
  final int deletedAt;
  const SyncTombstoneRow({
    required this.entityType,
    required this.entityId,
    required this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['entity_type'] = Variable<String>(entityType);
    map['entity_id'] = Variable<String>(entityId);
    map['deleted_at'] = Variable<int>(deletedAt);
    return map;
  }

  SyncTombstonesCompanion toCompanion(bool nullToAbsent) {
    return SyncTombstonesCompanion(
      entityType: Value(entityType),
      entityId: Value(entityId),
      deletedAt: Value(deletedAt),
    );
  }

  factory SyncTombstoneRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncTombstoneRow(
      entityType: serializer.fromJson<String>(json['entityType']),
      entityId: serializer.fromJson<String>(json['entityId']),
      deletedAt: serializer.fromJson<int>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'entityType': serializer.toJson<String>(entityType),
      'entityId': serializer.toJson<String>(entityId),
      'deletedAt': serializer.toJson<int>(deletedAt),
    };
  }

  SyncTombstoneRow copyWith({
    String? entityType,
    String? entityId,
    int? deletedAt,
  }) => SyncTombstoneRow(
    entityType: entityType ?? this.entityType,
    entityId: entityId ?? this.entityId,
    deletedAt: deletedAt ?? this.deletedAt,
  );
  SyncTombstoneRow copyWithCompanion(SyncTombstonesCompanion data) {
    return SyncTombstoneRow(
      entityType: data.entityType.present
          ? data.entityType.value
          : this.entityType,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncTombstoneRow(')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(entityType, entityId, deletedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncTombstoneRow &&
          other.entityType == this.entityType &&
          other.entityId == this.entityId &&
          other.deletedAt == this.deletedAt);
}

class SyncTombstonesCompanion extends UpdateCompanion<SyncTombstoneRow> {
  final Value<String> entityType;
  final Value<String> entityId;
  final Value<int> deletedAt;
  final Value<int> rowid;
  const SyncTombstonesCompanion({
    this.entityType = const Value.absent(),
    this.entityId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncTombstonesCompanion.insert({
    required String entityType,
    required String entityId,
    required int deletedAt,
    this.rowid = const Value.absent(),
  }) : entityType = Value(entityType),
       entityId = Value(entityId),
       deletedAt = Value(deletedAt);
  static Insertable<SyncTombstoneRow> custom({
    Expression<String>? entityType,
    Expression<String>? entityId,
    Expression<int>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (entityType != null) 'entity_type': entityType,
      if (entityId != null) 'entity_id': entityId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncTombstonesCompanion copyWith({
    Value<String>? entityType,
    Value<String>? entityId,
    Value<int>? deletedAt,
    Value<int>? rowid,
  }) {
    return SyncTombstonesCompanion(
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncTombstonesCompanion(')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncStatesTable extends SyncStates
    with TableInfo<$SyncStatesTable, SyncStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastPulledSeqMeta = const VerificationMeta(
    'lastPulledSeq',
  );
  @override
  late final GeneratedColumn<int> lastPulledSeq = GeneratedColumn<int>(
    'last_pulled_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastSyncedAtMeta = const VerificationMeta(
    'lastSyncedAt',
  );
  @override
  late final GeneratedColumn<int> lastSyncedAt = GeneratedColumn<int>(
    'last_synced_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    deviceId,
    lastPulledSeq,
    lastSyncedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncStateRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('last_pulled_seq')) {
      context.handle(
        _lastPulledSeqMeta,
        lastPulledSeq.isAcceptableOrUnknown(
          data['last_pulled_seq']!,
          _lastPulledSeqMeta,
        ),
      );
    }
    if (data.containsKey('last_synced_at')) {
      context.handle(
        _lastSyncedAtMeta,
        lastSyncedAt.isAcceptableOrUnknown(
          data['last_synced_at']!,
          _lastSyncedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncStateRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      lastPulledSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_pulled_seq'],
      )!,
      lastSyncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_synced_at'],
      ),
    );
  }

  @override
  $SyncStatesTable createAlias(String alias) {
    return $SyncStatesTable(attachedDatabase, alias);
  }
}

class SyncStateRow extends DataClass implements Insertable<SyncStateRow> {
  final int id;

  /// Stable per-install replica id. A reinstall is legitimately a new replica
  /// and syncs from zero rather than inheriting a checkpoint it cannot honour.
  final String deviceId;

  /// Highest server sequence this device has applied IN FULL. Advanced only
  /// after every change in a page lands, so a crash mid-page re-fetches that
  /// page instead of skipping it.
  final int lastPulledSeq;
  final int? lastSyncedAt;
  const SyncStateRow({
    required this.id,
    required this.deviceId,
    required this.lastPulledSeq,
    this.lastSyncedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['device_id'] = Variable<String>(deviceId);
    map['last_pulled_seq'] = Variable<int>(lastPulledSeq);
    if (!nullToAbsent || lastSyncedAt != null) {
      map['last_synced_at'] = Variable<int>(lastSyncedAt);
    }
    return map;
  }

  SyncStatesCompanion toCompanion(bool nullToAbsent) {
    return SyncStatesCompanion(
      id: Value(id),
      deviceId: Value(deviceId),
      lastPulledSeq: Value(lastPulledSeq),
      lastSyncedAt: lastSyncedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncedAt),
    );
  }

  factory SyncStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncStateRow(
      id: serializer.fromJson<int>(json['id']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      lastPulledSeq: serializer.fromJson<int>(json['lastPulledSeq']),
      lastSyncedAt: serializer.fromJson<int?>(json['lastSyncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'deviceId': serializer.toJson<String>(deviceId),
      'lastPulledSeq': serializer.toJson<int>(lastPulledSeq),
      'lastSyncedAt': serializer.toJson<int?>(lastSyncedAt),
    };
  }

  SyncStateRow copyWith({
    int? id,
    String? deviceId,
    int? lastPulledSeq,
    Value<int?> lastSyncedAt = const Value.absent(),
  }) => SyncStateRow(
    id: id ?? this.id,
    deviceId: deviceId ?? this.deviceId,
    lastPulledSeq: lastPulledSeq ?? this.lastPulledSeq,
    lastSyncedAt: lastSyncedAt.present ? lastSyncedAt.value : this.lastSyncedAt,
  );
  SyncStateRow copyWithCompanion(SyncStatesCompanion data) {
    return SyncStateRow(
      id: data.id.present ? data.id.value : this.id,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      lastPulledSeq: data.lastPulledSeq.present
          ? data.lastPulledSeq.value
          : this.lastPulledSeq,
      lastSyncedAt: data.lastSyncedAt.present
          ? data.lastSyncedAt.value
          : this.lastSyncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncStateRow(')
          ..write('id: $id, ')
          ..write('deviceId: $deviceId, ')
          ..write('lastPulledSeq: $lastPulledSeq, ')
          ..write('lastSyncedAt: $lastSyncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, deviceId, lastPulledSeq, lastSyncedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncStateRow &&
          other.id == this.id &&
          other.deviceId == this.deviceId &&
          other.lastPulledSeq == this.lastPulledSeq &&
          other.lastSyncedAt == this.lastSyncedAt);
}

class SyncStatesCompanion extends UpdateCompanion<SyncStateRow> {
  final Value<int> id;
  final Value<String> deviceId;
  final Value<int> lastPulledSeq;
  final Value<int?> lastSyncedAt;
  const SyncStatesCompanion({
    this.id = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.lastPulledSeq = const Value.absent(),
    this.lastSyncedAt = const Value.absent(),
  });
  SyncStatesCompanion.insert({
    this.id = const Value.absent(),
    required String deviceId,
    this.lastPulledSeq = const Value.absent(),
    this.lastSyncedAt = const Value.absent(),
  }) : deviceId = Value(deviceId);
  static Insertable<SyncStateRow> custom({
    Expression<int>? id,
    Expression<String>? deviceId,
    Expression<int>? lastPulledSeq,
    Expression<int>? lastSyncedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (deviceId != null) 'device_id': deviceId,
      if (lastPulledSeq != null) 'last_pulled_seq': lastPulledSeq,
      if (lastSyncedAt != null) 'last_synced_at': lastSyncedAt,
    });
  }

  SyncStatesCompanion copyWith({
    Value<int>? id,
    Value<String>? deviceId,
    Value<int>? lastPulledSeq,
    Value<int?>? lastSyncedAt,
  }) {
    return SyncStatesCompanion(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      lastPulledSeq: lastPulledSeq ?? this.lastPulledSeq,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (lastPulledSeq.present) {
      map['last_pulled_seq'] = Variable<int>(lastPulledSeq.value);
    }
    if (lastSyncedAt.present) {
      map['last_synced_at'] = Variable<int>(lastSyncedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStatesCompanion(')
          ..write('id: $id, ')
          ..write('deviceId: $deviceId, ')
          ..write('lastPulledSeq: $lastPulledSeq, ')
          ..write('lastSyncedAt: $lastSyncedAt')
          ..write(')'))
        .toString();
  }
}

class $InkIndexEntriesTable extends InkIndexEntries
    with TableInfo<$InkIndexEntriesTable, InkIndexEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $InkIndexEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _notebookIdMeta = const VerificationMeta(
    'notebookId',
  );
  @override
  late final GeneratedColumn<String> notebookId = GeneratedColumn<String>(
    'notebook_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lineIdMeta = const VerificationMeta('lineId');
  @override
  late final GeneratedColumn<String> lineId = GeneratedColumn<String>(
    'line_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _wordTextMeta = const VerificationMeta(
    'wordText',
  );
  @override
  late final GeneratedColumn<String> wordText = GeneratedColumn<String>(
    'word_text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _wordTextLowerMeta = const VerificationMeta(
    'wordTextLower',
  );
  @override
  late final GeneratedColumn<String> wordTextLower = GeneratedColumn<String>(
    'word_text_lower',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bboxJsonMeta = const VerificationMeta(
    'bboxJson',
  );
  @override
  late final GeneratedColumn<String> bboxJson = GeneratedColumn<String>(
    'bbox_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _strokeIdsJsonMeta = const VerificationMeta(
    'strokeIdsJson',
  );
  @override
  late final GeneratedColumn<String> strokeIdsJson = GeneratedColumn<String>(
    'stroke_ids_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
    'model',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _indexedAtMeta = const VerificationMeta(
    'indexedAt',
  );
  @override
  late final GeneratedColumn<int> indexedAt = GeneratedColumn<int>(
    'indexed_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    notebookId,
    lineId,
    wordText,
    wordTextLower,
    bboxJson,
    strokeIdsJson,
    model,
    indexedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ink_index_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<InkIndexEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('notebook_id')) {
      context.handle(
        _notebookIdMeta,
        notebookId.isAcceptableOrUnknown(data['notebook_id']!, _notebookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_notebookIdMeta);
    }
    if (data.containsKey('line_id')) {
      context.handle(
        _lineIdMeta,
        lineId.isAcceptableOrUnknown(data['line_id']!, _lineIdMeta),
      );
    } else if (isInserting) {
      context.missing(_lineIdMeta);
    }
    if (data.containsKey('word_text')) {
      context.handle(
        _wordTextMeta,
        wordText.isAcceptableOrUnknown(data['word_text']!, _wordTextMeta),
      );
    } else if (isInserting) {
      context.missing(_wordTextMeta);
    }
    if (data.containsKey('word_text_lower')) {
      context.handle(
        _wordTextLowerMeta,
        wordTextLower.isAcceptableOrUnknown(
          data['word_text_lower']!,
          _wordTextLowerMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_wordTextLowerMeta);
    }
    if (data.containsKey('bbox_json')) {
      context.handle(
        _bboxJsonMeta,
        bboxJson.isAcceptableOrUnknown(data['bbox_json']!, _bboxJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_bboxJsonMeta);
    }
    if (data.containsKey('stroke_ids_json')) {
      context.handle(
        _strokeIdsJsonMeta,
        strokeIdsJson.isAcceptableOrUnknown(
          data['stroke_ids_json']!,
          _strokeIdsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_strokeIdsJsonMeta);
    }
    if (data.containsKey('model')) {
      context.handle(
        _modelMeta,
        model.isAcceptableOrUnknown(data['model']!, _modelMeta),
      );
    } else if (isInserting) {
      context.missing(_modelMeta);
    }
    if (data.containsKey('indexed_at')) {
      context.handle(
        _indexedAtMeta,
        indexedAt.isAcceptableOrUnknown(data['indexed_at']!, _indexedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_indexedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  InkIndexEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return InkIndexEntry(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      notebookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}notebook_id'],
      )!,
      lineId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}line_id'],
      )!,
      wordText: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}word_text'],
      )!,
      wordTextLower: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}word_text_lower'],
      )!,
      bboxJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bbox_json'],
      )!,
      strokeIdsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stroke_ids_json'],
      )!,
      model: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model'],
      )!,
      indexedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}indexed_at'],
      )!,
    );
  }

  @override
  $InkIndexEntriesTable createAlias(String alias) {
    return $InkIndexEntriesTable(attachedDatabase, alias);
  }
}

class InkIndexEntry extends DataClass implements Insertable<InkIndexEntry> {
  final String id;
  final String notebookId;
  final String lineId;
  final String wordText;
  final String wordTextLower;
  final String bboxJson;
  final String strokeIdsJson;
  final String model;
  final int indexedAt;
  const InkIndexEntry({
    required this.id,
    required this.notebookId,
    required this.lineId,
    required this.wordText,
    required this.wordTextLower,
    required this.bboxJson,
    required this.strokeIdsJson,
    required this.model,
    required this.indexedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['notebook_id'] = Variable<String>(notebookId);
    map['line_id'] = Variable<String>(lineId);
    map['word_text'] = Variable<String>(wordText);
    map['word_text_lower'] = Variable<String>(wordTextLower);
    map['bbox_json'] = Variable<String>(bboxJson);
    map['stroke_ids_json'] = Variable<String>(strokeIdsJson);
    map['model'] = Variable<String>(model);
    map['indexed_at'] = Variable<int>(indexedAt);
    return map;
  }

  InkIndexEntriesCompanion toCompanion(bool nullToAbsent) {
    return InkIndexEntriesCompanion(
      id: Value(id),
      notebookId: Value(notebookId),
      lineId: Value(lineId),
      wordText: Value(wordText),
      wordTextLower: Value(wordTextLower),
      bboxJson: Value(bboxJson),
      strokeIdsJson: Value(strokeIdsJson),
      model: Value(model),
      indexedAt: Value(indexedAt),
    );
  }

  factory InkIndexEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return InkIndexEntry(
      id: serializer.fromJson<String>(json['id']),
      notebookId: serializer.fromJson<String>(json['notebookId']),
      lineId: serializer.fromJson<String>(json['lineId']),
      wordText: serializer.fromJson<String>(json['wordText']),
      wordTextLower: serializer.fromJson<String>(json['wordTextLower']),
      bboxJson: serializer.fromJson<String>(json['bboxJson']),
      strokeIdsJson: serializer.fromJson<String>(json['strokeIdsJson']),
      model: serializer.fromJson<String>(json['model']),
      indexedAt: serializer.fromJson<int>(json['indexedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'notebookId': serializer.toJson<String>(notebookId),
      'lineId': serializer.toJson<String>(lineId),
      'wordText': serializer.toJson<String>(wordText),
      'wordTextLower': serializer.toJson<String>(wordTextLower),
      'bboxJson': serializer.toJson<String>(bboxJson),
      'strokeIdsJson': serializer.toJson<String>(strokeIdsJson),
      'model': serializer.toJson<String>(model),
      'indexedAt': serializer.toJson<int>(indexedAt),
    };
  }

  InkIndexEntry copyWith({
    String? id,
    String? notebookId,
    String? lineId,
    String? wordText,
    String? wordTextLower,
    String? bboxJson,
    String? strokeIdsJson,
    String? model,
    int? indexedAt,
  }) => InkIndexEntry(
    id: id ?? this.id,
    notebookId: notebookId ?? this.notebookId,
    lineId: lineId ?? this.lineId,
    wordText: wordText ?? this.wordText,
    wordTextLower: wordTextLower ?? this.wordTextLower,
    bboxJson: bboxJson ?? this.bboxJson,
    strokeIdsJson: strokeIdsJson ?? this.strokeIdsJson,
    model: model ?? this.model,
    indexedAt: indexedAt ?? this.indexedAt,
  );
  InkIndexEntry copyWithCompanion(InkIndexEntriesCompanion data) {
    return InkIndexEntry(
      id: data.id.present ? data.id.value : this.id,
      notebookId: data.notebookId.present
          ? data.notebookId.value
          : this.notebookId,
      lineId: data.lineId.present ? data.lineId.value : this.lineId,
      wordText: data.wordText.present ? data.wordText.value : this.wordText,
      wordTextLower: data.wordTextLower.present
          ? data.wordTextLower.value
          : this.wordTextLower,
      bboxJson: data.bboxJson.present ? data.bboxJson.value : this.bboxJson,
      strokeIdsJson: data.strokeIdsJson.present
          ? data.strokeIdsJson.value
          : this.strokeIdsJson,
      model: data.model.present ? data.model.value : this.model,
      indexedAt: data.indexedAt.present ? data.indexedAt.value : this.indexedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('InkIndexEntry(')
          ..write('id: $id, ')
          ..write('notebookId: $notebookId, ')
          ..write('lineId: $lineId, ')
          ..write('wordText: $wordText, ')
          ..write('wordTextLower: $wordTextLower, ')
          ..write('bboxJson: $bboxJson, ')
          ..write('strokeIdsJson: $strokeIdsJson, ')
          ..write('model: $model, ')
          ..write('indexedAt: $indexedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    notebookId,
    lineId,
    wordText,
    wordTextLower,
    bboxJson,
    strokeIdsJson,
    model,
    indexedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is InkIndexEntry &&
          other.id == this.id &&
          other.notebookId == this.notebookId &&
          other.lineId == this.lineId &&
          other.wordText == this.wordText &&
          other.wordTextLower == this.wordTextLower &&
          other.bboxJson == this.bboxJson &&
          other.strokeIdsJson == this.strokeIdsJson &&
          other.model == this.model &&
          other.indexedAt == this.indexedAt);
}

class InkIndexEntriesCompanion extends UpdateCompanion<InkIndexEntry> {
  final Value<String> id;
  final Value<String> notebookId;
  final Value<String> lineId;
  final Value<String> wordText;
  final Value<String> wordTextLower;
  final Value<String> bboxJson;
  final Value<String> strokeIdsJson;
  final Value<String> model;
  final Value<int> indexedAt;
  final Value<int> rowid;
  const InkIndexEntriesCompanion({
    this.id = const Value.absent(),
    this.notebookId = const Value.absent(),
    this.lineId = const Value.absent(),
    this.wordText = const Value.absent(),
    this.wordTextLower = const Value.absent(),
    this.bboxJson = const Value.absent(),
    this.strokeIdsJson = const Value.absent(),
    this.model = const Value.absent(),
    this.indexedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  InkIndexEntriesCompanion.insert({
    required String id,
    required String notebookId,
    required String lineId,
    required String wordText,
    required String wordTextLower,
    required String bboxJson,
    required String strokeIdsJson,
    required String model,
    required int indexedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       notebookId = Value(notebookId),
       lineId = Value(lineId),
       wordText = Value(wordText),
       wordTextLower = Value(wordTextLower),
       bboxJson = Value(bboxJson),
       strokeIdsJson = Value(strokeIdsJson),
       model = Value(model),
       indexedAt = Value(indexedAt);
  static Insertable<InkIndexEntry> custom({
    Expression<String>? id,
    Expression<String>? notebookId,
    Expression<String>? lineId,
    Expression<String>? wordText,
    Expression<String>? wordTextLower,
    Expression<String>? bboxJson,
    Expression<String>? strokeIdsJson,
    Expression<String>? model,
    Expression<int>? indexedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (notebookId != null) 'notebook_id': notebookId,
      if (lineId != null) 'line_id': lineId,
      if (wordText != null) 'word_text': wordText,
      if (wordTextLower != null) 'word_text_lower': wordTextLower,
      if (bboxJson != null) 'bbox_json': bboxJson,
      if (strokeIdsJson != null) 'stroke_ids_json': strokeIdsJson,
      if (model != null) 'model': model,
      if (indexedAt != null) 'indexed_at': indexedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  InkIndexEntriesCompanion copyWith({
    Value<String>? id,
    Value<String>? notebookId,
    Value<String>? lineId,
    Value<String>? wordText,
    Value<String>? wordTextLower,
    Value<String>? bboxJson,
    Value<String>? strokeIdsJson,
    Value<String>? model,
    Value<int>? indexedAt,
    Value<int>? rowid,
  }) {
    return InkIndexEntriesCompanion(
      id: id ?? this.id,
      notebookId: notebookId ?? this.notebookId,
      lineId: lineId ?? this.lineId,
      wordText: wordText ?? this.wordText,
      wordTextLower: wordTextLower ?? this.wordTextLower,
      bboxJson: bboxJson ?? this.bboxJson,
      strokeIdsJson: strokeIdsJson ?? this.strokeIdsJson,
      model: model ?? this.model,
      indexedAt: indexedAt ?? this.indexedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (notebookId.present) {
      map['notebook_id'] = Variable<String>(notebookId.value);
    }
    if (lineId.present) {
      map['line_id'] = Variable<String>(lineId.value);
    }
    if (wordText.present) {
      map['word_text'] = Variable<String>(wordText.value);
    }
    if (wordTextLower.present) {
      map['word_text_lower'] = Variable<String>(wordTextLower.value);
    }
    if (bboxJson.present) {
      map['bbox_json'] = Variable<String>(bboxJson.value);
    }
    if (strokeIdsJson.present) {
      map['stroke_ids_json'] = Variable<String>(strokeIdsJson.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (indexedAt.present) {
      map['indexed_at'] = Variable<int>(indexedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('InkIndexEntriesCompanion(')
          ..write('id: $id, ')
          ..write('notebookId: $notebookId, ')
          ..write('lineId: $lineId, ')
          ..write('wordText: $wordText, ')
          ..write('wordTextLower: $wordTextLower, ')
          ..write('bboxJson: $bboxJson, ')
          ..write('strokeIdsJson: $strokeIdsJson, ')
          ..write('model: $model, ')
          ..write('indexedAt: $indexedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalSettingsTable extends LocalSettings
    with TableInfo<$LocalSettingsTable, LocalSettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalSettingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  LocalSettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalSettingRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $LocalSettingsTable createAlias(String alias) {
    return $LocalSettingsTable(attachedDatabase, alias);
  }
}

class LocalSettingRow extends DataClass implements Insertable<LocalSettingRow> {
  final String key;
  final String value;
  const LocalSettingRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  LocalSettingsCompanion toCompanion(bool nullToAbsent) {
    return LocalSettingsCompanion(key: Value(key), value: Value(value));
  }

  factory LocalSettingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalSettingRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  LocalSettingRow copyWith({String? key, String? value}) =>
      LocalSettingRow(key: key ?? this.key, value: value ?? this.value);
  LocalSettingRow copyWithCompanion(LocalSettingsCompanion data) {
    return LocalSettingRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalSettingRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalSettingRow &&
          other.key == this.key &&
          other.value == this.value);
}

class LocalSettingsCompanion extends UpdateCompanion<LocalSettingRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const LocalSettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalSettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<LocalSettingRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalSettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return LocalSettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalSettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TodosTable extends Todos with TableInfo<$TodosTable, TodoRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TodosTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _doneAtMeta = const VerificationMeta('doneAt');
  @override
  late final GeneratedColumn<String> doneAt = GeneratedColumn<String>(
    'done_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dueDateMeta = const VerificationMeta(
    'dueDate',
  );
  @override
  late final GeneratedColumn<String> dueDate = GeneratedColumn<String>(
    'due_date',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('manual'),
  );
  static const VerificationMeta _sourceRefMeta = const VerificationMeta(
    'sourceRef',
  );
  @override
  late final GeneratedColumn<String> sourceRef = GeneratedColumn<String>(
    'source_ref',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<String> deletedAt = GeneratedColumn<String>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _syncDirtyMeta = const VerificationMeta(
    'syncDirty',
  );
  @override
  late final GeneratedColumn<bool> syncDirty = GeneratedColumn<bool>(
    'sync_dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("sync_dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _syncedSeqMeta = const VerificationMeta(
    'syncedSeq',
  );
  @override
  late final GeneratedColumn<int> syncedSeq = GeneratedColumn<int>(
    'synced_seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _folderIdMeta = const VerificationMeta(
    'folderId',
  );
  @override
  late final GeneratedColumn<String> folderId = GeneratedColumn<String>(
    'folder_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _captureFingerprintMeta =
      const VerificationMeta('captureFingerprint');
  @override
  late final GeneratedColumn<String> captureFingerprint =
      GeneratedColumn<String>(
        'capture_fingerprint',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  @override
  late final GeneratedColumn<bool> pinned = GeneratedColumn<bool>(
    'pinned',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pinned" IN (0, 1))',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    body,
    doneAt,
    dueDate,
    source,
    sourceRef,
    createdAt,
    updatedAt,
    deletedAt,
    syncDirty,
    syncedSeq,
    folderId,
    captureFingerprint,
    pinned,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'todos';
  @override
  VerificationContext validateIntegrity(
    Insertable<TodoRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('text')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['text']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('done_at')) {
      context.handle(
        _doneAtMeta,
        doneAt.isAcceptableOrUnknown(data['done_at']!, _doneAtMeta),
      );
    }
    if (data.containsKey('due_date')) {
      context.handle(
        _dueDateMeta,
        dueDate.isAcceptableOrUnknown(data['due_date']!, _dueDateMeta),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('source_ref')) {
      context.handle(
        _sourceRefMeta,
        sourceRef.isAcceptableOrUnknown(data['source_ref']!, _sourceRefMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('sync_dirty')) {
      context.handle(
        _syncDirtyMeta,
        syncDirty.isAcceptableOrUnknown(data['sync_dirty']!, _syncDirtyMeta),
      );
    }
    if (data.containsKey('synced_seq')) {
      context.handle(
        _syncedSeqMeta,
        syncedSeq.isAcceptableOrUnknown(data['synced_seq']!, _syncedSeqMeta),
      );
    }
    if (data.containsKey('folder_id')) {
      context.handle(
        _folderIdMeta,
        folderId.isAcceptableOrUnknown(data['folder_id']!, _folderIdMeta),
      );
    }
    if (data.containsKey('capture_fingerprint')) {
      context.handle(
        _captureFingerprintMeta,
        captureFingerprint.isAcceptableOrUnknown(
          data['capture_fingerprint']!,
          _captureFingerprintMeta,
        ),
      );
    }
    if (data.containsKey('pinned')) {
      context.handle(
        _pinnedMeta,
        pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TodoRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TodoRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}text'],
      )!,
      doneAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}done_at'],
      ),
      dueDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}due_date'],
      ),
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      sourceRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ref'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}deleted_at'],
      ),
      syncDirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}sync_dirty'],
      )!,
      syncedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_seq'],
      ),
      folderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder_id'],
      ),
      captureFingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}capture_fingerprint'],
      ),
      pinned: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pinned'],
      ),
    );
  }

  @override
  $TodosTable createAlias(String alias) {
    return $TodosTable(attachedDatabase, alias);
  }
}

class TodoRow extends DataClass implements Insertable<TodoRow> {
  final String id;

  /// The item text. Named explicitly: a getter called `text` would shadow
  /// the Drift column builder of the same name.
  final String body;

  /// ISO instant when the item was checked off; null = open. Unchecking
  /// clears it. Nothing ever auto-deletes based on this.
  final String? doneAt;

  /// ISO date `YYYY-MM-DD`, no time. Null = Someday (undated).
  final String? dueDate;

  /// 'manual' now; 'voice', 'summary', 'notebook' reserved for Phases 2-3.
  final String source;

  /// Reserved provenance link (dump id / notebook id + block id).
  final String? sourceRef;
  final String createdAt;
  final String updatedAt;

  /// ISO instant of the soft delete; null = live. Soft, not a tombstone
  /// row: the deletion travels as an ordinary upsert carrying this field,
  /// and the 5-second undo snackbar restores by clearing it.
  final String? deletedAt;

  /// Same contract as notebooks: true until the server confirms a push.
  final bool syncDirty;
  final int? syncedSeq;

  /// v1.24.0: the SHARED folder this item is filed under (same `folders`
  /// rows as recordings and notebooks). Null = unfiled. Declared last so a
  /// fresh onCreate and a v23 `addColumn` upgrade agree on column order.
  final String? folderId;

  /// v1.28.0: LOCAL-ONLY fingerprint of the voice parse that created (or
  /// last reconciled) this row — SHA-1 of the parsed RESULT, so a
  /// re-transcribe that yields the same items is the same capture. Never
  /// pushed, never read from a pull (same pattern as `summary_requested_at`).
  /// Null on manual rows and on rows that arrived from a peer.
  final String? captureFingerprint;

  /// User pin. Nullable for an additive, appearance-preserving migration.
  final bool? pinned;
  const TodoRow({
    required this.id,
    required this.body,
    this.doneAt,
    this.dueDate,
    required this.source,
    this.sourceRef,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    required this.syncDirty,
    this.syncedSeq,
    this.folderId,
    this.captureFingerprint,
    this.pinned,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['text'] = Variable<String>(body);
    if (!nullToAbsent || doneAt != null) {
      map['done_at'] = Variable<String>(doneAt);
    }
    if (!nullToAbsent || dueDate != null) {
      map['due_date'] = Variable<String>(dueDate);
    }
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || sourceRef != null) {
      map['source_ref'] = Variable<String>(sourceRef);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<String>(deletedAt);
    }
    map['sync_dirty'] = Variable<bool>(syncDirty);
    if (!nullToAbsent || syncedSeq != null) {
      map['synced_seq'] = Variable<int>(syncedSeq);
    }
    if (!nullToAbsent || folderId != null) {
      map['folder_id'] = Variable<String>(folderId);
    }
    if (!nullToAbsent || captureFingerprint != null) {
      map['capture_fingerprint'] = Variable<String>(captureFingerprint);
    }
    if (!nullToAbsent || pinned != null) {
      map['pinned'] = Variable<bool>(pinned);
    }
    return map;
  }

  TodosCompanion toCompanion(bool nullToAbsent) {
    return TodosCompanion(
      id: Value(id),
      body: Value(body),
      doneAt: doneAt == null && nullToAbsent
          ? const Value.absent()
          : Value(doneAt),
      dueDate: dueDate == null && nullToAbsent
          ? const Value.absent()
          : Value(dueDate),
      source: Value(source),
      sourceRef: sourceRef == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceRef),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      syncDirty: Value(syncDirty),
      syncedSeq: syncedSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(syncedSeq),
      folderId: folderId == null && nullToAbsent
          ? const Value.absent()
          : Value(folderId),
      captureFingerprint: captureFingerprint == null && nullToAbsent
          ? const Value.absent()
          : Value(captureFingerprint),
      pinned: pinned == null && nullToAbsent
          ? const Value.absent()
          : Value(pinned),
    );
  }

  factory TodoRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TodoRow(
      id: serializer.fromJson<String>(json['id']),
      body: serializer.fromJson<String>(json['body']),
      doneAt: serializer.fromJson<String?>(json['doneAt']),
      dueDate: serializer.fromJson<String?>(json['dueDate']),
      source: serializer.fromJson<String>(json['source']),
      sourceRef: serializer.fromJson<String?>(json['sourceRef']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
      deletedAt: serializer.fromJson<String?>(json['deletedAt']),
      syncDirty: serializer.fromJson<bool>(json['syncDirty']),
      syncedSeq: serializer.fromJson<int?>(json['syncedSeq']),
      folderId: serializer.fromJson<String?>(json['folderId']),
      captureFingerprint: serializer.fromJson<String?>(
        json['captureFingerprint'],
      ),
      pinned: serializer.fromJson<bool?>(json['pinned']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'body': serializer.toJson<String>(body),
      'doneAt': serializer.toJson<String?>(doneAt),
      'dueDate': serializer.toJson<String?>(dueDate),
      'source': serializer.toJson<String>(source),
      'sourceRef': serializer.toJson<String?>(sourceRef),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
      'deletedAt': serializer.toJson<String?>(deletedAt),
      'syncDirty': serializer.toJson<bool>(syncDirty),
      'syncedSeq': serializer.toJson<int?>(syncedSeq),
      'folderId': serializer.toJson<String?>(folderId),
      'captureFingerprint': serializer.toJson<String?>(captureFingerprint),
      'pinned': serializer.toJson<bool?>(pinned),
    };
  }

  TodoRow copyWith({
    String? id,
    String? body,
    Value<String?> doneAt = const Value.absent(),
    Value<String?> dueDate = const Value.absent(),
    String? source,
    Value<String?> sourceRef = const Value.absent(),
    String? createdAt,
    String? updatedAt,
    Value<String?> deletedAt = const Value.absent(),
    bool? syncDirty,
    Value<int?> syncedSeq = const Value.absent(),
    Value<String?> folderId = const Value.absent(),
    Value<String?> captureFingerprint = const Value.absent(),
    Value<bool?> pinned = const Value.absent(),
  }) => TodoRow(
    id: id ?? this.id,
    body: body ?? this.body,
    doneAt: doneAt.present ? doneAt.value : this.doneAt,
    dueDate: dueDate.present ? dueDate.value : this.dueDate,
    source: source ?? this.source,
    sourceRef: sourceRef.present ? sourceRef.value : this.sourceRef,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    syncDirty: syncDirty ?? this.syncDirty,
    syncedSeq: syncedSeq.present ? syncedSeq.value : this.syncedSeq,
    folderId: folderId.present ? folderId.value : this.folderId,
    captureFingerprint: captureFingerprint.present
        ? captureFingerprint.value
        : this.captureFingerprint,
    pinned: pinned.present ? pinned.value : this.pinned,
  );
  TodoRow copyWithCompanion(TodosCompanion data) {
    return TodoRow(
      id: data.id.present ? data.id.value : this.id,
      body: data.body.present ? data.body.value : this.body,
      doneAt: data.doneAt.present ? data.doneAt.value : this.doneAt,
      dueDate: data.dueDate.present ? data.dueDate.value : this.dueDate,
      source: data.source.present ? data.source.value : this.source,
      sourceRef: data.sourceRef.present ? data.sourceRef.value : this.sourceRef,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      syncDirty: data.syncDirty.present ? data.syncDirty.value : this.syncDirty,
      syncedSeq: data.syncedSeq.present ? data.syncedSeq.value : this.syncedSeq,
      folderId: data.folderId.present ? data.folderId.value : this.folderId,
      captureFingerprint: data.captureFingerprint.present
          ? data.captureFingerprint.value
          : this.captureFingerprint,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TodoRow(')
          ..write('id: $id, ')
          ..write('body: $body, ')
          ..write('doneAt: $doneAt, ')
          ..write('dueDate: $dueDate, ')
          ..write('source: $source, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('syncDirty: $syncDirty, ')
          ..write('syncedSeq: $syncedSeq, ')
          ..write('folderId: $folderId, ')
          ..write('captureFingerprint: $captureFingerprint, ')
          ..write('pinned: $pinned')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    body,
    doneAt,
    dueDate,
    source,
    sourceRef,
    createdAt,
    updatedAt,
    deletedAt,
    syncDirty,
    syncedSeq,
    folderId,
    captureFingerprint,
    pinned,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TodoRow &&
          other.id == this.id &&
          other.body == this.body &&
          other.doneAt == this.doneAt &&
          other.dueDate == this.dueDate &&
          other.source == this.source &&
          other.sourceRef == this.sourceRef &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.syncDirty == this.syncDirty &&
          other.syncedSeq == this.syncedSeq &&
          other.folderId == this.folderId &&
          other.captureFingerprint == this.captureFingerprint &&
          other.pinned == this.pinned);
}

class TodosCompanion extends UpdateCompanion<TodoRow> {
  final Value<String> id;
  final Value<String> body;
  final Value<String?> doneAt;
  final Value<String?> dueDate;
  final Value<String> source;
  final Value<String?> sourceRef;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<String?> deletedAt;
  final Value<bool> syncDirty;
  final Value<int?> syncedSeq;
  final Value<String?> folderId;
  final Value<String?> captureFingerprint;
  final Value<bool?> pinned;
  final Value<int> rowid;
  const TodosCompanion({
    this.id = const Value.absent(),
    this.body = const Value.absent(),
    this.doneAt = const Value.absent(),
    this.dueDate = const Value.absent(),
    this.source = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.syncDirty = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.folderId = const Value.absent(),
    this.captureFingerprint = const Value.absent(),
    this.pinned = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TodosCompanion.insert({
    required String id,
    required String body,
    this.doneAt = const Value.absent(),
    this.dueDate = const Value.absent(),
    this.source = const Value.absent(),
    this.sourceRef = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.deletedAt = const Value.absent(),
    this.syncDirty = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.folderId = const Value.absent(),
    this.captureFingerprint = const Value.absent(),
    this.pinned = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       body = Value(body),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<TodoRow> custom({
    Expression<String>? id,
    Expression<String>? body,
    Expression<String>? doneAt,
    Expression<String>? dueDate,
    Expression<String>? source,
    Expression<String>? sourceRef,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<String>? deletedAt,
    Expression<bool>? syncDirty,
    Expression<int>? syncedSeq,
    Expression<String>? folderId,
    Expression<String>? captureFingerprint,
    Expression<bool>? pinned,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (body != null) 'text': body,
      if (doneAt != null) 'done_at': doneAt,
      if (dueDate != null) 'due_date': dueDate,
      if (source != null) 'source': source,
      if (sourceRef != null) 'source_ref': sourceRef,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (syncDirty != null) 'sync_dirty': syncDirty,
      if (syncedSeq != null) 'synced_seq': syncedSeq,
      if (folderId != null) 'folder_id': folderId,
      if (captureFingerprint != null) 'capture_fingerprint': captureFingerprint,
      if (pinned != null) 'pinned': pinned,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TodosCompanion copyWith({
    Value<String>? id,
    Value<String>? body,
    Value<String?>? doneAt,
    Value<String?>? dueDate,
    Value<String>? source,
    Value<String?>? sourceRef,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<String?>? deletedAt,
    Value<bool>? syncDirty,
    Value<int?>? syncedSeq,
    Value<String?>? folderId,
    Value<String?>? captureFingerprint,
    Value<bool?>? pinned,
    Value<int>? rowid,
  }) {
    return TodosCompanion(
      id: id ?? this.id,
      body: body ?? this.body,
      doneAt: doneAt ?? this.doneAt,
      dueDate: dueDate ?? this.dueDate,
      source: source ?? this.source,
      sourceRef: sourceRef ?? this.sourceRef,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      syncDirty: syncDirty ?? this.syncDirty,
      syncedSeq: syncedSeq ?? this.syncedSeq,
      folderId: folderId ?? this.folderId,
      captureFingerprint: captureFingerprint ?? this.captureFingerprint,
      pinned: pinned ?? this.pinned,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (body.present) {
      map['text'] = Variable<String>(body.value);
    }
    if (doneAt.present) {
      map['done_at'] = Variable<String>(doneAt.value);
    }
    if (dueDate.present) {
      map['due_date'] = Variable<String>(dueDate.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (sourceRef.present) {
      map['source_ref'] = Variable<String>(sourceRef.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<String>(deletedAt.value);
    }
    if (syncDirty.present) {
      map['sync_dirty'] = Variable<bool>(syncDirty.value);
    }
    if (syncedSeq.present) {
      map['synced_seq'] = Variable<int>(syncedSeq.value);
    }
    if (folderId.present) {
      map['folder_id'] = Variable<String>(folderId.value);
    }
    if (captureFingerprint.present) {
      map['capture_fingerprint'] = Variable<String>(captureFingerprint.value);
    }
    if (pinned.present) {
      map['pinned'] = Variable<bool>(pinned.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TodosCompanion(')
          ..write('id: $id, ')
          ..write('body: $body, ')
          ..write('doneAt: $doneAt, ')
          ..write('dueDate: $dueDate, ')
          ..write('source: $source, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('syncDirty: $syncDirty, ')
          ..write('syncedSeq: $syncedSeq, ')
          ..write('folderId: $folderId, ')
          ..write('captureFingerprint: $captureFingerprint, ')
          ..write('pinned: $pinned, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CalendarEventsTable extends CalendarEvents
    with TableInfo<$CalendarEventsTable, CalendarEventRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CalendarEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startMeta = const VerificationMeta('start');
  @override
  late final GeneratedColumn<String> start = GeneratedColumn<String>(
    'start',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endMeta = const VerificationMeta('end');
  @override
  late final GeneratedColumn<String> end = GeneratedColumn<String>(
    'end_',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _allDayMeta = const VerificationMeta('allDay');
  @override
  late final GeneratedColumn<bool> allDay = GeneratedColumn<bool>(
    'all_day',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("all_day" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _timeZoneMeta = const VerificationMeta(
    'timeZone',
  );
  @override
  late final GeneratedColumn<String> timeZone = GeneratedColumn<String>(
    'time_zone',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _needsDateMeta = const VerificationMeta(
    'needsDate',
  );
  @override
  late final GeneratedColumn<bool> needsDate = GeneratedColumn<bool>(
    'needs_date',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("needs_date" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('voice'),
  );
  static const VerificationMeta _sourceRefMeta = const VerificationMeta(
    'sourceRef',
  );
  @override
  late final GeneratedColumn<String> sourceRef = GeneratedColumn<String>(
    'source_ref',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<String> createdAt = GeneratedColumn<String>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<String> updatedAt = GeneratedColumn<String>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<String> deletedAt = GeneratedColumn<String>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _syncDirtyMeta = const VerificationMeta(
    'syncDirty',
  );
  @override
  late final GeneratedColumn<bool> syncDirty = GeneratedColumn<bool>(
    'sync_dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("sync_dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _syncedSeqMeta = const VerificationMeta(
    'syncedSeq',
  );
  @override
  late final GeneratedColumn<int> syncedSeq = GeneratedColumn<int>(
    'synced_seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _googleEventIdMeta = const VerificationMeta(
    'googleEventId',
  );
  @override
  late final GeneratedColumn<String> googleEventId = GeneratedColumn<String>(
    'google_event_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _googleHtmlLinkMeta = const VerificationMeta(
    'googleHtmlLink',
  );
  @override
  late final GeneratedColumn<String> googleHtmlLink = GeneratedColumn<String>(
    'google_html_link',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _googleUpdatedMeta = const VerificationMeta(
    'googleUpdated',
  );
  @override
  late final GeneratedColumn<String> googleUpdated = GeneratedColumn<String>(
    'google_updated',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _captureFingerprintMeta =
      const VerificationMeta('captureFingerprint');
  @override
  late final GeneratedColumn<String> captureFingerprint =
      GeneratedColumn<String>(
        'capture_fingerprint',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    start,
    end,
    allDay,
    timeZone,
    needsDate,
    source,
    sourceRef,
    createdAt,
    updatedAt,
    deletedAt,
    syncDirty,
    syncedSeq,
    googleEventId,
    googleHtmlLink,
    googleUpdated,
    captureFingerprint,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'calendar_events';
  @override
  VerificationContext validateIntegrity(
    Insertable<CalendarEventRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('start')) {
      context.handle(
        _startMeta,
        start.isAcceptableOrUnknown(data['start']!, _startMeta),
      );
    } else if (isInserting) {
      context.missing(_startMeta);
    }
    if (data.containsKey('end_')) {
      context.handle(
        _endMeta,
        end.isAcceptableOrUnknown(data['end_']!, _endMeta),
      );
    } else if (isInserting) {
      context.missing(_endMeta);
    }
    if (data.containsKey('all_day')) {
      context.handle(
        _allDayMeta,
        allDay.isAcceptableOrUnknown(data['all_day']!, _allDayMeta),
      );
    }
    if (data.containsKey('time_zone')) {
      context.handle(
        _timeZoneMeta,
        timeZone.isAcceptableOrUnknown(data['time_zone']!, _timeZoneMeta),
      );
    } else if (isInserting) {
      context.missing(_timeZoneMeta);
    }
    if (data.containsKey('needs_date')) {
      context.handle(
        _needsDateMeta,
        needsDate.isAcceptableOrUnknown(data['needs_date']!, _needsDateMeta),
      );
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    }
    if (data.containsKey('source_ref')) {
      context.handle(
        _sourceRefMeta,
        sourceRef.isAcceptableOrUnknown(data['source_ref']!, _sourceRefMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('sync_dirty')) {
      context.handle(
        _syncDirtyMeta,
        syncDirty.isAcceptableOrUnknown(data['sync_dirty']!, _syncDirtyMeta),
      );
    }
    if (data.containsKey('synced_seq')) {
      context.handle(
        _syncedSeqMeta,
        syncedSeq.isAcceptableOrUnknown(data['synced_seq']!, _syncedSeqMeta),
      );
    }
    if (data.containsKey('google_event_id')) {
      context.handle(
        _googleEventIdMeta,
        googleEventId.isAcceptableOrUnknown(
          data['google_event_id']!,
          _googleEventIdMeta,
        ),
      );
    }
    if (data.containsKey('google_html_link')) {
      context.handle(
        _googleHtmlLinkMeta,
        googleHtmlLink.isAcceptableOrUnknown(
          data['google_html_link']!,
          _googleHtmlLinkMeta,
        ),
      );
    }
    if (data.containsKey('google_updated')) {
      context.handle(
        _googleUpdatedMeta,
        googleUpdated.isAcceptableOrUnknown(
          data['google_updated']!,
          _googleUpdatedMeta,
        ),
      );
    }
    if (data.containsKey('capture_fingerprint')) {
      context.handle(
        _captureFingerprintMeta,
        captureFingerprint.isAcceptableOrUnknown(
          data['capture_fingerprint']!,
          _captureFingerprintMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CalendarEventRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CalendarEventRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      start: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}start'],
      )!,
      end: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}end_'],
      )!,
      allDay: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}all_day'],
      )!,
      timeZone: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}time_zone'],
      )!,
      needsDate: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}needs_date'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      sourceRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_ref'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}updated_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}deleted_at'],
      ),
      syncDirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}sync_dirty'],
      )!,
      syncedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_seq'],
      ),
      googleEventId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}google_event_id'],
      ),
      googleHtmlLink: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}google_html_link'],
      ),
      googleUpdated: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}google_updated'],
      ),
      captureFingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}capture_fingerprint'],
      ),
    );
  }

  @override
  $CalendarEventsTable createAlias(String alias) {
    return $CalendarEventsTable(attachedDatabase, alias);
  }
}

class CalendarEventRow extends DataClass
    implements Insertable<CalendarEventRow> {
  final String id;
  final String title;

  /// `YYYY-MM-DD` when [allDay], else local `YYYY-MM-DDTHH:MM:SS`.
  final String start;

  /// Same shape as [start]; all-day end is EXCLUSIVE (the next day). The
  /// column is `end_` because `end` is an SQL keyword; the wire key is `end`.
  final String end;
  final bool allDay;
  final String timeZone;

  /// The phrase carried no date (C3): sits on the recording day until the
  /// user fixes it on Google; cleared by the next pull that moves it.
  final bool needsDate;
  final String source;

  /// The dump id the event was captured from.
  final String? sourceRef;
  final String createdAt;
  final String updatedAt;
  final String? deletedAt;
  final bool syncDirty;
  final int? syncedSeq;
  final String? googleEventId;
  final String? googleHtmlLink;
  final String? googleUpdated;

  /// LOCAL-ONLY, same contract as [Todos.captureFingerprint].
  final String? captureFingerprint;
  const CalendarEventRow({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    required this.timeZone,
    required this.needsDate,
    required this.source,
    this.sourceRef,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    required this.syncDirty,
    this.syncedSeq,
    this.googleEventId,
    this.googleHtmlLink,
    this.googleUpdated,
    this.captureFingerprint,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['start'] = Variable<String>(start);
    map['end_'] = Variable<String>(end);
    map['all_day'] = Variable<bool>(allDay);
    map['time_zone'] = Variable<String>(timeZone);
    map['needs_date'] = Variable<bool>(needsDate);
    map['source'] = Variable<String>(source);
    if (!nullToAbsent || sourceRef != null) {
      map['source_ref'] = Variable<String>(sourceRef);
    }
    map['created_at'] = Variable<String>(createdAt);
    map['updated_at'] = Variable<String>(updatedAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<String>(deletedAt);
    }
    map['sync_dirty'] = Variable<bool>(syncDirty);
    if (!nullToAbsent || syncedSeq != null) {
      map['synced_seq'] = Variable<int>(syncedSeq);
    }
    if (!nullToAbsent || googleEventId != null) {
      map['google_event_id'] = Variable<String>(googleEventId);
    }
    if (!nullToAbsent || googleHtmlLink != null) {
      map['google_html_link'] = Variable<String>(googleHtmlLink);
    }
    if (!nullToAbsent || googleUpdated != null) {
      map['google_updated'] = Variable<String>(googleUpdated);
    }
    if (!nullToAbsent || captureFingerprint != null) {
      map['capture_fingerprint'] = Variable<String>(captureFingerprint);
    }
    return map;
  }

  CalendarEventsCompanion toCompanion(bool nullToAbsent) {
    return CalendarEventsCompanion(
      id: Value(id),
      title: Value(title),
      start: Value(start),
      end: Value(end),
      allDay: Value(allDay),
      timeZone: Value(timeZone),
      needsDate: Value(needsDate),
      source: Value(source),
      sourceRef: sourceRef == null && nullToAbsent
          ? const Value.absent()
          : Value(sourceRef),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      syncDirty: Value(syncDirty),
      syncedSeq: syncedSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(syncedSeq),
      googleEventId: googleEventId == null && nullToAbsent
          ? const Value.absent()
          : Value(googleEventId),
      googleHtmlLink: googleHtmlLink == null && nullToAbsent
          ? const Value.absent()
          : Value(googleHtmlLink),
      googleUpdated: googleUpdated == null && nullToAbsent
          ? const Value.absent()
          : Value(googleUpdated),
      captureFingerprint: captureFingerprint == null && nullToAbsent
          ? const Value.absent()
          : Value(captureFingerprint),
    );
  }

  factory CalendarEventRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CalendarEventRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      start: serializer.fromJson<String>(json['start']),
      end: serializer.fromJson<String>(json['end']),
      allDay: serializer.fromJson<bool>(json['allDay']),
      timeZone: serializer.fromJson<String>(json['timeZone']),
      needsDate: serializer.fromJson<bool>(json['needsDate']),
      source: serializer.fromJson<String>(json['source']),
      sourceRef: serializer.fromJson<String?>(json['sourceRef']),
      createdAt: serializer.fromJson<String>(json['createdAt']),
      updatedAt: serializer.fromJson<String>(json['updatedAt']),
      deletedAt: serializer.fromJson<String?>(json['deletedAt']),
      syncDirty: serializer.fromJson<bool>(json['syncDirty']),
      syncedSeq: serializer.fromJson<int?>(json['syncedSeq']),
      googleEventId: serializer.fromJson<String?>(json['googleEventId']),
      googleHtmlLink: serializer.fromJson<String?>(json['googleHtmlLink']),
      googleUpdated: serializer.fromJson<String?>(json['googleUpdated']),
      captureFingerprint: serializer.fromJson<String?>(
        json['captureFingerprint'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'start': serializer.toJson<String>(start),
      'end': serializer.toJson<String>(end),
      'allDay': serializer.toJson<bool>(allDay),
      'timeZone': serializer.toJson<String>(timeZone),
      'needsDate': serializer.toJson<bool>(needsDate),
      'source': serializer.toJson<String>(source),
      'sourceRef': serializer.toJson<String?>(sourceRef),
      'createdAt': serializer.toJson<String>(createdAt),
      'updatedAt': serializer.toJson<String>(updatedAt),
      'deletedAt': serializer.toJson<String?>(deletedAt),
      'syncDirty': serializer.toJson<bool>(syncDirty),
      'syncedSeq': serializer.toJson<int?>(syncedSeq),
      'googleEventId': serializer.toJson<String?>(googleEventId),
      'googleHtmlLink': serializer.toJson<String?>(googleHtmlLink),
      'googleUpdated': serializer.toJson<String?>(googleUpdated),
      'captureFingerprint': serializer.toJson<String?>(captureFingerprint),
    };
  }

  CalendarEventRow copyWith({
    String? id,
    String? title,
    String? start,
    String? end,
    bool? allDay,
    String? timeZone,
    bool? needsDate,
    String? source,
    Value<String?> sourceRef = const Value.absent(),
    String? createdAt,
    String? updatedAt,
    Value<String?> deletedAt = const Value.absent(),
    bool? syncDirty,
    Value<int?> syncedSeq = const Value.absent(),
    Value<String?> googleEventId = const Value.absent(),
    Value<String?> googleHtmlLink = const Value.absent(),
    Value<String?> googleUpdated = const Value.absent(),
    Value<String?> captureFingerprint = const Value.absent(),
  }) => CalendarEventRow(
    id: id ?? this.id,
    title: title ?? this.title,
    start: start ?? this.start,
    end: end ?? this.end,
    allDay: allDay ?? this.allDay,
    timeZone: timeZone ?? this.timeZone,
    needsDate: needsDate ?? this.needsDate,
    source: source ?? this.source,
    sourceRef: sourceRef.present ? sourceRef.value : this.sourceRef,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    syncDirty: syncDirty ?? this.syncDirty,
    syncedSeq: syncedSeq.present ? syncedSeq.value : this.syncedSeq,
    googleEventId: googleEventId.present
        ? googleEventId.value
        : this.googleEventId,
    googleHtmlLink: googleHtmlLink.present
        ? googleHtmlLink.value
        : this.googleHtmlLink,
    googleUpdated: googleUpdated.present
        ? googleUpdated.value
        : this.googleUpdated,
    captureFingerprint: captureFingerprint.present
        ? captureFingerprint.value
        : this.captureFingerprint,
  );
  CalendarEventRow copyWithCompanion(CalendarEventsCompanion data) {
    return CalendarEventRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      start: data.start.present ? data.start.value : this.start,
      end: data.end.present ? data.end.value : this.end,
      allDay: data.allDay.present ? data.allDay.value : this.allDay,
      timeZone: data.timeZone.present ? data.timeZone.value : this.timeZone,
      needsDate: data.needsDate.present ? data.needsDate.value : this.needsDate,
      source: data.source.present ? data.source.value : this.source,
      sourceRef: data.sourceRef.present ? data.sourceRef.value : this.sourceRef,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      syncDirty: data.syncDirty.present ? data.syncDirty.value : this.syncDirty,
      syncedSeq: data.syncedSeq.present ? data.syncedSeq.value : this.syncedSeq,
      googleEventId: data.googleEventId.present
          ? data.googleEventId.value
          : this.googleEventId,
      googleHtmlLink: data.googleHtmlLink.present
          ? data.googleHtmlLink.value
          : this.googleHtmlLink,
      googleUpdated: data.googleUpdated.present
          ? data.googleUpdated.value
          : this.googleUpdated,
      captureFingerprint: data.captureFingerprint.present
          ? data.captureFingerprint.value
          : this.captureFingerprint,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CalendarEventRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('allDay: $allDay, ')
          ..write('timeZone: $timeZone, ')
          ..write('needsDate: $needsDate, ')
          ..write('source: $source, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('syncDirty: $syncDirty, ')
          ..write('syncedSeq: $syncedSeq, ')
          ..write('googleEventId: $googleEventId, ')
          ..write('googleHtmlLink: $googleHtmlLink, ')
          ..write('googleUpdated: $googleUpdated, ')
          ..write('captureFingerprint: $captureFingerprint')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    start,
    end,
    allDay,
    timeZone,
    needsDate,
    source,
    sourceRef,
    createdAt,
    updatedAt,
    deletedAt,
    syncDirty,
    syncedSeq,
    googleEventId,
    googleHtmlLink,
    googleUpdated,
    captureFingerprint,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CalendarEventRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.start == this.start &&
          other.end == this.end &&
          other.allDay == this.allDay &&
          other.timeZone == this.timeZone &&
          other.needsDate == this.needsDate &&
          other.source == this.source &&
          other.sourceRef == this.sourceRef &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.deletedAt == this.deletedAt &&
          other.syncDirty == this.syncDirty &&
          other.syncedSeq == this.syncedSeq &&
          other.googleEventId == this.googleEventId &&
          other.googleHtmlLink == this.googleHtmlLink &&
          other.googleUpdated == this.googleUpdated &&
          other.captureFingerprint == this.captureFingerprint);
}

class CalendarEventsCompanion extends UpdateCompanion<CalendarEventRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> start;
  final Value<String> end;
  final Value<bool> allDay;
  final Value<String> timeZone;
  final Value<bool> needsDate;
  final Value<String> source;
  final Value<String?> sourceRef;
  final Value<String> createdAt;
  final Value<String> updatedAt;
  final Value<String?> deletedAt;
  final Value<bool> syncDirty;
  final Value<int?> syncedSeq;
  final Value<String?> googleEventId;
  final Value<String?> googleHtmlLink;
  final Value<String?> googleUpdated;
  final Value<String?> captureFingerprint;
  final Value<int> rowid;
  const CalendarEventsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.start = const Value.absent(),
    this.end = const Value.absent(),
    this.allDay = const Value.absent(),
    this.timeZone = const Value.absent(),
    this.needsDate = const Value.absent(),
    this.source = const Value.absent(),
    this.sourceRef = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.syncDirty = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.googleEventId = const Value.absent(),
    this.googleHtmlLink = const Value.absent(),
    this.googleUpdated = const Value.absent(),
    this.captureFingerprint = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CalendarEventsCompanion.insert({
    required String id,
    required String title,
    required String start,
    required String end,
    this.allDay = const Value.absent(),
    required String timeZone,
    this.needsDate = const Value.absent(),
    this.source = const Value.absent(),
    this.sourceRef = const Value.absent(),
    required String createdAt,
    required String updatedAt,
    this.deletedAt = const Value.absent(),
    this.syncDirty = const Value.absent(),
    this.syncedSeq = const Value.absent(),
    this.googleEventId = const Value.absent(),
    this.googleHtmlLink = const Value.absent(),
    this.googleUpdated = const Value.absent(),
    this.captureFingerprint = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       start = Value(start),
       end = Value(end),
       timeZone = Value(timeZone),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<CalendarEventRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? start,
    Expression<String>? end,
    Expression<bool>? allDay,
    Expression<String>? timeZone,
    Expression<bool>? needsDate,
    Expression<String>? source,
    Expression<String>? sourceRef,
    Expression<String>? createdAt,
    Expression<String>? updatedAt,
    Expression<String>? deletedAt,
    Expression<bool>? syncDirty,
    Expression<int>? syncedSeq,
    Expression<String>? googleEventId,
    Expression<String>? googleHtmlLink,
    Expression<String>? googleUpdated,
    Expression<String>? captureFingerprint,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (start != null) 'start': start,
      if (end != null) 'end_': end,
      if (allDay != null) 'all_day': allDay,
      if (timeZone != null) 'time_zone': timeZone,
      if (needsDate != null) 'needs_date': needsDate,
      if (source != null) 'source': source,
      if (sourceRef != null) 'source_ref': sourceRef,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (syncDirty != null) 'sync_dirty': syncDirty,
      if (syncedSeq != null) 'synced_seq': syncedSeq,
      if (googleEventId != null) 'google_event_id': googleEventId,
      if (googleHtmlLink != null) 'google_html_link': googleHtmlLink,
      if (googleUpdated != null) 'google_updated': googleUpdated,
      if (captureFingerprint != null) 'capture_fingerprint': captureFingerprint,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CalendarEventsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? start,
    Value<String>? end,
    Value<bool>? allDay,
    Value<String>? timeZone,
    Value<bool>? needsDate,
    Value<String>? source,
    Value<String?>? sourceRef,
    Value<String>? createdAt,
    Value<String>? updatedAt,
    Value<String?>? deletedAt,
    Value<bool>? syncDirty,
    Value<int?>? syncedSeq,
    Value<String?>? googleEventId,
    Value<String?>? googleHtmlLink,
    Value<String?>? googleUpdated,
    Value<String?>? captureFingerprint,
    Value<int>? rowid,
  }) {
    return CalendarEventsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      start: start ?? this.start,
      end: end ?? this.end,
      allDay: allDay ?? this.allDay,
      timeZone: timeZone ?? this.timeZone,
      needsDate: needsDate ?? this.needsDate,
      source: source ?? this.source,
      sourceRef: sourceRef ?? this.sourceRef,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      syncDirty: syncDirty ?? this.syncDirty,
      syncedSeq: syncedSeq ?? this.syncedSeq,
      googleEventId: googleEventId ?? this.googleEventId,
      googleHtmlLink: googleHtmlLink ?? this.googleHtmlLink,
      googleUpdated: googleUpdated ?? this.googleUpdated,
      captureFingerprint: captureFingerprint ?? this.captureFingerprint,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (start.present) {
      map['start'] = Variable<String>(start.value);
    }
    if (end.present) {
      map['end_'] = Variable<String>(end.value);
    }
    if (allDay.present) {
      map['all_day'] = Variable<bool>(allDay.value);
    }
    if (timeZone.present) {
      map['time_zone'] = Variable<String>(timeZone.value);
    }
    if (needsDate.present) {
      map['needs_date'] = Variable<bool>(needsDate.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (sourceRef.present) {
      map['source_ref'] = Variable<String>(sourceRef.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<String>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<String>(updatedAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<String>(deletedAt.value);
    }
    if (syncDirty.present) {
      map['sync_dirty'] = Variable<bool>(syncDirty.value);
    }
    if (syncedSeq.present) {
      map['synced_seq'] = Variable<int>(syncedSeq.value);
    }
    if (googleEventId.present) {
      map['google_event_id'] = Variable<String>(googleEventId.value);
    }
    if (googleHtmlLink.present) {
      map['google_html_link'] = Variable<String>(googleHtmlLink.value);
    }
    if (googleUpdated.present) {
      map['google_updated'] = Variable<String>(googleUpdated.value);
    }
    if (captureFingerprint.present) {
      map['capture_fingerprint'] = Variable<String>(captureFingerprint.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CalendarEventsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('start: $start, ')
          ..write('end: $end, ')
          ..write('allDay: $allDay, ')
          ..write('timeZone: $timeZone, ')
          ..write('needsDate: $needsDate, ')
          ..write('source: $source, ')
          ..write('sourceRef: $sourceRef, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('syncDirty: $syncDirty, ')
          ..write('syncedSeq: $syncedSeq, ')
          ..write('googleEventId: $googleEventId, ')
          ..write('googleHtmlLink: $googleHtmlLink, ')
          ..write('googleUpdated: $googleUpdated, ')
          ..write('captureFingerprint: $captureFingerprint, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AskMessagesTable extends AskMessages
    with TableInfo<$AskMessagesTable, AskMessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AskMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'text',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourcesJsonMeta = const VerificationMeta(
    'sourcesJson',
  );
  @override
  late final GeneratedColumn<String> sourcesJson = GeneratedColumn<String>(
    'sources_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverSeqMeta = const VerificationMeta(
    'serverSeq',
  );
  @override
  late final GeneratedColumn<int> serverSeq = GeneratedColumn<int>(
    'server_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    role,
    body,
    sourcesJson,
    createdAt,
    serverSeq,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ask_messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<AskMessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('text')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['text']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('sources_json')) {
      context.handle(
        _sourcesJsonMeta,
        sourcesJson.isAcceptableOrUnknown(
          data['sources_json']!,
          _sourcesJsonMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('server_seq')) {
      context.handle(
        _serverSeqMeta,
        serverSeq.isAcceptableOrUnknown(data['server_seq']!, _serverSeqMeta),
      );
    } else if (isInserting) {
      context.missing(_serverSeqMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AskMessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AskMessageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}text'],
      )!,
      sourcesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sources_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      serverSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}server_seq'],
      )!,
    );
  }

  @override
  $AskMessagesTable createAlias(String alias) {
    return $AskMessagesTable(attachedDatabase, alias);
  }
}

class AskMessageRow extends DataClass implements Insertable<AskMessageRow> {
  final String id;
  final String role;
  final String body;
  final String sourcesJson;
  final int createdAt;
  final int serverSeq;
  const AskMessageRow({
    required this.id,
    required this.role,
    required this.body,
    required this.sourcesJson,
    required this.createdAt,
    required this.serverSeq,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['role'] = Variable<String>(role);
    map['text'] = Variable<String>(body);
    map['sources_json'] = Variable<String>(sourcesJson);
    map['created_at'] = Variable<int>(createdAt);
    map['server_seq'] = Variable<int>(serverSeq);
    return map;
  }

  AskMessagesCompanion toCompanion(bool nullToAbsent) {
    return AskMessagesCompanion(
      id: Value(id),
      role: Value(role),
      body: Value(body),
      sourcesJson: Value(sourcesJson),
      createdAt: Value(createdAt),
      serverSeq: Value(serverSeq),
    );
  }

  factory AskMessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AskMessageRow(
      id: serializer.fromJson<String>(json['id']),
      role: serializer.fromJson<String>(json['role']),
      body: serializer.fromJson<String>(json['body']),
      sourcesJson: serializer.fromJson<String>(json['sourcesJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      serverSeq: serializer.fromJson<int>(json['serverSeq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'role': serializer.toJson<String>(role),
      'body': serializer.toJson<String>(body),
      'sourcesJson': serializer.toJson<String>(sourcesJson),
      'createdAt': serializer.toJson<int>(createdAt),
      'serverSeq': serializer.toJson<int>(serverSeq),
    };
  }

  AskMessageRow copyWith({
    String? id,
    String? role,
    String? body,
    String? sourcesJson,
    int? createdAt,
    int? serverSeq,
  }) => AskMessageRow(
    id: id ?? this.id,
    role: role ?? this.role,
    body: body ?? this.body,
    sourcesJson: sourcesJson ?? this.sourcesJson,
    createdAt: createdAt ?? this.createdAt,
    serverSeq: serverSeq ?? this.serverSeq,
  );
  AskMessageRow copyWithCompanion(AskMessagesCompanion data) {
    return AskMessageRow(
      id: data.id.present ? data.id.value : this.id,
      role: data.role.present ? data.role.value : this.role,
      body: data.body.present ? data.body.value : this.body,
      sourcesJson: data.sourcesJson.present
          ? data.sourcesJson.value
          : this.sourcesJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      serverSeq: data.serverSeq.present ? data.serverSeq.value : this.serverSeq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AskMessageRow(')
          ..write('id: $id, ')
          ..write('role: $role, ')
          ..write('body: $body, ')
          ..write('sourcesJson: $sourcesJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('serverSeq: $serverSeq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, role, body, sourcesJson, createdAt, serverSeq);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AskMessageRow &&
          other.id == this.id &&
          other.role == this.role &&
          other.body == this.body &&
          other.sourcesJson == this.sourcesJson &&
          other.createdAt == this.createdAt &&
          other.serverSeq == this.serverSeq);
}

class AskMessagesCompanion extends UpdateCompanion<AskMessageRow> {
  final Value<String> id;
  final Value<String> role;
  final Value<String> body;
  final Value<String> sourcesJson;
  final Value<int> createdAt;
  final Value<int> serverSeq;
  final Value<int> rowid;
  const AskMessagesCompanion({
    this.id = const Value.absent(),
    this.role = const Value.absent(),
    this.body = const Value.absent(),
    this.sourcesJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.serverSeq = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AskMessagesCompanion.insert({
    required String id,
    required String role,
    required String body,
    this.sourcesJson = const Value.absent(),
    required int createdAt,
    required int serverSeq,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       role = Value(role),
       body = Value(body),
       createdAt = Value(createdAt),
       serverSeq = Value(serverSeq);
  static Insertable<AskMessageRow> custom({
    Expression<String>? id,
    Expression<String>? role,
    Expression<String>? body,
    Expression<String>? sourcesJson,
    Expression<int>? createdAt,
    Expression<int>? serverSeq,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (role != null) 'role': role,
      if (body != null) 'text': body,
      if (sourcesJson != null) 'sources_json': sourcesJson,
      if (createdAt != null) 'created_at': createdAt,
      if (serverSeq != null) 'server_seq': serverSeq,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AskMessagesCompanion copyWith({
    Value<String>? id,
    Value<String>? role,
    Value<String>? body,
    Value<String>? sourcesJson,
    Value<int>? createdAt,
    Value<int>? serverSeq,
    Value<int>? rowid,
  }) {
    return AskMessagesCompanion(
      id: id ?? this.id,
      role: role ?? this.role,
      body: body ?? this.body,
      sourcesJson: sourcesJson ?? this.sourcesJson,
      createdAt: createdAt ?? this.createdAt,
      serverSeq: serverSeq ?? this.serverSeq,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (body.present) {
      map['text'] = Variable<String>(body.value);
    }
    if (sourcesJson.present) {
      map['sources_json'] = Variable<String>(sourcesJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (serverSeq.present) {
      map['server_seq'] = Variable<int>(serverSeq.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AskMessagesCompanion(')
          ..write('id: $id, ')
          ..write('role: $role, ')
          ..write('body: $body, ')
          ..write('sourcesJson: $sourcesJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('serverSeq: $serverSeq, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AskSourceVisitsTable extends AskSourceVisits
    with TableInfo<$AskSourceVisitsTable, AskSourceVisitRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AskSourceVisitsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceIndexMeta = const VerificationMeta(
    'sourceIndex',
  );
  @override
  late final GeneratedColumn<int> sourceIndex = GeneratedColumn<int>(
    'source_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _visitedAtMeta = const VerificationMeta(
    'visitedAt',
  );
  @override
  late final GeneratedColumn<int> visitedAt = GeneratedColumn<int>(
    'visited_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [messageId, sourceIndex, visitedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ask_source_visits';
  @override
  VerificationContext validateIntegrity(
    Insertable<AskSourceVisitRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('source_index')) {
      context.handle(
        _sourceIndexMeta,
        sourceIndex.isAcceptableOrUnknown(
          data['source_index']!,
          _sourceIndexMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceIndexMeta);
    }
    if (data.containsKey('visited_at')) {
      context.handle(
        _visitedAtMeta,
        visitedAt.isAcceptableOrUnknown(data['visited_at']!, _visitedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_visitedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {messageId, sourceIndex};
  @override
  AskSourceVisitRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AskSourceVisitRow(
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      sourceIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}source_index'],
      )!,
      visitedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}visited_at'],
      )!,
    );
  }

  @override
  $AskSourceVisitsTable createAlias(String alias) {
    return $AskSourceVisitsTable(attachedDatabase, alias);
  }
}

class AskSourceVisitRow extends DataClass
    implements Insertable<AskSourceVisitRow> {
  final String messageId;
  final int sourceIndex;
  final int visitedAt;
  const AskSourceVisitRow({
    required this.messageId,
    required this.sourceIndex,
    required this.visitedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['message_id'] = Variable<String>(messageId);
    map['source_index'] = Variable<int>(sourceIndex);
    map['visited_at'] = Variable<int>(visitedAt);
    return map;
  }

  AskSourceVisitsCompanion toCompanion(bool nullToAbsent) {
    return AskSourceVisitsCompanion(
      messageId: Value(messageId),
      sourceIndex: Value(sourceIndex),
      visitedAt: Value(visitedAt),
    );
  }

  factory AskSourceVisitRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AskSourceVisitRow(
      messageId: serializer.fromJson<String>(json['messageId']),
      sourceIndex: serializer.fromJson<int>(json['sourceIndex']),
      visitedAt: serializer.fromJson<int>(json['visitedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'messageId': serializer.toJson<String>(messageId),
      'sourceIndex': serializer.toJson<int>(sourceIndex),
      'visitedAt': serializer.toJson<int>(visitedAt),
    };
  }

  AskSourceVisitRow copyWith({
    String? messageId,
    int? sourceIndex,
    int? visitedAt,
  }) => AskSourceVisitRow(
    messageId: messageId ?? this.messageId,
    sourceIndex: sourceIndex ?? this.sourceIndex,
    visitedAt: visitedAt ?? this.visitedAt,
  );
  AskSourceVisitRow copyWithCompanion(AskSourceVisitsCompanion data) {
    return AskSourceVisitRow(
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      sourceIndex: data.sourceIndex.present
          ? data.sourceIndex.value
          : this.sourceIndex,
      visitedAt: data.visitedAt.present ? data.visitedAt.value : this.visitedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AskSourceVisitRow(')
          ..write('messageId: $messageId, ')
          ..write('sourceIndex: $sourceIndex, ')
          ..write('visitedAt: $visitedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(messageId, sourceIndex, visitedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AskSourceVisitRow &&
          other.messageId == this.messageId &&
          other.sourceIndex == this.sourceIndex &&
          other.visitedAt == this.visitedAt);
}

class AskSourceVisitsCompanion extends UpdateCompanion<AskSourceVisitRow> {
  final Value<String> messageId;
  final Value<int> sourceIndex;
  final Value<int> visitedAt;
  final Value<int> rowid;
  const AskSourceVisitsCompanion({
    this.messageId = const Value.absent(),
    this.sourceIndex = const Value.absent(),
    this.visitedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AskSourceVisitsCompanion.insert({
    required String messageId,
    required int sourceIndex,
    required int visitedAt,
    this.rowid = const Value.absent(),
  }) : messageId = Value(messageId),
       sourceIndex = Value(sourceIndex),
       visitedAt = Value(visitedAt);
  static Insertable<AskSourceVisitRow> custom({
    Expression<String>? messageId,
    Expression<int>? sourceIndex,
    Expression<int>? visitedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (messageId != null) 'message_id': messageId,
      if (sourceIndex != null) 'source_index': sourceIndex,
      if (visitedAt != null) 'visited_at': visitedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AskSourceVisitsCompanion copyWith({
    Value<String>? messageId,
    Value<int>? sourceIndex,
    Value<int>? visitedAt,
    Value<int>? rowid,
  }) {
    return AskSourceVisitsCompanion(
      messageId: messageId ?? this.messageId,
      sourceIndex: sourceIndex ?? this.sourceIndex,
      visitedAt: visitedAt ?? this.visitedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (sourceIndex.present) {
      map['source_index'] = Variable<int>(sourceIndex.value);
    }
    if (visitedAt.present) {
      map['visited_at'] = Variable<int>(visitedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AskSourceVisitsCompanion(')
          ..write('messageId: $messageId, ')
          ..write('sourceIndex: $sourceIndex, ')
          ..write('visitedAt: $visitedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$LocalDb extends GeneratedDatabase {
  _$LocalDb(QueryExecutor e) : super(e);
  $LocalDbManager get managers => $LocalDbManager(this);
  late final $DumpsTable dumps = $DumpsTable(this);
  late final $FoldersTable folders = $FoldersTable(this);
  late final $SyncQueueTable syncQueue = $SyncQueueTable(this);
  late final $StorageLocationsTable storageLocations = $StorageLocationsTable(
    this,
  );
  late final $StorageCatalogStatesTable storageCatalogStates =
      $StorageCatalogStatesTable(this);
  late final $RecordingBindingsTable recordingBindings =
      $RecordingBindingsTable(this);
  late final $CaptureReservationsTable captureReservations =
      $CaptureReservationsTable(this);
  late final $LocalDeletionBatchesTable localDeletionBatches =
      $LocalDeletionBatchesTable(this);
  late final $LocalDeletionTicketsTable localDeletionTickets =
      $LocalDeletionTicketsTable(this);
  late final $NotebooksTable notebooks = $NotebooksTable(this);
  late final $SyncTombstonesTable syncTombstones = $SyncTombstonesTable(this);
  late final $SyncStatesTable syncStates = $SyncStatesTable(this);
  late final $InkIndexEntriesTable inkIndexEntries = $InkIndexEntriesTable(
    this,
  );
  late final $LocalSettingsTable localSettings = $LocalSettingsTable(this);
  late final $TodosTable todos = $TodosTable(this);
  late final $CalendarEventsTable calendarEvents = $CalendarEventsTable(this);
  late final $AskMessagesTable askMessages = $AskMessagesTable(this);
  late final $AskSourceVisitsTable askSourceVisits = $AskSourceVisitsTable(
    this,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    dumps,
    folders,
    syncQueue,
    storageLocations,
    storageCatalogStates,
    recordingBindings,
    captureReservations,
    localDeletionBatches,
    localDeletionTickets,
    notebooks,
    syncTombstones,
    syncStates,
    inkIndexEntries,
    localSettings,
    todos,
    calendarEvents,
    askMessages,
    askSourceVisits,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'dumps',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('sync_queue', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$DumpsTableCreateCompanionBuilder =
    DumpsCompanion Function({
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
      Value<String?> folderId,
      Value<int?> autoFiledAt,
      Value<String?> autoFilePrevFolderId,
      Value<bool?> syncDirty,
      Value<int?> syncedSeq,
      Value<bool?> remoteOnly,
      Value<bool?> audioOnServer,
      Value<String?> summary,
      Value<String?> summaryModel,
      Value<int?> summarizedAt,
      Value<String?> transcriptTimings,
      Value<String?> summaryTemplate,
      Value<String?> speakerNames,
      Value<int?> summaryRequestedAt,
      Value<String?> language,
      Value<bool?> translated,
      Value<String?> summaryStatus,
      Value<String?> summaryError,
      Value<int?> summaryQueuePosition,
      Value<int?> summaryErrorDismissedAt,
      Value<bool?> pinned,
      Value<int> rowid,
    });
typedef $$DumpsTableUpdateCompanionBuilder =
    DumpsCompanion Function({
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
      Value<String?> folderId,
      Value<int?> autoFiledAt,
      Value<String?> autoFilePrevFolderId,
      Value<bool?> syncDirty,
      Value<int?> syncedSeq,
      Value<bool?> remoteOnly,
      Value<bool?> audioOnServer,
      Value<String?> summary,
      Value<String?> summaryModel,
      Value<int?> summarizedAt,
      Value<String?> transcriptTimings,
      Value<String?> summaryTemplate,
      Value<String?> speakerNames,
      Value<int?> summaryRequestedAt,
      Value<String?> language,
      Value<bool?> translated,
      Value<String?> summaryStatus,
      Value<String?> summaryError,
      Value<int?> summaryQueuePosition,
      Value<int?> summaryErrorDismissedAt,
      Value<bool?> pinned,
      Value<int> rowid,
    });

final class $$DumpsTableReferences
    extends BaseReferences<_$LocalDb, $DumpsTable, DumpRow> {
  $$DumpsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$SyncQueueTable, List<SyncQueueRow>>
  _syncQueueRefsTable(_$LocalDb db) => MultiTypedResultKey.fromTable(
    db.syncQueue,
    aliasName: 'dumps__id__sync_queue__dump_id',
  );

  $$SyncQueueTableProcessedTableManager get syncQueueRefs {
    final manager = $$SyncQueueTableTableManager(
      $_db,
      $_db.syncQueue,
    ).filter((f) => f.dumpId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_syncQueueRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
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
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get transcript => $composableBuilder(
    column: $table.transcript,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get meetingNotes => $composableBuilder(
    column: $table.meetingNotes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get audioPath => $composableBuilder(
    column: $table.audioPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get audioSizeBytes => $composableBuilder(
    column: $table.audioSizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get syncStatus => $composableBuilder(
    column: $table.syncStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncAttempts => $composableBuilder(
    column: $table.syncAttempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastSyncError => $composableBuilder(
    column: $table.lastSyncError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get transcriptionStatus => $composableBuilder(
    column: $table.transcriptionStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get transcriptionRequestId => $composableBuilder(
    column: $table.transcriptionRequestId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get transcriptionJobId => $composableBuilder(
    column: $table.transcriptionJobId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get transcriptionAttempt => $composableBuilder(
    column: $table.transcriptionAttempt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get transcriptionStartedAt => $composableBuilder(
    column: $table.transcriptionStartedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get transcriptionUpdatedAt => $composableBuilder(
    column: $table.transcriptionUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get transcriptionCompletedAt => $composableBuilder(
    column: $table.transcriptionCompletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get transcriptionError => $composableBuilder(
    column: $table.transcriptionError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get autoFiledAt => $composableBuilder(
    column: $table.autoFiledAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get autoFilePrevFolderId => $composableBuilder(
    column: $table.autoFilePrevFolderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get syncDirty => $composableBuilder(
    column: $table.syncDirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get remoteOnly => $composableBuilder(
    column: $table.remoteOnly,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get audioOnServer => $composableBuilder(
    column: $table.audioOnServer,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summaryModel => $composableBuilder(
    column: $table.summaryModel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get summarizedAt => $composableBuilder(
    column: $table.summarizedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get transcriptTimings => $composableBuilder(
    column: $table.transcriptTimings,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summaryTemplate => $composableBuilder(
    column: $table.summaryTemplate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get speakerNames => $composableBuilder(
    column: $table.speakerNames,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get summaryRequestedAt => $composableBuilder(
    column: $table.summaryRequestedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get language => $composableBuilder(
    column: $table.language,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get translated => $composableBuilder(
    column: $table.translated,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summaryStatus => $composableBuilder(
    column: $table.summaryStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summaryError => $composableBuilder(
    column: $table.summaryError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get summaryQueuePosition => $composableBuilder(
    column: $table.summaryQueuePosition,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get summaryErrorDismissedAt => $composableBuilder(
    column: $table.summaryErrorDismissedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> syncQueueRefs(
    Expression<bool> Function($$SyncQueueTableFilterComposer f) f,
  ) {
    final $$SyncQueueTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncQueue,
      getReferencedColumn: (t) => t.dumpId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncQueueTableFilterComposer(
            $db: $db,
            $table: $db.syncQueue,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
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
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get transcript => $composableBuilder(
    column: $table.transcript,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get meetingNotes => $composableBuilder(
    column: $table.meetingNotes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get audioPath => $composableBuilder(
    column: $table.audioPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get audioSizeBytes => $composableBuilder(
    column: $table.audioSizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get syncStatus => $composableBuilder(
    column: $table.syncStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncAttempts => $composableBuilder(
    column: $table.syncAttempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastSyncError => $composableBuilder(
    column: $table.lastSyncError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get transcriptionStatus => $composableBuilder(
    column: $table.transcriptionStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get transcriptionRequestId => $composableBuilder(
    column: $table.transcriptionRequestId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get transcriptionJobId => $composableBuilder(
    column: $table.transcriptionJobId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get transcriptionAttempt => $composableBuilder(
    column: $table.transcriptionAttempt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get transcriptionStartedAt => $composableBuilder(
    column: $table.transcriptionStartedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get transcriptionUpdatedAt => $composableBuilder(
    column: $table.transcriptionUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get transcriptionCompletedAt => $composableBuilder(
    column: $table.transcriptionCompletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get transcriptionError => $composableBuilder(
    column: $table.transcriptionError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get autoFiledAt => $composableBuilder(
    column: $table.autoFiledAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get autoFilePrevFolderId => $composableBuilder(
    column: $table.autoFilePrevFolderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get syncDirty => $composableBuilder(
    column: $table.syncDirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get remoteOnly => $composableBuilder(
    column: $table.remoteOnly,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get audioOnServer => $composableBuilder(
    column: $table.audioOnServer,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summaryModel => $composableBuilder(
    column: $table.summaryModel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get summarizedAt => $composableBuilder(
    column: $table.summarizedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get transcriptTimings => $composableBuilder(
    column: $table.transcriptTimings,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summaryTemplate => $composableBuilder(
    column: $table.summaryTemplate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get speakerNames => $composableBuilder(
    column: $table.speakerNames,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get summaryRequestedAt => $composableBuilder(
    column: $table.summaryRequestedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get language => $composableBuilder(
    column: $table.language,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get translated => $composableBuilder(
    column: $table.translated,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summaryStatus => $composableBuilder(
    column: $table.summaryStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summaryError => $composableBuilder(
    column: $table.summaryError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get summaryQueuePosition => $composableBuilder(
    column: $table.summaryQueuePosition,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get summaryErrorDismissedAt => $composableBuilder(
    column: $table.summaryErrorDismissedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnOrderings(column),
  );
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
    column: $table.durationSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get transcript => $composableBuilder(
    column: $table.transcript,
    builder: (column) => column,
  );

  GeneratedColumn<String> get meetingNotes => $composableBuilder(
    column: $table.meetingNotes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get audioPath =>
      $composableBuilder(column: $table.audioPath, builder: (column) => column);

  GeneratedColumn<int> get audioSizeBytes => $composableBuilder(
    column: $table.audioSizeBytes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get syncStatus => $composableBuilder(
    column: $table.syncStatus,
    builder: (column) => column,
  );

  GeneratedColumn<int> get syncAttempts => $composableBuilder(
    column: $table.syncAttempts,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastSyncError => $composableBuilder(
    column: $table.lastSyncError,
    builder: (column) => column,
  );

  GeneratedColumn<String> get transcriptionStatus => $composableBuilder(
    column: $table.transcriptionStatus,
    builder: (column) => column,
  );

  GeneratedColumn<String> get transcriptionRequestId => $composableBuilder(
    column: $table.transcriptionRequestId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get transcriptionJobId => $composableBuilder(
    column: $table.transcriptionJobId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get transcriptionAttempt => $composableBuilder(
    column: $table.transcriptionAttempt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get transcriptionStartedAt => $composableBuilder(
    column: $table.transcriptionStartedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get transcriptionUpdatedAt => $composableBuilder(
    column: $table.transcriptionUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get transcriptionCompletedAt => $composableBuilder(
    column: $table.transcriptionCompletedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get transcriptionError => $composableBuilder(
    column: $table.transcriptionError,
    builder: (column) => column,
  );

  GeneratedColumn<String> get folderId =>
      $composableBuilder(column: $table.folderId, builder: (column) => column);

  GeneratedColumn<int> get autoFiledAt => $composableBuilder(
    column: $table.autoFiledAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get autoFilePrevFolderId => $composableBuilder(
    column: $table.autoFilePrevFolderId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get syncDirty =>
      $composableBuilder(column: $table.syncDirty, builder: (column) => column);

  GeneratedColumn<int> get syncedSeq =>
      $composableBuilder(column: $table.syncedSeq, builder: (column) => column);

  GeneratedColumn<bool> get remoteOnly => $composableBuilder(
    column: $table.remoteOnly,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get audioOnServer => $composableBuilder(
    column: $table.audioOnServer,
    builder: (column) => column,
  );

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<String> get summaryModel => $composableBuilder(
    column: $table.summaryModel,
    builder: (column) => column,
  );

  GeneratedColumn<int> get summarizedAt => $composableBuilder(
    column: $table.summarizedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get transcriptTimings => $composableBuilder(
    column: $table.transcriptTimings,
    builder: (column) => column,
  );

  GeneratedColumn<String> get summaryTemplate => $composableBuilder(
    column: $table.summaryTemplate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get speakerNames => $composableBuilder(
    column: $table.speakerNames,
    builder: (column) => column,
  );

  GeneratedColumn<int> get summaryRequestedAt => $composableBuilder(
    column: $table.summaryRequestedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get language =>
      $composableBuilder(column: $table.language, builder: (column) => column);

  GeneratedColumn<bool> get translated => $composableBuilder(
    column: $table.translated,
    builder: (column) => column,
  );

  GeneratedColumn<String> get summaryStatus => $composableBuilder(
    column: $table.summaryStatus,
    builder: (column) => column,
  );

  GeneratedColumn<String> get summaryError => $composableBuilder(
    column: $table.summaryError,
    builder: (column) => column,
  );

  GeneratedColumn<int> get summaryQueuePosition => $composableBuilder(
    column: $table.summaryQueuePosition,
    builder: (column) => column,
  );

  GeneratedColumn<int> get summaryErrorDismissedAt => $composableBuilder(
    column: $table.summaryErrorDismissedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => column);

  Expression<T> syncQueueRefs<T extends Object>(
    Expression<T> Function($$SyncQueueTableAnnotationComposer a) f,
  ) {
    final $$SyncQueueTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncQueue,
      getReferencedColumn: (t) => t.dumpId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncQueueTableAnnotationComposer(
            $db: $db,
            $table: $db.syncQueue,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$DumpsTableTableManager
    extends
        RootTableManager<
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
          PrefetchHooks Function({bool syncQueueRefs})
        > {
  $$DumpsTableTableManager(_$LocalDb db, $DumpsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DumpsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DumpsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DumpsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
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
                Value<DateTime?> transcriptionCompletedAt =
                    const Value.absent(),
                Value<String?> transcriptionError = const Value.absent(),
                Value<String?> folderId = const Value.absent(),
                Value<int?> autoFiledAt = const Value.absent(),
                Value<String?> autoFilePrevFolderId = const Value.absent(),
                Value<bool?> syncDirty = const Value.absent(),
                Value<int?> syncedSeq = const Value.absent(),
                Value<bool?> remoteOnly = const Value.absent(),
                Value<bool?> audioOnServer = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<String?> summaryModel = const Value.absent(),
                Value<int?> summarizedAt = const Value.absent(),
                Value<String?> transcriptTimings = const Value.absent(),
                Value<String?> summaryTemplate = const Value.absent(),
                Value<String?> speakerNames = const Value.absent(),
                Value<int?> summaryRequestedAt = const Value.absent(),
                Value<String?> language = const Value.absent(),
                Value<bool?> translated = const Value.absent(),
                Value<String?> summaryStatus = const Value.absent(),
                Value<String?> summaryError = const Value.absent(),
                Value<int?> summaryQueuePosition = const Value.absent(),
                Value<int?> summaryErrorDismissedAt = const Value.absent(),
                Value<bool?> pinned = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DumpsCompanion(
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
                folderId: folderId,
                autoFiledAt: autoFiledAt,
                autoFilePrevFolderId: autoFilePrevFolderId,
                syncDirty: syncDirty,
                syncedSeq: syncedSeq,
                remoteOnly: remoteOnly,
                audioOnServer: audioOnServer,
                summary: summary,
                summaryModel: summaryModel,
                summarizedAt: summarizedAt,
                transcriptTimings: transcriptTimings,
                summaryTemplate: summaryTemplate,
                speakerNames: speakerNames,
                summaryRequestedAt: summaryRequestedAt,
                language: language,
                translated: translated,
                summaryStatus: summaryStatus,
                summaryError: summaryError,
                summaryQueuePosition: summaryQueuePosition,
                summaryErrorDismissedAt: summaryErrorDismissedAt,
                pinned: pinned,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
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
                Value<DateTime?> transcriptionCompletedAt =
                    const Value.absent(),
                Value<String?> transcriptionError = const Value.absent(),
                Value<String?> folderId = const Value.absent(),
                Value<int?> autoFiledAt = const Value.absent(),
                Value<String?> autoFilePrevFolderId = const Value.absent(),
                Value<bool?> syncDirty = const Value.absent(),
                Value<int?> syncedSeq = const Value.absent(),
                Value<bool?> remoteOnly = const Value.absent(),
                Value<bool?> audioOnServer = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<String?> summaryModel = const Value.absent(),
                Value<int?> summarizedAt = const Value.absent(),
                Value<String?> transcriptTimings = const Value.absent(),
                Value<String?> summaryTemplate = const Value.absent(),
                Value<String?> speakerNames = const Value.absent(),
                Value<int?> summaryRequestedAt = const Value.absent(),
                Value<String?> language = const Value.absent(),
                Value<bool?> translated = const Value.absent(),
                Value<String?> summaryStatus = const Value.absent(),
                Value<String?> summaryError = const Value.absent(),
                Value<int?> summaryQueuePosition = const Value.absent(),
                Value<int?> summaryErrorDismissedAt = const Value.absent(),
                Value<bool?> pinned = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DumpsCompanion.insert(
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
                folderId: folderId,
                autoFiledAt: autoFiledAt,
                autoFilePrevFolderId: autoFilePrevFolderId,
                syncDirty: syncDirty,
                syncedSeq: syncedSeq,
                remoteOnly: remoteOnly,
                audioOnServer: audioOnServer,
                summary: summary,
                summaryModel: summaryModel,
                summarizedAt: summarizedAt,
                transcriptTimings: transcriptTimings,
                summaryTemplate: summaryTemplate,
                speakerNames: speakerNames,
                summaryRequestedAt: summaryRequestedAt,
                language: language,
                translated: translated,
                summaryStatus: summaryStatus,
                summaryError: summaryError,
                summaryQueuePosition: summaryQueuePosition,
                summaryErrorDismissedAt: summaryErrorDismissedAt,
                pinned: pinned,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DumpsTable, DumpRow>(table),
                  $$DumpsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({syncQueueRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (syncQueueRefs) db.syncQueue],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (syncQueueRefs)
                    await $_getPrefetchedData<
                      DumpRow,
                      $DumpsTable,
                      SyncQueueRow
                    >(
                      currentTable: table,
                      referencedTable: $$DumpsTableReferences
                          ._syncQueueRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$DumpsTableReferences(db, table, p0).syncQueueRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.dumpId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$DumpsTableProcessedTableManager =
    ProcessedTableManager<
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
      PrefetchHooks Function({bool syncQueueRefs})
    >;
typedef $$FoldersTableCreateCompanionBuilder =
    FoldersCompanion Function({
      required String id,
      required String name,
      required int createdAt,
      Value<bool?> syncDirty,
      Value<int?> syncedSeq,
      Value<int> rowid,
    });
typedef $$FoldersTableUpdateCompanionBuilder =
    FoldersCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<int> createdAt,
      Value<bool?> syncDirty,
      Value<int?> syncedSeq,
      Value<int> rowid,
    });

class $$FoldersTableFilterComposer extends Composer<_$LocalDb, $FoldersTable> {
  $$FoldersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get syncDirty => $composableBuilder(
    column: $table.syncDirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FoldersTableOrderingComposer
    extends Composer<_$LocalDb, $FoldersTable> {
  $$FoldersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get syncDirty => $composableBuilder(
    column: $table.syncDirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FoldersTableAnnotationComposer
    extends Composer<_$LocalDb, $FoldersTable> {
  $$FoldersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<bool> get syncDirty =>
      $composableBuilder(column: $table.syncDirty, builder: (column) => column);

  GeneratedColumn<int> get syncedSeq =>
      $composableBuilder(column: $table.syncedSeq, builder: (column) => column);
}

class $$FoldersTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $FoldersTable,
          Folder,
          $$FoldersTableFilterComposer,
          $$FoldersTableOrderingComposer,
          $$FoldersTableAnnotationComposer,
          $$FoldersTableCreateCompanionBuilder,
          $$FoldersTableUpdateCompanionBuilder,
          (Folder, BaseReferences<_$LocalDb, $FoldersTable, Folder>),
          Folder,
          PrefetchHooks Function()
        > {
  $$FoldersTableTableManager(_$LocalDb db, $FoldersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FoldersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FoldersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FoldersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<bool?> syncDirty = const Value.absent(),
                Value<int?> syncedSeq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FoldersCompanion(
                id: id,
                name: name,
                createdAt: createdAt,
                syncDirty: syncDirty,
                syncedSeq: syncedSeq,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required int createdAt,
                Value<bool?> syncDirty = const Value.absent(),
                Value<int?> syncedSeq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FoldersCompanion.insert(
                id: id,
                name: name,
                createdAt: createdAt,
                syncDirty: syncDirty,
                syncedSeq: syncedSeq,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$FoldersTable, Folder>(table),
                  BaseReferences<_$LocalDb, $FoldersTable, Folder>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FoldersTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $FoldersTable,
      Folder,
      $$FoldersTableFilterComposer,
      $$FoldersTableOrderingComposer,
      $$FoldersTableAnnotationComposer,
      $$FoldersTableCreateCompanionBuilder,
      $$FoldersTableUpdateCompanionBuilder,
      (Folder, BaseReferences<_$LocalDb, $FoldersTable, Folder>),
      Folder,
      PrefetchHooks Function()
    >;
typedef $$SyncQueueTableCreateCompanionBuilder =
    SyncQueueCompanion Function({
      Value<int> id,
      required String dumpId,
      required DateTime queuedAt,
    });
typedef $$SyncQueueTableUpdateCompanionBuilder =
    SyncQueueCompanion Function({
      Value<int> id,
      Value<String> dumpId,
      Value<DateTime> queuedAt,
    });

final class $$SyncQueueTableReferences
    extends BaseReferences<_$LocalDb, $SyncQueueTable, SyncQueueRow> {
  $$SyncQueueTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $DumpsTable _dumpIdTable(_$LocalDb db) =>
      db.dumps.createAlias('sync_queue__dump_id__dumps__id');

  $$DumpsTableProcessedTableManager get dumpId {
    final $_column = $_itemColumn<String>('dump_id')!;

    final manager = $$DumpsTableTableManager(
      $_db,
      $_db.dumps,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_dumpIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
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
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get queuedAt => $composableBuilder(
    column: $table.queuedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$DumpsTableFilterComposer get dumpId {
    final $$DumpsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.dumpId,
      referencedTable: $db.dumps,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$DumpsTableFilterComposer(
            $db: $db,
            $table: $db.dumps,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
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
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get queuedAt => $composableBuilder(
    column: $table.queuedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$DumpsTableOrderingComposer get dumpId {
    final $$DumpsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.dumpId,
      referencedTable: $db.dumps,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$DumpsTableOrderingComposer(
            $db: $db,
            $table: $db.dumps,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
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
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$DumpsTableAnnotationComposer(
            $db: $db,
            $table: $db.dumps,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncQueueTableTableManager
    extends
        RootTableManager<
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
          PrefetchHooks Function({bool dumpId})
        > {
  $$SyncQueueTableTableManager(_$LocalDb db, $SyncQueueTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncQueueTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncQueueTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncQueueTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> dumpId = const Value.absent(),
                Value<DateTime> queuedAt = const Value.absent(),
              }) => SyncQueueCompanion(
                id: id,
                dumpId: dumpId,
                queuedAt: queuedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String dumpId,
                required DateTime queuedAt,
              }) => SyncQueueCompanion.insert(
                id: id,
                dumpId: dumpId,
                queuedAt: queuedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncQueueTable, SyncQueueRow>(table),
                  $$SyncQueueTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({dumpId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
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
                      dynamic
                    >
                  >(state) {
                    if (dumpId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.dumpId,
                                referencedTable: $$SyncQueueTableReferences
                                    ._dumpIdTable(db),
                                referencedColumn: $$SyncQueueTableReferences
                                    ._dumpIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$SyncQueueTableProcessedTableManager =
    ProcessedTableManager<
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
      PrefetchHooks Function({bool dumpId})
    >;
typedef $$StorageLocationsTableCreateCompanionBuilder =
    StorageLocationsCompanion Function({
      required String id,
      required String canonicalKey,
      required String directoryJson,
      required String label,
      Value<bool> legacyRestore,
      Value<int> rowid,
    });
typedef $$StorageLocationsTableUpdateCompanionBuilder =
    StorageLocationsCompanion Function({
      Value<String> id,
      Value<String> canonicalKey,
      Value<String> directoryJson,
      Value<String> label,
      Value<bool> legacyRestore,
      Value<int> rowid,
    });

class $$StorageLocationsTableFilterComposer
    extends Composer<_$LocalDb, $StorageLocationsTable> {
  $$StorageLocationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get canonicalKey => $composableBuilder(
    column: $table.canonicalKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get directoryJson => $composableBuilder(
    column: $table.directoryJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get legacyRestore => $composableBuilder(
    column: $table.legacyRestore,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StorageLocationsTableOrderingComposer
    extends Composer<_$LocalDb, $StorageLocationsTable> {
  $$StorageLocationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get canonicalKey => $composableBuilder(
    column: $table.canonicalKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get directoryJson => $composableBuilder(
    column: $table.directoryJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get label => $composableBuilder(
    column: $table.label,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get legacyRestore => $composableBuilder(
    column: $table.legacyRestore,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StorageLocationsTableAnnotationComposer
    extends Composer<_$LocalDb, $StorageLocationsTable> {
  $$StorageLocationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get canonicalKey => $composableBuilder(
    column: $table.canonicalKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get directoryJson => $composableBuilder(
    column: $table.directoryJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get label =>
      $composableBuilder(column: $table.label, builder: (column) => column);

  GeneratedColumn<bool> get legacyRestore => $composableBuilder(
    column: $table.legacyRestore,
    builder: (column) => column,
  );
}

class $$StorageLocationsTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $StorageLocationsTable,
          StorageLocationRow,
          $$StorageLocationsTableFilterComposer,
          $$StorageLocationsTableOrderingComposer,
          $$StorageLocationsTableAnnotationComposer,
          $$StorageLocationsTableCreateCompanionBuilder,
          $$StorageLocationsTableUpdateCompanionBuilder,
          (
            StorageLocationRow,
            BaseReferences<
              _$LocalDb,
              $StorageLocationsTable,
              StorageLocationRow
            >,
          ),
          StorageLocationRow,
          PrefetchHooks Function()
        > {
  $$StorageLocationsTableTableManager(
    _$LocalDb db,
    $StorageLocationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StorageLocationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StorageLocationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StorageLocationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> canonicalKey = const Value.absent(),
                Value<String> directoryJson = const Value.absent(),
                Value<String> label = const Value.absent(),
                Value<bool> legacyRestore = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StorageLocationsCompanion(
                id: id,
                canonicalKey: canonicalKey,
                directoryJson: directoryJson,
                label: label,
                legacyRestore: legacyRestore,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String canonicalKey,
                required String directoryJson,
                required String label,
                Value<bool> legacyRestore = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StorageLocationsCompanion.insert(
                id: id,
                canonicalKey: canonicalKey,
                directoryJson: directoryJson,
                label: label,
                legacyRestore: legacyRestore,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$StorageLocationsTable, StorageLocationRow>(
                    table,
                  ),
                  BaseReferences<
                    _$LocalDb,
                    $StorageLocationsTable,
                    StorageLocationRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StorageLocationsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $StorageLocationsTable,
      StorageLocationRow,
      $$StorageLocationsTableFilterComposer,
      $$StorageLocationsTableOrderingComposer,
      $$StorageLocationsTableAnnotationComposer,
      $$StorageLocationsTableCreateCompanionBuilder,
      $$StorageLocationsTableUpdateCompanionBuilder,
      (
        StorageLocationRow,
        BaseReferences<_$LocalDb, $StorageLocationsTable, StorageLocationRow>,
      ),
      StorageLocationRow,
      PrefetchHooks Function()
    >;
typedef $$StorageCatalogStatesTableCreateCompanionBuilder =
    StorageCatalogStatesCompanion Function({
      Value<int> id,
      Value<String?> defaultLocationId,
      Value<int> revision,
      Value<int> bootstrapVersion,
      Value<String?> legacyAnchorJson,
      Value<String?> candidateJson,
    });
typedef $$StorageCatalogStatesTableUpdateCompanionBuilder =
    StorageCatalogStatesCompanion Function({
      Value<int> id,
      Value<String?> defaultLocationId,
      Value<int> revision,
      Value<int> bootstrapVersion,
      Value<String?> legacyAnchorJson,
      Value<String?> candidateJson,
    });

class $$StorageCatalogStatesTableFilterComposer
    extends Composer<_$LocalDb, $StorageCatalogStatesTable> {
  $$StorageCatalogStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get defaultLocationId => $composableBuilder(
    column: $table.defaultLocationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bootstrapVersion => $composableBuilder(
    column: $table.bootstrapVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get legacyAnchorJson => $composableBuilder(
    column: $table.legacyAnchorJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get candidateJson => $composableBuilder(
    column: $table.candidateJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StorageCatalogStatesTableOrderingComposer
    extends Composer<_$LocalDb, $StorageCatalogStatesTable> {
  $$StorageCatalogStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get defaultLocationId => $composableBuilder(
    column: $table.defaultLocationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bootstrapVersion => $composableBuilder(
    column: $table.bootstrapVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get legacyAnchorJson => $composableBuilder(
    column: $table.legacyAnchorJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get candidateJson => $composableBuilder(
    column: $table.candidateJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StorageCatalogStatesTableAnnotationComposer
    extends Composer<_$LocalDb, $StorageCatalogStatesTable> {
  $$StorageCatalogStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get defaultLocationId => $composableBuilder(
    column: $table.defaultLocationId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get revision =>
      $composableBuilder(column: $table.revision, builder: (column) => column);

  GeneratedColumn<int> get bootstrapVersion => $composableBuilder(
    column: $table.bootstrapVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get legacyAnchorJson => $composableBuilder(
    column: $table.legacyAnchorJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get candidateJson => $composableBuilder(
    column: $table.candidateJson,
    builder: (column) => column,
  );
}

class $$StorageCatalogStatesTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $StorageCatalogStatesTable,
          StorageCatalogStateRow,
          $$StorageCatalogStatesTableFilterComposer,
          $$StorageCatalogStatesTableOrderingComposer,
          $$StorageCatalogStatesTableAnnotationComposer,
          $$StorageCatalogStatesTableCreateCompanionBuilder,
          $$StorageCatalogStatesTableUpdateCompanionBuilder,
          (
            StorageCatalogStateRow,
            BaseReferences<
              _$LocalDb,
              $StorageCatalogStatesTable,
              StorageCatalogStateRow
            >,
          ),
          StorageCatalogStateRow,
          PrefetchHooks Function()
        > {
  $$StorageCatalogStatesTableTableManager(
    _$LocalDb db,
    $StorageCatalogStatesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StorageCatalogStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StorageCatalogStatesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$StorageCatalogStatesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> defaultLocationId = const Value.absent(),
                Value<int> revision = const Value.absent(),
                Value<int> bootstrapVersion = const Value.absent(),
                Value<String?> legacyAnchorJson = const Value.absent(),
                Value<String?> candidateJson = const Value.absent(),
              }) => StorageCatalogStatesCompanion(
                id: id,
                defaultLocationId: defaultLocationId,
                revision: revision,
                bootstrapVersion: bootstrapVersion,
                legacyAnchorJson: legacyAnchorJson,
                candidateJson: candidateJson,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> defaultLocationId = const Value.absent(),
                Value<int> revision = const Value.absent(),
                Value<int> bootstrapVersion = const Value.absent(),
                Value<String?> legacyAnchorJson = const Value.absent(),
                Value<String?> candidateJson = const Value.absent(),
              }) => StorageCatalogStatesCompanion.insert(
                id: id,
                defaultLocationId: defaultLocationId,
                revision: revision,
                bootstrapVersion: bootstrapVersion,
                legacyAnchorJson: legacyAnchorJson,
                candidateJson: candidateJson,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $StorageCatalogStatesTable,
                    StorageCatalogStateRow
                  >(table),
                  BaseReferences<
                    _$LocalDb,
                    $StorageCatalogStatesTable,
                    StorageCatalogStateRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StorageCatalogStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $StorageCatalogStatesTable,
      StorageCatalogStateRow,
      $$StorageCatalogStatesTableFilterComposer,
      $$StorageCatalogStatesTableOrderingComposer,
      $$StorageCatalogStatesTableAnnotationComposer,
      $$StorageCatalogStatesTableCreateCompanionBuilder,
      $$StorageCatalogStatesTableUpdateCompanionBuilder,
      (
        StorageCatalogStateRow,
        BaseReferences<
          _$LocalDb,
          $StorageCatalogStatesTable,
          StorageCatalogStateRow
        >,
      ),
      StorageCatalogStateRow,
      PrefetchHooks Function()
    >;
typedef $$RecordingBindingsTableCreateCompanionBuilder =
    RecordingBindingsCompanion Function({
      required String dumpId,
      required String incarnation,
      Value<String?> locationId,
      required String audioJson,
      required String metadataName,
      Value<String?> legacyAnchorJson,
      Value<bool> resolved,
      Value<int> rowid,
    });
typedef $$RecordingBindingsTableUpdateCompanionBuilder =
    RecordingBindingsCompanion Function({
      Value<String> dumpId,
      Value<String> incarnation,
      Value<String?> locationId,
      Value<String> audioJson,
      Value<String> metadataName,
      Value<String?> legacyAnchorJson,
      Value<bool> resolved,
      Value<int> rowid,
    });

class $$RecordingBindingsTableFilterComposer
    extends Composer<_$LocalDb, $RecordingBindingsTable> {
  $$RecordingBindingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get dumpId => $composableBuilder(
    column: $table.dumpId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get incarnation => $composableBuilder(
    column: $table.incarnation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get locationId => $composableBuilder(
    column: $table.locationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get audioJson => $composableBuilder(
    column: $table.audioJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metadataName => $composableBuilder(
    column: $table.metadataName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get legacyAnchorJson => $composableBuilder(
    column: $table.legacyAnchorJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get resolved => $composableBuilder(
    column: $table.resolved,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecordingBindingsTableOrderingComposer
    extends Composer<_$LocalDb, $RecordingBindingsTable> {
  $$RecordingBindingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get dumpId => $composableBuilder(
    column: $table.dumpId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get incarnation => $composableBuilder(
    column: $table.incarnation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get locationId => $composableBuilder(
    column: $table.locationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get audioJson => $composableBuilder(
    column: $table.audioJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metadataName => $composableBuilder(
    column: $table.metadataName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get legacyAnchorJson => $composableBuilder(
    column: $table.legacyAnchorJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get resolved => $composableBuilder(
    column: $table.resolved,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecordingBindingsTableAnnotationComposer
    extends Composer<_$LocalDb, $RecordingBindingsTable> {
  $$RecordingBindingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get dumpId =>
      $composableBuilder(column: $table.dumpId, builder: (column) => column);

  GeneratedColumn<String> get incarnation => $composableBuilder(
    column: $table.incarnation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get locationId => $composableBuilder(
    column: $table.locationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get audioJson =>
      $composableBuilder(column: $table.audioJson, builder: (column) => column);

  GeneratedColumn<String> get metadataName => $composableBuilder(
    column: $table.metadataName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get legacyAnchorJson => $composableBuilder(
    column: $table.legacyAnchorJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get resolved =>
      $composableBuilder(column: $table.resolved, builder: (column) => column);
}

class $$RecordingBindingsTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $RecordingBindingsTable,
          RecordingBindingRow,
          $$RecordingBindingsTableFilterComposer,
          $$RecordingBindingsTableOrderingComposer,
          $$RecordingBindingsTableAnnotationComposer,
          $$RecordingBindingsTableCreateCompanionBuilder,
          $$RecordingBindingsTableUpdateCompanionBuilder,
          (
            RecordingBindingRow,
            BaseReferences<
              _$LocalDb,
              $RecordingBindingsTable,
              RecordingBindingRow
            >,
          ),
          RecordingBindingRow,
          PrefetchHooks Function()
        > {
  $$RecordingBindingsTableTableManager(
    _$LocalDb db,
    $RecordingBindingsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecordingBindingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecordingBindingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecordingBindingsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> dumpId = const Value.absent(),
                Value<String> incarnation = const Value.absent(),
                Value<String?> locationId = const Value.absent(),
                Value<String> audioJson = const Value.absent(),
                Value<String> metadataName = const Value.absent(),
                Value<String?> legacyAnchorJson = const Value.absent(),
                Value<bool> resolved = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecordingBindingsCompanion(
                dumpId: dumpId,
                incarnation: incarnation,
                locationId: locationId,
                audioJson: audioJson,
                metadataName: metadataName,
                legacyAnchorJson: legacyAnchorJson,
                resolved: resolved,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String dumpId,
                required String incarnation,
                Value<String?> locationId = const Value.absent(),
                required String audioJson,
                required String metadataName,
                Value<String?> legacyAnchorJson = const Value.absent(),
                Value<bool> resolved = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecordingBindingsCompanion.insert(
                dumpId: dumpId,
                incarnation: incarnation,
                locationId: locationId,
                audioJson: audioJson,
                metadataName: metadataName,
                legacyAnchorJson: legacyAnchorJson,
                resolved: resolved,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RecordingBindingsTable, RecordingBindingRow>(
                    table,
                  ),
                  BaseReferences<
                    _$LocalDb,
                    $RecordingBindingsTable,
                    RecordingBindingRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecordingBindingsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $RecordingBindingsTable,
      RecordingBindingRow,
      $$RecordingBindingsTableFilterComposer,
      $$RecordingBindingsTableOrderingComposer,
      $$RecordingBindingsTableAnnotationComposer,
      $$RecordingBindingsTableCreateCompanionBuilder,
      $$RecordingBindingsTableUpdateCompanionBuilder,
      (
        RecordingBindingRow,
        BaseReferences<_$LocalDb, $RecordingBindingsTable, RecordingBindingRow>,
      ),
      RecordingBindingRow,
      PrefetchHooks Function()
    >;
typedef $$CaptureReservationsTableCreateCompanionBuilder =
    CaptureReservationsCompanion Function({
      required String reservationId,
      required String dumpId,
      required String incarnation,
      required String locationId,
      required String stagingPath,
      required String mode,
      required int startedAt,
      required String state,
      required String processEpoch,
      Value<String?> publicationJson,
      Value<int> rowid,
    });
typedef $$CaptureReservationsTableUpdateCompanionBuilder =
    CaptureReservationsCompanion Function({
      Value<String> reservationId,
      Value<String> dumpId,
      Value<String> incarnation,
      Value<String> locationId,
      Value<String> stagingPath,
      Value<String> mode,
      Value<int> startedAt,
      Value<String> state,
      Value<String> processEpoch,
      Value<String?> publicationJson,
      Value<int> rowid,
    });

class $$CaptureReservationsTableFilterComposer
    extends Composer<_$LocalDb, $CaptureReservationsTable> {
  $$CaptureReservationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get reservationId => $composableBuilder(
    column: $table.reservationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dumpId => $composableBuilder(
    column: $table.dumpId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get incarnation => $composableBuilder(
    column: $table.incarnation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get locationId => $composableBuilder(
    column: $table.locationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stagingPath => $composableBuilder(
    column: $table.stagingPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get processEpoch => $composableBuilder(
    column: $table.processEpoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get publicationJson => $composableBuilder(
    column: $table.publicationJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CaptureReservationsTableOrderingComposer
    extends Composer<_$LocalDb, $CaptureReservationsTable> {
  $$CaptureReservationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get reservationId => $composableBuilder(
    column: $table.reservationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dumpId => $composableBuilder(
    column: $table.dumpId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get incarnation => $composableBuilder(
    column: $table.incarnation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get locationId => $composableBuilder(
    column: $table.locationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stagingPath => $composableBuilder(
    column: $table.stagingPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get processEpoch => $composableBuilder(
    column: $table.processEpoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get publicationJson => $composableBuilder(
    column: $table.publicationJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CaptureReservationsTableAnnotationComposer
    extends Composer<_$LocalDb, $CaptureReservationsTable> {
  $$CaptureReservationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get reservationId => $composableBuilder(
    column: $table.reservationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get dumpId =>
      $composableBuilder(column: $table.dumpId, builder: (column) => column);

  GeneratedColumn<String> get incarnation => $composableBuilder(
    column: $table.incarnation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get locationId => $composableBuilder(
    column: $table.locationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stagingPath => $composableBuilder(
    column: $table.stagingPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mode =>
      $composableBuilder(column: $table.mode, builder: (column) => column);

  GeneratedColumn<int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get processEpoch => $composableBuilder(
    column: $table.processEpoch,
    builder: (column) => column,
  );

  GeneratedColumn<String> get publicationJson => $composableBuilder(
    column: $table.publicationJson,
    builder: (column) => column,
  );
}

class $$CaptureReservationsTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $CaptureReservationsTable,
          CaptureReservationRow,
          $$CaptureReservationsTableFilterComposer,
          $$CaptureReservationsTableOrderingComposer,
          $$CaptureReservationsTableAnnotationComposer,
          $$CaptureReservationsTableCreateCompanionBuilder,
          $$CaptureReservationsTableUpdateCompanionBuilder,
          (
            CaptureReservationRow,
            BaseReferences<
              _$LocalDb,
              $CaptureReservationsTable,
              CaptureReservationRow
            >,
          ),
          CaptureReservationRow,
          PrefetchHooks Function()
        > {
  $$CaptureReservationsTableTableManager(
    _$LocalDb db,
    $CaptureReservationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CaptureReservationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CaptureReservationsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CaptureReservationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> reservationId = const Value.absent(),
                Value<String> dumpId = const Value.absent(),
                Value<String> incarnation = const Value.absent(),
                Value<String> locationId = const Value.absent(),
                Value<String> stagingPath = const Value.absent(),
                Value<String> mode = const Value.absent(),
                Value<int> startedAt = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String> processEpoch = const Value.absent(),
                Value<String?> publicationJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CaptureReservationsCompanion(
                reservationId: reservationId,
                dumpId: dumpId,
                incarnation: incarnation,
                locationId: locationId,
                stagingPath: stagingPath,
                mode: mode,
                startedAt: startedAt,
                state: state,
                processEpoch: processEpoch,
                publicationJson: publicationJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String reservationId,
                required String dumpId,
                required String incarnation,
                required String locationId,
                required String stagingPath,
                required String mode,
                required int startedAt,
                required String state,
                required String processEpoch,
                Value<String?> publicationJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CaptureReservationsCompanion.insert(
                reservationId: reservationId,
                dumpId: dumpId,
                incarnation: incarnation,
                locationId: locationId,
                stagingPath: stagingPath,
                mode: mode,
                startedAt: startedAt,
                state: state,
                processEpoch: processEpoch,
                publicationJson: publicationJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CaptureReservationsTable, CaptureReservationRow>(
                    table,
                  ),
                  BaseReferences<
                    _$LocalDb,
                    $CaptureReservationsTable,
                    CaptureReservationRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CaptureReservationsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $CaptureReservationsTable,
      CaptureReservationRow,
      $$CaptureReservationsTableFilterComposer,
      $$CaptureReservationsTableOrderingComposer,
      $$CaptureReservationsTableAnnotationComposer,
      $$CaptureReservationsTableCreateCompanionBuilder,
      $$CaptureReservationsTableUpdateCompanionBuilder,
      (
        CaptureReservationRow,
        BaseReferences<
          _$LocalDb,
          $CaptureReservationsTable,
          CaptureReservationRow
        >,
      ),
      CaptureReservationRow,
      PrefetchHooks Function()
    >;
typedef $$LocalDeletionBatchesTableCreateCompanionBuilder =
    LocalDeletionBatchesCompanion Function({
      required String operationId,
      required String payloadJson,
      required String resultsJson,
      required String state,
      Value<int> rowid,
    });
typedef $$LocalDeletionBatchesTableUpdateCompanionBuilder =
    LocalDeletionBatchesCompanion Function({
      Value<String> operationId,
      Value<String> payloadJson,
      Value<String> resultsJson,
      Value<String> state,
      Value<int> rowid,
    });

class $$LocalDeletionBatchesTableFilterComposer
    extends Composer<_$LocalDb, $LocalDeletionBatchesTable> {
  $$LocalDeletionBatchesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resultsJson => $composableBuilder(
    column: $table.resultsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalDeletionBatchesTableOrderingComposer
    extends Composer<_$LocalDb, $LocalDeletionBatchesTable> {
  $$LocalDeletionBatchesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resultsJson => $composableBuilder(
    column: $table.resultsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalDeletionBatchesTableAnnotationComposer
    extends Composer<_$LocalDb, $LocalDeletionBatchesTable> {
  $$LocalDeletionBatchesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get resultsJson => $composableBuilder(
    column: $table.resultsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);
}

class $$LocalDeletionBatchesTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $LocalDeletionBatchesTable,
          LocalDeletionBatchRow,
          $$LocalDeletionBatchesTableFilterComposer,
          $$LocalDeletionBatchesTableOrderingComposer,
          $$LocalDeletionBatchesTableAnnotationComposer,
          $$LocalDeletionBatchesTableCreateCompanionBuilder,
          $$LocalDeletionBatchesTableUpdateCompanionBuilder,
          (
            LocalDeletionBatchRow,
            BaseReferences<
              _$LocalDb,
              $LocalDeletionBatchesTable,
              LocalDeletionBatchRow
            >,
          ),
          LocalDeletionBatchRow,
          PrefetchHooks Function()
        > {
  $$LocalDeletionBatchesTableTableManager(
    _$LocalDb db,
    $LocalDeletionBatchesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalDeletionBatchesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalDeletionBatchesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LocalDeletionBatchesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> operationId = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<String> resultsJson = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalDeletionBatchesCompanion(
                operationId: operationId,
                payloadJson: payloadJson,
                resultsJson: resultsJson,
                state: state,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String operationId,
                required String payloadJson,
                required String resultsJson,
                required String state,
                Value<int> rowid = const Value.absent(),
              }) => LocalDeletionBatchesCompanion.insert(
                operationId: operationId,
                payloadJson: payloadJson,
                resultsJson: resultsJson,
                state: state,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $LocalDeletionBatchesTable,
                    LocalDeletionBatchRow
                  >(table),
                  BaseReferences<
                    _$LocalDb,
                    $LocalDeletionBatchesTable,
                    LocalDeletionBatchRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalDeletionBatchesTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $LocalDeletionBatchesTable,
      LocalDeletionBatchRow,
      $$LocalDeletionBatchesTableFilterComposer,
      $$LocalDeletionBatchesTableOrderingComposer,
      $$LocalDeletionBatchesTableAnnotationComposer,
      $$LocalDeletionBatchesTableCreateCompanionBuilder,
      $$LocalDeletionBatchesTableUpdateCompanionBuilder,
      (
        LocalDeletionBatchRow,
        BaseReferences<
          _$LocalDb,
          $LocalDeletionBatchesTable,
          LocalDeletionBatchRow
        >,
      ),
      LocalDeletionBatchRow,
      PrefetchHooks Function()
    >;
typedef $$LocalDeletionTicketsTableCreateCompanionBuilder =
    LocalDeletionTicketsCompanion Function({
      required String dumpId,
      required String incarnation,
      required String ticketId,
      required String operationId,
      required String bindingJson,
      required String audioState,
      required String metadataState,
      required String state,
      Value<String?> problemJson,
      Value<int> rowid,
    });
typedef $$LocalDeletionTicketsTableUpdateCompanionBuilder =
    LocalDeletionTicketsCompanion Function({
      Value<String> dumpId,
      Value<String> incarnation,
      Value<String> ticketId,
      Value<String> operationId,
      Value<String> bindingJson,
      Value<String> audioState,
      Value<String> metadataState,
      Value<String> state,
      Value<String?> problemJson,
      Value<int> rowid,
    });

class $$LocalDeletionTicketsTableFilterComposer
    extends Composer<_$LocalDb, $LocalDeletionTicketsTable> {
  $$LocalDeletionTicketsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get dumpId => $composableBuilder(
    column: $table.dumpId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get incarnation => $composableBuilder(
    column: $table.incarnation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ticketId => $composableBuilder(
    column: $table.ticketId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bindingJson => $composableBuilder(
    column: $table.bindingJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get audioState => $composableBuilder(
    column: $table.audioState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metadataState => $composableBuilder(
    column: $table.metadataState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get problemJson => $composableBuilder(
    column: $table.problemJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalDeletionTicketsTableOrderingComposer
    extends Composer<_$LocalDb, $LocalDeletionTicketsTable> {
  $$LocalDeletionTicketsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get dumpId => $composableBuilder(
    column: $table.dumpId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get incarnation => $composableBuilder(
    column: $table.incarnation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ticketId => $composableBuilder(
    column: $table.ticketId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bindingJson => $composableBuilder(
    column: $table.bindingJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get audioState => $composableBuilder(
    column: $table.audioState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metadataState => $composableBuilder(
    column: $table.metadataState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get problemJson => $composableBuilder(
    column: $table.problemJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalDeletionTicketsTableAnnotationComposer
    extends Composer<_$LocalDb, $LocalDeletionTicketsTable> {
  $$LocalDeletionTicketsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get dumpId =>
      $composableBuilder(column: $table.dumpId, builder: (column) => column);

  GeneratedColumn<String> get incarnation => $composableBuilder(
    column: $table.incarnation,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ticketId =>
      $composableBuilder(column: $table.ticketId, builder: (column) => column);

  GeneratedColumn<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get bindingJson => $composableBuilder(
    column: $table.bindingJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get audioState => $composableBuilder(
    column: $table.audioState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get metadataState => $composableBuilder(
    column: $table.metadataState,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get problemJson => $composableBuilder(
    column: $table.problemJson,
    builder: (column) => column,
  );
}

class $$LocalDeletionTicketsTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $LocalDeletionTicketsTable,
          LocalDeletionTicketRow,
          $$LocalDeletionTicketsTableFilterComposer,
          $$LocalDeletionTicketsTableOrderingComposer,
          $$LocalDeletionTicketsTableAnnotationComposer,
          $$LocalDeletionTicketsTableCreateCompanionBuilder,
          $$LocalDeletionTicketsTableUpdateCompanionBuilder,
          (
            LocalDeletionTicketRow,
            BaseReferences<
              _$LocalDb,
              $LocalDeletionTicketsTable,
              LocalDeletionTicketRow
            >,
          ),
          LocalDeletionTicketRow,
          PrefetchHooks Function()
        > {
  $$LocalDeletionTicketsTableTableManager(
    _$LocalDb db,
    $LocalDeletionTicketsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalDeletionTicketsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalDeletionTicketsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LocalDeletionTicketsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> dumpId = const Value.absent(),
                Value<String> incarnation = const Value.absent(),
                Value<String> ticketId = const Value.absent(),
                Value<String> operationId = const Value.absent(),
                Value<String> bindingJson = const Value.absent(),
                Value<String> audioState = const Value.absent(),
                Value<String> metadataState = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> problemJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalDeletionTicketsCompanion(
                dumpId: dumpId,
                incarnation: incarnation,
                ticketId: ticketId,
                operationId: operationId,
                bindingJson: bindingJson,
                audioState: audioState,
                metadataState: metadataState,
                state: state,
                problemJson: problemJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String dumpId,
                required String incarnation,
                required String ticketId,
                required String operationId,
                required String bindingJson,
                required String audioState,
                required String metadataState,
                required String state,
                Value<String?> problemJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalDeletionTicketsCompanion.insert(
                dumpId: dumpId,
                incarnation: incarnation,
                ticketId: ticketId,
                operationId: operationId,
                bindingJson: bindingJson,
                audioState: audioState,
                metadataState: metadataState,
                state: state,
                problemJson: problemJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $LocalDeletionTicketsTable,
                    LocalDeletionTicketRow
                  >(table),
                  BaseReferences<
                    _$LocalDb,
                    $LocalDeletionTicketsTable,
                    LocalDeletionTicketRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalDeletionTicketsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $LocalDeletionTicketsTable,
      LocalDeletionTicketRow,
      $$LocalDeletionTicketsTableFilterComposer,
      $$LocalDeletionTicketsTableOrderingComposer,
      $$LocalDeletionTicketsTableAnnotationComposer,
      $$LocalDeletionTicketsTableCreateCompanionBuilder,
      $$LocalDeletionTicketsTableUpdateCompanionBuilder,
      (
        LocalDeletionTicketRow,
        BaseReferences<
          _$LocalDb,
          $LocalDeletionTicketsTable,
          LocalDeletionTicketRow
        >,
      ),
      LocalDeletionTicketRow,
      PrefetchHooks Function()
    >;
typedef $$NotebooksTableCreateCompanionBuilder =
    NotebooksCompanion Function({
      required String id,
      required String title,
      required int createdAt,
      required int updatedAt,
      required String docJson,
      required String inkJson,
      Value<String?> folderId,
      Value<String?> ruling,
      Value<String?> lastPenStyle,
      Value<String?> passwordHash,
      Value<String?> passwordSalt,
      Value<int?> passwordIterations,
      Value<String?> passwordHashPrev,
      Value<bool> syncDirty,
      Value<int?> syncedSeq,
      Value<int?> deletedAt,
      Value<bool?> pinned,
      Value<int> rowid,
    });
typedef $$NotebooksTableUpdateCompanionBuilder =
    NotebooksCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<String> docJson,
      Value<String> inkJson,
      Value<String?> folderId,
      Value<String?> ruling,
      Value<String?> lastPenStyle,
      Value<String?> passwordHash,
      Value<String?> passwordSalt,
      Value<int?> passwordIterations,
      Value<String?> passwordHashPrev,
      Value<bool> syncDirty,
      Value<int?> syncedSeq,
      Value<int?> deletedAt,
      Value<bool?> pinned,
      Value<int> rowid,
    });

class $$NotebooksTableFilterComposer
    extends Composer<_$LocalDb, $NotebooksTable> {
  $$NotebooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get docJson => $composableBuilder(
    column: $table.docJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get inkJson => $composableBuilder(
    column: $table.inkJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ruling => $composableBuilder(
    column: $table.ruling,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastPenStyle => $composableBuilder(
    column: $table.lastPenStyle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get passwordHash => $composableBuilder(
    column: $table.passwordHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get passwordSalt => $composableBuilder(
    column: $table.passwordSalt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get passwordIterations => $composableBuilder(
    column: $table.passwordIterations,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get passwordHashPrev => $composableBuilder(
    column: $table.passwordHashPrev,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get syncDirty => $composableBuilder(
    column: $table.syncDirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnFilters(column),
  );
}

class $$NotebooksTableOrderingComposer
    extends Composer<_$LocalDb, $NotebooksTable> {
  $$NotebooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get docJson => $composableBuilder(
    column: $table.docJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get inkJson => $composableBuilder(
    column: $table.inkJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ruling => $composableBuilder(
    column: $table.ruling,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastPenStyle => $composableBuilder(
    column: $table.lastPenStyle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get passwordHash => $composableBuilder(
    column: $table.passwordHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get passwordSalt => $composableBuilder(
    column: $table.passwordSalt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get passwordIterations => $composableBuilder(
    column: $table.passwordIterations,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get passwordHashPrev => $composableBuilder(
    column: $table.passwordHashPrev,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get syncDirty => $composableBuilder(
    column: $table.syncDirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$NotebooksTableAnnotationComposer
    extends Composer<_$LocalDb, $NotebooksTable> {
  $$NotebooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get docJson =>
      $composableBuilder(column: $table.docJson, builder: (column) => column);

  GeneratedColumn<String> get inkJson =>
      $composableBuilder(column: $table.inkJson, builder: (column) => column);

  GeneratedColumn<String> get folderId =>
      $composableBuilder(column: $table.folderId, builder: (column) => column);

  GeneratedColumn<String> get ruling =>
      $composableBuilder(column: $table.ruling, builder: (column) => column);

  GeneratedColumn<String> get lastPenStyle => $composableBuilder(
    column: $table.lastPenStyle,
    builder: (column) => column,
  );

  GeneratedColumn<String> get passwordHash => $composableBuilder(
    column: $table.passwordHash,
    builder: (column) => column,
  );

  GeneratedColumn<String> get passwordSalt => $composableBuilder(
    column: $table.passwordSalt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get passwordIterations => $composableBuilder(
    column: $table.passwordIterations,
    builder: (column) => column,
  );

  GeneratedColumn<String> get passwordHashPrev => $composableBuilder(
    column: $table.passwordHashPrev,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get syncDirty =>
      $composableBuilder(column: $table.syncDirty, builder: (column) => column);

  GeneratedColumn<int> get syncedSeq =>
      $composableBuilder(column: $table.syncedSeq, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<bool> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => column);
}

class $$NotebooksTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $NotebooksTable,
          NotebookRow,
          $$NotebooksTableFilterComposer,
          $$NotebooksTableOrderingComposer,
          $$NotebooksTableAnnotationComposer,
          $$NotebooksTableCreateCompanionBuilder,
          $$NotebooksTableUpdateCompanionBuilder,
          (
            NotebookRow,
            BaseReferences<_$LocalDb, $NotebooksTable, NotebookRow>,
          ),
          NotebookRow,
          PrefetchHooks Function()
        > {
  $$NotebooksTableTableManager(_$LocalDb db, $NotebooksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$NotebooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$NotebooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$NotebooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<String> docJson = const Value.absent(),
                Value<String> inkJson = const Value.absent(),
                Value<String?> folderId = const Value.absent(),
                Value<String?> ruling = const Value.absent(),
                Value<String?> lastPenStyle = const Value.absent(),
                Value<String?> passwordHash = const Value.absent(),
                Value<String?> passwordSalt = const Value.absent(),
                Value<int?> passwordIterations = const Value.absent(),
                Value<String?> passwordHashPrev = const Value.absent(),
                Value<bool> syncDirty = const Value.absent(),
                Value<int?> syncedSeq = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<bool?> pinned = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotebooksCompanion(
                id: id,
                title: title,
                createdAt: createdAt,
                updatedAt: updatedAt,
                docJson: docJson,
                inkJson: inkJson,
                folderId: folderId,
                ruling: ruling,
                lastPenStyle: lastPenStyle,
                passwordHash: passwordHash,
                passwordSalt: passwordSalt,
                passwordIterations: passwordIterations,
                passwordHashPrev: passwordHashPrev,
                syncDirty: syncDirty,
                syncedSeq: syncedSeq,
                deletedAt: deletedAt,
                pinned: pinned,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required int createdAt,
                required int updatedAt,
                required String docJson,
                required String inkJson,
                Value<String?> folderId = const Value.absent(),
                Value<String?> ruling = const Value.absent(),
                Value<String?> lastPenStyle = const Value.absent(),
                Value<String?> passwordHash = const Value.absent(),
                Value<String?> passwordSalt = const Value.absent(),
                Value<int?> passwordIterations = const Value.absent(),
                Value<String?> passwordHashPrev = const Value.absent(),
                Value<bool> syncDirty = const Value.absent(),
                Value<int?> syncedSeq = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
                Value<bool?> pinned = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => NotebooksCompanion.insert(
                id: id,
                title: title,
                createdAt: createdAt,
                updatedAt: updatedAt,
                docJson: docJson,
                inkJson: inkJson,
                folderId: folderId,
                ruling: ruling,
                lastPenStyle: lastPenStyle,
                passwordHash: passwordHash,
                passwordSalt: passwordSalt,
                passwordIterations: passwordIterations,
                passwordHashPrev: passwordHashPrev,
                syncDirty: syncDirty,
                syncedSeq: syncedSeq,
                deletedAt: deletedAt,
                pinned: pinned,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$NotebooksTable, NotebookRow>(table),
                  BaseReferences<_$LocalDb, $NotebooksTable, NotebookRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$NotebooksTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $NotebooksTable,
      NotebookRow,
      $$NotebooksTableFilterComposer,
      $$NotebooksTableOrderingComposer,
      $$NotebooksTableAnnotationComposer,
      $$NotebooksTableCreateCompanionBuilder,
      $$NotebooksTableUpdateCompanionBuilder,
      (NotebookRow, BaseReferences<_$LocalDb, $NotebooksTable, NotebookRow>),
      NotebookRow,
      PrefetchHooks Function()
    >;
typedef $$SyncTombstonesTableCreateCompanionBuilder =
    SyncTombstonesCompanion Function({
      required String entityType,
      required String entityId,
      required int deletedAt,
      Value<int> rowid,
    });
typedef $$SyncTombstonesTableUpdateCompanionBuilder =
    SyncTombstonesCompanion Function({
      Value<String> entityType,
      Value<String> entityId,
      Value<int> deletedAt,
      Value<int> rowid,
    });

class $$SyncTombstonesTableFilterComposer
    extends Composer<_$LocalDb, $SyncTombstonesTable> {
  $$SyncTombstonesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncTombstonesTableOrderingComposer
    extends Composer<_$LocalDb, $SyncTombstonesTable> {
  $$SyncTombstonesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncTombstonesTableAnnotationComposer
    extends Composer<_$LocalDb, $SyncTombstonesTable> {
  $$SyncTombstonesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$SyncTombstonesTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $SyncTombstonesTable,
          SyncTombstoneRow,
          $$SyncTombstonesTableFilterComposer,
          $$SyncTombstonesTableOrderingComposer,
          $$SyncTombstonesTableAnnotationComposer,
          $$SyncTombstonesTableCreateCompanionBuilder,
          $$SyncTombstonesTableUpdateCompanionBuilder,
          (
            SyncTombstoneRow,
            BaseReferences<_$LocalDb, $SyncTombstonesTable, SyncTombstoneRow>,
          ),
          SyncTombstoneRow,
          PrefetchHooks Function()
        > {
  $$SyncTombstonesTableTableManager(_$LocalDb db, $SyncTombstonesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncTombstonesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncTombstonesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncTombstonesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> entityType = const Value.absent(),
                Value<String> entityId = const Value.absent(),
                Value<int> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncTombstonesCompanion(
                entityType: entityType,
                entityId: entityId,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String entityType,
                required String entityId,
                required int deletedAt,
                Value<int> rowid = const Value.absent(),
              }) => SyncTombstonesCompanion.insert(
                entityType: entityType,
                entityId: entityId,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncTombstonesTable, SyncTombstoneRow>(table),
                  BaseReferences<
                    _$LocalDb,
                    $SyncTombstonesTable,
                    SyncTombstoneRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncTombstonesTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $SyncTombstonesTable,
      SyncTombstoneRow,
      $$SyncTombstonesTableFilterComposer,
      $$SyncTombstonesTableOrderingComposer,
      $$SyncTombstonesTableAnnotationComposer,
      $$SyncTombstonesTableCreateCompanionBuilder,
      $$SyncTombstonesTableUpdateCompanionBuilder,
      (
        SyncTombstoneRow,
        BaseReferences<_$LocalDb, $SyncTombstonesTable, SyncTombstoneRow>,
      ),
      SyncTombstoneRow,
      PrefetchHooks Function()
    >;
typedef $$SyncStatesTableCreateCompanionBuilder =
    SyncStatesCompanion Function({
      Value<int> id,
      required String deviceId,
      Value<int> lastPulledSeq,
      Value<int?> lastSyncedAt,
    });
typedef $$SyncStatesTableUpdateCompanionBuilder =
    SyncStatesCompanion Function({
      Value<int> id,
      Value<String> deviceId,
      Value<int> lastPulledSeq,
      Value<int?> lastSyncedAt,
    });

class $$SyncStatesTableFilterComposer
    extends Composer<_$LocalDb, $SyncStatesTable> {
  $$SyncStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastPulledSeq => $composableBuilder(
    column: $table.lastPulledSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSyncedAt => $composableBuilder(
    column: $table.lastSyncedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncStatesTableOrderingComposer
    extends Composer<_$LocalDb, $SyncStatesTable> {
  $$SyncStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastPulledSeq => $composableBuilder(
    column: $table.lastPulledSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSyncedAt => $composableBuilder(
    column: $table.lastSyncedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncStatesTableAnnotationComposer
    extends Composer<_$LocalDb, $SyncStatesTable> {
  $$SyncStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<int> get lastPulledSeq => $composableBuilder(
    column: $table.lastPulledSeq,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastSyncedAt => $composableBuilder(
    column: $table.lastSyncedAt,
    builder: (column) => column,
  );
}

class $$SyncStatesTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $SyncStatesTable,
          SyncStateRow,
          $$SyncStatesTableFilterComposer,
          $$SyncStatesTableOrderingComposer,
          $$SyncStatesTableAnnotationComposer,
          $$SyncStatesTableCreateCompanionBuilder,
          $$SyncStatesTableUpdateCompanionBuilder,
          (
            SyncStateRow,
            BaseReferences<_$LocalDb, $SyncStatesTable, SyncStateRow>,
          ),
          SyncStateRow,
          PrefetchHooks Function()
        > {
  $$SyncStatesTableTableManager(_$LocalDb db, $SyncStatesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<int> lastPulledSeq = const Value.absent(),
                Value<int?> lastSyncedAt = const Value.absent(),
              }) => SyncStatesCompanion(
                id: id,
                deviceId: deviceId,
                lastPulledSeq: lastPulledSeq,
                lastSyncedAt: lastSyncedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String deviceId,
                Value<int> lastPulledSeq = const Value.absent(),
                Value<int?> lastSyncedAt = const Value.absent(),
              }) => SyncStatesCompanion.insert(
                id: id,
                deviceId: deviceId,
                lastPulledSeq: lastPulledSeq,
                lastSyncedAt: lastSyncedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncStatesTable, SyncStateRow>(table),
                  BaseReferences<_$LocalDb, $SyncStatesTable, SyncStateRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $SyncStatesTable,
      SyncStateRow,
      $$SyncStatesTableFilterComposer,
      $$SyncStatesTableOrderingComposer,
      $$SyncStatesTableAnnotationComposer,
      $$SyncStatesTableCreateCompanionBuilder,
      $$SyncStatesTableUpdateCompanionBuilder,
      (SyncStateRow, BaseReferences<_$LocalDb, $SyncStatesTable, SyncStateRow>),
      SyncStateRow,
      PrefetchHooks Function()
    >;
typedef $$InkIndexEntriesTableCreateCompanionBuilder =
    InkIndexEntriesCompanion Function({
      required String id,
      required String notebookId,
      required String lineId,
      required String wordText,
      required String wordTextLower,
      required String bboxJson,
      required String strokeIdsJson,
      required String model,
      required int indexedAt,
      Value<int> rowid,
    });
typedef $$InkIndexEntriesTableUpdateCompanionBuilder =
    InkIndexEntriesCompanion Function({
      Value<String> id,
      Value<String> notebookId,
      Value<String> lineId,
      Value<String> wordText,
      Value<String> wordTextLower,
      Value<String> bboxJson,
      Value<String> strokeIdsJson,
      Value<String> model,
      Value<int> indexedAt,
      Value<int> rowid,
    });

class $$InkIndexEntriesTableFilterComposer
    extends Composer<_$LocalDb, $InkIndexEntriesTable> {
  $$InkIndexEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lineId => $composableBuilder(
    column: $table.lineId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get wordText => $composableBuilder(
    column: $table.wordText,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get wordTextLower => $composableBuilder(
    column: $table.wordTextLower,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bboxJson => $composableBuilder(
    column: $table.bboxJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get strokeIdsJson => $composableBuilder(
    column: $table.strokeIdsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get indexedAt => $composableBuilder(
    column: $table.indexedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$InkIndexEntriesTableOrderingComposer
    extends Composer<_$LocalDb, $InkIndexEntriesTable> {
  $$InkIndexEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lineId => $composableBuilder(
    column: $table.lineId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get wordText => $composableBuilder(
    column: $table.wordText,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get wordTextLower => $composableBuilder(
    column: $table.wordTextLower,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bboxJson => $composableBuilder(
    column: $table.bboxJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get strokeIdsJson => $composableBuilder(
    column: $table.strokeIdsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get indexedAt => $composableBuilder(
    column: $table.indexedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$InkIndexEntriesTableAnnotationComposer
    extends Composer<_$LocalDb, $InkIndexEntriesTable> {
  $$InkIndexEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get notebookId => $composableBuilder(
    column: $table.notebookId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lineId =>
      $composableBuilder(column: $table.lineId, builder: (column) => column);

  GeneratedColumn<String> get wordText =>
      $composableBuilder(column: $table.wordText, builder: (column) => column);

  GeneratedColumn<String> get wordTextLower => $composableBuilder(
    column: $table.wordTextLower,
    builder: (column) => column,
  );

  GeneratedColumn<String> get bboxJson =>
      $composableBuilder(column: $table.bboxJson, builder: (column) => column);

  GeneratedColumn<String> get strokeIdsJson => $composableBuilder(
    column: $table.strokeIdsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<int> get indexedAt =>
      $composableBuilder(column: $table.indexedAt, builder: (column) => column);
}

class $$InkIndexEntriesTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $InkIndexEntriesTable,
          InkIndexEntry,
          $$InkIndexEntriesTableFilterComposer,
          $$InkIndexEntriesTableOrderingComposer,
          $$InkIndexEntriesTableAnnotationComposer,
          $$InkIndexEntriesTableCreateCompanionBuilder,
          $$InkIndexEntriesTableUpdateCompanionBuilder,
          (
            InkIndexEntry,
            BaseReferences<_$LocalDb, $InkIndexEntriesTable, InkIndexEntry>,
          ),
          InkIndexEntry,
          PrefetchHooks Function()
        > {
  $$InkIndexEntriesTableTableManager(_$LocalDb db, $InkIndexEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$InkIndexEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$InkIndexEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$InkIndexEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> notebookId = const Value.absent(),
                Value<String> lineId = const Value.absent(),
                Value<String> wordText = const Value.absent(),
                Value<String> wordTextLower = const Value.absent(),
                Value<String> bboxJson = const Value.absent(),
                Value<String> strokeIdsJson = const Value.absent(),
                Value<String> model = const Value.absent(),
                Value<int> indexedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => InkIndexEntriesCompanion(
                id: id,
                notebookId: notebookId,
                lineId: lineId,
                wordText: wordText,
                wordTextLower: wordTextLower,
                bboxJson: bboxJson,
                strokeIdsJson: strokeIdsJson,
                model: model,
                indexedAt: indexedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String notebookId,
                required String lineId,
                required String wordText,
                required String wordTextLower,
                required String bboxJson,
                required String strokeIdsJson,
                required String model,
                required int indexedAt,
                Value<int> rowid = const Value.absent(),
              }) => InkIndexEntriesCompanion.insert(
                id: id,
                notebookId: notebookId,
                lineId: lineId,
                wordText: wordText,
                wordTextLower: wordTextLower,
                bboxJson: bboxJson,
                strokeIdsJson: strokeIdsJson,
                model: model,
                indexedAt: indexedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$InkIndexEntriesTable, InkIndexEntry>(table),
                  BaseReferences<
                    _$LocalDb,
                    $InkIndexEntriesTable,
                    InkIndexEntry
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$InkIndexEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $InkIndexEntriesTable,
      InkIndexEntry,
      $$InkIndexEntriesTableFilterComposer,
      $$InkIndexEntriesTableOrderingComposer,
      $$InkIndexEntriesTableAnnotationComposer,
      $$InkIndexEntriesTableCreateCompanionBuilder,
      $$InkIndexEntriesTableUpdateCompanionBuilder,
      (
        InkIndexEntry,
        BaseReferences<_$LocalDb, $InkIndexEntriesTable, InkIndexEntry>,
      ),
      InkIndexEntry,
      PrefetchHooks Function()
    >;
typedef $$LocalSettingsTableCreateCompanionBuilder =
    LocalSettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$LocalSettingsTableUpdateCompanionBuilder =
    LocalSettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$LocalSettingsTableFilterComposer
    extends Composer<_$LocalDb, $LocalSettingsTable> {
  $$LocalSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalSettingsTableOrderingComposer
    extends Composer<_$LocalDb, $LocalSettingsTable> {
  $$LocalSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalSettingsTableAnnotationComposer
    extends Composer<_$LocalDb, $LocalSettingsTable> {
  $$LocalSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$LocalSettingsTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $LocalSettingsTable,
          LocalSettingRow,
          $$LocalSettingsTableFilterComposer,
          $$LocalSettingsTableOrderingComposer,
          $$LocalSettingsTableAnnotationComposer,
          $$LocalSettingsTableCreateCompanionBuilder,
          $$LocalSettingsTableUpdateCompanionBuilder,
          (
            LocalSettingRow,
            BaseReferences<_$LocalDb, $LocalSettingsTable, LocalSettingRow>,
          ),
          LocalSettingRow,
          PrefetchHooks Function()
        > {
  $$LocalSettingsTableTableManager(_$LocalDb db, $LocalSettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) =>
                  LocalSettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => LocalSettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalSettingsTable, LocalSettingRow>(table),
                  BaseReferences<
                    _$LocalDb,
                    $LocalSettingsTable,
                    LocalSettingRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $LocalSettingsTable,
      LocalSettingRow,
      $$LocalSettingsTableFilterComposer,
      $$LocalSettingsTableOrderingComposer,
      $$LocalSettingsTableAnnotationComposer,
      $$LocalSettingsTableCreateCompanionBuilder,
      $$LocalSettingsTableUpdateCompanionBuilder,
      (
        LocalSettingRow,
        BaseReferences<_$LocalDb, $LocalSettingsTable, LocalSettingRow>,
      ),
      LocalSettingRow,
      PrefetchHooks Function()
    >;
typedef $$TodosTableCreateCompanionBuilder =
    TodosCompanion Function({
      required String id,
      required String body,
      Value<String?> doneAt,
      Value<String?> dueDate,
      Value<String> source,
      Value<String?> sourceRef,
      required String createdAt,
      required String updatedAt,
      Value<String?> deletedAt,
      Value<bool> syncDirty,
      Value<int?> syncedSeq,
      Value<String?> folderId,
      Value<String?> captureFingerprint,
      Value<bool?> pinned,
      Value<int> rowid,
    });
typedef $$TodosTableUpdateCompanionBuilder =
    TodosCompanion Function({
      Value<String> id,
      Value<String> body,
      Value<String?> doneAt,
      Value<String?> dueDate,
      Value<String> source,
      Value<String?> sourceRef,
      Value<String> createdAt,
      Value<String> updatedAt,
      Value<String?> deletedAt,
      Value<bool> syncDirty,
      Value<int?> syncedSeq,
      Value<String?> folderId,
      Value<String?> captureFingerprint,
      Value<bool?> pinned,
      Value<int> rowid,
    });

class $$TodosTableFilterComposer extends Composer<_$LocalDb, $TodosTable> {
  $$TodosTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get doneAt => $composableBuilder(
    column: $table.doneAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dueDate => $composableBuilder(
    column: $table.dueDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get syncDirty => $composableBuilder(
    column: $table.syncDirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get captureFingerprint => $composableBuilder(
    column: $table.captureFingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TodosTableOrderingComposer extends Composer<_$LocalDb, $TodosTable> {
  $$TodosTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get doneAt => $composableBuilder(
    column: $table.doneAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dueDate => $composableBuilder(
    column: $table.dueDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get syncDirty => $composableBuilder(
    column: $table.syncDirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get captureFingerprint => $composableBuilder(
    column: $table.captureFingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TodosTableAnnotationComposer extends Composer<_$LocalDb, $TodosTable> {
  $$TodosTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get doneAt =>
      $composableBuilder(column: $table.doneAt, builder: (column) => column);

  GeneratedColumn<String> get dueDate =>
      $composableBuilder(column: $table.dueDate, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get sourceRef =>
      $composableBuilder(column: $table.sourceRef, builder: (column) => column);

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<bool> get syncDirty =>
      $composableBuilder(column: $table.syncDirty, builder: (column) => column);

  GeneratedColumn<int> get syncedSeq =>
      $composableBuilder(column: $table.syncedSeq, builder: (column) => column);

  GeneratedColumn<String> get folderId =>
      $composableBuilder(column: $table.folderId, builder: (column) => column);

  GeneratedColumn<String> get captureFingerprint => $composableBuilder(
    column: $table.captureFingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => column);
}

class $$TodosTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $TodosTable,
          TodoRow,
          $$TodosTableFilterComposer,
          $$TodosTableOrderingComposer,
          $$TodosTableAnnotationComposer,
          $$TodosTableCreateCompanionBuilder,
          $$TodosTableUpdateCompanionBuilder,
          (TodoRow, BaseReferences<_$LocalDb, $TodosTable, TodoRow>),
          TodoRow,
          PrefetchHooks Function()
        > {
  $$TodosTableTableManager(_$LocalDb db, $TodosTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TodosTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TodosTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TodosTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<String?> doneAt = const Value.absent(),
                Value<String?> dueDate = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> sourceRef = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
                Value<String> updatedAt = const Value.absent(),
                Value<String?> deletedAt = const Value.absent(),
                Value<bool> syncDirty = const Value.absent(),
                Value<int?> syncedSeq = const Value.absent(),
                Value<String?> folderId = const Value.absent(),
                Value<String?> captureFingerprint = const Value.absent(),
                Value<bool?> pinned = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TodosCompanion(
                id: id,
                body: body,
                doneAt: doneAt,
                dueDate: dueDate,
                source: source,
                sourceRef: sourceRef,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                syncDirty: syncDirty,
                syncedSeq: syncedSeq,
                folderId: folderId,
                captureFingerprint: captureFingerprint,
                pinned: pinned,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String body,
                Value<String?> doneAt = const Value.absent(),
                Value<String?> dueDate = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> sourceRef = const Value.absent(),
                required String createdAt,
                required String updatedAt,
                Value<String?> deletedAt = const Value.absent(),
                Value<bool> syncDirty = const Value.absent(),
                Value<int?> syncedSeq = const Value.absent(),
                Value<String?> folderId = const Value.absent(),
                Value<String?> captureFingerprint = const Value.absent(),
                Value<bool?> pinned = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TodosCompanion.insert(
                id: id,
                body: body,
                doneAt: doneAt,
                dueDate: dueDate,
                source: source,
                sourceRef: sourceRef,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                syncDirty: syncDirty,
                syncedSeq: syncedSeq,
                folderId: folderId,
                captureFingerprint: captureFingerprint,
                pinned: pinned,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TodosTable, TodoRow>(table),
                  BaseReferences<_$LocalDb, $TodosTable, TodoRow>(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TodosTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $TodosTable,
      TodoRow,
      $$TodosTableFilterComposer,
      $$TodosTableOrderingComposer,
      $$TodosTableAnnotationComposer,
      $$TodosTableCreateCompanionBuilder,
      $$TodosTableUpdateCompanionBuilder,
      (TodoRow, BaseReferences<_$LocalDb, $TodosTable, TodoRow>),
      TodoRow,
      PrefetchHooks Function()
    >;
typedef $$CalendarEventsTableCreateCompanionBuilder =
    CalendarEventsCompanion Function({
      required String id,
      required String title,
      required String start,
      required String end,
      Value<bool> allDay,
      required String timeZone,
      Value<bool> needsDate,
      Value<String> source,
      Value<String?> sourceRef,
      required String createdAt,
      required String updatedAt,
      Value<String?> deletedAt,
      Value<bool> syncDirty,
      Value<int?> syncedSeq,
      Value<String?> googleEventId,
      Value<String?> googleHtmlLink,
      Value<String?> googleUpdated,
      Value<String?> captureFingerprint,
      Value<int> rowid,
    });
typedef $$CalendarEventsTableUpdateCompanionBuilder =
    CalendarEventsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String> start,
      Value<String> end,
      Value<bool> allDay,
      Value<String> timeZone,
      Value<bool> needsDate,
      Value<String> source,
      Value<String?> sourceRef,
      Value<String> createdAt,
      Value<String> updatedAt,
      Value<String?> deletedAt,
      Value<bool> syncDirty,
      Value<int?> syncedSeq,
      Value<String?> googleEventId,
      Value<String?> googleHtmlLink,
      Value<String?> googleUpdated,
      Value<String?> captureFingerprint,
      Value<int> rowid,
    });

class $$CalendarEventsTableFilterComposer
    extends Composer<_$LocalDb, $CalendarEventsTable> {
  $$CalendarEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get start => $composableBuilder(
    column: $table.start,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get end => $composableBuilder(
    column: $table.end,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get allDay => $composableBuilder(
    column: $table.allDay,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get timeZone => $composableBuilder(
    column: $table.timeZone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get needsDate => $composableBuilder(
    column: $table.needsDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get syncDirty => $composableBuilder(
    column: $table.syncDirty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get googleEventId => $composableBuilder(
    column: $table.googleEventId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get googleHtmlLink => $composableBuilder(
    column: $table.googleHtmlLink,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get googleUpdated => $composableBuilder(
    column: $table.googleUpdated,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get captureFingerprint => $composableBuilder(
    column: $table.captureFingerprint,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CalendarEventsTableOrderingComposer
    extends Composer<_$LocalDb, $CalendarEventsTable> {
  $$CalendarEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get start => $composableBuilder(
    column: $table.start,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get end => $composableBuilder(
    column: $table.end,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get allDay => $composableBuilder(
    column: $table.allDay,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get timeZone => $composableBuilder(
    column: $table.timeZone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get needsDate => $composableBuilder(
    column: $table.needsDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceRef => $composableBuilder(
    column: $table.sourceRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get syncDirty => $composableBuilder(
    column: $table.syncDirty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedSeq => $composableBuilder(
    column: $table.syncedSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get googleEventId => $composableBuilder(
    column: $table.googleEventId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get googleHtmlLink => $composableBuilder(
    column: $table.googleHtmlLink,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get googleUpdated => $composableBuilder(
    column: $table.googleUpdated,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get captureFingerprint => $composableBuilder(
    column: $table.captureFingerprint,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CalendarEventsTableAnnotationComposer
    extends Composer<_$LocalDb, $CalendarEventsTable> {
  $$CalendarEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get start =>
      $composableBuilder(column: $table.start, builder: (column) => column);

  GeneratedColumn<String> get end =>
      $composableBuilder(column: $table.end, builder: (column) => column);

  GeneratedColumn<bool> get allDay =>
      $composableBuilder(column: $table.allDay, builder: (column) => column);

  GeneratedColumn<String> get timeZone =>
      $composableBuilder(column: $table.timeZone, builder: (column) => column);

  GeneratedColumn<bool> get needsDate =>
      $composableBuilder(column: $table.needsDate, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<String> get sourceRef =>
      $composableBuilder(column: $table.sourceRef, builder: (column) => column);

  GeneratedColumn<String> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<bool> get syncDirty =>
      $composableBuilder(column: $table.syncDirty, builder: (column) => column);

  GeneratedColumn<int> get syncedSeq =>
      $composableBuilder(column: $table.syncedSeq, builder: (column) => column);

  GeneratedColumn<String> get googleEventId => $composableBuilder(
    column: $table.googleEventId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get googleHtmlLink => $composableBuilder(
    column: $table.googleHtmlLink,
    builder: (column) => column,
  );

  GeneratedColumn<String> get googleUpdated => $composableBuilder(
    column: $table.googleUpdated,
    builder: (column) => column,
  );

  GeneratedColumn<String> get captureFingerprint => $composableBuilder(
    column: $table.captureFingerprint,
    builder: (column) => column,
  );
}

class $$CalendarEventsTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $CalendarEventsTable,
          CalendarEventRow,
          $$CalendarEventsTableFilterComposer,
          $$CalendarEventsTableOrderingComposer,
          $$CalendarEventsTableAnnotationComposer,
          $$CalendarEventsTableCreateCompanionBuilder,
          $$CalendarEventsTableUpdateCompanionBuilder,
          (
            CalendarEventRow,
            BaseReferences<_$LocalDb, $CalendarEventsTable, CalendarEventRow>,
          ),
          CalendarEventRow,
          PrefetchHooks Function()
        > {
  $$CalendarEventsTableTableManager(_$LocalDb db, $CalendarEventsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CalendarEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CalendarEventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CalendarEventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> start = const Value.absent(),
                Value<String> end = const Value.absent(),
                Value<bool> allDay = const Value.absent(),
                Value<String> timeZone = const Value.absent(),
                Value<bool> needsDate = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> sourceRef = const Value.absent(),
                Value<String> createdAt = const Value.absent(),
                Value<String> updatedAt = const Value.absent(),
                Value<String?> deletedAt = const Value.absent(),
                Value<bool> syncDirty = const Value.absent(),
                Value<int?> syncedSeq = const Value.absent(),
                Value<String?> googleEventId = const Value.absent(),
                Value<String?> googleHtmlLink = const Value.absent(),
                Value<String?> googleUpdated = const Value.absent(),
                Value<String?> captureFingerprint = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventsCompanion(
                id: id,
                title: title,
                start: start,
                end: end,
                allDay: allDay,
                timeZone: timeZone,
                needsDate: needsDate,
                source: source,
                sourceRef: sourceRef,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                syncDirty: syncDirty,
                syncedSeq: syncedSeq,
                googleEventId: googleEventId,
                googleHtmlLink: googleHtmlLink,
                googleUpdated: googleUpdated,
                captureFingerprint: captureFingerprint,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required String start,
                required String end,
                Value<bool> allDay = const Value.absent(),
                required String timeZone,
                Value<bool> needsDate = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<String?> sourceRef = const Value.absent(),
                required String createdAt,
                required String updatedAt,
                Value<String?> deletedAt = const Value.absent(),
                Value<bool> syncDirty = const Value.absent(),
                Value<int?> syncedSeq = const Value.absent(),
                Value<String?> googleEventId = const Value.absent(),
                Value<String?> googleHtmlLink = const Value.absent(),
                Value<String?> googleUpdated = const Value.absent(),
                Value<String?> captureFingerprint = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CalendarEventsCompanion.insert(
                id: id,
                title: title,
                start: start,
                end: end,
                allDay: allDay,
                timeZone: timeZone,
                needsDate: needsDate,
                source: source,
                sourceRef: sourceRef,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                syncDirty: syncDirty,
                syncedSeq: syncedSeq,
                googleEventId: googleEventId,
                googleHtmlLink: googleHtmlLink,
                googleUpdated: googleUpdated,
                captureFingerprint: captureFingerprint,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CalendarEventsTable, CalendarEventRow>(table),
                  BaseReferences<
                    _$LocalDb,
                    $CalendarEventsTable,
                    CalendarEventRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CalendarEventsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $CalendarEventsTable,
      CalendarEventRow,
      $$CalendarEventsTableFilterComposer,
      $$CalendarEventsTableOrderingComposer,
      $$CalendarEventsTableAnnotationComposer,
      $$CalendarEventsTableCreateCompanionBuilder,
      $$CalendarEventsTableUpdateCompanionBuilder,
      (
        CalendarEventRow,
        BaseReferences<_$LocalDb, $CalendarEventsTable, CalendarEventRow>,
      ),
      CalendarEventRow,
      PrefetchHooks Function()
    >;
typedef $$AskMessagesTableCreateCompanionBuilder =
    AskMessagesCompanion Function({
      required String id,
      required String role,
      required String body,
      Value<String> sourcesJson,
      required int createdAt,
      required int serverSeq,
      Value<int> rowid,
    });
typedef $$AskMessagesTableUpdateCompanionBuilder =
    AskMessagesCompanion Function({
      Value<String> id,
      Value<String> role,
      Value<String> body,
      Value<String> sourcesJson,
      Value<int> createdAt,
      Value<int> serverSeq,
      Value<int> rowid,
    });

class $$AskMessagesTableFilterComposer
    extends Composer<_$LocalDb, $AskMessagesTable> {
  $$AskMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourcesJson => $composableBuilder(
    column: $table.sourcesJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serverSeq => $composableBuilder(
    column: $table.serverSeq,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AskMessagesTableOrderingComposer
    extends Composer<_$LocalDb, $AskMessagesTable> {
  $$AskMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourcesJson => $composableBuilder(
    column: $table.sourcesJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serverSeq => $composableBuilder(
    column: $table.serverSeq,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AskMessagesTableAnnotationComposer
    extends Composer<_$LocalDb, $AskMessagesTable> {
  $$AskMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get sourcesJson => $composableBuilder(
    column: $table.sourcesJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get serverSeq =>
      $composableBuilder(column: $table.serverSeq, builder: (column) => column);
}

class $$AskMessagesTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $AskMessagesTable,
          AskMessageRow,
          $$AskMessagesTableFilterComposer,
          $$AskMessagesTableOrderingComposer,
          $$AskMessagesTableAnnotationComposer,
          $$AskMessagesTableCreateCompanionBuilder,
          $$AskMessagesTableUpdateCompanionBuilder,
          (
            AskMessageRow,
            BaseReferences<_$LocalDb, $AskMessagesTable, AskMessageRow>,
          ),
          AskMessageRow,
          PrefetchHooks Function()
        > {
  $$AskMessagesTableTableManager(_$LocalDb db, $AskMessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AskMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AskMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AskMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<String> sourcesJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> serverSeq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AskMessagesCompanion(
                id: id,
                role: role,
                body: body,
                sourcesJson: sourcesJson,
                createdAt: createdAt,
                serverSeq: serverSeq,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String role,
                required String body,
                Value<String> sourcesJson = const Value.absent(),
                required int createdAt,
                required int serverSeq,
                Value<int> rowid = const Value.absent(),
              }) => AskMessagesCompanion.insert(
                id: id,
                role: role,
                body: body,
                sourcesJson: sourcesJson,
                createdAt: createdAt,
                serverSeq: serverSeq,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AskMessagesTable, AskMessageRow>(table),
                  BaseReferences<_$LocalDb, $AskMessagesTable, AskMessageRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AskMessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $AskMessagesTable,
      AskMessageRow,
      $$AskMessagesTableFilterComposer,
      $$AskMessagesTableOrderingComposer,
      $$AskMessagesTableAnnotationComposer,
      $$AskMessagesTableCreateCompanionBuilder,
      $$AskMessagesTableUpdateCompanionBuilder,
      (
        AskMessageRow,
        BaseReferences<_$LocalDb, $AskMessagesTable, AskMessageRow>,
      ),
      AskMessageRow,
      PrefetchHooks Function()
    >;
typedef $$AskSourceVisitsTableCreateCompanionBuilder =
    AskSourceVisitsCompanion Function({
      required String messageId,
      required int sourceIndex,
      required int visitedAt,
      Value<int> rowid,
    });
typedef $$AskSourceVisitsTableUpdateCompanionBuilder =
    AskSourceVisitsCompanion Function({
      Value<String> messageId,
      Value<int> sourceIndex,
      Value<int> visitedAt,
      Value<int> rowid,
    });

class $$AskSourceVisitsTableFilterComposer
    extends Composer<_$LocalDb, $AskSourceVisitsTable> {
  $$AskSourceVisitsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sourceIndex => $composableBuilder(
    column: $table.sourceIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get visitedAt => $composableBuilder(
    column: $table.visitedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AskSourceVisitsTableOrderingComposer
    extends Composer<_$LocalDb, $AskSourceVisitsTable> {
  $$AskSourceVisitsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sourceIndex => $composableBuilder(
    column: $table.sourceIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get visitedAt => $composableBuilder(
    column: $table.visitedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AskSourceVisitsTableAnnotationComposer
    extends Composer<_$LocalDb, $AskSourceVisitsTable> {
  $$AskSourceVisitsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<int> get sourceIndex => $composableBuilder(
    column: $table.sourceIndex,
    builder: (column) => column,
  );

  GeneratedColumn<int> get visitedAt =>
      $composableBuilder(column: $table.visitedAt, builder: (column) => column);
}

class $$AskSourceVisitsTableTableManager
    extends
        RootTableManager<
          _$LocalDb,
          $AskSourceVisitsTable,
          AskSourceVisitRow,
          $$AskSourceVisitsTableFilterComposer,
          $$AskSourceVisitsTableOrderingComposer,
          $$AskSourceVisitsTableAnnotationComposer,
          $$AskSourceVisitsTableCreateCompanionBuilder,
          $$AskSourceVisitsTableUpdateCompanionBuilder,
          (
            AskSourceVisitRow,
            BaseReferences<_$LocalDb, $AskSourceVisitsTable, AskSourceVisitRow>,
          ),
          AskSourceVisitRow,
          PrefetchHooks Function()
        > {
  $$AskSourceVisitsTableTableManager(_$LocalDb db, $AskSourceVisitsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AskSourceVisitsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AskSourceVisitsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AskSourceVisitsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> messageId = const Value.absent(),
                Value<int> sourceIndex = const Value.absent(),
                Value<int> visitedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AskSourceVisitsCompanion(
                messageId: messageId,
                sourceIndex: sourceIndex,
                visitedAt: visitedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String messageId,
                required int sourceIndex,
                required int visitedAt,
                Value<int> rowid = const Value.absent(),
              }) => AskSourceVisitsCompanion.insert(
                messageId: messageId,
                sourceIndex: sourceIndex,
                visitedAt: visitedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AskSourceVisitsTable, AskSourceVisitRow>(table),
                  BaseReferences<
                    _$LocalDb,
                    $AskSourceVisitsTable,
                    AskSourceVisitRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AskSourceVisitsTableProcessedTableManager =
    ProcessedTableManager<
      _$LocalDb,
      $AskSourceVisitsTable,
      AskSourceVisitRow,
      $$AskSourceVisitsTableFilterComposer,
      $$AskSourceVisitsTableOrderingComposer,
      $$AskSourceVisitsTableAnnotationComposer,
      $$AskSourceVisitsTableCreateCompanionBuilder,
      $$AskSourceVisitsTableUpdateCompanionBuilder,
      (
        AskSourceVisitRow,
        BaseReferences<_$LocalDb, $AskSourceVisitsTable, AskSourceVisitRow>,
      ),
      AskSourceVisitRow,
      PrefetchHooks Function()
    >;

class $LocalDbManager {
  final _$LocalDb _db;
  $LocalDbManager(this._db);
  $$DumpsTableTableManager get dumps =>
      $$DumpsTableTableManager(_db, _db.dumps);
  $$FoldersTableTableManager get folders =>
      $$FoldersTableTableManager(_db, _db.folders);
  $$SyncQueueTableTableManager get syncQueue =>
      $$SyncQueueTableTableManager(_db, _db.syncQueue);
  $$StorageLocationsTableTableManager get storageLocations =>
      $$StorageLocationsTableTableManager(_db, _db.storageLocations);
  $$StorageCatalogStatesTableTableManager get storageCatalogStates =>
      $$StorageCatalogStatesTableTableManager(_db, _db.storageCatalogStates);
  $$RecordingBindingsTableTableManager get recordingBindings =>
      $$RecordingBindingsTableTableManager(_db, _db.recordingBindings);
  $$CaptureReservationsTableTableManager get captureReservations =>
      $$CaptureReservationsTableTableManager(_db, _db.captureReservations);
  $$LocalDeletionBatchesTableTableManager get localDeletionBatches =>
      $$LocalDeletionBatchesTableTableManager(_db, _db.localDeletionBatches);
  $$LocalDeletionTicketsTableTableManager get localDeletionTickets =>
      $$LocalDeletionTicketsTableTableManager(_db, _db.localDeletionTickets);
  $$NotebooksTableTableManager get notebooks =>
      $$NotebooksTableTableManager(_db, _db.notebooks);
  $$SyncTombstonesTableTableManager get syncTombstones =>
      $$SyncTombstonesTableTableManager(_db, _db.syncTombstones);
  $$SyncStatesTableTableManager get syncStates =>
      $$SyncStatesTableTableManager(_db, _db.syncStates);
  $$InkIndexEntriesTableTableManager get inkIndexEntries =>
      $$InkIndexEntriesTableTableManager(_db, _db.inkIndexEntries);
  $$LocalSettingsTableTableManager get localSettings =>
      $$LocalSettingsTableTableManager(_db, _db.localSettings);
  $$TodosTableTableManager get todos =>
      $$TodosTableTableManager(_db, _db.todos);
  $$CalendarEventsTableTableManager get calendarEvents =>
      $$CalendarEventsTableTableManager(_db, _db.calendarEvents);
  $$AskMessagesTableTableManager get askMessages =>
      $$AskMessagesTableTableManager(_db, _db.askMessages);
  $$AskSourceVisitsTableTableManager get askSourceVisits =>
      $$AskSourceVisitsTableTableManager(_db, _db.askSourceVisits);
}
