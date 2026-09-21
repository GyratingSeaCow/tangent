// SPDX-License-Identifier: AGPL-3.0-or-later
/// One pending pairing as served by GET /v1/pair/pending.
///
/// The wire mirrors the server's PairPendingEntry: pair_id, display_name,
/// platform, requested_at, code. There is NO expires_at on the wire — codes
/// live a fixed 120 s from the request (server PAIR_TTL_SECONDS), so expiry
/// is derived here. The server omits restart-orphaned pairings (their raw
/// code left with the old process), so every entry that arrives has a code.
library;

import 'package:flutter/foundation.dart';

/// Server-side pairing code lifetime (PAIR_TTL_SECONDS).
const Duration kPairCodeTtl = Duration(seconds: 120);

@immutable
class PairPendingEntry {
  const PairPendingEntry({
    required this.pairId,
    required this.displayName,
    required this.platform,
    required this.requestedAt,
    required this.code,
  });

  factory PairPendingEntry.fromJson(Map<String, dynamic> json) =>
      PairPendingEntry(
        pairId: json['pair_id'] as String? ?? '',
        displayName: json['display_name'] as String? ?? '',
        platform: json['platform'] as String? ?? '',
        requestedAt:
            DateTime.parse(json['requested_at'] as String).toUtc(),
        code: json['code'] as String? ?? '',
      );

  final String pairId;
  final String displayName;
  final String platform;
  final DateTime requestedAt;

  /// The raw 6-digit code — the whole point of the display.
  final String code;

  /// When the code stops being claimable: request time + the fixed TTL.
  DateTime get expiresAt => requestedAt.add(kPairCodeTtl);
}
