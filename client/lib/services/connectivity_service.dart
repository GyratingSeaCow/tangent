// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

enum ConnectivityStatus { wifi, mobile, offline, unknown }

extension ConnectivityStatusX on ConnectivityStatus {
  bool get isOnline =>
      this == ConnectivityStatus.wifi || this == ConnectivityStatus.mobile;
}

class ConnectivityService {
  final Connectivity _connectivity;

  ConnectivityService({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  Stream<ConnectivityStatus> get statusStream {
    return _connectivity.onConnectivityChanged.map(_toStatus);
  }

  Future<ConnectivityStatus> currentStatus() async {
    final results = await _connectivity.checkConnectivity();
    return _toStatus(results);
  }

  ConnectivityStatus _toStatus(List<ConnectivityResult> results) {
    if (results.isEmpty) return ConnectivityStatus.unknown;
    final first = results.first;
    if (first == ConnectivityResult.wifi) return ConnectivityStatus.wifi;
    if (first == ConnectivityResult.mobile) return ConnectivityStatus.mobile;
    if (first == ConnectivityResult.none) return ConnectivityStatus.offline;
    return ConnectivityStatus.unknown;
  }
}