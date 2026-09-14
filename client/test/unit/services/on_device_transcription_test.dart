// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/on_device_transcription.dart';

void main() {
  test('transcribes through local decoder and runtime then deletes temporary WAV',
      () async {
    final temp = await Directory.systemTemp.createTemp('tangent-local-stt-test-');
    addTearDown(() => temp.delete(recursive: true));
    final decoder = _FakeDecoder();
    final runtime = _FakeRuntime(installed: false, transcript: '  local words  ');
    final progress = <LocalTranscriptionProgress>[];
    final service = OnDeviceTranscriptionService(
      decoder: decoder,
      runtime: runtime,
      temporaryDirectory: () async => temp,
    );

    final result = await service.transcribe(
      Uint8List.fromList([1, 2, 3]),
      onProgress: progress.add,
    );

    expect(result, 'local words');
    expect(decoder.received, [1, 2, 3]);
    expect(runtime.installs, 1);
    expect(runtime.transcriptions, 1);
    expect(await runtime.receivedWav!.exists(), isFalse);
    expect(
      progress.map((event) => event.stage),
      containsAllInOrder([
        LocalTranscriptionStage.preparingAudio,
        LocalTranscriptionStage.downloadingModel,
        LocalTranscriptionStage.loadingModel,
        LocalTranscriptionStage.transcribing,
        LocalTranscriptionStage.complete,
      ]),
    );
  });
}

final class _FakeDecoder implements LocalAudioDecoder {
  List<int>? received;

  @override
  Future<File> decodeToWav(Uint8List source, Directory temporaryDirectory) async {
    received = source.toList();
    final wav = File('${temporaryDirectory.path}/prepared.wav');
    await wav.writeAsBytes(List<int>.filled(44, 0));
    return wav;
  }
}

final class _FakeRuntime implements LocalWhisperRuntime {
  _FakeRuntime({required this.installed, required this.transcript});

  bool installed;
  final String transcript;
  int installs = 0;
  int transcriptions = 0;
  File? receivedWav;

  @override
  Future<bool> isModelInstalled() async => installed;

  @override
  Future<void> installModel({required ModelProgressCallback onProgress}) async {
    installs++;
    onProgress(50, 100);
    installed = true;
  }

  @override
  Future<String> transcribe(
    File wav, {
    required ModelLoadedCallback onModelLoaded,
    required InferenceProgressCallback onProgress,
  }) async {
    transcriptions++;
    receivedWav = wav;
    onModelLoaded();
    onProgress(25);
    return transcript;
  }

  @override
  void cancel() {}
}
