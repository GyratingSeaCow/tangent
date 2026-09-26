// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

enum ConnectivityStatus { wifi, mobile, offline, unknown }

extension ConnectivityStatusX on ConnectivityStatus {
  bool get isOnline =>
      this == ConnectivityStatus.wifi || this == ConnectivityStatus.mobile;
}

/// Collapses the platform's transport list to one status.
///
/// The list is scanned, not just its head: with a VPN up Android reports
/// `[vpn, mobile]` (or `[vpn, wifi]`), and inspecting only `first` turned
/// the VPN into `unknown` — which read as offline and made the download
/// gate refuse 'No connection' on the one network configuration that can
/// actually reach the self-hosted server (Tailscale). Wi-Fi wins when
/// several transports are up because that is where Android routes; a bare
/// `[vpn]` with no listed underlay is treated as mobile-grade so the
/// wifi-only preference stays conservative about spending cellular data.
ConnectivityStatus statusFromResults(List<ConnectivityResult> results) {
  if (results.isEmpty) return ConnectivityStatus.unknown;
  // Ethernet ranks with wifi, not mobile: the wifi-only preference guards
  // cellular data, and a wired desktop (the Windows/Linux builds) is the
  // least metered link there is. Mapping it to `mobile` made the default
  // setting refuse every audio download on a cabled PC.
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return ConnectivityStatus.wifi;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return ConnectivityStatus.mobile;
  }
  if (results.contains(ConnectivityResult.vpn)) {
    return ConnectivityStatus.mobile;
  }
  if (results.contains(ConnectivityResult.none)) {
    return ConnectivityStatus.offline;
  }
  return ConnectivityStatus.unknown;
}

class ConnectivityService {
  final Connectivity _connectivity;

  ConnectivityService({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  Stream<ConnectivityStatus> get statusStream {
    return _connectivity.onConnectivityChanged.map(statusFromResults);
  }

  Future<ConnectivityStatus> currentStatus() async {
    final results = await _connectivity.checkConnectivity();
    return statusFromResults(results);
  }
}
