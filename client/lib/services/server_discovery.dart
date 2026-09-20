// SPDX-License-Identifier: AGPL-3.0-or-later
/// Finds Tangent servers on the local network by sweeping the subnet.
///
/// The CLIENT does the discovering, per the design doc: the server usually
/// runs in a bridged Docker container whose mDNS announcements would carry an
/// unreachable container IP, so server-side advertisement is a dead end. A
/// parallel probe of the device's own /24 works identically for Docker,
/// bare-metal, and Raspberry Pi deployments and needs no server change.
///
/// The sweep only identifies hosts answering the UNAUTHENTICATED
/// `/v1/server/info/public` form with `service == "tangent"` — anything else
/// on the same port is silently skipped. Overlay networks (Tailscale) are
/// out of sweep range by nature; manual entry remains first-class.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One discovered server.
@immutable
class DiscoveredServer {
  const DiscoveredServer({
    required this.host,
    required this.port,
    required this.name,
    required this.version,
    required this.requiresAuth,
  });

  final String host;
  final int port;
  final String name;
  final String version;
  final bool requiresAuth;

  String get baseUrl => 'http://$host:$port';

  @override
  bool operator ==(Object other) =>
      other is DiscoveredServer && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// Result of probing one host:port.
@immutable
class ProbeResult {
  const ProbeResult.notTangent()
      : name = null,
        version = null,
        requiresAuth = false;

  const ProbeResult.tangent({
    required String this.name,
    required String this.version,
    required this.requiresAuth,
  });

  final String? name;
  final String? version;
  final bool requiresAuth;

  bool get isTangent => name != null;
}

/// Probes one candidate address. Injectable so tests exercise the sweep
/// logic without sockets.
typedef ServerProbe = Future<ProbeResult> Function(String host, int port);

/// Ports tried per host, in order: the documented compose default first,
/// then the bare uvicorn default.
const List<int> kDiscoveryPorts = <int>[8765, 8000];

/// Hosts probed concurrently. High enough to finish a /24 in seconds, low
/// enough not to look like a SYN flood to consumer routers.
const int kSweepConcurrency = 32;

/// Enumerates every OTHER host on [selfAddress]'s /24.
///
/// Only /24 (or narrower, treated as /24) is swept. Enumerating a /16 means
/// 65k probes — scanning behaviour, and minutes of runtime. On a wider
/// netmask the UI says so and offers manual entry instead.
List<String> subnetHosts(String selfAddress) {
  final List<String> parts = selfAddress.split('.');
  if (parts.length != 4) return const <String>[];
  final String prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
  return <String>[
    for (int i = 1; i < 255; i++)
      if ('$prefix.$i' != selfAddress) '$prefix.$i',
  ];
}

/// Sweeps the subnet for Tangent servers.
class ServerDiscovery {
  ServerDiscovery({ServerProbe? probe}) : _probe = probe ?? _httpProbe;

  final ServerProbe _probe;
  bool _cancelled = false;

  /// Stops an in-flight sweep. Already-found servers stay reported;
  /// remaining candidates are skipped.
  void cancel() => _cancelled = true;

  /// Probes every host on [selfAddress]'s /24 across [ports], reporting each
  /// find through [onFound] as it happens (a sheet that fills in live reads
  /// as scanning; a spinner that dumps a list at the end reads as hung).
  /// Returns all finds.
  Future<List<DiscoveredServer>> sweep({
    required String selfAddress,
    List<int> ports = kDiscoveryPorts,
    void Function(DiscoveredServer server)? onFound,
  }) async {
    _cancelled = false;
    final List<String> hosts = subnetHosts(selfAddress);
    final List<DiscoveredServer> found = <DiscoveredServer>[];
    if (hosts.isEmpty) return found;

    // Work queue: chunks of kSweepConcurrency, all ports for a host probed
    // sequentially (a host that answers 8765 is never also probed on 8000 —
    // one server, one entry).
    for (int start = 0; start < hosts.length; start += kSweepConcurrency) {
      if (_cancelled) break;
      final Iterable<String> chunk = hosts.skip(start).take(kSweepConcurrency);
      await Future.wait(
        chunk.map((String host) async {
          for (final int port in ports) {
            if (_cancelled) return;
            final ProbeResult result = await _probe(host, port);
            if (result.isTangent) {
              final DiscoveredServer server = DiscoveredServer(
                host: host,
                port: port,
                name: result.name!,
                version: result.version ?? '',
                requiresAuth: result.requiresAuth,
              );
              found.add(server);
              onFound?.call(server);
              return;
            }
          }
        }),
      );
    }
    return found;
  }

  /// The real probe: GET /v1/server/info/public with a short deadline.
  /// 750 ms is generous for a LAN round-trip and short enough that a full
  /// sweep of dead addresses stays under ~6 s at 32-way concurrency.
  static Future<ProbeResult> _httpProbe(String host, int port) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 750);
    try {
      final HttpClientRequest request = await client
          .getUrl(Uri.parse('http://$host:$port/v1/server/info/public'))
          .timeout(const Duration(milliseconds: 750));
      final HttpClientResponse response =
          await request.close().timeout(const Duration(milliseconds: 750));
      if (response.statusCode != 200) return const ProbeResult.notTangent();
      final String body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(milliseconds: 750));
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return const ProbeResult.notTangent();
      }
      if (decoded['service'] != 'tangent') {
        return const ProbeResult.notTangent();
      }
      return ProbeResult.tangent(
        name: decoded['name'] as String? ?? 'Tangent',
        version: decoded['version'] as String? ?? '',
        requiresAuth: decoded['requires_auth'] == true,
      );
    } on Object {
      // Timeouts, refusals, and non-JSON bodies all mean the same thing to
      // a sweep: not our server. Never let one weird host kill the scan.
      return const ProbeResult.notTangent();
    } finally {
      client.close(force: true);
    }
  }
}
