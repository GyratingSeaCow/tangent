// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../models/api_exception.dart';
import '../models/server_info.dart';

HttpClient _newHttpClient() => HttpClient();
DateTime _utcNow() => DateTime.now().toUtc();
Future<void> _delayFor(Duration duration) => Future<void>.delayed(duration);

/// Sentinel exception for when SSE fails — triggers polling fallback.
class _SseUnavailable implements Exception {
  final String reason;
  const _SseUnavailable(this.reason);
  @override
  String toString() => '_SseUnavailable: $reason';
}

/// Job status events from the SSE stream.
class JobEvent {
  final String
      status; // 'queued' | 'running' | 'completed' | 'failed' | 'error' | 'timeout'
  final Map<String, dynamic> data;

  const JobEvent(this.status, this.data);
}

final class TranscriptionJobSnapshot {
  const TranscriptionJobSnapshot({
    required this.id,
    required this.requestId,
    required this.dumpId,
    required this.status,
    required this.model,
    this.startedAt,
    this.completedAt,
    this.transcript,
    this.error,
  });

  final String id;
  final String requestId;
  final String dumpId;
  final String status;
  final String model;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? transcript;
  final String? error;
}

class TranscriptionClient {
  final Dio _dio;
  final String _baseUrl;
  final HttpClient Function() _httpClientFactory;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  TranscriptionClient({required String baseUrl, String? token})
      : _baseUrl = baseUrl,
        _httpClientFactory = _newHttpClient,
        _now = _utcNow,
        _delay = _delayFor,
        _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            contentType: 'application/json',
            headers: token != null ? {'Authorization': 'Bearer $token'} : {},
            validateStatus: (status) => status != null && status < 500,
          ),
        );

  TranscriptionClient.forTesting({
    required Dio dio,
    required String baseUrl,
    HttpClient Function()? httpClientFactory,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  })  : _httpClientFactory = httpClientFactory ?? _newHttpClient,
        _now = now ?? _utcNow,
        _delay = delay ?? _delayFor,
        _dio = dio,
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
  Future<TranscriptionJobSnapshot> enqueueTranscription(
    String dumpId, {
    required String requestId,
    String model = 'large-v3',
  }) async {
    final resp = await _fetch(
      '/v1/dumps/$dumpId/transcribe',
      method: 'POST',
      data: {'model': model, 'request_id': requestId},
    );
    return _snapshotFromJson(resp);
  }

  TranscriptionJobSnapshot _snapshotFromJson(Map<String, dynamic> json) {
    DateTime? timestamp(String key) {
      final value = json[key];
      return value is String ? DateTime.tryParse(value)?.toUtc() : null;
    }

    return TranscriptionJobSnapshot(
      id: json['id'] as String,
      requestId: json['request_id'] as String,
      dumpId: json['dump_id'] as String,
      status: json['status'] as String,
      model: json['model'] as String,
      startedAt: timestamp('started_at'),
      completedAt: timestamp('completed_at'),
      transcript: json['result_transcript'] as String?,
      error: json['error'] as String?,
    );
  }

  /// Fetches the latest durable snapshot for a transcription job.
  Future<TranscriptionJobSnapshot> getJob(String jobId) async {
    final response = await _fetch('/v1/jobs/$jobId');
    return _snapshotFromJson(response);
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
  Stream<JobEvent> streamJob(
    String jobId, {
    Duration maxWait = const Duration(minutes: 30),
  }) async* {
    final deadline = _now().add(maxWait);
    try {
      var reachedTerminal = false;
      await for (final evt in _sseStream(jobId, deadline: deadline)) {
        yield evt;
        reachedTerminal = evt.status == 'completed' || evt.status == 'failed';
      }
      if (!reachedTerminal) {
        throw const _SseUnavailable('SSE ended before terminal event');
      }
    } on _SseUnavailable {
      // Fallback to polling for environments that don't support SSE.
      yield* _pollJob(jobId, deadline: deadline);
    } on SocketException {
      yield* _pollJob(jobId, deadline: deadline);
    } on TimeoutException {
      yield* _pollJob(jobId, deadline: deadline);
    }
  }

  Stream<JobEvent> _sseStream(
    String jobId, {
    required DateTime deadline,
  }) async* {
    final uri = Uri.parse('$_baseUrl/v1/jobs/$jobId/stream');
    final httpClient = _httpClientFactory();
    StreamIterator<String>? iterator;
    try {
      final request =
          await httpClient.getUrl(uri).timeout(_remaining(deadline));
      final authHeader = _dio.options.headers['Authorization'];
      if (authHeader is String) {
        request.headers.set('Authorization', authHeader);
      }
      request.headers.set('Accept', 'text/event-stream');
      request.headers.set('Cache-Control', 'no-cache');

      final response = await request.close().timeout(_remaining(deadline));
      if (response.statusCode != 200) {
        throw _SseUnavailable('SSE returned ${response.statusCode}');
      }

      final events = <String, String>{};
      String? currentEvent;
      final lines =
          response.transform(utf8.decoder).transform(const LineSplitter());

      iterator = StreamIterator<String>(lines);
      while (await iterator.moveNext().timeout(_remaining(deadline))) {
        final line = iterator.current;
        if (line.isEmpty) {
          if (events.isNotEmpty) {
            final ev = currentEvent ?? 'message';
            final data = events['data'] ?? '';
            Map<String, dynamic> parsed;
            try {
              parsed = jsonDecode(data) as Map<String, dynamic>;
            } catch (_) {
              parsed = _decodePythonMap(data) ?? {'raw': data};
            }
            yield JobEvent(ev, parsed);
            if (ev == 'completed' || ev == 'failed') return;
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
      }
    } finally {
      await iterator?.cancel();
      httpClient.close(force: true);
    }
  }

  /// Decodes the Python `str(dict)` payload currently emitted by the server's
  /// SSE endpoint without evaluating arbitrary input.
  Map<String, dynamic>? _decodePythonMap(String source) {
    final fields = RegExp(
      r'''['"]([^'"]+)['"]\s*:\s*(None|True|False|-?\d+(?:\.\d+)?|'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")''',
    ).allMatches(source);
    final result = <String, dynamic>{};
    for (final field in fields) {
      final key = field.group(1)!;
      final value = field.group(2)!;
      result[key] = switch (value) {
        'None' => null,
        'True' => true,
        'False' => false,
        _ when value.startsWith("'") || value.startsWith('"') =>
          _decodePythonString(value),
        _ => num.tryParse(value) ?? value,
      };
    }
    return result.isEmpty ? null : result;
  }

  String _decodePythonString(String literal) {
    final source = literal.substring(1, literal.length - 1);
    final output = StringBuffer();
    for (var i = 0; i < source.length; i++) {
      final character = source[i];
      if (character != '\\' || i + 1 >= source.length) {
        output.write(character);
        continue;
      }
      final escaped = source[++i];
      output.write(
        switch (escaped) {
          'n' => String.fromCharCode(10),
          'r' => String.fromCharCode(13),
          't' => String.fromCharCode(9),
          'b' => String.fromCharCode(8),
          'f' => String.fromCharCode(12),
          _ => escaped,
        },
      );
    }
    return output.toString();
  }

  Stream<JobEvent> _pollJob(
    String jobId, {
    required DateTime deadline,
  }) async* {
    while (_now().isBefore(deadline)) {
      try {
        final snapshot = await getJob(jobId).timeout(_remaining(deadline));
        final data = <String, dynamic>{
          'status': snapshot.status,
          'request_id': snapshot.requestId,
          'transcript': snapshot.transcript,
          'error': snapshot.error,
        };
        yield JobEvent(snapshot.status, data);
        if (snapshot.status == 'completed' || snapshot.status == 'failed') {
          return;
        }
      } on TimeoutException {
        break;
      } catch (error) {
        if (!_isTransientPollingError(error)) rethrow;
      }
      if (!_now().isBefore(deadline)) break;
      final remaining = deadline.difference(_now());
      await _delay(
        remaining < const Duration(seconds: 2)
            ? remaining
            : const Duration(seconds: 2),
      );
    }
    yield const JobEvent('timeout', {});
  }

  Duration _remaining(DateTime deadline) {
    final remaining = deadline.difference(_now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Transcription job deadline reached');
    }
    return remaining;
  }

  bool _isTransientPollingError(Object error) {
    if (error is SocketException) return true;
    if (error is ApiException) {
      return error.statusCode == 408 ||
          error.statusCode == 429 ||
          error.statusCode >= 500;
    }
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (error.type == DioExceptionType.badResponse) {
        return statusCode == 408 ||
            statusCode == 429 ||
            (statusCode ?? 0) >= 500;
      }
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.connectionError =>
          true,
        DioExceptionType.unknown when error.error is SocketException => true,
        _ => false,
      };
    }
    return false;
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
      if (status == 422 && body is Map) {
        final detail = body['detail'];
        if (detail is String &&
            RegExp(
              r"^No audio file uploaded for dump '[^']+'\. POST the audio to /v1/dumps/\{id\}/audio first\.$",
            ).hasMatch(detail)) {
          throw ApiException(
            statusCode: 422,
            code: 'missing_audio',
            message: detail,
          );
        }
      }
      if (status == 409 &&
          body is Map &&
          body['detail'] == 'request_id conflict') {
        throw const ApiException(
          statusCode: 409,
          code: 'request_id_conflict',
          message: 'request_id conflict',
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
