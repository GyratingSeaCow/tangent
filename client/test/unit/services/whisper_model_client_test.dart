// SPDX-License-Identifier: AGPL-3.0-or-later
/// [WhisperModelClient] talks to /v1/transcription/models* the way
/// [SummariesClient] talks to /v1/summaries/*, and these tests pin the same
/// contract points: full payload parsing, accuracy-ordered catalogue, and
/// the THREE distinct 409s the section routes on — select-not-installed
/// (install first), install-already-running (attach, never an error), and
/// delete-active (refused, the server must stay able to transcribe).
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/services/whisper_model_client.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  setUpAll(() {
    registerFallbackValue(Options());
    registerFallbackValue(RequestOptions(path: ''));
  });

  group('WhisperModelClient', () {
    late _MockDio dio;
    late WhisperModelClient client;

    setUp(() {
      dio = _MockDio();
      client = WhisperModelClient.forTesting(dio: dio);
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

    Map<String, dynamic> catalogJson() => <String, dynamic>{
          'active': 'large-v3',
          'models': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'large-v3',
              'installed': true,
              'size_bytes_on_disk': 3095000000,
              'approx_download_bytes': 3100000000,
            },
            <String, dynamic>{
              'name': 'medium',
              'installed': false,
              'size_bytes_on_disk': 0,
              'approx_download_bytes': 1500000000,
            },
            <String, dynamic>{
              'name': 'small',
              'installed': true,
              'size_bytes_on_disk': 484000000,
              'approx_download_bytes': 484000000,
            },
            <String, dynamic>{
              'name': 'base',
              'installed': false,
              'size_bytes_on_disk': 0,
              'approx_download_bytes': 145000000,
            },
            <String, dynamic>{
              'name': 'tiny',
              'installed': false,
              'size_bytes_on_disk': 0,
              'approx_download_bytes': 75000000,
            },
          ],
        };

    test('getModels parses the catalogue in the order the server sent',
        () async {
      // Accuracy order is the SERVER's contract (large-v3 first, tiny last);
      // the client must not re-sort it, or the radio list silently reorders
      // the moment the server's table changes.
      when(() => dio.get<dynamic>('/v1/transcription/models')).thenAnswer(
        (_) async => respond('/v1/transcription/models', 200, catalogJson()),
      );

      final WhisperModelCatalog catalog = await client.getModels();

      expect(catalog.active, 'large-v3');
      expect(
        catalog.models.map((WhisperModelInfo m) => m.name).toList(),
        <String>['large-v3', 'medium', 'small', 'base', 'tiny'],
      );
      expect(catalog.models.first.installed, isTrue);
      expect(catalog.models.first.sizeBytesOnDisk, 3095000000);
      expect(catalog.models.first.approxDownloadBytes, 3100000000);
      expect(catalog.models[1].installed, isFalse);
      expect(catalog.models[1].sizeBytesOnDisk, 0);
    });

    test('getModels tolerates a payload with missing fields', () async {
      when(() => dio.get<dynamic>('/v1/transcription/models')).thenAnswer(
        (_) async => respond('/v1/transcription/models', 200, <String, dynamic>{
          'active': 'tiny',
          'models': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'tiny'},
          ],
        }),
      );

      final WhisperModelCatalog catalog = await client.getModels();

      expect(catalog.active, 'tiny');
      expect(catalog.models.single.installed, isFalse);
      expect(catalog.models.single.sizeBytesOnDisk, 0);
      expect(catalog.models.single.approxDownloadBytes, 0);
    });

    test('selectModel PUTs the name and returns the fresh catalogue',
        () async {
      when(
        () => dio.put<dynamic>(
          '/v1/transcription/model',
          data: any(named: 'data'),
        ),
      ).thenAnswer(
        (_) async => respond(
          '/v1/transcription/model',
          200,
          <String, dynamic>{...catalogJson(), 'active': 'small'},
        ),
      );

      final WhisperModelCatalog catalog = await client.selectModel('small');

      expect(catalog.active, 'small');
      final captured = verify(
        () => dio.put<dynamic>(
          '/v1/transcription/model',
          data: captureAny(named: 'data'),
        ),
      ).captured;
      expect(captured.single, <String, dynamic>{'name': 'small'});
    });

    test('selectModel types the 409 not-installed conflict', () async {
      // The section routes this one into the install wizard, so it may never
      // arrive as an anonymous ApiException the UI has to string-match.
      when(
        () => dio.put<dynamic>(
          '/v1/transcription/model',
          data: any(named: 'data'),
        ),
      ).thenAnswer(
        (_) async => respond('/v1/transcription/model', 409, <String, dynamic>{
          'detail': "Model 'medium' is not installed",
        }),
      );

      await expectLater(
        client.selectModel('medium'),
        throwsA(
          isA<WhisperModelNotInstalledException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.model, 'model', 'medium')
              .having((e) => e.message, 'message', contains('not installed')),
        ),
      );
    });

    test('selectModel types the 400 unsupported name', () async {
      when(
        () => dio.put<dynamic>(
          '/v1/transcription/model',
          data: any(named: 'data'),
        ),
      ).thenAnswer(
        (_) async => respond('/v1/transcription/model', 400, <String, dynamic>{
          'detail': "Unsupported model 'huge'",
        }),
      );

      await expectLater(
        client.selectModel('huge'),
        throwsA(
          isA<UnsupportedWhisperModelException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.model, 'model', 'huge'),
        ),
      );
    });

    test('startInstall posts to the per-model install route', () async {
      when(() => dio.post<dynamic>('/v1/transcription/models/small/install'))
          .thenAnswer(
        (_) async => respond(
          '/v1/transcription/models/small/install',
          200,
          <String, dynamic>{'status': 'installing'},
        ),
      );

      await client.startInstall('small');

      verify(() => dio.post<dynamic>('/v1/transcription/models/small/install'))
          .called(1);
    });

    test('startInstall types the 409 already-running conflict', () async {
      // Attach-and-watch, never an error: the wizard depends on telling this
      // apart from a real failure.
      when(() => dio.post<dynamic>('/v1/transcription/models/small/install'))
          .thenAnswer(
        (_) async => respond(
          '/v1/transcription/models/small/install',
          409,
          <String, dynamic>{'detail': 'A model install is already running'},
        ),
      );

      await expectLater(
        client.startInstall('small'),
        throwsA(
          isA<WhisperInstallAlreadyRunningException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.message, 'message', contains('already running')),
        ),
      );
    });

    test('startInstall types the 400 unsupported name', () async {
      when(() => dio.post<dynamic>('/v1/transcription/models/huge/install'))
          .thenAnswer(
        (_) async => respond(
          '/v1/transcription/models/huge/install',
          400,
          <String, dynamic>{'detail': "Unsupported model 'huge'"},
        ),
      );

      await expectLater(
        client.startInstall('huge'),
        throwsA(isA<UnsupportedWhisperModelException>()),
      );
    });

    test('getInstallProgress parses phase, percent, detail and model',
        () async {
      when(() => dio.get<dynamic>('/v1/transcription/models/install/progress'))
          .thenAnswer(
        (_) async => respond(
          '/v1/transcription/models/install/progress',
          200,
          <String, dynamic>{
            'phase': 'downloading',
            'percent': 42,
            'detail': 'Fetching model.bin',
            'model': 'small',
          },
        ),
      );

      final WhisperInstallProgress progress = await client.getInstallProgress();

      expect(progress.phase, 'downloading');
      expect(progress.percent, 42);
      expect(progress.detail, 'Fetching model.bin');
      expect(progress.model, 'small');
    });

    test('getInstallProgress defaults an empty body to idle', () async {
      when(() => dio.get<dynamic>('/v1/transcription/models/install/progress'))
          .thenAnswer(
        (_) async => respond(
          '/v1/transcription/models/install/progress',
          200,
          <String, dynamic>{},
        ),
      );

      final WhisperInstallProgress progress = await client.getInstallProgress();

      expect(progress.phase, 'idle');
      expect(progress.percent, 0);
      expect(progress.detail, '');
      expect(progress.model, isNull);
    });

    test('deleteModel removes the weights', () async {
      when(() => dio.delete<dynamic>('/v1/transcription/models/small'))
          .thenAnswer(
        (_) async => respond(
          '/v1/transcription/models/small',
          200,
          <String, dynamic>{...catalogJson(), 'active': 'large-v3'},
        ),
      );

      final WhisperModelCatalog catalog = await client.deleteModel('small');

      expect(catalog.active, 'large-v3');
      verify(() => dio.delete<dynamic>('/v1/transcription/models/small'))
          .called(1);
    });

    test('deleteModel types the 409 delete-the-active-model refusal',
        () async {
      // Never leave the server unable to transcribe: this 409 is a rule, not
      // a transient, and the UI says so in its own words.
      when(() => dio.delete<dynamic>('/v1/transcription/models/large-v3'))
          .thenAnswer(
        (_) async => respond(
          '/v1/transcription/models/large-v3',
          409,
          <String, dynamic>{'detail': 'Cannot delete the active model'},
        ),
      );

      await expectLater(
        client.deleteModel('large-v3'),
        throwsA(
          isA<CannotDeleteActiveModelException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.model, 'model', 'large-v3'),
        ),
      );
    });

    test('a 401 with the error envelope becomes a typed ApiException',
        () async {
      when(() => dio.get<dynamic>('/v1/transcription/models')).thenAnswer(
        (_) async => respond('/v1/transcription/models', 401, <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'unauthorized',
            'message': 'Invalid token',
          },
        }),
      );

      await expectLater(
        client.getModels(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
    });

    test('constructor wires baseUrl and the bearer token into Dio', () {
      final WhisperModelClient built = WhisperModelClient(
        baseUrl: 'http://server.local:8787',
        token: 'tok-123',
      );

      expect(built.baseUrl, 'http://server.local:8787');
      expect(built.authorizationHeader, 'Bearer tok-123');
    });

    test('constructor without a token sends no Authorization header', () {
      final WhisperModelClient built =
          WhisperModelClient(baseUrl: 'http://server.local:8787');

      expect(built.authorizationHeader, isNull);
    });
  });
}
