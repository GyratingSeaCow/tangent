// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/unreachable_server_notice.dart';

void main() {
  final DateTime t0 = DateTime.utc(2026, 9, 28, 20, 0, 0);
  const String lan = 'http://192.168.1.206:8765';
  const String ts = 'http://100.88.126.107:8765';

  String? notice({
    bool inProgress = true,
    String? error = 'reconciliation_pending: DioException [connection timeout]',
    DateTime? startedAt,
    Duration elapsed = const Duration(minutes: 2),
    String baseUrl = lan,
  }) =>
      unreachableServerNotice(
        inProgress: inProgress,
        transcriptionError: error,
        startedAt: startedAt ?? t0,
        now: t0.add(elapsed),
        baseUrl: baseUrl,
      );

  group('unreachableServerNotice', () {
    test('LAN address, stuck retrying: names the address and the fix', () {
      final String? n = notice();
      expect(n, isNotNull);
      expect(n, contains("Can't reach the server at 192.168.1.206:8765"));
      expect(n, contains('Wi-Fi address'));
      expect(n, contains('Tailscale address (http://100.x.x.x:8765)'));
      expect(n, contains('still retrying'));
    });

    test('Tailscale address, stuck retrying: says to check Tailscale', () {
      final String? n = notice(baseUrl: ts);
      expect(n, contains('100.88.126.107:8765'));
      expect(n, contains('Tailscale is connected on this device'));
      expect(n, isNot(contains('Wi-Fi address')));
    });

    test('too early: a slow link is not called unreachable', () {
      expect(notice(elapsed: const Duration(seconds: 44)), isNull);
      expect(notice(elapsed: const Duration(seconds: 45)), isNotNull);
    });

    test('no reconciliation marker: the server is simply working', () {
      expect(notice(error: null), isNull);
      expect(notice(error: 'sidecar_sync_pending: x'), isNull);
    });

    test('not in progress: never', () {
      expect(notice(inProgress: false), isNull);
    });

    test('no start time: nothing to measure, nothing to say', () {
      expect(
        unreachableServerNotice(
          inProgress: true,
          transcriptionError: 'reconciliation_pending: x',
          startedAt: null,
          now: t0,
          baseUrl: lan,
        ),
        isNull,
      );
    });
  });

  group('address helpers', () {
    test('displayHost strips scheme and path', () {
      expect(displayHost('http://192.168.1.206:8765'), '192.168.1.206:8765');
      expect(displayHost('http://homelab.lan'), 'homelab.lan');
      expect(displayHost('garbage'), 'garbage');
    });

    test('isLanAddress: RFC 1918 only', () {
      expect(isLanAddress('http://192.168.1.206:8765'), isTrue);
      expect(isLanAddress('http://10.0.0.5:8765'), isTrue);
      expect(isLanAddress('http://172.20.0.1:8765'), isTrue);
      expect(isLanAddress('http://100.88.126.107:8765'), isFalse);
      expect(isLanAddress('http://33.27.147.9:8765'), isFalse);
      expect(isLanAddress('http://homelab.lan:8765'), isFalse);
    });
  });
}
