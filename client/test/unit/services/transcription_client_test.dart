// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/services/transcription_client.dart';

class _MockDio extends Mock implements Dio {}

class _MockHttpClient extends Mock implements HttpClient {}

void main() {
  setUpAll(() {
    registerFallbackValue(Options());
    registerFallbackValue(RequestOptions(path: ''));
    registerFallbackValue(Uri.parse('http://test'));
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

    test('enqueue sends request id and returns a typed snapshot', () async {
      when(
        () => mock.post<dynamic>(
          '/v1/dumps/dump-1/transcribe',
          data: any(named: 'data'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: '/v1/dumps/dump-1/transcribe',
          ),
          statusCode: 201,
          data: {
            'id': 'job-1',
            'request_id': 'request-client-001',
            'dump_id': 'dump-1',
            'status': 'queued',
            'model': 'large-v3',
            'started_at': null,
            'completed_at': null,
            'result_transcript': null,
            'error': null,
          },
        ),
      );

      final snapshot = await client.enqueueTranscription(
        'dump-1',
        requestId: 'request-client-001',
      );
      final request = verify(
        () => mock.post<dynamic>(
          '/v1/dumps/dump-1/transcribe',
          data: captureAny(named: 'data'),
        ),
      ).captured.single;

      expect(request, {
        'model': 'large-v3',
        'request_id': 'request-client-001',
      });
      expect(snapshot.id, 'job-1');
      expect(snapshot.requestId, 'request-client-001');
      expect(snapshot.status, 'queued');
    });

    test('poll response maps result transcript into typed snapshot', () async {
      when(() => mock.get<dynamic>('/v1/jobs/job-1')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/jobs/job-1'),
          statusCode: 200,
          data: const {
            'id': 'job-1',
            'request_id': 'request-client-001',
            'dump_id': 'dump-1',
            'status': 'completed',
            'model': 'large-v3',
            'started_at': '2026-09-14T20:00:00Z',
            'completed_at': '2026-09-14T20:01:00Z',
            'result_transcript': 'poll result',
            'error': null,
          },
        ),
      );

      final snapshot = await client.getJob('job-1');

      expect(snapshot.id, 'job-1');
      expect(snapshot.requestId, 'request-client-001');
      expect(snapshot.status, 'completed');
      expect(snapshot.transcript, 'poll result');
    });

    test('clean SSE EOF after running falls back to completed poll', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.first.then((request) async {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'event: running\n'
            'data: {"status":"running"}\n\n',
          );
          await request.response.close();
        }),
      );
      when(() => mock.options).thenReturn(BaseOptions());
      when(() => mock.get<dynamic>('/v1/jobs/job-eof')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/jobs/job-eof'),
          statusCode: 200,
          data: const {
            'id': 'job-eof',
            'request_id': 'request-eof-001',
            'dump_id': 'dump-eof',
            'status': 'completed',
            'model': 'large-v3',
            'started_at': null,
            'completed_at': null,
            'result_transcript': 'poll result',
            'error': null,
          },
        ),
      );
      final fallbackClient = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://${server.address.address}:${server.port}',
        httpClientFactory: HttpClient.new,
      );

      final terminal = (await fallbackClient.streamJob('job-eof').toList())
          .where((event) => event.status == 'completed')
          .toList();

      expect(terminal, hasLength(1));
      expect(terminal.single.data['transcript'], 'poll result');
    });

    test('SSE socket failure falls back to completed poll', () async {
      final closedServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = closedServer.port;
      await closedServer.close(force: true);
      when(() => mock.options).thenReturn(BaseOptions());
      when(() => mock.get<dynamic>('/v1/jobs/job-socket')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/jobs/job-socket'),
          statusCode: 200,
          data: const {
            'id': 'job-socket',
            'request_id': 'request-socket-001',
            'dump_id': 'dump-socket',
            'status': 'completed',
            'model': 'large-v3',
            'started_at': null,
            'completed_at': null,
            'result_transcript': 'poll result',
            'error': null,
          },
        ),
      );
      final fallbackClient = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://${InternetAddress.loopbackIPv4.address}:$port',
        httpClientFactory: HttpClient.new,
      );

      final terminal = (await fallbackClient.streamJob('job-socket').toList())
          .where((event) => event.status == 'completed')
          .toList();

      expect(terminal, hasLength(1));
      expect(terminal.single.data['transcript'], 'poll result');
    });

    test('SSE timeout before terminal falls back to completed poll', () async {
      final httpClient = _MockHttpClient();
      when(() => httpClient.getUrl(any())).thenThrow(
        TimeoutException('SSE connection timed out'),
      );
      when(() => mock.options).thenReturn(BaseOptions());
      when(() => mock.get<dynamic>('/v1/jobs/job-timeout')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/jobs/job-timeout'),
          statusCode: 200,
          data: const {
            'id': 'job-timeout',
            'request_id': 'request-timeout-001',
            'dump_id': 'dump-timeout',
            'status': 'completed',
            'model': 'large-v3',
            'started_at': null,
            'completed_at': null,
            'result_transcript': 'poll result',
            'error': null,
          },
        ),
      );
      final fallbackClient = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://test',
        httpClientFactory: () => httpClient,
      );

      final terminal = (await fallbackClient.streamJob('job-timeout').toList())
          .where((event) => event.status == 'completed')
          .toList();

      expect(terminal, hasLength(1));
      expect(terminal.single.data['transcript'], 'poll result');
    });

    test('SSE and polling share one deadline', () async {
      var fakeNow = DateTime.utc(2026, 9, 14, 20);
      var pollCalls = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.first.then((request) async {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'event: running\n'
            'data: {"status":"running"}\n\n',
          );
          fakeNow = fakeNow.add(const Duration(minutes: 20));
          await request.response.close();
        }),
      );
      when(() => mock.options).thenReturn(BaseOptions());
      when(() => mock.get<dynamic>('/v1/jobs/job-deadline'))
          .thenAnswer((_) async {
        pollCalls++;
        return Response(
          requestOptions: RequestOptions(path: '/v1/jobs/job-deadline'),
          statusCode: 200,
          data: const {
            'id': 'job-deadline',
            'request_id': 'request-deadline-001',
            'dump_id': 'dump-deadline',
            'status': 'running',
            'model': 'large-v3',
            'started_at': null,
            'completed_at': null,
            'result_transcript': null,
            'error': null,
          },
        );
      });
      final fallbackClient = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://${server.address.address}:${server.port}',
        httpClientFactory: HttpClient.new,
        now: () => fakeNow,
        delay: (_) async {
          fakeNow = fakeNow.add(const Duration(minutes: 10));
        },
      );

      final events = await fallbackClient.streamJob('job-deadline').toList();

      expect(events.last.status, 'timeout');
      expect(pollCalls, 1);
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
