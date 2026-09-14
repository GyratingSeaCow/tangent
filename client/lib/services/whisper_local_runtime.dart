// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:whisper_cpp_flutter_plus/whisper_cpp_flutter_plus.dart';

import 'on_device_transcription.dart';

final class LocalModelSpec {
  const LocalModelSpec({
    required this.id,
    required this.fileName,
    required this.url,
    required this.byteSize,
    required this.sha256,
  });

  final String id;
  final String fileName;
  final Uri url;
  final int byteSize;
  final String sha256;
}

final largeV3ModelSpec = LocalModelSpec(
  id: 'large-v3',
  fileName: 'ggml-large-v3.bin',
  url: Uri.parse(
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
    '5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin',
  ),
  byteSize: 3095033483,
  sha256: '64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2',
);

abstract interface class WhisperPluginGateway {
  Future<bool> isModelInstalled(LocalModelSpec spec);

  Stream<(int receivedBytes, int totalBytes)> installModel(
    LocalModelSpec spec,
  );

  Future<String> transcribe(
    LocalModelSpec spec,
    File wav, {
    required void Function(int percent) onProgress,
  });

  void cancel();
}

final class WhisperLocalRuntime implements LocalWhisperRuntime {
  WhisperLocalRuntime({WhisperPluginGateway? gateway})
      : _gateway = gateway ?? DefaultWhisperPluginGateway();

  final WhisperPluginGateway _gateway;

  @override
  Future<bool> isModelInstalled() =>
      _gateway.isModelInstalled(largeV3ModelSpec);

  @override
  Future<void> installModel({required ModelProgressCallback onProgress}) async {
    await for (final progress in _gateway.installModel(largeV3ModelSpec)) {
      onProgress(progress.$1, progress.$2);
    }
    if (!await _gateway.isModelInstalled(largeV3ModelSpec)) {
      throw const LocalTranscriptionException(
        'The large-v3 model download did not produce a verified model',
      );
    }
  }

  @override
  Future<String> transcribe(
    File wav, {
    required InferenceProgressCallback onProgress,
  }) =>
      _gateway.transcribe(
        largeV3ModelSpec,
        wav,
        onProgress: onProgress,
      );

  @override
  void cancel() => _gateway.cancel();
}

final class DefaultWhisperPluginGateway implements WhisperPluginGateway {
  WhisperModelManager _manager = WhisperModelManager();
  WhisperTask? _activeTask;
  bool _verifiedThisSession = false;

  WhisperModelDescriptor _descriptor(LocalModelSpec spec) =>
      WhisperModelDescriptor(
        id: spec.id,
        fileName: spec.fileName,
        url: spec.url.toString(),
        sha256: spec.sha256,
        approximateBytes: spec.byteSize,
        languageScope: WhisperModelLanguageScope.multilingual,
        purpose: WhisperModelPurpose.transcription,
      );

  @override
  Future<bool> isModelInstalled(LocalModelSpec spec) async {
    if (_verifiedThisSession) {
      return await _manager.find(spec.fileName) != null;
    }
    final installed = await _manager.findCatalogModel(_descriptor(spec)) != null;
    _verifiedThisSession = installed;
    return installed;
  }

  @override
  Stream<(int, int)> installModel(LocalModelSpec spec) async* {
    _verifiedThisSession = false;
    await for (final progress
        in _manager.downloadCatalogModel(_descriptor(spec))) {
      yield (progress.received, progress.total);
    }
  }

  @override
  Future<String> transcribe(
    LocalModelSpec spec,
    File wav, {
    required void Function(int percent) onProgress,
  }) async {
    final model = await _manager.findCatalogModel(_descriptor(spec));
    if (model == null) {
      throw const LocalTranscriptionException(
        'Whisper large-v3 is not installed',
      );
    }
    final samples = await WhisperAudio.readWav(wav);
    final engine = await WhisperEngine.load(
      model.path,
      config: const WhisperConfig(
        useGpu: true,
        useFlashAttention: true,
      ),
    );
    StreamSubscription<int>? progressSubscription;
    try {
      final task = engine.transcribe(
        samples,
        options: const TranscribeOptions(
          strategy: WhisperSamplingStrategy.beamSearch,
          language: 'auto',
          detectLanguage: true,
          tokenTimestamps: false,
          noTimestamps: true,
          noContext: false,
          beamSize: 5,
        ),
      );
      _activeTask = task;
      progressSubscription = task.progress.listen(onProgress);
      final result = await task.result;
      return result.text;
    } finally {
      _activeTask = null;
      await progressSubscription?.cancel();
      engine.dispose();
    }
  }

  @override
  void cancel() {
    _activeTask?.cancel();
    if (_activeTask == null) {
      _manager.close();
      _manager = WhisperModelManager();
      _verifiedThisSession = false;
    }
  }
}
