// SPDX-License-Identifier: AGPL-3.0-or-later
/// Client for the server's OCR environment endpoints (Task 2).
///
/// The heavy handwriting-OCR environment does NOT ship in the base server
/// container: the server installs it on demand into a persistent venv, and
/// these four calls are how the Settings wizard drives that — check what the
/// server can do, kick off an install, watch it, or tear the whole thing
/// down again (which also deletes the search index).
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/api_exception.dart';

/// GET /v1/ocr/capability — what the server could install and what it has.
@immutable
final class OcrCapability {
  const OcrCapability({
    required this.installed,
    required this.flavour,
    required this.gpuVisible,
    required this.diskFreeBytes,
    required this.installRunning,
  });

  factory OcrCapability.fromJson(Map<String, dynamic> json) => OcrCapability(
        installed: json['installed'] == true,
        flavour: json['flavour'] as String?,
        gpuVisible: json['gpu_visible'] == true,
        diskFreeBytes: (json['disk_free_bytes'] as num?)?.toInt() ?? 0,
        installRunning: json['install_running'] == true,
      );

  final bool installed;

  /// 'gpu' | 'cpu' when installed, null on a bare server.
  ///
  /// Both flavours run the same trocr-base model — 'gpu' means
  /// CUDA-accelerated indexing, not different recognition.
  final String? flavour;
  final bool gpuVisible;
  final int diskFreeBytes;
  final bool installRunning;
}

/// GET /v1/ocr/install/progress — where the running (or finished) install is.
@immutable
final class OcrInstallProgress {
  const OcrInstallProgress({
    required this.phase,
    required this.percent,
    required this.detail,
  });

  factory OcrInstallProgress.fromJson(Map<String, dynamic> json) =>
      OcrInstallProgress(
        phase: json['phase'] as String? ?? 'idle',
        percent: (json['percent'] as num?)?.toInt() ?? 0,
        detail: json['detail'] as String? ?? '',
      );

  /// 'idle' | 'venv' | 'torch' | 'transformers' | 'weights' | 'verify' |
  /// 'done' | 'failed'.
  final String phase;
  final int percent;
  final String detail;
}

/// Talks to /v1/ocr/* with the same Dio conventions as [TranscriptionClient]:
/// bearer token, sub-500 statuses surfaced as [ApiException] via _checkStatus.
class OcrSettingsClient {
  OcrSettingsClient({required String baseUrl, String? token})
      : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            contentType: 'application/json',
            headers: token != null ? {'Authorization': 'Bearer $token'} : {},
            validateStatus: (status) => status != null && status < 500,
            // Same transport deadlines as the transcription client: a dead
            // route must FAIL, not wedge the Settings screen.
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );

  OcrSettingsClient.forTesting({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// The server this client talks to. Mirrors [TranscriptionClient.baseUrl];
  /// lets a test prove the provider rebuilt against a new server rather than
  /// handing back a cached client pointed at the old one.
  String get baseUrl => _dio.options.baseUrl;

  /// The Authorization header this client will send, or null if it has none.
  ///
  /// Exposed so a test can prove the stored token actually reaches the
  /// request options: asserting [baseUrl] alone passes even when the token
  /// is dropped, and every /v1/ocr/* call would then 401 behind a UI that
  /// just shows a dead toggle.
  String? get authorizationHeader =>
      _dio.options.headers['Authorization'] as String?;

  Future<OcrCapability> getCapability() async {
    final resp = await _dio.get<dynamic>('/v1/ocr/capability');
    _checkStatus(resp);
    return OcrCapability.fromJson(
      (resp.data as Map<String, dynamic>?) ?? const {},
    );
  }

  /// POST /v1/ocr/install — a 202 means the background install started.
  /// A second install while one runs is a 409 [ApiException].
  Future<void> startInstall({required String flavour}) async {
    final resp = await _dio.post<dynamic>(
      '/v1/ocr/install',
      data: <String, dynamic>{'flavour': flavour},
    );
    _checkStatus(resp);
  }

  /// Non-blocking; safe to poll every couple of seconds while installing.
  Future<OcrInstallProgress> getInstallProgress() async {
    final resp = await _dio.get<dynamic>('/v1/ocr/install/progress');
    _checkStatus(resp);
    return OcrInstallProgress.fromJson(
      (resp.data as Map<String, dynamic>?) ?? const {},
    );
  }

  /// Deletes the OCR venv + model weights AND drops the handwriting search
  /// index server-side. The caller owns confirming that with the user.
  Future<void> uninstall() async {
    final resp = await _dio.post<dynamic>('/v1/ocr/uninstall');
    _checkStatus(resp);
  }

  void _checkStatus(Response<dynamic> resp) {
    final int status = resp.statusCode ?? 0;
    if (status < 400) return;
    final Object? body = resp.data;
    if (body is Map && body['error'] is Map) {
      throw ApiException(
        statusCode: status,
        code: body['error']['code'] as String,
        message: body['error']['message'] as String,
      );
    }
    // FastAPI's plain HTTPException shape ({'detail': '...'}): the detail is
    // exactly what the user needs to see ("an install is already running").
    if (body is Map && body['detail'] is String) {
      throw ApiException(
        statusCode: status,
        code: 'http_error',
        message: body['detail'] as String,
      );
    }
    throw ApiException(
      statusCode: status,
      code: 'http_error',
      message: 'HTTP $status',
    );
  }
}
