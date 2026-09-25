// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'dump.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

Dump _$DumpFromJson(Map<String, dynamic> json) {
  return _Dump.fromJson(json);
}

/// @nodoc
mixin _$Dump {
  String get id => throw _privateConstructorUsedError;
  DateTime get createdAt => throw _privateConstructorUsedError;
  DateTime get updatedAt => throw _privateConstructorUsedError;
  DumpMode get mode => throw _privateConstructorUsedError;
  int get durationSeconds => throw _privateConstructorUsedError;
  String get title => throw _privateConstructorUsedError;
  String? get transcript => throw _privateConstructorUsedError;
  @JsonKey(name: 'audio_path')
  String get audioPath => throw _privateConstructorUsedError;
  @JsonKey(name: 'audio_size_bytes')
  int get audioSizeBytes => throw _privateConstructorUsedError;
  @JsonKey(name: 'sync_status')
  SyncStatus get syncStatus => throw _privateConstructorUsedError;
  @JsonKey(name: 'sync_attempts')
  int get syncAttempts => throw _privateConstructorUsedError;
  @JsonKey(name: 'last_sync_error')
  String? get lastSyncError => throw _privateConstructorUsedError;

  /// Server-generated AI summary (markdown sections). Null until the
  /// server has summarized this recording; never written by the client.
  String? get summary => throw _privateConstructorUsedError;

  /// The model stem that produced [summary]; null with it.
  @JsonKey(name: 'summary_model')
  String? get summaryModel => throw _privateConstructorUsedError;

  /// When the server generated [summary]; null with it.
  @JsonKey(name: 'summarized_at')
  DateTime? get summarizedAt => throw _privateConstructorUsedError;

  /// Serializes this Dump to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of Dump
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $DumpCopyWith<Dump> get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $DumpCopyWith<$Res> {
  factory $DumpCopyWith(Dump value, $Res Function(Dump) then) =
      _$DumpCopyWithImpl<$Res, Dump>;
  @useResult
  $Res call(
      {String id,
      DateTime createdAt,
      DateTime updatedAt,
      DumpMode mode,
      int durationSeconds,
      String title,
      String? transcript,
      @JsonKey(name: 'audio_path') String audioPath,
      @JsonKey(name: 'audio_size_bytes') int audioSizeBytes,
      @JsonKey(name: 'sync_status') SyncStatus syncStatus,
      @JsonKey(name: 'sync_attempts') int syncAttempts,
      @JsonKey(name: 'last_sync_error') String? lastSyncError,
      String? summary,
      @JsonKey(name: 'summary_model') String? summaryModel,
      @JsonKey(name: 'summarized_at') DateTime? summarizedAt});
}

/// @nodoc
class _$DumpCopyWithImpl<$Res, $Val extends Dump>
    implements $DumpCopyWith<$Res> {
  _$DumpCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of Dump
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? createdAt = null,
    Object? updatedAt = null,
    Object? mode = null,
    Object? durationSeconds = null,
    Object? title = null,
    Object? transcript = freezed,
    Object? audioPath = null,
    Object? audioSizeBytes = null,
    Object? syncStatus = null,
    Object? syncAttempts = null,
    Object? lastSyncError = freezed,
    Object? summary = freezed,
    Object? summaryModel = freezed,
    Object? summarizedAt = freezed,
  }) {
    return _then(_value.copyWith(
      id: null == id
          ? _value.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      createdAt: null == createdAt
          ? _value.createdAt
          : createdAt // ignore: cast_nullable_to_non_nullable
              as DateTime,
      updatedAt: null == updatedAt
          ? _value.updatedAt
          : updatedAt // ignore: cast_nullable_to_non_nullable
              as DateTime,
      mode: null == mode
          ? _value.mode
          : mode // ignore: cast_nullable_to_non_nullable
              as DumpMode,
      durationSeconds: null == durationSeconds
          ? _value.durationSeconds
          : durationSeconds // ignore: cast_nullable_to_non_nullable
              as int,
      title: null == title
          ? _value.title
          : title // ignore: cast_nullable_to_non_nullable
              as String,
      transcript: freezed == transcript
          ? _value.transcript
          : transcript // ignore: cast_nullable_to_non_nullable
              as String?,
      audioPath: null == audioPath
          ? _value.audioPath
          : audioPath // ignore: cast_nullable_to_non_nullable
              as String,
      audioSizeBytes: null == audioSizeBytes
          ? _value.audioSizeBytes
          : audioSizeBytes // ignore: cast_nullable_to_non_nullable
              as int,
      syncStatus: null == syncStatus
          ? _value.syncStatus
          : syncStatus // ignore: cast_nullable_to_non_nullable
              as SyncStatus,
      syncAttempts: null == syncAttempts
          ? _value.syncAttempts
          : syncAttempts // ignore: cast_nullable_to_non_nullable
              as int,
      lastSyncError: freezed == lastSyncError
          ? _value.lastSyncError
          : lastSyncError // ignore: cast_nullable_to_non_nullable
              as String?,
      summary: freezed == summary
          ? _value.summary
          : summary // ignore: cast_nullable_to_non_nullable
              as String?,
      summaryModel: freezed == summaryModel
          ? _value.summaryModel
          : summaryModel // ignore: cast_nullable_to_non_nullable
              as String?,
      summarizedAt: freezed == summarizedAt
          ? _value.summarizedAt
          : summarizedAt // ignore: cast_nullable_to_non_nullable
              as DateTime?,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$DumpImplCopyWith<$Res> implements $DumpCopyWith<$Res> {
  factory _$$DumpImplCopyWith(
          _$DumpImpl value, $Res Function(_$DumpImpl) then) =
      __$$DumpImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String id,
      DateTime createdAt,
      DateTime updatedAt,
      DumpMode mode,
      int durationSeconds,
      String title,
      String? transcript,
      @JsonKey(name: 'audio_path') String audioPath,
      @JsonKey(name: 'audio_size_bytes') int audioSizeBytes,
      @JsonKey(name: 'sync_status') SyncStatus syncStatus,
      @JsonKey(name: 'sync_attempts') int syncAttempts,
      @JsonKey(name: 'last_sync_error') String? lastSyncError,
      String? summary,
      @JsonKey(name: 'summary_model') String? summaryModel,
      @JsonKey(name: 'summarized_at') DateTime? summarizedAt});
}

/// @nodoc
class __$$DumpImplCopyWithImpl<$Res>
    extends _$DumpCopyWithImpl<$Res, _$DumpImpl>
    implements _$$DumpImplCopyWith<$Res> {
  __$$DumpImplCopyWithImpl(_$DumpImpl _value, $Res Function(_$DumpImpl) _then)
      : super(_value, _then);

  /// Create a copy of Dump
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? createdAt = null,
    Object? updatedAt = null,
    Object? mode = null,
    Object? durationSeconds = null,
    Object? title = null,
    Object? transcript = freezed,
    Object? audioPath = null,
    Object? audioSizeBytes = null,
    Object? syncStatus = null,
    Object? syncAttempts = null,
    Object? lastSyncError = freezed,
    Object? summary = freezed,
    Object? summaryModel = freezed,
    Object? summarizedAt = freezed,
  }) {
    return _then(_$DumpImpl(
      id: null == id
          ? _value.id
          : id // ignore: cast_nullable_to_non_nullable
              as String,
      createdAt: null == createdAt
          ? _value.createdAt
          : createdAt // ignore: cast_nullable_to_non_nullable
              as DateTime,
      updatedAt: null == updatedAt
          ? _value.updatedAt
          : updatedAt // ignore: cast_nullable_to_non_nullable
              as DateTime,
      mode: null == mode
          ? _value.mode
          : mode // ignore: cast_nullable_to_non_nullable
              as DumpMode,
      durationSeconds: null == durationSeconds
          ? _value.durationSeconds
          : durationSeconds // ignore: cast_nullable_to_non_nullable
              as int,
      title: null == title
          ? _value.title
          : title // ignore: cast_nullable_to_non_nullable
              as String,
      transcript: freezed == transcript
          ? _value.transcript
          : transcript // ignore: cast_nullable_to_non_nullable
              as String?,
      audioPath: null == audioPath
          ? _value.audioPath
          : audioPath // ignore: cast_nullable_to_non_nullable
              as String,
      audioSizeBytes: null == audioSizeBytes
          ? _value.audioSizeBytes
          : audioSizeBytes // ignore: cast_nullable_to_non_nullable
              as int,
      syncStatus: null == syncStatus
          ? _value.syncStatus
          : syncStatus // ignore: cast_nullable_to_non_nullable
              as SyncStatus,
      syncAttempts: null == syncAttempts
          ? _value.syncAttempts
          : syncAttempts // ignore: cast_nullable_to_non_nullable
              as int,
      lastSyncError: freezed == lastSyncError
          ? _value.lastSyncError
          : lastSyncError // ignore: cast_nullable_to_non_nullable
              as String?,
      summary: freezed == summary
          ? _value.summary
          : summary // ignore: cast_nullable_to_non_nullable
              as String?,
      summaryModel: freezed == summaryModel
          ? _value.summaryModel
          : summaryModel // ignore: cast_nullable_to_non_nullable
              as String?,
      summarizedAt: freezed == summarizedAt
          ? _value.summarizedAt
          : summarizedAt // ignore: cast_nullable_to_non_nullable
              as DateTime?,
    ));
  }
}

