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
      store = SecureStore(storage: mock);
    });

    test('getToken returns the stored token', () async {
      when(() => mock.read(key: 'api_token'))
          .thenAnswer((_) async => 'abc-123');
      expect(await store.getToken(), 'abc-123');
    });

    test('setToken stores the token', () async {
      when(() => mock.write(key: 'api_token', value: 'xyz-789'))
          .thenAnswer((_) async {});
      await store.setToken('xyz-789');
      verify(() => mock.write(key: 'api_token', value: 'xyz-789')).called(1);
    });

    test('getServerUrl returns null when not set', () async {
      when(() => mock.read(key: 'server_url'))
          .thenAnswer((_) async => null);
      expect(await store.getServerUrl(), isNull);
    });

    test('setServerUrl stores the url', () async {
      when(() => mock.write(key: 'server_url', value: 'http://homelab:8000'))
          .thenAnswer((_) async {});
      await store.setServerUrl('http://homelab:8000');
      verify(() => mock.write(
              key: 'server_url', value: 'http://homelab:8000',),)
          .called(1);
    });

    test('clear removes all stored keys', () async {
      when(() => mock.deleteAll()).thenAnswer((_) async {});
      await store.clear();
      verify(() => mock.deleteAll()).called(1);
    });
  });
}