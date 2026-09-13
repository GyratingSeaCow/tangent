// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/api_exception.dart';
import '../models/server_info.dart';

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
    final resp = await _dio.fetch<dynamic>(
      RequestOptions(
        path: '/v1/dumps/$dumpId/audio',
        method: 'POST',
        data: form,
      ),
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

  /// Stream job status. v1 polls; SSE upgrade is Phase 2.5.
  Stream<JobEvent> streamJob(String jobId) async* {
    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(seconds: 2));
      final resp = await _fetch('/v1/jobs/$jobId');
      final status = resp['status'] as String;
      yield JobEvent(status, resp);
      if (status == 'completed' || status == 'failed') return;
    }
    yield const JobEvent('timeout', {});
  }

  Future<Map<String, dynamic>> _fetch(
    String path, {
    String method = 'GET',
    Object? data,
  }) async {
    final resp = await _dio.fetch<Map<String, dynamic>>(
      RequestOptions(path: path, method: method, data: data),
    );
    _checkStatus(resp);
    return resp.data!;
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