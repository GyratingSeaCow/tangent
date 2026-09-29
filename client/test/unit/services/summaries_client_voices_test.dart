// SPDX-License-Identifier: AGPL-3.0-or-later
/// v1.36.0 voice matching: the Settings → Voices wire contract on
/// [SummariesClient] (list + per-name forget) and the `diarization` flag on
/// [ServerInfo] that decides whether the section shows at all.
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/models/server_info.dart';
import 'package:tangent/services/summaries_client.dart';

class _MockDio extends Mock implements Dio {}

const Map<String, dynamic> _minimalInfo = <String, dynamic>{
  'version': '1.36.0',
  'setup_complete': true,
  'default_model': 'large-v3',
  'available_models': <String>['large-v3'],
  'storage_used_bytes': 0,
  'dump_count': 0,
};

void main() {
  setUpAll(() {
    registerFallbackValue(Options());
    registerFallbackValue(RequestOptions(path: ''));
  });

  group('ServerInfo.diarization', () {
    test('absent on an older server → false', () {
      expect(ServerInfo.fromJson(_minimalInfo).diarization, isFalse);
    });

    test('true when the server says so', () {
      expect(
        ServerInfo.fromJson(<String, dynamic>{
          ..._minimalInfo,
          'diarization': true,
        }).diarization,
        isTrue,
      );
    });
  });

  group('SummariesClient voices', () {
    late _MockDio dio;
    late SummariesClient client;

    setUp(() {
      dio = _MockDio();
      client = SummariesClient.forTesting(dio: dio);
    });

    Response<dynamic> respond(String path, int statusCode, [Object? data]) =>
        Response<dynamic>(
          data: data,
          requestOptions: RequestOptions(path: path),
          statusCode: statusCode,
        );

    test('listVoices decodes the list in server order', () async {
      when(() => dio.get<dynamic>('/v1/voices')).thenAnswer(
        (_) async => respond('/v1/voices', 200, <dynamic>[
          <String, dynamic>{
            'name': "Jeff O'Neil",
            'samples': 3,
            'updated_at': '2026-09-29T02:00:00Z',
          },
          <String, dynamic>{
            'name': 'Tom',
            'samples': 1,
            'updated_at': '2026-09-29T01:00:00Z',
          },
        ]),
      );

      final List<VoiceEntry> voices = await client.listVoices();

      expect(voices.map((v) => v.name), ["Jeff O'Neil", 'Tom']);
      expect(voices.first.samples, 3);
      expect(voices.first.updatedAt, DateTime.utc(2026, 9, 29, 2));
    });

    test('listVoices on an older server (404) → empty, not a throw', () async {
      when(() => dio.get<dynamic>('/v1/voices')).thenAnswer(
        (_) async => respond('/v1/voices', 404, <String, dynamic>{
          'detail': 'Not Found',
        }),
      );
      expect(await client.listVoices(), isEmpty);
    });

    test('forgetVoice DELETEs the percent-encoded name', () async {
      when(() => dio.delete<dynamic>(any())).thenAnswer(
        (invocation) async =>
            respond(invocation.positionalArguments.first as String, 204),
      );

      await client.forgetVoice('Zoë Smith');

      final String path = verify(() => dio.delete<dynamic>(captureAny()))
          .captured
          .single as String;
      expect(path, '/v1/voices/Zo%C3%AB%20Smith');
    });

    test('forgetVoice 404 throws ApiException', () async {
      when(() => dio.delete<dynamic>(any())).thenAnswer(
        (_) async => respond('/v1/voices/Nobody', 404, <String, dynamic>{
          'detail': 'unknown voice',
        }),
      );
      expect(() => client.forgetVoice('Nobody'), throwsA(isA<ApiException>()));
    });
  });
}
