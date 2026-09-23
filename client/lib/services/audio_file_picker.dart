// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/services.dart';

/// A file the user chose to import.
class PickedAudio {
  const PickedAudio({required this.path, required this.name});

  /// Absolute path to a private copy of the chosen file.
  final String path;

  /// The file's display name, used as the recording's title.
  final String name;
}

/// Opens the system picker for a single audio file.
///
/// The native side copies the chosen document into app-private cache and
/// returns that path: the import then works from a file that is entirely
/// ours, so a transient content:// grant cannot expire mid-import.
class AudioFilePicker {
  AudioFilePicker({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('dev.tangent.tangent/audio');

  final MethodChannel _channel;

  /// Returns the picked file, or null if the user cancelled.
  Future<PickedAudio?> pick() async {
    final Map<Object?, Object?>? picked =
        await _channel.invokeMapMethod<Object?, Object?>('pickAudioFile');
    if (picked == null) return null;
    final String? path = picked['path'] as String?;
    if (path == null || path.isEmpty) return null;
    return PickedAudio(
      path: path,
      name: (picked['name'] as String?) ?? 'Imported audio',
    );
  }

  /// Returns every picked file (multi-select), or an empty list when the
  /// user cancels. Same cache-copy contract as [pick], per file.
  Future<List<PickedAudio>> pickMultiple() async {
    final List<Object?>? picked =
        await _channel.invokeListMethod<Object?>('pickAudioFiles');
    if (picked == null) return const <PickedAudio>[];
    final files = <PickedAudio>[];
    for (final Object? entry in picked) {
      if (entry is! Map<Object?, Object?>) continue;
      final String? path = entry['path'] as String?;
      if (path == null || path.isEmpty) continue;
      files.add(
        PickedAudio(
          path: path,
          name: (entry['name'] as String?) ?? 'Imported audio',
        ),
      );
    }
    return files;
  }
}
