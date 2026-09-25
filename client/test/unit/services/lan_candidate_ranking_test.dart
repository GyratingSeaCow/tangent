// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/lan_candidate_ranking.dart';

void main() {
  group('pickSweepAddress', () {
    // The exact interface set that broke discovery on Jeff's bench
    // (2026-09-25): Tailscale + two Hyper-V/WSL host NICs beside the
    // real LAN. The LAN must win in ANY enumeration order.
    const bench = <LanCandidate>[
      LanCandidate('Tailscale', '100.88.126.107'),
      LanCandidate('vEthernet (WSL (Hyper-V firewall))', '172.29.32.1'),
      LanCandidate('vEthernet (Default Switch)', '172.25.96.1'),
      LanCandidate('Ethernet', '192.168.1.206'),
    ];

    test('bench set: physical LAN wins', () {
      expect(pickSweepAddress(bench), '192.168.1.206');
    });

    test('bench set: wins regardless of enumeration order', () {
      for (var start = 0; start < bench.length; start++) {
        final rotated = <LanCandidate>[
          ...bench.sublist(start),
          ...bench.sublist(0, start),
        ];
        expect(
          pickSweepAddress(rotated),
          '192.168.1.206',
          reason: 'rotation starting at $start',
        );
      }
    });

    test('CGNAT (Tailscale) is never swept, even when alone', () {
      expect(
        pickSweepAddress(
          const [LanCandidate('Tailscale', '100.88.126.107')],
        ),
        isNull,
      );
    });

    test('100.x outside 100.64/10 is not treated as CGNAT', () {
      expect(isCgnat('100.63.0.1'), isFalse);
      expect(isCgnat('100.128.0.1'), isFalse);
      expect(isCgnat('100.64.0.1'), isTrue);
      expect(isCgnat('100.127.255.254'), isTrue);
    });

    test('10.x LAN beats virtual-named 192.168 adapter', () {
      expect(
        pickSweepAddress(const [
          LanCandidate('vEthernet (Default Switch)', '192.168.144.1'),
          LanCandidate('eth0', '10.0.0.5'),
        ]),
        '10.0.0.5',
      );
    });

    test('plain 172.16/12 is a last resort but still sweepable', () {
      expect(
        pickSweepAddress(
          const [LanCandidate('Ethernet 2', '172.20.1.10')],
        ),
        '172.20.1.10',
      );
    });

    test('empty input → null (no sweep)', () {
      expect(pickSweepAddress(const []), isNull);
    });

    test('phone-like single interface still works', () {
      expect(
        pickSweepAddress(const [LanCandidate('wlan0', '192.168.1.42')]),
        '192.168.1.42',
      );
    });
  });
}
