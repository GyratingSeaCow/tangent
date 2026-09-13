// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'server_info.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$ServerInfo {
  String get version => throw _privateConstructorUsedError;
  bool get setupComplete => throw _privateConstructorUsedError;
  String get defaultModel => throw _privateConstructorUsedError;
  List<String> get availableModels => throw _privateConstructorUsedError;
  int get storageUsedBytes => throw _privateConstructorUsedError;
  int get dumpCount => throw _privateConstructorUsedError;

  /// Create a copy of ServerInfo
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $ServerInfoCopyWith<ServerInfo> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ServerInfoCopyWith<$Res> {
  factory $ServerInfoCopyWith(
          ServerInfo value, $Res Function(ServerInfo) then) =
      _$ServerInfoCopyWithImpl<$Res, ServerInfo>;
  @useResult
  $Res call(
      {String version,
      bool setupComplete,
      String defaultModel,
      List<String> availableModels,
      int storageUsedBytes,
      int dumpCount});
}

/// @nodoc
class _$ServerInfoCopyWithImpl<$Res, $Val extends ServerInfo>
    implements $ServerInfoCopyWith<$Res> {
  _$ServerInfoCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of ServerInfo
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? version = null,
    Object? setupComplete = null,
    Object? defaultModel = null,
    Object? availableModels = null,
    Object? storageUsedBytes = null,
    Object? dumpCount = null,
  }) {
    return _then(_value.copyWith(
      version: null == version
          ? _value.version
          : version // ignore: cast_nullable_to_non_nullable
              as String,
      setupComplete: null == setupComplete
          ? _value.setupComplete
          : setupComplete // ignore: cast_nullable_to_non_nullable
              as bool,
      defaultModel: null == defaultModel
          ? _value.defaultModel
          : defaultModel // ignore: cast_nullable_to_non_nullable
              as String,
      availableModels: null == availableModels
          ? _value.availableModels
          : availableModels // ignore: cast_nullable_to_non_nullable
              as List<String>,
      storageUsedBytes: null == storageUsedBytes
          ? _value.storageUsedBytes
          : storageUsedBytes // ignore: cast_nullable_to_non_nullable
              as int,
      dumpCount: null == dumpCount
          ? _value.dumpCount
          : dumpCount // ignore: cast_nullable_to_non_nullable
              as int,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$ServerInfoImplCopyWith<$Res>
    implements $ServerInfoCopyWith<$Res> {
  factory _$$ServerInfoImplCopyWith(
          _$ServerInfoImpl value, $Res Function(_$ServerInfoImpl) then) =
      __$$ServerInfoImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String version,
      bool setupComplete,
      String defaultModel,
      List<String> availableModels,
      int storageUsedBytes,
      int dumpCount});
}

/// @nodoc
class __$$ServerInfoImplCopyWithImpl<$Res>
    extends _$ServerInfoCopyWithImpl<$Res, _$ServerInfoImpl>
    implements _$$ServerInfoImplCopyWith<$Res> {
  __$$ServerInfoImplCopyWithImpl(
      _$ServerInfoImpl _value, $Res Function(_$ServerInfoImpl) _then)
      : super(_value, _then);

  /// Create a copy of ServerInfo
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? version = null,
    Object? setupComplete = null,
    Object? defaultModel = null,
    Object? availableModels = null,
    Object? storageUsedBytes = null,
    Object? dumpCount = null,
  }) {
    return _then(_$ServerInfoImpl(
      version: null == version
          ? _value.version
          : version // ignore: cast_nullable_to_non_nullable
              as String,
      setupComplete: null == setupComplete
          ? _value.setupComplete
          : setupComplete // ignore: cast_nullable_to_non_nullable
              as bool,
      defaultModel: null == defaultModel
          ? _value.defaultModel
          : defaultModel // ignore: cast_nullable_to_non_nullable
              as String,
      availableModels: null == availableModels
          ? _value._availableModels
          : availableModels // ignore: cast_nullable_to_non_nullable
              as List<String>,
      storageUsedBytes: null == storageUsedBytes
          ? _value.storageUsedBytes
          : storageUsedBytes // ignore: cast_nullable_to_non_nullable
              as int,
      dumpCount: null == dumpCount
          ? _value.dumpCount
          : dumpCount // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class _$ServerInfoImpl extends _ServerInfo {
  const _$ServerInfoImpl(
      {required this.version,
      required this.setupComplete,
      required this.defaultModel,
      required final List<String> availableModels,
      required this.storageUsedBytes,
      required this.dumpCount})
      : _availableModels = availableModels,
        super._();

  @override
  final String version;
  @override
  final bool setupComplete;
  @override
  final String defaultModel;
  final List<String> _availableModels;
  @override
  List<String> get availableModels {
    if (_availableModels is EqualUnmodifiableListView) return _availableModels;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_availableModels);
  }

  @override
  final int storageUsedBytes;
  @override
  final int dumpCount;

  @override
  String toString() {
    return 'ServerInfo(version: $version, setupComplete: $setupComplete, defaultModel: $defaultModel, availableModels: $availableModels, storageUsedBytes: $storageUsedBytes, dumpCount: $dumpCount)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ServerInfoImpl &&
            (identical(other.version, version) || other.version == version) &&
            (identical(other.setupComplete, setupComplete) ||
                other.setupComplete == setupComplete) &&
            (identical(other.defaultModel, defaultModel) ||
                other.defaultModel == defaultModel) &&
            const DeepCollectionEquality()
                .equals(other._availableModels, _availableModels) &&
            (identical(other.storageUsedBytes, storageUsedBytes) ||
                other.storageUsedBytes == storageUsedBytes) &&
            (identical(other.dumpCount, dumpCount) ||
                other.dumpCount == dumpCount));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType,
      version,
      setupComplete,
      defaultModel,
      const DeepCollectionEquality().hash(_availableModels),
      storageUsedBytes,
      dumpCount);

  /// Create a copy of ServerInfo
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ServerInfoImplCopyWith<_$ServerInfoImpl> get copyWith =>
      __$$ServerInfoImplCopyWithImpl<_$ServerInfoImpl>(this, _$identity);
}

abstract class _ServerInfo extends ServerInfo {
  const factory _ServerInfo(
      {required final String version,
      required final bool setupComplete,
      required final String defaultModel,
      required final List<String> availableModels,
      required final int storageUsedBytes,
      required final int dumpCount}) = _$ServerInfoImpl;
  const _ServerInfo._() : super._();

  @override
  String get version;
  @override
  bool get setupComplete;
  @override
  String get defaultModel;
  @override
  List<String> get availableModels;
  @override
  int get storageUsedBytes;
  @override
  int get dumpCount;

  /// Create a copy of ServerInfo
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ServerInfoImplCopyWith<_$ServerInfoImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
