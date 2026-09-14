// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/whisper_local_runtime.dart';

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
    expect(gateway.specs, everyElement(same(largeV3ModelSpec)));
    expect(gateway.cancelled, isTrue);
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
