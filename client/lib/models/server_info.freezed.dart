// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'server_info.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ServerInfo {

 String get version; bool get setupComplete; String get defaultModel; List<String> get availableModels; int get storageUsedBytes; int get dumpCount;/// v1.36.0: whether the server diarizes (and so keeps a voice book).
/// Older servers omit it → false, and Settings hides the Voices section.
 bool get diarization;
/// Create a copy of ServerInfo
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ServerInfoCopyWith<ServerInfo> get copyWith => _$ServerInfoCopyWithImpl<ServerInfo>(this as ServerInfo, _$identity);



@override
bool operator ==(Object other) {
  final _this = this as ServerInfo;
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ServerInfo&&(identical(other.version, _this.version) || other.version == _this.version)&&(identical(other.setupComplete, _this.setupComplete) || other.setupComplete == _this.setupComplete)&&(identical(other.defaultModel, _this.defaultModel) || other.defaultModel == _this.defaultModel)&&const DeepCollectionEquality().equals(other.availableModels, _this.availableModels)&&(identical(other.storageUsedBytes, _this.storageUsedBytes) || other.storageUsedBytes == _this.storageUsedBytes)&&(identical(other.dumpCount, _this.dumpCount) || other.dumpCount == _this.dumpCount)&&(identical(other.diarization, _this.diarization) || other.diarization == _this.diarization));
}


@override
int get hashCode {
  final _this = this as ServerInfo;
  return Object.hash(runtimeType,_this.version,_this.setupComplete,_this.defaultModel,const DeepCollectionEquality().hash(_this.availableModels),_this.storageUsedBytes,_this.dumpCount,_this.diarization);
}

@override
String toString() {
  final _this = this as ServerInfo;
  return 'ServerInfo(version: ${_this.version}, setupComplete: ${_this.setupComplete}, defaultModel: ${_this.defaultModel}, availableModels: ${_this.availableModels}, storageUsedBytes: ${_this.storageUsedBytes}, dumpCount: ${_this.dumpCount}, diarization: ${_this.diarization})';
}


}

/// @nodoc
abstract mixin class $ServerInfoCopyWith<$Res>  {
  factory $ServerInfoCopyWith(ServerInfo value, $Res Function(ServerInfo) _then) = _$ServerInfoCopyWithImpl;
@useResult
$Res call({
 String version, bool setupComplete, String defaultModel, List<String> availableModels, int storageUsedBytes, int dumpCount, bool diarization
});




}
/// @nodoc
class _$ServerInfoCopyWithImpl<$Res>
    implements $ServerInfoCopyWith<$Res> {
  _$ServerInfoCopyWithImpl(this._self, this._then);

  final ServerInfo _self;
  final $Res Function(ServerInfo) _then;

/// Create a copy of ServerInfo
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? version = null,Object? setupComplete = null,Object? defaultModel = null,Object? availableModels = null,Object? storageUsedBytes = null,Object? dumpCount = null,Object? diarization = null,}) {
  return _then(ServerInfo(
version: null == version ? _self.version : version // ignore: cast_nullable_to_non_nullable
as String,setupComplete: null == setupComplete ? _self.setupComplete : setupComplete // ignore: cast_nullable_to_non_nullable
as bool,defaultModel: null == defaultModel ? _self.defaultModel : defaultModel // ignore: cast_nullable_to_non_nullable
as String,availableModels: null == availableModels ? _self.availableModels : availableModels // ignore: cast_nullable_to_non_nullable
as List<String>,storageUsedBytes: null == storageUsedBytes ? _self.storageUsedBytes : storageUsedBytes // ignore: cast_nullable_to_non_nullable
as int,dumpCount: null == dumpCount ? _self.dumpCount : dumpCount // ignore: cast_nullable_to_non_nullable
as int,diarization: null == diarization ? _self.diarization : diarization // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [ServerInfo].
extension ServerInfoPatterns on ServerInfo {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ServerInfo value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ServerInfo() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ServerInfo value)  $default,){
final _that = this;
switch (_that) {
case _ServerInfo():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ServerInfo value)?  $default,){
final _that = this;
switch (_that) {
case _ServerInfo() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String version,  bool setupComplete,  String defaultModel,  List<String> availableModels,  int storageUsedBytes,  int dumpCount,  bool diarization)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ServerInfo() when $default != null:
return $default(_that.version,_that.setupComplete,_that.defaultModel,_that.availableModels,_that.storageUsedBytes,_that.dumpCount,_that.diarization);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String version,  bool setupComplete,  String defaultModel,  List<String> availableModels,  int storageUsedBytes,  int dumpCount,  bool diarization)  $default,) {final _that = this;
switch (_that) {
case _ServerInfo():
return $default(_that.version,_that.setupComplete,_that.defaultModel,_that.availableModels,_that.storageUsedBytes,_that.dumpCount,_that.diarization);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String version,  bool setupComplete,  String defaultModel,  List<String> availableModels,  int storageUsedBytes,  int dumpCount,  bool diarization)?  $default,) {final _that = this;
switch (_that) {
case _ServerInfo() when $default != null:
return $default(_that.version,_that.setupComplete,_that.defaultModel,_that.availableModels,_that.storageUsedBytes,_that.dumpCount,_that.diarization);case _:
  return null;

}
}

}