/// @nodoc
@JsonSerializable()
@JsonKey(name: 'mode')
class _$DumpImpl implements _Dump {
  const _$DumpImpl(
      {required this.id,
      required this.createdAt,
      required this.updatedAt,
      required this.mode,
      required this.durationSeconds,
      required this.title,
      this.transcript,
      @JsonKey(name: 'audio_path') required this.audioPath,
      @JsonKey(name: 'audio_size_bytes') required this.audioSizeBytes,
      @JsonKey(name: 'sync_status') required this.syncStatus,
      @JsonKey(name: 'sync_attempts') this.syncAttempts = 0,
      @JsonKey(name: 'last_sync_error') this.lastSyncError,
      this.summary,
      @JsonKey(name: 'summary_model') this.summaryModel,
      @JsonKey(name: 'summarized_at') this.summarizedAt});

  factory _$DumpImpl.fromJson(Map<String, dynamic> json) =>
      _$$DumpImplFromJson(json);

  @override
  final String id;
  @override
  final DateTime createdAt;
  @override
  final DateTime updatedAt;
  @override
  final DumpMode mode;
  @override
  final int durationSeconds;
  @override
  final String title;
  @override
  final String? transcript;
  @override
  @JsonKey(name: 'audio_path')
  final String audioPath;
  @override
  @JsonKey(name: 'audio_size_bytes')
  final int audioSizeBytes;
  @override
  @JsonKey(name: 'sync_status')
  final SyncStatus syncStatus;
  @override
  @JsonKey(name: 'sync_attempts')
  final int syncAttempts;
  @override
  @JsonKey(name: 'last_sync_error')
  final String? lastSyncError;

