// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:freezed_annotation/freezed_annotation.dart';

part 'server_info.freezed.dart';

@freezed
class ServerInfo with _$ServerInfo {
  const ServerInfo._();

  const factory ServerInfo({
    required String version,
    required bool setupComplete,
    required String defaultModel,
    required List<String> availableModels,
    required int storageUsedBytes,
    required int dumpCount,

    /// v1.36.0: whether the server diarizes (and so keeps a voice book).
    /// Older servers omit it → false, and Settings hides the Voices section.
    @Default(false) bool diarization,
  }) = _ServerInfo;

  factory ServerInfo.fromJson(Map<String, dynamic> json) {
    return _ServerInfo(
      version: json['version'] as String,
      setupComplete: json['setup_complete'] as bool,
      defaultModel: json['default_model'] as String,
      availableModels: (json['available_models'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      storageUsedBytes: (json['storage_used_bytes'] as num).toInt(),
      dumpCount: (json['dump_count'] as num).toInt(),
      diarization: (json['diarization'] as bool?) ?? false,
    );
  }
}
