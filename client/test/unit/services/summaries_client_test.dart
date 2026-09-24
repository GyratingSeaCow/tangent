// SPDX-License-Identifier: AGPL-3.0-or-later
/// [SummariesClient] talks to /v1/summaries/* the way [OcrSettingsClient]
/// talks to /v1/ocr/*, and these tests pin the same contract points: full
/// payload parsing, bare-server tolerance, the 409s the wizard depends on
/// (install-already-running → attach), and the TYPED summarize 409 that
/// Task 4 uses to tell "no transcript" from "capability not installed".
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/services/summaries_client.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  setUpAll(() {
    registerFallbackValue(Options());
    registerFallbackValue(RequestOptions(path: ''));
  });

  group('SummariesClient', () {
    late _MockDio dio;
    late SummariesClient client;

    setUp(() {
      dio = _MockDio();
      client = SummariesClient.forTesting(dio: dio);
    });

    Response<dynamic> respond(
      String path,
      int statusCode, [
      Object? data,
    ]) =>
        Response<dynamic>(
          data: data,
          requestOptions: RequestOptions(path: path),
          statusCode: statusCode,
        );

    test('getSettings parses the full payload', () async {
      when(() => dio.get<dynamic>('/v1/summaries/settings')).thenAnswer(
        (_) async => respond('/v1/summaries/settings', 200, <String, dynamic>{
          'installed': true,
          'runtime': 'cuda',
          'gpu_visible': true,
          'disk_free_bytes': 64424509440,
          'install_running': false,
          'enabled': true,
        }),
      );

      final SummarySettings settings = await client.getSettings();

      expect(settings.installed, isTrue);
      expect(settings.runtime, 'cuda');
      expect(settings.gpuVisible, isTrue);
      expect(settings.diskFreeBytes, 64424509440);
      expect(settings.installRunning, isFalse);
      expect(settings.enabled, isTrue);
    });

    test('getSettings tolerates a bare server (null runtime)', () async {
      when(() => dio.get<dynamic>('/v1/summaries/settings')).thenAnswer(
        (_) async => respond('/v1/summaries/settings', 200, <String, dynamic>{
          'installed': false,
          'runtime': null,
          'gpu_visible': false,
          'disk_free_bytes': 0,
          'install_running': false,
          'enabled': false,
        }),
      );

      final SummarySettings settings = await client.getSettings();

      expect(settings.installed, isFalse);
      expect(settings.runtime, isNull);
      expect(settings.gpuVisible, isFalse);
      expect(settings.enabled, isFalse);
    });

    test('setEnabled posts the toggle and returns the fresh state', () async {
      when(
        () => dio.post<dynamic>(
          '/v1/summaries/settings',
          data: any(named: 'data'),
        ),
      ).thenAnswer(
        (_) async => respond('/v1/summaries/settings', 200, <String, dynamic>{
          'installed': true,
          'runtime': 'cpu',
          'gpu_visible': false,
          'disk_free_bytes': 1,
          'install_running': false,
          'enabled': true,
        }),
      );

      final SummarySettings settings = await client.setEnabled(true);

      expect(settings.enabled, isTrue);
      final captured = verify(
        () => dio.post<dynamic>(
          '/v1/summaries/settings',
          data: captureAny(named: 'data'),
        ),
      ).captured;
      expect(captured.single, <String, dynamic>{'enabled': true});
    });

    test('startInstall accepts the 202', () async {
      when(() => dio.post<dynamic>('/v1/summaries/install')).thenAnswer(
        (_) async => respond('/v1/summaries/install', 202, <String, dynamic>{
          'status': 'installing',
        }),
      );

      await client.startInstall();

      verify(() => dio.post<dynamic>('/v1/summaries/install')).called(1);
    });

    test('startInstall surfaces the 409 already-running conflict', () async {
      when(() => dio.post<dynamic>('/v1/summaries/install')).thenAnswer(
        (_) async => respond('/v1/summaries/install', 409, <String, dynamic>{
          'detail': 'A summarizer environment install is already running',
        }),
      );

      await expectLater(
        client.startInstall(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.message, 'message', contains('already running')),
        ),
      );
    });

    test('getInstallProgress parses phase, percent and detail', () async {
      when(() => dio.get<dynamic>('/v1/summaries/install/progress'))
          .thenAnswer(
        (_) async =>
            respond('/v1/summaries/install/progress', 200, <String, dynamic>{
          'phase': 'weights',
          'percent': 60,
          'detail': 'Downloading Qwen3-4B weights',
        }),
      );

      final SummaryInstallProgress progress =
          await client.getInstallProgress();

      expect(progress.phase, 'weights');
      expect(progress.percent, 60);
      expect(progress.detail, 'Downloading Qwen3-4B weights');
    });

    test('uninstall posts and returns on 200', () async {
      when(() => dio.post<dynamic>('/v1/summaries/uninstall')).thenAnswer(
        (_) async => respond('/v1/summaries/uninstall', 200, <String, dynamic>{
          'uninstalled': true,
        }),
      );

      await client.uninstall();

      verify(() => dio.post<dynamic>('/v1/summaries/uninstall')).called(1);
    });

    test('uninstall surfaces the 409 install-running conflict', () async {
      when(() => dio.post<dynamic>('/v1/summaries/uninstall')).thenAnswer(
        (_) async => respond('/v1/summaries/uninstall', 409, <String, dynamic>{
          'detail': 'Cannot uninstall while an install is running',
        }),
      );

      await expectLater(
        client.uninstall(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having(
                (e) => e.message,
                'message',
                contains('while an install is running'),
              ),
        ),
      );
    });

    test('summarizeDump accepts the 202', () async {
      when(() => dio.post<dynamic>('/v1/dumps/d1/summarize')).thenAnswer(
        (_) async => respond('/v1/dumps/d1/summarize', 202, <String, dynamic>{
          'dump_id': 'd1',
          'status': 'queued',
        }),
      );

      await client.summarizeDump('d1');

      verify(() => dio.post<dynamic>('/v1/dumps/d1/summarize')).called(1);
    });

    test('summarizeDump types the no-transcript 409', () async {
      // Task 4 shows different UI for "this dump can never summarize"
      // vs "install the capability first" — the reason must be typed, not
      // re-derived from server strings at every call site.
      when(() => dio.post<dynamic>('/v1/dumps/d1/summarize')).thenAnswer(
        (_) async => respond('/v1/dumps/d1/summarize', 409, <String, dynamic>{
          'detail': 'Dump has no transcript to summarize',
        }),
      );

      await expectLater(
        client.summarizeDump('d1'),
        throwsA(
          isA<SummarizeConflictException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having(
                (e) => e.reason,
                'reason',
                SummarizeConflictReason.noTranscript,
              ),
        ),
      );
    });

    test('summarizeDump types the not-installed 409', () async {
      when(() => dio.post<dynamic>('/v1/dumps/d1/summarize')).thenAnswer(
        (_) async => respond('/v1/dumps/d1/summarize', 409, <String, dynamic>{
          'detail': 'Summarizer environment is not installed',
        }),
      );

      await expectLater(
        client.summarizeDump('d1'),
        throwsA(
          isA<SummarizeConflictException>().having(
            (e) => e.reason,
            'reason',
            SummarizeConflictReason.notInstalled,
          ),
        ),
      );
    });

    test('summarizeDump surfaces a plain 404 as an ApiException', () async {
      when(() => dio.post<dynamic>('/v1/dumps/gone/summarize')).thenAnswer(
        (_) async =>
            respond('/v1/dumps/gone/summarize', 404, <String, dynamic>{
          'detail': "Dump 'gone' not found",
        }),
      );

      await expectLater(
        client.summarizeDump('gone'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('not found')),
        ),
      );
    });

    test('401 with the error envelope becomes a typed ApiException', () async {
      when(() => dio.get<dynamic>('/v1/summaries/settings')).thenAnswer(
        (_) async => respond('/v1/summaries/settings', 401, <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'unauthorized',
            'message': 'Invalid token',
          },
        }),
      );

      await expectLater(
        client.getSettings(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
    });

    test('constructor wires baseUrl and the bearer token into Dio', () {
      final SummariesClient built = SummariesClient(
        baseUrl: 'http://server.local:8787',
        token: 'tok-123',
      );

      expect(built.baseUrl, 'http://server.local:8787');
      expect(built.authorizationHeader, 'Bearer tok-123');
    });

    test('constructor without a token sends no Authorization header', () {
      final SummariesClient built =
          SummariesClient(baseUrl: 'http://server.local:8787');

      expect(built.authorizationHeader, isNull);
    });
  });
}
