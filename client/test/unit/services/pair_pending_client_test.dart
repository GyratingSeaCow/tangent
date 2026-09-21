// SPDX-License-Identifier: AGPL-3.0-or-later
/// pairPending(): the authenticated read of /v1/pair/pending that lets an
/// already-paired device DISPLAY codes instead of the user reading docker
/// logs. The wire carries requested_at but no expires_at — expiry is
/// requested_at + the server's fixed 120 s TTL.
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/services/transcription_client.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  group('TranscriptionClient.pairPending', () {
    late _MockDio mock;
    late TranscriptionClient client;

    setUp(() {
      mock = _MockDio();
      client = TranscriptionClient.forTesting(
        dio: mock,
        baseUrl: 'http://test',
      );
    });

    test('parses pending entries on 200', () async {
      when(() => mock.get<dynamic>(any())).thenAnswer(
        (_) async => Response(
          data: {
            'pending': [
              {
                'pair_id': 'pair-1',
                'display_name': "Jeff's tablet",
                'platform': 'android',
                'requested_at': '2026-01-01T12:00:00+00:00',
                'code': '123456',
              },
              {
                'pair_id': 'pair-2',
                'display_name': 'workbench',
                'platform': 'linux',
                'requested_at': '2026-01-01T12:01:00+00:00',
                'code': '654321',
              },
            ],
          },
          requestOptions: RequestOptions(path: '/v1/pair/pending'),
          statusCode: 200,
        ),
      );

      final entries = await client.pairPending();

      expect(entries, hasLength(2));
      final first = entries.first;
      expect(first.pairId, 'pair-1');
      expect(first.displayName, "Jeff's tablet");
      expect(first.platform, 'android');
      expect(first.code, '123456');
      expect(first.requestedAt, DateTime.utc(2026, 1, 1, 12));
      // No expires_at on the wire: it is requested_at + the 120 s TTL.
      expect(first.expiresAt, DateTime.utc(2026, 1, 1, 12, 2));
      verify(() => mock.get<dynamic>('/v1/pair/pending')).called(1);
    });

    test('an empty pending list parses to an empty list', () async {
      when(() => mock.get<dynamic>(any())).thenAnswer(
        (_) async => Response(
          data: {'pending': <dynamic>[]},
          requestOptions: RequestOptions(path: '/v1/pair/pending'),
          statusCode: 200,
        ),
      );

      expect(await client.pairPending(), isEmpty);
    });

    test('surfaces auth failure as ApiException 401', () async {
      // require_auth rejects with FastAPI's plain {'detail': ...} shape.
      when(() => mock.get<dynamic>(any())).thenAnswer(
        (_) async => Response(
          data: {'detail': 'Invalid or missing token'},
          requestOptions: RequestOptions(path: '/v1/pair/pending'),
          statusCode: 401,
        ),
      );

      await expectLater(
        client.pairPending(),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });
  });
}
