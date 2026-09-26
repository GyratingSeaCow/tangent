// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:connectivity_plus/connectivity_plus.dart';
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

  group('statusFromResults', () {
    test('single transports map directly', () {
      expect(
        statusFromResults([ConnectivityResult.wifi]),
        ConnectivityStatus.wifi,
      );
      expect(
        statusFromResults([ConnectivityResult.mobile]),
        ConnectivityStatus.mobile,
      );
      expect(
        statusFromResults([ConnectivityResult.none]),
        ConnectivityStatus.offline,
      );
      expect(statusFromResults(const []), ConnectivityStatus.unknown);
    });

    test('ethernet is unmetered: it satisfies the wifi-only preference', () {
      // A wired desktop reported [ethernet] (or [ethernet, vpn] with
      // Tailscale up) and was mapped to `mobile`, so the default wifi-only
      // setting refused every audio download with 'connect to Wi-Fi' — a
      // condition a wired PC can never meet. The preference exists to
      // protect cellular data; a cable is the opposite of metered.
      expect(
        statusFromResults([ConnectivityResult.ethernet]),
        ConnectivityStatus.wifi,
      );
      expect(
        statusFromResults(
          [ConnectivityResult.ethernet, ConnectivityResult.vpn],
        ),
        ConnectivityStatus.wifi,
      );
      expect(
        statusFromResults([ConnectivityResult.vpn, ConnectivityResult.mobile]),
        ConnectivityStatus.mobile,
        reason: 'a phone on cellular + VPN is still metered',
      );
    });

    test('a VPN entry must not mask the real transport underneath', () {
      // The Fold's exact production state: Tailscale up on cellular reports
      // [vpn, mobile]. Only result.first was inspected, so vpn -> unknown ->
      // the download gate refused 'No connection' on the ONE configuration
      // that can actually reach the server.
      expect(
        statusFromResults([ConnectivityResult.vpn, ConnectivityResult.mobile]),
        ConnectivityStatus.mobile,
      );
      expect(
        statusFromResults([ConnectivityResult.vpn, ConnectivityResult.wifi]),
        ConnectivityStatus.wifi,
      );
    });

    test('wifi wins over mobile when both are present', () {
      // Wi-Fi-only users care about which transport carries the bytes;
      // when both are up Android routes over Wi-Fi.
      expect(
        statusFromResults([ConnectivityResult.mobile, ConnectivityResult.wifi]),
        ConnectivityStatus.wifi,
      );
    });

    test('a VPN with no underlying transport listed is still online', () {
      // Some Android builds report only [vpn] while the tunnel is up. The
      // tunnel cannot exist without a transport, so treat it as mobile-grade
      // connectivity (the conservative choice for the wifi-only gate).
      expect(
        statusFromResults([ConnectivityResult.vpn]),
        ConnectivityStatus.mobile,
      );
    });
  });
}
