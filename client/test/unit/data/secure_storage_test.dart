// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tangent/data/secure_storage.dart';

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  setUpAll(() {
    registerFallbackValue('');
  });

  group('SecureStore', () {
    late _MockFlutterSecureStorage mock;
    late SecureStore store;

    setUp(() {
      mock = _MockFlutterSecureStorage();
      store = SecureStore.forTesting(storage: mock);
    });

    test('readToken returns the stored token', () async {
      when(() => mock.read(key: 'api_token'))
          .thenAnswer((_) async => 'abc-123');
      expect(await store.readToken(), 'abc-123');
    });

    test('writeToken stores the token', () async {
      when(() => mock.write(key: 'api_token', value: 'xyz-789'))
          .thenAnswer((_) async {});
      await store.writeToken('xyz-789');
      verify(() => mock.write(key: 'api_token', value: 'xyz-789')).called(1);
    });

    test('readServerUrl returns null when not set', () async {
      when(() => mock.read(key: 'server_url'))
          .thenAnswer((_) async => null);
      expect(await store.readServerUrl(), isNull);
    });

    test('writeServerUrl stores the url', () async {
      when(() => mock.write(key: 'server_url', value: 'http://homelab:8000'))
          .thenAnswer((_) async {});
      await store.writeServerUrl('http://homelab:8000');
      verify(() => mock.write(
              key: 'server_url', value: 'http://homelab:8000'))
          .called(1);
    });

    test('clear removes all stored keys', () async {
      when(() => mock.deleteAll()).thenAnswer((_) async {});
      await store.clear();
      verify(() => mock.deleteAll()).called(1);
    });
  });
}