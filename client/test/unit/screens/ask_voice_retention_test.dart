// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/screens/ask/ask_screen.dart';

void main() {
  Future<({bool rowExists, bool audioExists, List<String> asked})> run(
    double duration,
  ) async {
    final Directory dir = await Directory.systemTemp.createTemp('ask-voice-');
    addTearDown(() => dir.delete(recursive: true));
    final File audio = File('${dir.path}/voice.m4a');
    await audio.writeAsBytes(<int>[7, 4, 2]);
    bool rowExists = true;
    final asked = <String>[];
    await finishAskVoiceRecording(
      durationSeconds: duration,
      transcribe: () async => '  Where is the Zephyr adapter?  ',
      discard: () async {
        rowExists = false;
        if (await audio.exists()) await audio.delete();
      },
      submit: (question) async => asked.add(question),
    );
    return (
      rowExists: rowExists,
      audioExists: await audio.exists(),
      asked: asked,
    );
  }

  test('12.7 second voice ask submits then leaves no row or audio', () async {
    final result = await run(12.7);
    expect(result.asked, <String>['Where is the Zephyr adapter?']);
    expect(result.rowExists, isFalse);
    expect(result.audioExists, isFalse);
  });

  test('31.4 second voice ask submits and keeps recording', () async {
    final result = await run(31.4);
    expect(result.asked, <String>['Where is the Zephyr adapter?']);
    expect(result.rowExists, isTrue);
    expect(result.audioExists, isTrue);
  });

  test('exactly 25.0 seconds is on the persist side', () async {
    final result = await run(25.0);
    expect(result.asked, <String>['Where is the Zephyr adapter?']);
    expect(result.rowExists, isTrue);
    expect(result.audioExists, isTrue);
  });
}
