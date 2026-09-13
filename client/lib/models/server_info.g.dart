// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$ServerInfoImpl _$$ServerInfoImplFromJson(Map<String, dynamic> json) =>
    _$ServerInfoImpl(
      version: json['version'] as String,
      setupComplete: json['setupComplete'] as bool,
      defaultModel: json['defaultModel'] as String,
      availableModels: (json['availableModels'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      storageUsedBytes: (json['storageUsedBytes'] as num).toInt(),
      dumpCount: (json['dumpCount'] as num).toInt(),
    );

Map<String, dynamic> _$$ServerInfoImplToJson(_$ServerInfoImpl instance) =>
    <String, dynamic>{
      'version': instance.version,
      'setupComplete': instance.setupComplete,
      'defaultModel': instance.defaultModel,
      'availableModels': instance.availableModels,
      'storageUsedBytes': instance.storageUsedBytes,
      'dumpCount': instance.dumpCount,
    };