  /// Server-generated AI summary (markdown sections). Null until the
  /// server has summarized this recording; never written by the client.
  @override
  final String? summary;

  /// The model stem that produced [summary]; null with it.
  @override
  @JsonKey(name: 'summary_model')
  final String? summaryModel;

  /// When the server generated [summary]; null with it.
  @override
  @JsonKey(name: 'summarized_at')
  final DateTime? summarizedAt;

  @override
  String toString() {
    return 'Dump(id: $id, createdAt: $createdAt, updatedAt: $updatedAt, mode: $mode, durationSeconds: $durationSeconds, title: $title, transcript: $transcript, audioPath: $audioPath, audioSizeBytes: $audioSizeBytes, syncStatus: $syncStatus, syncAttempts: $syncAttempts, lastSyncError: $lastSyncError, summary: $summary, summaryModel: $summaryModel, summarizedAt: $summarizedAt)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$DumpImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.createdAt, createdAt) ||
                other.createdAt == createdAt) &&
            (identical(other.updatedAt, updatedAt) ||
                other.updatedAt == updatedAt) &&
            (identical(other.mode, mode) || other.mode == mode) &&
            (identical(other.durationSeconds, durationSeconds) ||
                other.durationSeconds == durationSeconds) &&
            (identical(other.title, title) || other.title == title) &&
            (identical(other.transcript, transcript) ||
                other.transcript == transcript) &&
            (identical(other.audioPath, audioPath) ||
                other.audioPath == audioPath) &&
            (identical(other.audioSizeBytes, audioSizeBytes) ||
                other.audioSizeBytes == audioSizeBytes) &&
            (identical(other.syncStatus, syncStatus) ||
                other.syncStatus == syncStatus) &&
            (identical(other.syncAttempts, syncAttempts) ||
                other.syncAttempts == syncAttempts) &&
            (identical(other.lastSyncError, lastSyncError) ||
                other.lastSyncError == lastSyncError) &&
            (identical(other.summary, summary) || other.summary == summary) &&
            (identical(other.summaryModel, summaryModel) ||
                other.summaryModel == summaryModel) &&
            (identical(other.summarizedAt, summarizedAt) ||
                other.summarizedAt == summarizedAt));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
      runtimeType,
      id,
      createdAt,
      updatedAt,
      mode,
      durationSeconds,
      title,
      transcript,
      audioPath,
      audioSizeBytes,
      syncStatus,
      syncAttempts,
      lastSyncError,
      summary,
      summaryModel,
      summarizedAt);

  /// Create a copy of Dump
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$DumpImplCopyWith<_$DumpImpl> get copyWith =>
      __$$DumpImplCopyWithImpl<_$DumpImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$DumpImplToJson(
      this,
    );
  }
}

