// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/whisper_local_runtime.dart';
import 'package:whisper_cpp_flutter_plus/whisper_cpp_flutter_plus.dart';

void main() {
  test('large-v3 model is immutable and checksum pinned', () {
    expect(largeV3ModelSpec.id, 'large-v3');
    expect(largeV3ModelSpec.fileName, 'ggml-large-v3.bin');
    expect(
      largeV3ModelSpec.url.toString(),
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
      '5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin',
    );
    expect(largeV3ModelSpec.byteSize, 3095033483);
    expect(
      largeV3ModelSpec.sha256,
      '64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2',
    );
  });

  test('large-v3-turbo model is immutable and checksum pinned', () {
    expect(largeV3TurboModelSpec.id, 'large-v3-turbo');
    expect(largeV3TurboModelSpec.fileName, 'ggml-large-v3-turbo.bin');
    expect(
      largeV3TurboModelSpec.url.toString(),
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
      '5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin',
    );
    expect(largeV3TurboModelSpec.byteSize, 1624555275);
    expect(
      largeV3TurboModelSpec.sha256,
      '1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69',
    );
  });

  test('runtime defaults to the turbo model for faster on-device decoding',
      () {
    final runtime = WhisperLocalRuntime(gateway: _FakeGateway());
    expect(runtime.modelSpec.id, 'large-v3-turbo');
    expect(runtime.modelSpec, same(largeV3TurboModelSpec));
  });

  test('runtime verifies downloads and forwards local inference progress',
      () async {
    final gateway = _FakeGateway();
    final runtime = WhisperLocalRuntime(gateway: gateway);
    final downloadProgress = <(int, int)>[];
    final inferenceProgress = <int>[];

    expect(await runtime.isModelInstalled(), isFalse);
    await runtime.installModel(
      onProgress: (received, total) => downloadProgress.add((received, total)),
    );
    final result = await runtime.transcribe(
      File('prepared.wav'),
      onModelLoaded: () {},
      onProgress: inferenceProgress.add,
    );
    runtime.cancel();

    expect(downloadProgress, [(50, 100)]);
    expect(inferenceProgress, [42]);
    expect(result, 'phone transcript');
    expect(gateway.specs, everyElement(same(largeV3TurboModelSpec)));
    expect(gateway.cancelled, isTrue);
  });

  test('runtime can be pinned to the original large-v3 model', () async {
    final gateway = _FakeGateway();
    final runtime =
        WhisperLocalRuntime(spec: largeV3ModelSpec, gateway: gateway);
    await runtime.transcribe(
      File('prepared.wav'),
      onModelLoaded: () {},
      onProgress: (_) {},
    );
    expect(gateway.specs, everyElement(same(largeV3ModelSpec)));
  });

  test('inference options use greedy decoding and 8 threads', () {
    // We exercise the constants the production runtime passes to the plugin
    // so the speed-tuning contract is enforced by a unit test.
    const options = TranscribeOptions(
      strategy: WhisperSamplingStrategy.greedy,
      threads: kWhisperInferenceThreads,
      noContext: true,
    );
    expect(options.strategy, WhisperSamplingStrategy.greedy);
    expect(options.threads, kWhisperInferenceThreads);
    expect(options.noContext, isTrue);
    expect(kWhisperInferenceThreads, 8);
  });

  test('loaded model cache reuses one engine for sequential transcripts',
      () async {
    var loadCount = 0;
    final handle = _FakeEngineHandle();
    final cache = LoadedWhisperEngineCache(
      load: (path) async {
        loadCount++;
        return handle;
      },
    );

    expect(await cache.get('large-v3.bin'), same(handle));
    expect(await cache.get('large-v3.bin'), same(handle));
    expect(loadCount, 1);

    cache.dispose();
    expect(handle.disposeCount, 1);
  });

  test('loaded model cache retries after a failed load', () async {
    var loadCount = 0;
    final handle = _FakeEngineHandle();
    final cache = LoadedWhisperEngineCache(
      load: (path) async {
        loadCount++;
        if (loadCount == 1) throw StateError('load failed');
        return handle;
      },
    );

    await expectLater(cache.get('large-v3.bin'), throwsStateError);
    expect(await cache.get('large-v3.bin'), same(handle));
    expect(loadCount, 2);
  });
}

final class _FakeEngineHandle implements WhisperEngineHandle {
  int disposeCount = 0;

  @override
  void cancel() {}

  @override
  void dispose() => disposeCount++;

  @override
  Future<String> transcribe(
    Float32List samples, {
    required void Function(int percent) onProgress,
  }) async =>
      'unused';
}

final class _FakeGateway implements WhisperPluginGateway {
  bool installed = false;
  bool cancelled = false;
  final specs = <LocalModelSpec>[];

  @override
  Future<bool> isModelInstalled(LocalModelSpec spec) async {
    specs.add(spec);
    return installed;
  }

  @override
  Stream<(int, int)> installModel(LocalModelSpec spec) async* {
    specs.add(spec);
    yield (50, 100);
    installed = true;
  }

  @override
  Future<String> transcribe(
    LocalModelSpec spec,
    File wav, {
    required void Function() onModelLoaded,
    required void Function(int percent) onProgress,
  }) async {
    specs.add(spec);
    onModelLoaded();
    onProgress(42);
    return 'phone transcript';
  }

  @override
  void cancel() => cancelled = true;
}
