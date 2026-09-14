// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:whisper_cpp_flutter_plus/whisper_cpp_flutter_plus.dart';

import 'on_device_transcription.dart';

final class LocalModelSpec {
  const LocalModelSpec({
    required this.id,
    required this.fileName,
    required this.url,
    required this.byteSize,
    required this.sha256,
    required this.approximateBytesLabel,
  });

  final String id;
  final String fileName;
  final Uri url;
  final int byteSize;
  final String sha256;
  final String approximateBytesLabel;
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
  approximateBytesLabel: '3.1 GB',
);

final largeV3TurboModelSpec = LocalModelSpec(
  id: 'large-v3-turbo',
  fileName: 'ggml-large-v3-turbo.bin',
  url: Uri.parse(
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
    '5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin',
  ),
  byteSize: 1624555275,
  sha256: '1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69',
  approximateBytesLabel: '1.5 GB',
);

abstract interface class WhisperPluginGateway {
  Future<bool> isModelInstalled(LocalModelSpec spec);

  Stream<(int receivedBytes, int totalBytes)> installModel(
    LocalModelSpec spec,
  );

  Future<String> transcribe(
    LocalModelSpec spec,
    File wav, {
    required ModelLoadedCallback onModelLoaded,
    required void Function(int percent) onProgress,
  });

  void cancel();
}

abstract interface class WhisperEngineHandle {
  Future<String> transcribe(
    Float32List samples, {
    required void Function(int percent) onProgress,
  });

  void cancel();

  void dispose();
}

typedef WhisperEngineHandleLoader = Future<WhisperEngineHandle> Function(
  String modelPath,
);

final class LoadedWhisperEngineCache {
  LoadedWhisperEngineCache({
    required WhisperEngineHandleLoader load,
    this.idleDuration = const Duration(minutes: 15),
  }) : _load = load;

  final WhisperEngineHandleLoader _load;
  final Duration idleDuration;
  String? _modelPath;
  Future<WhisperEngineHandle>? _loading;
  WhisperEngineHandle? _engine;
  Timer? _idleTimer;

  Future<WhisperEngineHandle> get(String modelPath) async {
    _idleTimer?.cancel();
    if (_modelPath == modelPath && _engine != null) return _engine!;
    if (_modelPath == modelPath && _loading != null) return _loading!;

    dispose();
    _modelPath = modelPath;
    final loading = _load(modelPath);
    _loading = loading;
    try {
      final engine = await loading;
      if (identical(_loading, loading)) {
        _engine = engine;
        _loading = null;
      }
      return engine;
    } catch (_) {
      if (identical(_loading, loading)) {
        _loading = null;
        _modelPath = null;
      }
      rethrow;
    }
  }

  void release() {
    _idleTimer?.cancel();
    if (_engine == null) return;
    _idleTimer = Timer(idleDuration, dispose);
  }

  void cancel() => _engine?.cancel();

  void dispose() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _engine?.dispose();
    _engine = null;
    _loading = null;
    _modelPath = null;
  }
}

/// Number of CPU threads dedicated to Whisper inference.
/// Eight matches the big-core count of common flagship phones and is the
/// sweet spot for `large-v3-turbo` decoding.
const int kWhisperInferenceThreads = 8;

final class _PluginWhisperEngineHandle implements WhisperEngineHandle {
  _PluginWhisperEngineHandle(this._engine);

  final WhisperEngine _engine;
  WhisperTask? _activeTask;

  @override
  Future<String> transcribe(
    Float32List samples, {
    required void Function(int percent) onProgress,
  }) async {
    final task = _engine.transcribe(
      samples,
      options: const TranscribeOptions(
        strategy: WhisperSamplingStrategy.greedy,
        // Eight threads matches the big-core count on flagship phones and is
        // the sweet spot for large-v3-turbo decoding. The plugin's
        // WhisperConfig does not expose thread count; TranscribeOptions does.
        threads: kWhisperInferenceThreads,
        language: 'auto',
        // language='auto' selects language before full transcription.
        // whisper.cpp's detect_language flag is detect-only and would skip text.
        detectLanguage: false,
        tokenTimestamps: false,
        noTimestamps: true,
        // Skip context from previous windows: each Dump is its own note and
        // re-encoding context adds noticeable latency on short clips.
        noContext: true,
      ),
    );
    _activeTask = task;
    final progressSubscription = task.progress.listen(onProgress);
    try {
      return (await task.result).text;
    } finally {
      _activeTask = null;
      await progressSubscription.cancel();
    }
  }

