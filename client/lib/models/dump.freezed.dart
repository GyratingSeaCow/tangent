// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'dump.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$Dump {

 String get id; DateTime get createdAt; DateTime get updatedAt; DumpMode get mode; int get durationSeconds; String get title; String? get transcript;@JsonKey(name: 'audio_path') String get audioPath;@JsonKey(name: 'audio_size_bytes') int get audioSizeBytes;@JsonKey(name: 'sync_status') SyncStatus get syncStatus;@JsonKey(name: 'sync_attempts') int get syncAttempts;@JsonKey(name: 'last_sync_error') String? get lastSyncError;/// Server-generated AI summary (markdown sections). Null until the
/// server has summarized this recording; never written by the client.
 String? get summary;/// The model stem that produced [summary]; null with it.
@JsonKey(name: 'summary_model') String? get summaryModel;/// When the server generated [summary]; null with it.
@JsonKey(name: 'summarized_at') DateTime? get summarizedAt;/// Word-level timings JSON (server-owned, see transcript_timings.dart).
/// Null until a transcription with timings has completed.
@JsonKey(name: 'transcript_timings') String? get transcriptTimings;/// The summary template id the server last used for this recording
/// (server-owned; null = mode default).
@JsonKey(name: 'summary_template') String? get summaryTemplate;/// Per-recording speaker name map as JSON text (`{"Speaker 1":"Jeff"}`),
/// device-authored; null = no names (see models/speaker_names.dart).
@JsonKey(name: 'speaker_names') String? get speakerNames;
/// Create a copy of Dump
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$DumpCopyWith<Dump> get copyWith => _$DumpCopyWithImpl<Dump>(this as Dump, _$identity);

  /// Serializes this Dump to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  final _this = this as Dump;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Dump&&(identical(other.id, _this.id) || other.id == _this.id)&&(identical(other.createdAt, _this.createdAt) || other.createdAt == _this.createdAt)&&(identical(other.updatedAt, _this.updatedAt) || other.updatedAt == _this.updatedAt)&&(identical(other.mode, _this.mode) || other.mode == _this.mode)&&(identical(other.durationSeconds, _this.durationSeconds) || other.durationSeconds == _this.durationSeconds)&&(identical(other.title, _this.title) || other.title == _this.title)&&(identical(other.transcript, _this.transcript) || other.transcript == _this.transcript)&&(identical(other.audioPath, _this.audioPath) || other.audioPath == _this.audioPath)&&(identical(other.audioSizeBytes, _this.audioSizeBytes) || other.audioSizeBytes == _this.audioSizeBytes)&&(identical(other.syncStatus, _this.syncStatus) || other.syncStatus == _this.syncStatus)&&(identical(other.syncAttempts, _this.syncAttempts) || other.syncAttempts == _this.syncAttempts)&&(identical(other.lastSyncError, _this.lastSyncError) || other.lastSyncError == _this.lastSyncError)&&(identical(other.summary, _this.summary) || other.summary == _this.summary)&&(identical(other.summaryModel, _this.summaryModel) || other.summaryModel == _this.summaryModel)&&(identical(other.summarizedAt, _this.summarizedAt) || other.summarizedAt == _this.summarizedAt)&&(identical(other.transcriptTimings, _this.transcriptTimings) || other.transcriptTimings == _this.transcriptTimings)&&(identical(other.summaryTemplate, _this.summaryTemplate) || other.summaryTemplate == _this.summaryTemplate)&&(identical(other.speakerNames, _this.speakerNames) || other.speakerNames == _this.speakerNames));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
  final _this = this as Dump;
  return Object.hash(runtimeType,_this.id,_this.createdAt,_this.updatedAt,_this.mode,_this.durationSeconds,_this.title,_this.transcript,_this.audioPath,_this.audioSizeBytes,_this.syncStatus,_this.syncAttempts,_this.lastSyncError,_this.summary,_this.summaryModel,_this.summarizedAt,_this.transcriptTimings,_this.summaryTemplate,_this.speakerNames);
}

