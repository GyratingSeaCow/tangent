// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/services/transcription_client.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  setUpAll(() {
    registerFallbackValue(RequestOptions(path: ''));
  });

  group('TranscriptionClient', () {
    late _MockDio mock;
    late TranscriptionClient client;

    setUp(() {
      mock = _MockDio();
      client = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://test',
      );
    });

    test('getServerInfo returns parsed ServerInfo on 200', () async {
      when(() => mock.fetch<Map<String, dynamic>>(any())).thenAnswer(
        (_) async => Response(
          data: {
            'version': '0.1.0',
            'setup_complete': true,
            'default_model': 'large-v3',
            'available_models': ['tiny', 'large-v3'],
            'storage_used_bytes': 1024,
            'dump_count': 5,
          },
          requestOptions: RequestOptions(path: '/v1/server/info'),
          statusCode: 200,
        ),
      );
      final info = await client.getServerInfo();
      expect(info.version, '0.1.0');
      expect(info.setupComplete, isTrue);
      expect(info.dumpCount, 5);
      expect(info.availableModels, contains('large-v3'));
    });

    test('throws ApiException on 401', () async {
      when(() => mock.fetch<Map<String, dynamic>>(any())).thenAnswer(
        (_) async => Response(
          data: {'error': {'code': 'unauthorized', 'message': 'Invalid token'}},
          requestOptions: RequestOptions(path: '/v1/server/info'),
          statusCode: 401,
        ),
      );
      expect(
        () => client.getServerInfo(),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.code, 'code', 'unauthorized')),
      );
    });

    test('exposes baseUrl', () {
      expect(client.baseUrl, 'http://test');
    });

    test('uploadAudio returns on 204', () async {
      when(() => mock.fetch<dynamic>(any())).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/dumps/1/audio'),
          statusCode: 204,
        ),
      );
      await client.uploadAudio(dumpId: '1', audioBytes: [0, 1, 2]);
      verify(() => mock.fetch<dynamic>(any())).called(1);
    });

    test('uploadAudio throws on non-204', () async {
      when(() => mock.fetch<dynamic>(any())).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/dumps/1/audio'),
          statusCode: 500,
        ),
      );
      expect(
        () => client.uploadAudio(dumpId: '1', audioBytes: [0]),
        throwsA(isA<ApiException>()),
      );
    });
  });
}