/// @nodoc


class _ServerInfo extends ServerInfo {
  const _ServerInfo({required this.version, required this.setupComplete, required this.defaultModel, required  List<String> availableModels, required this.storageUsedBytes, required this.dumpCount, this.diarization = false}): _availableModels = availableModels,super._();
  

@override final  String version;
@override final  bool setupComplete;
@override final  String defaultModel;
 final  List<String> _availableModels;
@override List<String> get availableModels {
  if (_availableModels is EqualUnmodifiableListView) return _availableModels;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_availableModels);
}

@override final  int storageUsedBytes;
@override final  int dumpCount;
/// v1.36.0: whether the server diarizes (and so keeps a voice book).
/// Older servers omit it → false, and Settings hides the Voices section.
@override@JsonKey() final  bool diarization;

/// Create a copy of ServerInfo
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ServerInfoCopyWith<_ServerInfo> get copyWith => __$ServerInfoCopyWithImpl<_ServerInfo>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is _ServerInfo&&(identical(other.version, version) || other.version == version)&&(identical(other.setupComplete, setupComplete) || other.setupComplete == setupComplete)&&(identical(other.defaultModel, defaultModel) || other.defaultModel == defaultModel)&&const DeepCollectionEquality().equals(other.availableModels, _availableModels)&&(identical(other.storageUsedBytes, storageUsedBytes) || other.storageUsedBytes == storageUsedBytes)&&(identical(other.dumpCount, dumpCount) || other.dumpCount == dumpCount)&&(identical(other.diarization, diarization) || other.diarization == diarization));
}


@override
int get hashCode {
    return Object.hash(runtimeType,version,setupComplete,defaultModel,const DeepCollectionEquality().hash(_availableModels),storageUsedBytes,dumpCount,diarization);
}

@override
String toString() {
    return 'ServerInfo(version: $version, setupComplete: $setupComplete, defaultModel: $defaultModel, availableModels: $availableModels, storageUsedBytes: $storageUsedBytes, dumpCount: $dumpCount, diarization: $diarization)';
}


}

/// @nodoc
abstract mixin class _$ServerInfoCopyWith<$Res> implements $ServerInfoCopyWith<$Res> {
  factory _$ServerInfoCopyWith(_ServerInfo value, $Res Function(_ServerInfo) _then) = __$ServerInfoCopyWithImpl;
@override @useResult
$Res call({
 String version, bool setupComplete, String defaultModel, List<String> availableModels, int storageUsedBytes, int dumpCount, bool diarization
});




}
/// @nodoc
class __$ServerInfoCopyWithImpl<$Res>
    implements _$ServerInfoCopyWith<$Res> {
  __$ServerInfoCopyWithImpl(this._self, this._then);

  final _ServerInfo _self;
  final $Res Function(_ServerInfo) _then;

/// Create a copy of ServerInfo
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? version = null,Object? setupComplete = null,Object? defaultModel = null,Object? availableModels = null,Object? storageUsedBytes = null,Object? dumpCount = null,Object? diarization = null,}) {
  return _then(_ServerInfo(
version: null == version ? _self.version : version // ignore: cast_nullable_to_non_nullable
as String,setupComplete: null == setupComplete ? _self.setupComplete : setupComplete // ignore: cast_nullable_to_non_nullable
as bool,defaultModel: null == defaultModel ? _self.defaultModel : defaultModel // ignore: cast_nullable_to_non_nullable
as String,availableModels: null == availableModels ? _self._availableModels : availableModels // ignore: cast_nullable_to_non_nullable
as List<String>,storageUsedBytes: null == storageUsedBytes ? _self.storageUsedBytes : storageUsedBytes // ignore: cast_nullable_to_non_nullable
as int,dumpCount: null == dumpCount ? _self.dumpCount : dumpCount // ignore: cast_nullable_to_non_nullable
as int,diarization: null == diarization ? _self.diarization : diarization // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
