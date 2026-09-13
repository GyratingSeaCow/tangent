// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../models/api_exception.dart';
import '../models/server_info.dart';

/// Sentinel exception for when SSE fails — triggers polling fallback.
class _SseUnavailable implements Exception {
  final String reason;
  const _SseUnavailable(this.reason);
  @override
  String toString() => '_SseUnavailable: $reason';
}

/// Job status events from the SSE stream.
class JobEvent {
  final String status; // 'queued' | 'running' | 'completed' | 'failed' | 'error' | 'timeout'
  final Map<String, dynamic> data;

  const JobEvent(this.status, this.data);
}

class TranscriptionClient {
  final Dio _dio;
  final String _baseUrl;

  TranscriptionClient({required String baseUrl, String? token})
      : _baseUrl = baseUrl,
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          contentType: 'application/json',
          headers: token != null ? {'Authorization': 'Bearer $token'} : {},
          validateStatus: (status) => status != null && status < 500,
        ));

  TranscriptionClient.forTesting({required Dio dio, required String baseUrl})
      : _dio = dio,
        _baseUrl = baseUrl;

  String get baseUrl => _baseUrl;

  Future<ServerInfo> getServerInfo() async {
    final resp = await _fetch('/v1/server/info');
    return ServerInfo.fromJson(resp);
  }

  /// Create a dump record (metadata only). Audio is uploaded separately.
  Future<String> createDump({
    required String id,
    required String mode,
    required int durationSeconds,
    required String title,
    required DateTime createdAt,
  }) async {
    final resp = await _fetch(
      '/v1/dumps',
      method: 'POST',
      data: {
        'id': id,
        'mode': mode,
        'duration_seconds': durationSeconds,
        'title': title,
        'created_at': createdAt.toUtc().toIso8601String(),
      },
    );
    return resp['id'] as String;
  }

  /// Upload audio for an existing dump. 204 No Content on success.
  Future<void> uploadAudio({
    required String dumpId,
    required List<int> audioBytes,
    String filename = 'recording.opus',
    String mimeType = 'audio/ogg',
  }) async {
    final form = FormData.fromMap({
      'audio': MultipartFile.fromBytes(
        audioBytes,
        filename: filename,
        contentType: DioMediaType.parse(mimeType),
      ),
    });
    // Same bug as _fetch: _dio.fetch(RequestOptions(path: ...)) drops baseUrl.
    // Use _dio.post() so the path is correctly joined with baseUrl.
    final resp = await _dio.post<dynamic>(
      '/v1/dumps/$dumpId/audio',
      data: form,
    );
    if (resp.statusCode != 204) {
      _checkStatus(resp);
      throw ApiException(
        statusCode: resp.statusCode ?? 0,
        code: 'upload_failed',
        message: 'Audio upload returned ${resp.statusCode}',
      );
    }
  }

  /// Enqueue a transcription job on the server.
  Future<String> enqueueTranscription(
    String dumpId, {
    String model = 'large-v3',
  }) async {
    final resp = await _fetch(
      '/v1/dumps/$dumpId/transcribe',
      method: 'POST',
      data: {'model': model},
    );
    return resp['id'] as String;
  }

  /// Stream job status via Server-Sent Events.
  ///
  /// Yields events as the server emits them. The server sends:
  /// - `queued` → `running` → `completed` (with `transcript`)
  /// - or `queued` → `running` → `failed` (with `error`)
  /// - `error` if the job disappears mid-stream
  /// - `timeout` if no terminal event within 30 minutes
  ///
  /// Falls back to polling if SSE is unavailable (e.g. corporate proxies
  /// that buffer/close SSE connections).
  Stream<JobEvent> streamJob(String jobId, {Duration maxWait = const Duration(minutes: 30)}) async* {
    try {
      await for (final evt in _sseStream(jobId, maxWait: maxWait)) {
        yield evt;
      }
    } on _SseUnavailable {
      // Fallback to polling for environments that don't support SSE.
      yield* _pollJob(jobId);
    }
  }

  Stream<JobEvent> _sseStream(String jobId,
      {required Duration maxWait}) async* {
    final uri = Uri.parse('$_baseUrl/v1/jobs/$jobId/stream');
    final request = await HttpClient().getUrl(uri);
    final authHeader = _dio.options.headers['Authorization'];
    if (authHeader is String) {
      request.headers.set('Authorization', authHeader);
    }
    request.headers.set('Accept', 'text/event-stream');
    request.headers.set('Cache-Control', 'no-cache');

    final response = await request.close();
    if (response.statusCode != 200) {
      throw _SseUnavailable('SSE returned ${response.statusCode}');
    }

    final events = <String, String>{};
    String? currentEvent;
    final lines = response
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines.timeout(maxWait)) {
      if (line.isEmpty) {
        // End of event.
        if (events.isNotEmpty) {
          final ev = currentEvent ?? 'message';
          final data = events['data'] ?? '';
          Map<String, dynamic> parsed;
          try {
            parsed = jsonDecode(data) as Map<String, dynamic>;
          } catch (_) {
            parsed = {'raw': data};
          }
          yield JobEvent(ev, parsed);
          events.clear();
          currentEvent = null;
        }
        continue;
      }
      if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        events['data'] = (events['data'] ?? '') + line.substring(5).trim();
      }
      // Ignore comments (lines starting with ':') and other fields.
    }
  }

  Stream<JobEvent> _pollJob(String jobId) async* {
    for (var i = 0; i < 1800; i++) {
      await Future.delayed(const Duration(seconds: 2));
      try {
        final resp = await _fetch('/v1/jobs/$jobId');
        final status = resp['status'] as String;
        yield JobEvent(status, resp);
        if (status == 'completed' || status == 'failed') return;
      } catch (_) {
        // Ignore transient errors during poll.
      }
    }
    yield const JobEvent('timeout', {});
  }

  Future<Map<String, dynamic>> _fetch(
    String path, {
    String method = 'GET',
    Object? data,
  }) async {
    // NOTE: We MUST use the typed convenience methods (_dio.get, _dio.post,
    // etc.) instead of _dio.fetch(RequestOptions(path: ...)). The latter was
    // observed to dispatch with the raw `path` as the URI and ignore
    // baseUrl, producing "Invalid argument(s): No host specified in URI".
    final Response<dynamic> resp;
    switch (method) {
      case 'POST':
        resp = await _dio.post<dynamic>(path, data: data);
      case 'PATCH':
        resp = await _dio.patch<dynamic>(path, data: data);
      case 'DELETE':
        resp = await _dio.delete<dynamic>(path, data: data);
      case 'GET':
      default:
        resp = await _dio.get<dynamic>(path);
    }
    _checkStatus(resp);
    return (resp.data as Map<String, dynamic>?) ?? {};
  }

  void _checkStatus(Response<dynamic> resp) {
    final status = resp.statusCode ?? 0;
    if (status >= 400) {
      final body = resp.data;
      if (body is Map && body['error'] is Map) {
        throw ApiException(
          statusCode: status,
          code: body['error']['code'] as String,
          message: body['error']['message'] as String,
        );
      }
      throw ApiException(
        statusCode: status,
        code: 'http_error',
        message: 'HTTP $status',
      );
    }
  }
}