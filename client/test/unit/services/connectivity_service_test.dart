// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/connectivity_service.dart';

void main() {
  group('ConnectivityStatus', () {
    test('isOnline is true for wifi and mobile', () {
      expect(ConnectivityStatus.wifi.isOnline, isTrue);
      expect(ConnectivityStatus.mobile.isOnline, isTrue);
      expect(ConnectivityStatus.offline.isOnline, isFalse);
      expect(ConnectivityStatus.unknown.isOnline, isFalse);
    });
  });
}