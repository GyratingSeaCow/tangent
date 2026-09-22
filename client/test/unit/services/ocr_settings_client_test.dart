// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/services/ocr_settings_client.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  setUpAll(() {
    registerFallbackValue(Options());
    registerFallbackValue(RequestOptions(path: ''));
  });

  group('OcrSettingsClient', () {
    late _MockDio dio;
    late OcrSettingsClient client;

    setUp(() {
      dio = _MockDio();
      client = OcrSettingsClient.forTesting(dio: dio);
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

    test('getCapability parses the full payload', () async {
      when(() => dio.get<dynamic>('/v1/ocr/capability')).thenAnswer(
        (_) async => respond('/v1/ocr/capability', 200, <String, dynamic>{
          'installed': true,
          'flavour': 'gpu',
          'gpu_visible': true,
          'disk_free_bytes': 64424509440,
          'install_running': false,
        }),
      );

      final OcrCapability capability = await client.getCapability();

      expect(capability.installed, isTrue);
      expect(capability.flavour, 'gpu');
      expect(capability.gpuVisible, isTrue);
      expect(capability.diskFreeBytes, 64424509440);
      expect(capability.installRunning, isFalse);
    });

    test('getCapability tolerates a bare server (null flavour)', () async {
      when(() => dio.get<dynamic>('/v1/ocr/capability')).thenAnswer(
        (_) async => respond('/v1/ocr/capability', 200, <String, dynamic>{
          'installed': false,
          'flavour': null,
          'gpu_visible': false,
          'disk_free_bytes': 0,
          'install_running': false,
        }),
      );

      final OcrCapability capability = await client.getCapability();

      expect(capability.installed, isFalse);
      expect(capability.flavour, isNull);
      expect(capability.gpuVisible, isFalse);
    });

    test('startInstall posts the flavour and accepts the 202', () async {
      when(
        () => dio.post<dynamic>('/v1/ocr/install', data: any(named: 'data')),
      ).thenAnswer(
        (_) async => respond('/v1/ocr/install', 202, <String, dynamic>{
          'flavour': 'cpu',
          'status': 'installing',
        }),
      );

      await client.startInstall(flavour: 'cpu');

      final captured = verify(
        () => dio.post<dynamic>(
          '/v1/ocr/install',
          data: captureAny(named: 'data'),
        ),
      ).captured;
      expect(captured.single, <String, dynamic>{'flavour': 'cpu'});
    });

    test('startInstall surfaces the 409 already-running conflict', () async {
      when(
        () => dio.post<dynamic>('/v1/ocr/install', data: any(named: 'data')),
      ).thenAnswer(
        (_) async => respond('/v1/ocr/install', 409, <String, dynamic>{
          'detail': 'An OCR environment install is already running',
        }),
      );

      await expectLater(
        client.startInstall(flavour: 'gpu'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.message, 'message', contains('already running')),
        ),
      );
    });

    test('getInstallProgress parses phase, percent and detail', () async {
      when(() => dio.get<dynamic>('/v1/ocr/install/progress')).thenAnswer(
        (_) async =>
            respond('/v1/ocr/install/progress', 200, <String, dynamic>{
          'phase': 'torch',
          'percent': 40,
          'detail': 'Downloading PyTorch (CUDA)',
        }),
      );

      final OcrInstallProgress progress = await client.getInstallProgress();

      expect(progress.phase, 'torch');
      expect(progress.percent, 40);
      expect(progress.detail, 'Downloading PyTorch (CUDA)');
    });

    test('uninstall posts and returns on 200', () async {
      when(
        () => dio.post<dynamic>('/v1/ocr/uninstall', data: any(named: 'data')),
      ).thenAnswer(
        (_) async => respond('/v1/ocr/uninstall', 200, <String, dynamic>{
          'uninstalled': true,
        }),
      );

      await client.uninstall();

      verify(
        () => dio.post<dynamic>('/v1/ocr/uninstall', data: any(named: 'data')),
      ).called(1);
    });

    test('uninstall surfaces the 409 install-running conflict', () async {
      when(
        () => dio.post<dynamic>('/v1/ocr/uninstall', data: any(named: 'data')),
      ).thenAnswer(
        (_) async => respond('/v1/ocr/uninstall', 409, <String, dynamic>{
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

    test('401 with the error envelope becomes a typed ApiException', () async {
      when(() => dio.get<dynamic>('/v1/ocr/capability')).thenAnswer(
        (_) async => respond('/v1/ocr/capability', 401, <String, dynamic>{
          'error': <String, dynamic>{
            'code': 'unauthorized',
            'message': 'Invalid token',
          },
        }),
      );

      await expectLater(
        client.getCapability(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
    });
  });
}
