// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

typedef ModelProgressCallback = void Function(int receivedBytes, int totalBytes);
typedef InferenceProgressCallback = void Function(int percent);
typedef LocalTranscriptionProgressCallback = void Function(
  LocalTranscriptionProgress progress,
);

enum LocalTranscriptionStage {
  preparingAudio,
  downloadingModel,
  loadingModel,
  transcribing,
  complete,
}

final class LocalTranscriptionProgress {
  const LocalTranscriptionProgress({
    required this.stage,
    this.fraction,
    this.receivedBytes,
    this.totalBytes,
  });

  final LocalTranscriptionStage stage;
  final double? fraction;
  final int? receivedBytes;
  final int? totalBytes;
}

abstract interface class LocalAudioDecoder {
  Future<File> decodeToWav(Uint8List source, Directory temporaryDirectory);
}

abstract interface class LocalWhisperRuntime {
  Future<bool> isModelInstalled();

  Future<void> installModel({required ModelProgressCallback onProgress});

  Future<String> transcribe(
    File wav, {
    required InferenceProgressCallback onProgress,
  });

  void cancel();
}

final class LocalTranscriptionException implements Exception {
  const LocalTranscriptionException(this.message);

  final String message;

  @override
  String toString() => 'LocalTranscriptionException: $message';
}

final class OnDeviceTranscriptionService {
  OnDeviceTranscriptionService({
    required LocalAudioDecoder decoder,
    required LocalWhisperRuntime runtime,
    required Future<Directory> Function() temporaryDirectory,
  })  : _decoder = decoder,
        _runtime = runtime,
        _temporaryDirectory = temporaryDirectory;

  final LocalAudioDecoder _decoder;
  final LocalWhisperRuntime _runtime;
  final Future<Directory> Function() _temporaryDirectory;
  bool _cancelled = false;
  bool _active = false;

  bool get isActive => _active;

  Future<String> transcribe(
    Uint8List audio, {
    required LocalTranscriptionProgressCallback onProgress,
  }) async {
    if (_active) {
      throw const LocalTranscriptionException(
        'Another on-device transcription is already running',
      );
    }
    if (audio.isEmpty) {
      throw const LocalTranscriptionException('Recording audio is empty');
    }

    _active = true;
    _cancelled = false;
    File? wav;
    try {
      onProgress(const LocalTranscriptionProgress(
        stage: LocalTranscriptionStage.preparingAudio,
        fraction: 0,
      ));
      final directory = await _temporaryDirectory();
      await directory.create(recursive: true);
      wav = await _decoder.decodeToWav(audio, directory);
      _throwIfCancelled();

      if (!await _runtime.isModelInstalled()) {
        onProgress(const LocalTranscriptionProgress(
          stage: LocalTranscriptionStage.downloadingModel,
          fraction: 0,
        ));
        await _runtime.installModel(onProgress: (received, total) {
          onProgress(LocalTranscriptionProgress(
            stage: LocalTranscriptionStage.downloadingModel,
            fraction: total > 0 ? received / total : null,
            receivedBytes: received,
            totalBytes: total,
          ));
        });
      }
      _throwIfCancelled();

      onProgress(const LocalTranscriptionProgress(
        stage: LocalTranscriptionStage.loadingModel,
      ));
      onProgress(const LocalTranscriptionProgress(
        stage: LocalTranscriptionStage.transcribing,
        fraction: 0,
      ));
      final transcript = (await _runtime.transcribe(
        wav,
        onProgress: (percent) {
          onProgress(LocalTranscriptionProgress(
            stage: LocalTranscriptionStage.transcribing,
            fraction: percent.clamp(0, 100) / 100,
          ));
        },
      ))
          .trim();
      _throwIfCancelled();
      if (transcript.isEmpty) {
        throw const LocalTranscriptionException(
          'The on-device model returned an empty transcript',
        );
      }
      onProgress(const LocalTranscriptionProgress(
        stage: LocalTranscriptionStage.complete,
        fraction: 1,
      ));
      return transcript;
    } finally {
      _active = false;
      if (wav != null && await wav.exists()) {
        await wav.delete();
      }
    }
  }

  void cancel() {
    if (!_active) return;
    _cancelled = true;
    _runtime.cancel();
  }

  void _throwIfCancelled() {
    if (_cancelled) {
      throw const LocalTranscriptionException('Transcription was cancelled');
    }
  }
}
