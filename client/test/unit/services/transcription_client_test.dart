// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/services/transcription_client.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  setUpAll(() {
    registerFallbackValue(Options());
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
      when(() => mock.get<dynamic>(any())).thenAnswer(
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
      when(() => mock.get<dynamic>(any())).thenAnswer(
        (_) async => Response(
          data: {
            'error': {'code': 'unauthorized', 'message': 'Invalid token'},
          },
          requestOptions: RequestOptions(path: '/v1/server/info'),
          statusCode: 401,
        ),
      );
      await expectLater(
        client.getServerInfo(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
    });

    test('exposes baseUrl', () {
      expect(client.baseUrl, 'http://test');
    });

    test('uploadAudio returns on 204', () async {
      when(
        () => mock.post<dynamic>(
          any(),
          data: any(named: 'data'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/dumps/1/audio'),
          statusCode: 204,
        ),
      );
      await client.uploadAudio(dumpId: '1', audioBytes: [0, 1, 2]);
      verify(() => mock.post<dynamic>(any(), data: any(named: 'data')))
          .called(1);
    });

    test('uploadAudio throws on non-204', () async {
      when(
        () => mock.post<dynamic>(
          any(),
          data: any(named: 'data'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/dumps/1/audio'),
          statusCode: 500,
        ),
      );
      await expectLater(
        client.uploadAudio(dumpId: '1', audioBytes: [0]),
        throwsA(isA<ApiException>()),
      );
    });

    test('parses the server completed SSE Python-map payload', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final transcript = "Dr. Lee's completed transcript from the server.";
      unawaited(
        server.first.then((request) async {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'event: completed\n'
            "data: {'status': 'completed', 'transcript': "
            "'Dr. Lee\\'s completed transcript from the server.'}\n\n",
          );
          await request.response.close();
        }),
      );
      final sseClient = TranscriptionClient(
        baseUrl: 'http://${server.address.address}:${server.port}',
      );

      final event = await sseClient.streamJob('real-job').first;

      expect(event.status, 'completed');
      expect(event.data['transcript'], transcript);
    });
  });
}
