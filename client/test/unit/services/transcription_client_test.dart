// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/services/meeting_transcript_formatter.dart';
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

    test('enqueue maps the server request-id conflict response', () async {
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
          statusCode: 409,
          data: const {'detail': 'request_id conflict'},
        ),
      );

      await expectLater(
        client.enqueueTranscription(
          'dump-1',
          requestId: 'request-conflict',
        ),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'statusCode', 409)
              .having(
                (error) => error.code,
                'code',
                'request_id_conflict',
              ),
        ),
      );
    });

    test('only the exact server missing-audio 422 gets a typed code', () async {
      Future<ApiException> enqueueError(Object detail) async {
        final dio = _MockDio();
        when(
          () => dio.post<dynamic>(
            '/v1/dumps/dump-1/transcribe',
            data: any(named: 'data'),
          ),
        ).thenAnswer(
          (_) async => Response(
            requestOptions: RequestOptions(
              path: '/v1/dumps/dump-1/transcribe',
            ),
            statusCode: 422,
            data: {'detail': detail},
          ),
        );
        final testClient = TranscriptionClient.forTesting(
          dio: dio,
          baseUrl: 'http://test',
        );
        try {
          await testClient.enqueueTranscription(
            'dump-1',
            requestId: 'request-422',
          );
          fail('enqueue unexpectedly succeeded');
        } on ApiException catch (error) {
          return error;
        }
      }

      const missingAudioDetail = "No audio file uploaded for dump 'dump-1'. "
          'POST the audio to /v1/dumps/{id}/audio first.';
      final missingAudio = await enqueueError(missingAudioDetail);
      final validation = await enqueueError(const [
        {
          'type': 'missing',
          'loc': ['body', 'request_id'],
          'msg': 'Field required',
        },
      ]);

      expect(missingAudio.statusCode, 422);
      expect(missingAudio.code, 'missing_audio');
      expect(missingAudio.message, missingAudioDetail);
      expect(validation.statusCode, 422);
      expect(validation.code, 'http_error');
      expect(validation.message, 'HTTP 422');
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
      expect(snapshot.segments, isEmpty);
    });

    test('poll response maps result segments into typed snapshot', () async {
      when(() => mock.get<dynamic>('/v1/jobs/job-seg')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/jobs/job-seg'),
          statusCode: 200,
          data: const {
            'id': 'job-seg',
            'request_id': 'request-client-seg',
            'dump_id': 'dump-seg',
            'status': 'completed',
            'model': 'large-v3',
            'result_transcript': 'Hello. Bye.',
            'result_segments': [
              {
                'start': 0.0,
                'end': 2.0,
                'speaker': 'Speaker 1',
                'text': 'Hello.',
              },
              {
                'start': 65.0,
                'end': 67.0,
                'speaker': 'Speaker 2',
                'text': 'Bye.',
              },
            ],
            'error': null,
          },
        ),
      );

      final snapshot = await client.getJob('job-seg');

      expect(snapshot.transcript, 'Hello. Bye.');
      expect(snapshot.segments, hasLength(2));
      expect(snapshot.segments.first.speaker, 'Speaker 1');
      expect(snapshot.segments.first.text, 'Hello.');
      expect(snapshot.segments.last.start, 65.0);
      expect(
        formatMeetingTranscript(snapshot.segments),
        '[00:00] Speaker 1: Hello.\n\n[01:05] Speaker 2: Bye.',
      );
    });

    test('terminal SSE ends promptly with one event and zero polls', () async {
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
            'event: completed\n'
            'data: {"status":"completed","transcript":"done"}\n\n'
            'event: running\n'
            'data: {"status":"running"}\n\n',
          );
          await request.response.close();
        }),
      );
      when(() => mock.options).thenReturn(BaseOptions());
      final terminalClient = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://${server.address.address}:${server.port}',
        httpClientFactory: HttpClient.new,
      );

      final events = await terminalClient
          .streamJob('job-terminal')
          .toList()
          .timeout(const Duration(seconds: 1));

      expect(events, hasLength(1));
      expect(events.single.status, 'completed');
      verifyNever(() => mock.get<dynamic>(any()));
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

    test('in-flight poll is bounded by the shared deadline', () async {
      final httpClient = _MockHttpClient();
      final pendingPoll = Completer<Response<dynamic>>();
      when(() => httpClient.getUrl(any())).thenThrow(
        const SocketException('SSE unavailable'),
      );
      when(() => mock.get<dynamic>('/v1/jobs/job-pending'))
          .thenAnswer((_) => pendingPoll.future);
      final fallbackClient = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://test',
        httpClientFactory: () => httpClient,
      );

      final events = await fallbackClient
          .streamJob('job-pending', maxWait: const Duration(milliseconds: 20))
          .toList()
          .timeout(const Duration(milliseconds: 200));

      expect(events.map((event) => event.status), ['timeout']);
    });

    test('polling propagates permanent API errors', () async {
      final httpClient = _MockHttpClient();
      when(() => httpClient.getUrl(any())).thenThrow(
        const SocketException('SSE unavailable'),
      );
      when(() => mock.get<dynamic>('/v1/jobs/job-unauthorized')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/jobs/job-unauthorized'),
          statusCode: 401,
          data: const {
            'error': {'code': 'unauthorized', 'message': 'Invalid token'},
          },
        ),
      );
      final fallbackClient = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://test',
        httpClientFactory: () => httpClient,
      );

      await expectLater(
        fallbackClient
            .streamJob(
              'job-unauthorized',
              maxWait: const Duration(milliseconds: 20),
            )
            .toList(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
    });

    test('polling propagates malformed typed responses', () async {
      final httpClient = _MockHttpClient();
      when(() => httpClient.getUrl(any())).thenThrow(
        const SocketException('SSE unavailable'),
      );
      when(() => mock.get<dynamic>('/v1/jobs/job-malformed')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/v1/jobs/job-malformed'),
          statusCode: 200,
          data: const {'status': 'completed'},
        ),
      );
      final fallbackClient = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://test',
        httpClientFactory: () => httpClient,
      );

      await expectLater(
        fallbackClient
            .streamJob(
              'job-malformed',
              maxWait: const Duration(milliseconds: 20),
            )
            .toList(),
        throwsA(isA<TypeError>()),
      );
    });

    test('polling retries transient transport failures', () async {
      final httpClient = _MockHttpClient();
      var pollCalls = 0;
      when(() => httpClient.getUrl(any())).thenThrow(
        const SocketException('SSE unavailable'),
      );
      when(() => mock.get<dynamic>('/v1/jobs/job-transient'))
          .thenAnswer((_) async {
        pollCalls++;
        if (pollCalls == 1) {
          throw DioException(
            requestOptions: RequestOptions(path: '/v1/jobs/job-transient'),
            type: DioExceptionType.connectionError,
            error: const SocketException('temporary disconnect'),
          );
        }
        return Response(
          requestOptions: RequestOptions(path: '/v1/jobs/job-transient'),
          statusCode: 200,
          data: const {
            'id': 'job-transient',
            'request_id': 'request-transient-001',
            'dump_id': 'dump-transient',
            'status': 'completed',
            'model': 'large-v3',
            'started_at': null,
            'completed_at': null,
            'result_transcript': 'poll result',
            'error': null,
          },
        );
      });
      final fallbackClient = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://test',
        httpClientFactory: () => httpClient,
        delay: (_) async {},
      );

      final events = await fallbackClient.streamJob('job-transient').toList();

      expect(events.single.status, 'completed');
      expect(events.single.data['transcript'], 'poll result');
      expect(pollCalls, 2);
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
