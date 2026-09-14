// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/services.dart';

import 'on_device_transcription.dart';

final class AndroidAudioDecoder implements LocalAudioDecoder {
  const AndroidAudioDecoder();

  static const _channel = MethodChannel('dev.tangent.tangent/audio');

  @override
  Future<File> decodeToWav(
    Uint8List source,
    Directory temporaryDirectory,
  ) async {
    if (source.isEmpty) {
      throw const LocalTranscriptionException('Recording audio is empty');
    }
    await temporaryDirectory.create(recursive: true);
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final input = File('${temporaryDirectory.path}/local-stt-$nonce.opus');
    final output = File('${temporaryDirectory.path}/local-stt-$nonce.wav');
    await input.writeAsBytes(source, flush: true);
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'decodeOpusToWav',
        {'inputPath': input.path, 'outputPath': output.path},
      );
      final pcmBytes = (result?['pcmBytes'] as num?)?.toInt() ?? 0;
      if (pcmBytes <= 0 ||
          !await output.exists() ||
          await output.length() <= 44) {
        throw const LocalTranscriptionException(
          'Android produced an empty WAV while preparing the recording',
        );
      }
      return output;
    } catch (_) {
      if (await output.exists()) await output.delete();
      rethrow;
    } finally {
      if (await input.exists()) await input.delete();
    }
  }
}
