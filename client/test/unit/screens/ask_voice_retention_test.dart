// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/screens/ask/ask_screen.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/services/transcription_client.dart';

class _Dio extends Mock implements Dio {}

void main() {
  setUpAll(() => registerFallbackValue(Options()));
  Future<({bool rowExists, bool audioExists, List<String> asked})> run(
    int duration,
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

  test('24 second voice ask submits then leaves no row or audio', () async {
    final result = await run(24);
    expect(result.asked, <String>['Where is the Zephyr adapter?']);
    expect(result.rowExists, isFalse);
    expect(result.audioExists, isFalse);
  });

  test('26 second voice ask submits and keeps recording', () async {
    final result = await run(26);
    expect(result.asked, <String>['Where is the Zephyr adapter?']);
    expect(result.rowExists, isTrue);
    expect(result.audioExists, isTrue);
  });

  test('exactly 25 seconds is on the persist side', () async {
    final result = await run(25);
    expect(result.asked, <String>['Where is the Zephyr adapter?']);
    expect(result.rowExists, isTrue);
    expect(result.audioExists, isTrue);
  });

  test('cleanup failure never eats the submitted question', () async {
    final asked = <String>[];
    Object? cleanupError;
    await finishAskVoiceRecording(
      durationSeconds: 24,
      transcribe: () async => 'Keep my question',
      submit: (text) async => asked.add(text),
      discard: () async => throw StateError('SAF delete failed'),
      onCleanupError: (error) async => cleanupError = error,
    );
    expect(asked, <String>['Keep my question']);
    expect(cleanupError, isA<StateError>());
  });

  test('skipped local deletion is surfaced as cleanup failure', () {
    const component = (state: ComponentState.pending, problem: null);
    expect(
      () => ensureAskVoiceDeletionComplete(
        (
          replayed: false,
          items: <DeletionItemResult>[
            (
              id: 'voice-busy',
              state: DeleteState.skipped,
              audio: component,
              metadata: component,
              ticketId: null,
              problem: null,
            ),
          ],
        ),
      ),
      throwsA(isA<StorageFault>()),
    );
  });

  test('short cleanup issues authoritative server DELETE', () async {
    final dio = _Dio();
    when(
      () => dio.delete<dynamic>(
        '/v1/dumps/voice-short',
        data: any(named: 'data'),
      ),
    ).thenAnswer(
      (_) async => Response<dynamic>(
        requestOptions: RequestOptions(path: '/v1/dumps/voice-short'),
        statusCode: 204,
      ),
    );
    final client = TranscriptionClient.forTesting(
      dio: dio,
      baseUrl: 'http://named-server',
    );
    final order = <String>[];
    await finishAskVoiceRecording(
      durationSeconds: 24,
      transcribe: () async => 'Question from mic',
      submit: (text) async => order.add('ask:$text'),
      discard: () async {
        await client.deleteDump('voice-short');
        order.add('local-delete:content://recordings/voice-short');
      },
    );
    expect(order, <String>[
      'ask:Question from mic',
      'local-delete:content://recordings/voice-short',
    ]);
    verify(
      () => dio.delete<dynamic>(
        '/v1/dumps/voice-short',
        data: any(named: 'data'),
      ),
    ).called(1);
  });
}