  @override
  void cancel() => _activeTask?.cancel();

  @override
  void dispose() => _engine.dispose();
}

final class WhisperLocalRuntime implements LocalWhisperRuntime {
  WhisperLocalRuntime({
    LocalModelSpec? spec,
    WhisperPluginGateway? gateway,
  })  : _spec = spec ?? largeV3TurboModelSpec,
        _gateway = gateway ?? DefaultWhisperPluginGateway();

  final LocalModelSpec _spec;
  final WhisperPluginGateway _gateway;

  LocalModelSpec get modelSpec => _spec;

  @override
  Future<bool> isModelInstalled() => _gateway.isModelInstalled(_spec);

  @override
  Future<void> installModel({required ModelProgressCallback onProgress}) async {
    await for (final progress in _gateway.installModel(_spec)) {
      onProgress(progress.$1, progress.$2);
    }
    if (!await _gateway.isModelInstalled(_spec)) {
      throw const LocalTranscriptionException(
        'The selected Whisper model download did not produce a verified model',
      );
    }
  }

  @override
  Future<String> transcribe(
    File wav, {
    required ModelLoadedCallback onModelLoaded,
    required InferenceProgressCallback onProgress,
  }) =>
      _gateway.transcribe(
        _spec,
        wav,
        onModelLoaded: onModelLoaded,
        onProgress: onProgress,
      );

  @override
  void cancel() => _gateway.cancel();
}

final class DefaultWhisperPluginGateway implements WhisperPluginGateway {
  DefaultWhisperPluginGateway({LoadedWhisperEngineCache? engineCache})
      : _engineCache = engineCache ??
            LoadedWhisperEngineCache(
              load: (path) async => _PluginWhisperEngineHandle(
                await WhisperEngine.load(
                  path,
                  config: const WhisperConfig(
                    useGpu: true,
                    useFlashAttention: true,
                  ),
                ),
              ),
            );

  final WhisperModelManager _manager = WhisperModelManager();
  final LoadedWhisperEngineCache _engineCache;
  bool _verifiedThisSession = false;
  bool _cancelRequested = false;

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
    final installed =
        await _manager.findCatalogModel(_descriptor(spec)) != null;
    _verifiedThisSession = installed;
    return installed;
  }

  @override
  Stream<(int, int)> installModel(LocalModelSpec spec) async* {
    _verifiedThisSession = false;
    _cancelRequested = false;
    await for (final progress
        in _manager.downloadCatalogModel(_descriptor(spec))) {
      if (_cancelRequested) {
        throw const LocalTranscriptionException('Transcription was cancelled');
      }
      yield (progress.received, progress.total);
    }
  }

  @override
  Future<String> transcribe(
    LocalModelSpec spec,
    File wav, {
    required ModelLoadedCallback onModelLoaded,
    required void Function(int percent) onProgress,
  }) async {
    _cancelRequested = false;
    final model = await _manager.findCatalogModel(_descriptor(spec));
    if (model == null) {
      throw LocalTranscriptionException(
        'Whisper ${spec.id} is not installed',
      );
    }
    final samples = await WhisperAudio.readWav(wav);
    if (_cancelRequested) {
      throw const LocalTranscriptionException('Transcription was cancelled');
    }
    final engine = await _engineCache.get(model.path);
    if (_cancelRequested) {
      _engineCache.release();
      throw const LocalTranscriptionException('Transcription was cancelled');
    }
    onModelLoaded();
    try {
      return await engine.transcribe(
        samples,
        onProgress: onProgress,
      );
    } finally {
      _engineCache.release();
    }
  }

  @override
  void cancel() {
    _cancelRequested = true;
    _engineCache.cancel();
  }
}