@override
String toString() {
  final _this = this as Dump;
  return 'Dump(id: ${_this.id}, createdAt: ${_this.createdAt}, updatedAt: ${_this.updatedAt}, mode: ${_this.mode}, durationSeconds: ${_this.durationSeconds}, title: ${_this.title}, transcript: ${_this.transcript}, audioPath: ${_this.audioPath}, audioSizeBytes: ${_this.audioSizeBytes}, syncStatus: ${_this.syncStatus}, syncAttempts: ${_this.syncAttempts}, lastSyncError: ${_this.lastSyncError}, summary: ${_this.summary}, summaryModel: ${_this.summaryModel}, summarizedAt: ${_this.summarizedAt}, transcriptTimings: ${_this.transcriptTimings}, summaryTemplate: ${_this.summaryTemplate}, speakerNames: ${_this.speakerNames})';
}


}

/// @nodoc
abstract mixin class $DumpCopyWith<$Res>  {
  factory $DumpCopyWith(Dump value, $Res Function(Dump) _then) = _$DumpCopyWithImpl;
@useResult
$Res call({
 String id, DateTime createdAt, DateTime updatedAt, DumpMode mode, int durationSeconds, String title, String? transcript,@JsonKey(name: 'audio_path') String audioPath,@JsonKey(name: 'audio_size_bytes') int audioSizeBytes,@JsonKey(name: 'sync_status') SyncStatus syncStatus,@JsonKey(name: 'sync_attempts') int syncAttempts,@JsonKey(name: 'last_sync_error') String? lastSyncError, String? summary,@JsonKey(name: 'summary_model') String? summaryModel,@JsonKey(name: 'summarized_at') DateTime? summarizedAt,@JsonKey(name: 'transcript_timings') String? transcriptTimings,@JsonKey(name: 'summary_template') String? summaryTemplate,@JsonKey(name: 'speaker_names') String? speakerNames
});




}
/// @nodoc
class _$DumpCopyWithImpl<$Res>
    implements $DumpCopyWith<$Res> {
  _$DumpCopyWithImpl(this._self, this._then);

  final Dump _self;
  final $Res Function(Dump) _then;

/// Create a copy of Dump
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? createdAt = null,Object? updatedAt = null,Object? mode = null,Object? durationSeconds = null,Object? title = null,Object? transcript = freezed,Object? audioPath = null,Object? audioSizeBytes = null,Object? syncStatus = null,Object? syncAttempts = null,Object? lastSyncError = freezed,Object? summary = freezed,Object? summaryModel = freezed,Object? summarizedAt = freezed,Object? transcriptTimings = freezed,Object? summaryTemplate = freezed,Object? speakerNames = freezed,}) {
  return _then(Dump(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as DumpMode,durationSeconds: null == durationSeconds ? _self.durationSeconds : durationSeconds // ignore: cast_nullable_to_non_nullable
as int,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,transcript: freezed == transcript ? _self.transcript : transcript // ignore: cast_nullable_to_non_nullable
as String?,audioPath: null == audioPath ? _self.audioPath : audioPath // ignore: cast_nullable_to_non_nullable
as String,audioSizeBytes: null == audioSizeBytes ? _self.audioSizeBytes : audioSizeBytes // ignore: cast_nullable_to_non_nullable
as int,syncStatus: null == syncStatus ? _self.syncStatus : syncStatus // ignore: cast_nullable_to_non_nullable
as SyncStatus,syncAttempts: null == syncAttempts ? _self.syncAttempts : syncAttempts // ignore: cast_nullable_to_non_nullable
as int,lastSyncError: freezed == lastSyncError ? _self.lastSyncError : lastSyncError // ignore: cast_nullable_to_non_nullable
as String?,summary: freezed == summary ? _self.summary : summary // ignore: cast_nullable_to_non_nullable
as String?,summaryModel: freezed == summaryModel ? _self.summaryModel : summaryModel // ignore: cast_nullable_to_non_nullable
as String?,summarizedAt: freezed == summarizedAt ? _self.summarizedAt : summarizedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,transcriptTimings: freezed == transcriptTimings ? _self.transcriptTimings : transcriptTimings // ignore: cast_nullable_to_non_nullable
as String?,summaryTemplate: freezed == summaryTemplate ? _self.summaryTemplate : summaryTemplate // ignore: cast_nullable_to_non_nullable
as String?,speakerNames: freezed == speakerNames ? _self.speakerNames : speakerNames // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}

}


/// Adds pattern-matching-related methods to [Dump].
extension DumpPatterns on Dump {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _Dump value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _Dump() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _Dump value)  $default,){
final _that = this;
switch (_that) {
case _Dump():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _Dump value)?  $default,){
final _that = this;
switch (_that) {
case _Dump() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  DateTime createdAt,  DateTime updatedAt,  DumpMode mode,  int durationSeconds,  String title,  String? transcript, @JsonKey(name: 'audio_path')  String audioPath, @JsonKey(name: 'audio_size_bytes')  int audioSizeBytes, @JsonKey(name: 'sync_status')  SyncStatus syncStatus, @JsonKey(name: 'sync_attempts')  int syncAttempts, @JsonKey(name: 'last_sync_error')  String? lastSyncError,  String? summary, @JsonKey(name: 'summary_model')  String? summaryModel, @JsonKey(name: 'summarized_at')  DateTime? summarizedAt, @JsonKey(name: 'transcript_timings')  String? transcriptTimings, @JsonKey(name: 'summary_template')  String? summaryTemplate, @JsonKey(name: 'speaker_names')  String? speakerNames)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _Dump() when $default != null:
return $default(_that.id,_that.createdAt,_that.updatedAt,_that.mode,_that.durationSeconds,_that.title,_that.transcript,_that.audioPath,_that.audioSizeBytes,_that.syncStatus,_that.syncAttempts,_that.lastSyncError,_that.summary,_that.summaryModel,_that.summarizedAt,_that.transcriptTimings,_that.summaryTemplate,_that.speakerNames);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  DateTime createdAt,  DateTime updatedAt,  DumpMode mode,  int durationSeconds,  String title,  String? transcript, @JsonKey(name: 'audio_path')  String audioPath, @JsonKey(name: 'audio_size_bytes')  int audioSizeBytes, @JsonKey(name: 'sync_status')  SyncStatus syncStatus, @JsonKey(name: 'sync_attempts')  int syncAttempts, @JsonKey(name: 'last_sync_error')  String? lastSyncError,  String? summary, @JsonKey(name: 'summary_model')  String? summaryModel, @JsonKey(name: 'summarized_at')  DateTime? summarizedAt, @JsonKey(name: 'transcript_timings')  String? transcriptTimings, @JsonKey(name: 'summary_template')  String? summaryTemplate, @JsonKey(name: 'speaker_names')  String? speakerNames)  $default,) {final _that = this;
switch (_that) {
case _Dump():
return $default(_that.id,_that.createdAt,_that.updatedAt,_that.mode,_that.durationSeconds,_that.title,_that.transcript,_that.audioPath,_that.audioSizeBytes,_that.syncStatus,_that.syncAttempts,_that.lastSyncError,_that.summary,_that.summaryModel,_that.summarizedAt,_that.transcriptTimings,_that.summaryTemplate,_that.speakerNames);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  DateTime createdAt,  DateTime updatedAt,  DumpMode mode,  int durationSeconds,  String title,  String? transcript, @JsonKey(name: 'audio_path')  String audioPath, @JsonKey(name: 'audio_size_bytes')  int audioSizeBytes, @JsonKey(name: 'sync_status')  SyncStatus syncStatus, @JsonKey(name: 'sync_attempts')  int syncAttempts, @JsonKey(name: 'last_sync_error')  String? lastSyncError,  String? summary, @JsonKey(name: 'summary_model')  String? summaryModel, @JsonKey(name: 'summarized_at')  DateTime? summarizedAt, @JsonKey(name: 'transcript_timings')  String? transcriptTimings, @JsonKey(name: 'summary_template')  String? summaryTemplate, @JsonKey(name: 'speaker_names')  String? speakerNames)?  $default,) {final _that = this;
switch (_that) {
case _Dump() when $default != null:
return $default(_that.id,_that.createdAt,_that.updatedAt,_that.mode,_that.durationSeconds,_that.title,_that.transcript,_that.audioPath,_that.audioSizeBytes,_that.syncStatus,_that.syncAttempts,_that.lastSyncError,_that.summary,_that.summaryModel,_that.summarizedAt,_that.transcriptTimings,_that.summaryTemplate,_that.speakerNames);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()
@JsonKey(name: 'mode')
class _Dump implements Dump {
  const _Dump({required this.id, required this.createdAt, required this.updatedAt, required this.mode, required this.durationSeconds, required this.title, this.transcript, @JsonKey(name: 'audio_path') required this.audioPath, @JsonKey(name: 'audio_size_bytes') required this.audioSizeBytes, @JsonKey(name: 'sync_status') required this.syncStatus, @JsonKey(name: 'sync_attempts') this.syncAttempts = 0, @JsonKey(name: 'last_sync_error') this.lastSyncError, this.summary, @JsonKey(name: 'summary_model') this.summaryModel, @JsonKey(name: 'summarized_at') this.summarizedAt, @JsonKey(name: 'transcript_timings') this.transcriptTimings, @JsonKey(name: 'summary_template') this.summaryTemplate, @JsonKey(name: 'speaker_names') this.speakerNames});
  factory _Dump.fromJson(Map<String, dynamic> json) => _$DumpFromJson(json);

@override final  String id;
@override final  DateTime createdAt;
@override final  DateTime updatedAt;
@override final  DumpMode mode;
@override final  int durationSeconds;
@override final  String title;
@override final  String? transcript;
@override@JsonKey(name: 'audio_path') final  String audioPath;
@override@JsonKey(name: 'audio_size_bytes') final  int audioSizeBytes;
@override@JsonKey(name: 'sync_status') final  SyncStatus syncStatus;
@override@JsonKey(name: 'sync_attempts') final  int syncAttempts;
@override@JsonKey(name: 'last_sync_error') final  String? lastSyncError;
/// Server-generated AI summary (markdown sections). Null until the
/// server has summarized this recording; never written by the client.
@override final  String? summary;
/// The model stem that produced [summary]; null with it.
@override@JsonKey(name: 'summary_model') final  String? summaryModel;
/// When the server generated [summary]; null with it.
@override@JsonKey(name: 'summarized_at') final  DateTime? summarizedAt;
/// Word-level timings JSON (server-owned, see transcript_timings.dart).
/// Null until a transcription with timings has completed.
@override@JsonKey(name: 'transcript_timings') final  String? transcriptTimings;
/// The summary template id the server last used for this recording
/// (server-owned; null = mode default).
@override@JsonKey(name: 'summary_template') final  String? summaryTemplate;
/// Per-recording speaker name map as JSON text (`{"Speaker 1":"Jeff"}`),
/// device-authored; null = no names (see models/speaker_names.dart).
@override@JsonKey(name: 'speaker_names') final  String? speakerNames;

/// Create a copy of Dump
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$DumpCopyWith<_Dump> get copyWith => __$DumpCopyWithImpl<_Dump>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$DumpToJson(this, );
}

@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _Dump&&(identical(other.id, id) || other.id == id)&&(identical(other.createdAt, createdAt) || other.createdAt == createdAt)&&(identical(other.updatedAt, updatedAt) || other.updatedAt == updatedAt)&&(identical(other.mode, mode) || other.mode == mode)&&(identical(other.durationSeconds, durationSeconds) || other.durationSeconds == durationSeconds)&&(identical(other.title, title) || other.title == title)&&(identical(other.transcript, transcript) || other.transcript == transcript)&&(identical(other.audioPath, audioPath) || other.audioPath == audioPath)&&(identical(other.audioSizeBytes, audioSizeBytes) || other.audioSizeBytes == audioSizeBytes)&&(identical(other.syncStatus, syncStatus) || other.syncStatus == syncStatus)&&(identical(other.syncAttempts, syncAttempts) || other.syncAttempts == syncAttempts)&&(identical(other.lastSyncError, lastSyncError) || other.lastSyncError == lastSyncError)&&(identical(other.summary, summary) || other.summary == summary)&&(identical(other.summaryModel, summaryModel) || other.summaryModel == summaryModel)&&(identical(other.summarizedAt, summarizedAt) || other.summarizedAt == summarizedAt)&&(identical(other.transcriptTimings, transcriptTimings) || other.transcriptTimings == transcriptTimings)&&(identical(other.summaryTemplate, summaryTemplate) || other.summaryTemplate == summaryTemplate)&&(identical(other.speakerNames, speakerNames) || other.speakerNames == speakerNames));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode {
    return Object.hash(runtimeType,id,createdAt,updatedAt,mode,durationSeconds,title,transcript,audioPath,audioSizeBytes,syncStatus,syncAttempts,lastSyncError,summary,summaryModel,summarizedAt,transcriptTimings,summaryTemplate,speakerNames);
}

@override
String toString() {
    return 'Dump(id: $id, createdAt: $createdAt, updatedAt: $updatedAt, mode: $mode, durationSeconds: $durationSeconds, title: $title, transcript: $transcript, audioPath: $audioPath, audioSizeBytes: $audioSizeBytes, syncStatus: $syncStatus, syncAttempts: $syncAttempts, lastSyncError: $lastSyncError, summary: $summary, summaryModel: $summaryModel, summarizedAt: $summarizedAt, transcriptTimings: $transcriptTimings, summaryTemplate: $summaryTemplate, speakerNames: $speakerNames)';
}


}

