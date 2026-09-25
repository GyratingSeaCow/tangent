// SPDX-License-Identifier: AGPL-3.0-or-later
/// Picks which local IPv4 a server-discovery sweep should use.
///
/// Phones usually carry ONE candidate interface, so "first non-loopback
/// IPv4" worked on Android. Desktops do not: the Windows bench exposes
/// Tailscale (100.88.x, CGNAT) and Hyper-V/WSL host adapters (172.2x.x.1)
/// beside the real LAN NIC, and whichever enumerates first used to win —
/// sweeping the wrong /24 and finding nothing. This ranks candidates so
/// the physical-LAN address wins regardless of enumeration order.
library;

import 'dart:io';

/// One (interface name, address) candidate for the sweep.
class LanCandidate {
  const LanCandidate(this.interfaceName, this.address);

  final String interfaceName;
  final String address;
}

/// Interface-name fragments that mark a VIRTUAL adapter whose subnet is
/// not the physical LAN: WSL / Hyper-V ("vEthernet"), VirtualBox, VMware,
/// Docker, loopback tunnels. Matched case-insensitively.
const List<String> _virtualNameFragments = <String>[
  'wsl',
  'vethernet',
  'hyper-v',
  'virtualbox',
  'vmware',
  'docker',
  'loopback',
];

/// True when [address] parses as IPv4 inside `100.64.0.0/10` — Tailscale
/// and other CGNAT overlays. Reachable, but its /24 is not a LAN and must
/// never be swept.
bool isCgnat(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  if (a == null || b == null) return false;
  return a == 100 && b >= 64 && b <= 127;
}

bool _isRfc1918(String address) {
  final parts = address.split('.');
  if (parts.length != 4) return false;
  final a = int.tryParse(parts[0]);
  final b = int.tryParse(parts[1]);
  if (a == null || b == null) return false;
  if (a == 192 && b == 168) return true;
  if (a == 10) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  return false;
}

bool _looksVirtual(String interfaceName) {
  final lower = interfaceName.toLowerCase();
  return _virtualNameFragments.any(lower.contains);
}

/// Rank score for a candidate; LOWER is better. Returns null for
/// candidates that must never be swept (CGNAT — a /24 probe there is
/// meaningless and looks like scanning).
int? _rank(LanCandidate c) {
  if (isCgnat(c.address)) return null;
  if (!_isRfc1918(c.address)) return 40; // public/odd: last resort
  final virtual = _looksVirtual(c.interfaceName);
  final parts = c.address.split('.');
  final a = int.parse(parts[0]);
  // Physical-looking RFC1918 first. 192.168/16 and 10/8 are what home
  // and shop LANs actually use; 172.16/12 is overwhelmingly virtual
  // (WSL, Hyper-V, Docker) even when the adapter name doesn't say so.
  final base = switch (a) {
    192 => 0,
    10 => 10,
    _ => 30, // 172.16/12
  };
  return virtual ? base + 25 : base;
}

/// The address the sweep should use, or null when no candidate is
/// sweepable (Tailscale-only, cellular, airplane mode) — in which case
/// the caller shows the manual-entry hint, unchanged.
String? pickSweepAddress(Iterable<LanCandidate> candidates) {
  String? best;
  int? bestRank;
  for (final c in candidates) {
    final r = _rank(c);
    if (r == null) continue;
    // Strictly-less keeps the first seen on ties, making the choice
    // deterministic under any enumeration order for equal-rank NICs.
    if (bestRank == null || r < bestRank) {
      bestRank = r;
      best = c.address;
    }
  }
  return best;
}

/// Live enumeration → ranked pick. IO wrapper kept thin so tests drive
/// [pickSweepAddress] with fixture candidates directly.
Future<String?> rankedLocalIPv4() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    return pickSweepAddress(<LanCandidate>[
      for (final iface in interfaces)
        for (final addr in iface.addresses)
          if (!addr.isLoopback) LanCandidate(iface.name, addr.address),
    ]);
  } on Object {
    return null; // No address, no sweep.
  }
}
