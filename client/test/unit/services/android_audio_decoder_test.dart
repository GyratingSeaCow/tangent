// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/android_audio_decoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.tangent.tangent/audio');

  test('writes Opus input and invokes exact Android WAV decoder contract',
      () async {
    final temp = await Directory.systemTemp.createTemp('tangent-decoder-test-');
    addTearDown(() => temp.delete(recursive: true));
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      final input = File(args['inputPath']! as String);
      final output = File(args['outputPath']! as String);
      expect(await input.readAsBytes(), [1, 2, 3, 4]);
      await output.writeAsBytes(_minimalWav());
      return <String, Object>{
        'sampleRate': 16000,
        'channels': 1,
        'pcmBytes': 2,
      };
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final wav = await const AndroidAudioDecoder().decodeToWav(
      Uint8List.fromList([1, 2, 3, 4]),
      temp,
    );

    expect(received!.method, 'decodeOpusToWav');
    expect(received!.arguments, containsPair('inputPath', isA<String>()));
    expect(received!.arguments, containsPair('outputPath', wav.path));
    expect(await wav.length(), 46);
    expect(
      temp
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.opus')),
      isEmpty,
    );
  });
}

Uint8List _minimalWav() {
  final bytes = Uint8List(46);
  bytes.setAll(0, 'RIFF'.codeUnits);
  bytes.setAll(8, 'WAVEfmt '.codeUnits);
  bytes.setAll(36, 'data'.codeUnits);
  bytes[40] = 2;
  return bytes;
}