/// @nodoc
abstract mixin class _$DumpCopyWith<$Res> implements $DumpCopyWith<$Res> {
  factory _$DumpCopyWith(_Dump value, $Res Function(_Dump) _then) = __$DumpCopyWithImpl;
@override @useResult
$Res call({
 String id, DateTime createdAt, DateTime updatedAt, DumpMode mode, int durationSeconds, String title, String? transcript,@JsonKey(name: 'audio_path') String audioPath,@JsonKey(name: 'audio_size_bytes') int audioSizeBytes,@JsonKey(name: 'sync_status') SyncStatus syncStatus,@JsonKey(name: 'sync_attempts') int syncAttempts,@JsonKey(name: 'last_sync_error') String? lastSyncError, String? summary,@JsonKey(name: 'summary_model') String? summaryModel,@JsonKey(name: 'summarized_at') DateTime? summarizedAt,@JsonKey(name: 'transcript_timings') String? transcriptTimings,@JsonKey(name: 'summary_template') String? summaryTemplate,@JsonKey(name: 'speaker_names') String? speakerNames
});




}
/// @nodoc
class __$DumpCopyWithImpl<$Res>
    implements _$DumpCopyWith<$Res> {
  __$DumpCopyWithImpl(this._self, this._then);

  final _Dump _self;
  final $Res Function(_Dump) _then;

/// Create a copy of Dump
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? createdAt = null,Object? updatedAt = null,Object? mode = null,Object? durationSeconds = null,Object? title = null,Object? transcript = freezed,Object? audioPath = null,Object? audioSizeBytes = null,Object? syncStatus = null,Object? syncAttempts = null,Object? lastSyncError = freezed,Object? summary = freezed,Object? summaryModel = freezed,Object? summarizedAt = freezed,Object? transcriptTimings = freezed,Object? summaryTemplate = freezed,Object? speakerNames = freezed,}) {
  return _then(_Dump(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,createdAt: null == createdAt ? _self.createdAt : createdAt // ignore: cast_nullable_to_non_nullable
as DateTime,updatedAt: null == updatedAt ? _self.updatedAt : updatedAt // ignore: cast_nullable_to_non_nullable
as DateTime,mode: null == mode ? _self.mode : mode // ignore: cast_nullable_to_non_nullable
as DumpMode,durationSeconds: null == durationSeconds ? _self.durationSeconds : durationSeconds // ignore: cast_nullable_to_non_nullable
as int,title: null == title ? _self.title : title // ignore: cast_nullable_to_non_nullable
as String,transcript: freezed == transcript ? _self.transcript : transcript // ignore: cast_nullable_to_non_nullable
as String?,audioPath: null == audioPath ? _self.audioPath : audioPath // ignore: cast_nullable_to_non_nullable
as String,audioSizeBytes: null == audioSizeBytes ? _self.audioSizeBytes : audioSizeBytes // ignore: cast_nullable_to_non_nullable
as int,syncStatus: null == syncStatus ? _self.syncStatus : syncStatus // ignore: cast_nullable_to_non_nullable
as SyncStatus,syncAttempts: null == syncAttempts ? _self.syncAttempts : syncAttempts // ignore: cast_nullable_to_non_nullable
as int,lastSyncError: freezed == lastSyncError ? _self.lastSyncError : lastSyncError // ignore: cast_nullable_to_non_nullable
as String?,summary: freezed == summary ? _self.summary : summary // ignore: cast_nullable_to_non_nullable
as String?,summaryModel: freezed == summaryModel ? _self.summaryModel : summaryModel // ignore: cast_nullable_to_non_nullable
as String?,summarizedAt: freezed == summarizedAt ? _self.summarizedAt : summarizedAt // ignore: cast_nullable_to_non_nullable
as DateTime?,transcriptTimings: freezed == transcriptTimings ? _self.transcriptTimings : transcriptTimings // ignore: cast_nullable_to_non_nullable
as String?,summaryTemplate: freezed == summaryTemplate ? _self.summaryTemplate : summaryTemplate // ignore: cast_nullable_to_non_nullable
as String?,speakerNames: freezed == speakerNames ? _self.speakerNames : speakerNames // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

// dart format on