abstract class _Dump implements Dump {
  const factory _Dump(
          {required final String id,
          required final DateTime createdAt,
          required final DateTime updatedAt,
          required final DumpMode mode,
          required final int durationSeconds,
          required final String title,
          final String? transcript,
          @JsonKey(name: 'audio_path') required final String audioPath,
          @JsonKey(name: 'audio_size_bytes') required final int audioSizeBytes,
          @JsonKey(name: 'sync_status') required final SyncStatus syncStatus,
          @JsonKey(name: 'sync_attempts') final int syncAttempts,
          @JsonKey(name: 'last_sync_error') final String? lastSyncError,
          final String? summary,
          @JsonKey(name: 'summary_model') final String? summaryModel,
          @JsonKey(name: 'summarized_at') final DateTime? summarizedAt}) =
      _$DumpImpl;

  factory _Dump.fromJson(Map<String, dynamic> json) = _$DumpImpl.fromJson;

  @override
  String get id;
  @override
  DateTime get createdAt;
  @override
  DateTime get updatedAt;
  @override
  DumpMode get mode;
  @override
  int get durationSeconds;
  @override
  String get title;
  @override
  String? get transcript;
  @override
  @JsonKey(name: 'audio_path')
  String get audioPath;
  @override
  @JsonKey(name: 'audio_size_bytes')
  int get audioSizeBytes;
  @override
  @JsonKey(name: 'sync_status')
  SyncStatus get syncStatus;
  @override
  @JsonKey(name: 'sync_attempts')
  int get syncAttempts;
  @override
  @JsonKey(name: 'last_sync_error')
  String? get lastSyncError;

  /// Server-generated AI summary (markdown sections). Null until the
  /// server has summarized this recording; never written by the client.
  @override
  String? get summary;

  /// The model stem that produced [summary]; null with it.
  @override
  @JsonKey(name: 'summary_model')
  String? get summaryModel;

  /// When the server generated [summary]; null with it.
  @override
  @JsonKey(name: 'summarized_at')
  DateTime? get summarizedAt;

  /// Create a copy of Dump
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$DumpImplCopyWith<_$DumpImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
