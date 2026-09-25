// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/server_discovery.dart';

void main() {
  group('subnetHosts', () {
    test('enumerates the /24 including self, excluding network/broadcast',
        () {
      final List<String> hosts = subnetHosts('192.168.1.57');
      expect(hosts, hasLength(254));
      expect(
        hosts,
        contains('192.168.1.57'),
        reason: 'self is swept: a desktop hosting its own server answers '
            'on its LAN address (bench, 2026-09-25)',
      );
      expect(hosts, isNot(contains('192.168.1.0')), reason: 'network addr');
      expect(hosts, isNot(contains('192.168.1.255')), reason: 'broadcast');
      expect(hosts.first, '192.168.1.1');
      expect(hosts.last, '192.168.1.254');
    });

    test('garbage input yields no hosts rather than a crash', () {
      expect(subnetHosts('not-an-ip'), isEmpty);
      expect(subnetHosts(''), isEmpty);
    });
  });

  group('sweep', () {
    test('finds servers and reports them live via onFound', () async {
      final ServerDiscovery discovery = ServerDiscovery(
        probe: (String host, int port) async {
          if (host == '10.0.0.7' && port == 8765) {
            return const ProbeResult.tangent(
              name: 'Homelab',
              version: '1.2.0',
              requiresAuth: true,
            );
          }
          return const ProbeResult.notTangent();
        },
      );

      final List<DiscoveredServer> live = <DiscoveredServer>[];
      final List<DiscoveredServer> found = await discovery.sweep(
        selfAddress: '10.0.0.5',
        onFound: live.add,
      );

      expect(found, hasLength(1));
      expect(found.single.host, '10.0.0.7');
      expect(found.single.port, 8765);
      expect(found.single.name, 'Homelab');
      expect(found.single.baseUrl, 'http://10.0.0.7:8765');
      expect(live, found, reason: 'live callback must mirror the result');
    });

    test('a host answering the first port is not probed on the second',
        () async {
      final List<String> probes = <String>[];
      final ServerDiscovery discovery = ServerDiscovery(
        probe: (String host, int port) async {
          probes.add('$host:$port');
          if (host == '10.0.0.20') {
            return const ProbeResult.tangent(
              name: 'X',
              version: '1',
              requiresAuth: true,
            );
          }
          return const ProbeResult.notTangent();
        },
      );

      await discovery.sweep(selfAddress: '10.0.0.5');
      expect(probes, contains('10.0.0.20:8765'));
      expect(
        probes,
        isNot(contains('10.0.0.20:8000')),
        reason: 'one server must yield one entry, not one per port',
      );
      // A dead host IS probed on both ports.
      expect(probes, contains('10.0.0.21:8765'));
      expect(probes, contains('10.0.0.21:8000'));
    });

    test('cancel stops probing the remaining hosts', () async {
      int probeCount = 0;
      late ServerDiscovery discovery;
      discovery = ServerDiscovery(
        probe: (String host, int port) async {
          probeCount++;
          if (probeCount == 5) discovery.cancel();
          return const ProbeResult.notTangent();
        },
      );

      await discovery.sweep(selfAddress: '10.0.0.5');
      // One chunk (32 hosts x 2 ports = up to 64) may complete after cancel
      // fires mid-chunk, but the remaining ~220 hosts must not be probed.
      expect(probeCount, lessThan(70));
    });

    test('finds multiple servers across the subnet', () async {
      final ServerDiscovery discovery = ServerDiscovery(
        probe: (String host, int port) async {
          if ((host == '10.0.0.7' || host == '10.0.0.200') && port == 8765) {
            return ProbeResult.tangent(
              name: 'S-$host',
              version: '1',
              requiresAuth: true,
            );
          }
          return const ProbeResult.notTangent();
        },
      );

      final List<DiscoveredServer> found =
          await discovery.sweep(selfAddress: '10.0.0.5');
      expect(found, hasLength(2));
    });
  });
}
