// SPDX-License-Identifier: AGPL-3.0-or-later
/// Client side of the pairing handshake.
///
/// Separate from [TranscriptionClient] on purpose: pairing runs BEFORE the
/// device has a token, against a server chosen seconds ago, and its error
/// codes are part of the protocol (401 = wrong code with attempts left,
/// 410 = expired/voided). The general client treats 4xx as exceptions;
/// here they are states the UI must narrate.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Opened pairing: show "enter the code from your server" while this lives.
@immutable
class PairingTicket {
  const PairingTicket({required this.pairId, required this.expiresAt});

  final String pairId;
  final DateTime expiresAt;
}

/// Terminal result of one claim attempt.
enum PairClaimStatus { success, wrongCode, gone, unreachable }

@immutable
class PairClaimResult {
  const PairClaimResult({
    required this.status,
    this.token,
    this.serverName,
    this.attemptsRemaining,
  });

  final PairClaimStatus status;
  final String? token;
  final String? serverName;
  final int? attemptsRemaining;
}

/// Talks to one server's /v1/pair endpoints.
class PairingClient {
  PairingClient({required String baseUrl, Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                contentType: 'application/json',
                // 4xx are protocol states here, not exceptions.
                validateStatus: (int? s) => s != null && s < 500,
                connectTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 5),
              ),
            );

  final Dio _dio;

  /// Opens a pairing. The server logs the 6-digit code; the response never
  /// carries it.
  Future<PairingTicket?> request({
    required String deviceId,
    required String displayName,
    required String platform,
  }) async {
    try {
      final Response<dynamic> resp = await _dio.post<dynamic>(
        '/v1/pair/request',
        data: <String, String>{
          'device_id': deviceId,
          'display_name': displayName,
          'platform': platform,
        },
      );
      if (resp.statusCode != 201) return null;
      final Map<String, dynamic> body = resp.data as Map<String, dynamic>;
      return PairingTicket(
        pairId: body['pair_id'] as String,
        expiresAt: DateTime.parse(body['expires_at'] as String),
      );
    } on DioException {
      return null;
    }
  }

  /// Trades the typed code for a token.
  Future<PairClaimResult> claim({
    required String pairId,
    required String code,
  }) async {
    try {
      final Response<dynamic> resp = await _dio.post<dynamic>(
        '/v1/pair/claim',
        data: <String, String>{'pair_id': pairId, 'code': code},
      );
      switch (resp.statusCode) {
        case 200:
          final Map<String, dynamic> body = resp.data as Map<String, dynamic>;
          return PairClaimResult(
            status: PairClaimStatus.success,
            token: body['token'] as String?,
            serverName: body['server_name'] as String?,
          );
        case 401:
          final Object? detail =
              (resp.data as Map<String, dynamic>?)?['detail'];
          return PairClaimResult(
            status: PairClaimStatus.wrongCode,
            attemptsRemaining: detail is Map<String, dynamic>
                ? (detail['attempts_remaining'] as num?)?.toInt()
                : null,
          );
        default:
          return const PairClaimResult(status: PairClaimStatus.gone);
      }
    } on DioException {
      return const PairClaimResult(status: PairClaimStatus.unreachable);
    }
  }
}
