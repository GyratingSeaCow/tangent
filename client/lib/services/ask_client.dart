// SPDX-License-Identifier: AGPL-3.0-or-later
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/api_exception.dart';

@immutable
final class AskSource {
  const AskSource({
    required this.entityType,
    required this.entityId,
    required this.snippet,
    this.seekSeconds,
  });

  factory AskSource.fromJson(Map<String, dynamic> json) => AskSource(
        entityType: json['entity_type'] as String,
        entityId: json['entity_id'] as String,
        snippet: json['snippet'] as String,
        seekSeconds: (json['seek_seconds'] as num?)?.toDouble(),
      );

  final String entityType;
  final String entityId;
  final String snippet;
  final double? seekSeconds;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'entity_type': entityType,
        'entity_id': entityId,
        'snippet': snippet,
        'seek_seconds': seekSeconds,
      };
}

@immutable
final class AskResponse {
  const AskResponse({required this.answer, required this.sources});

  factory AskResponse.fromJson(Map<String, dynamic> json) => AskResponse(
        answer: json['answer'] as String,
        sources: (json['sources'] as List<dynamic>)
            .map(
              (dynamic item) =>
                  AskSource.fromJson((item as Map).cast<String, dynamic>()),
            )
            .toList(growable: false),
      );

  final String answer;
  final List<AskSource> sources;
}

class AskClient {
  AskClient({required String baseUrl, String? token})
      : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            contentType: 'application/json',
            headers: token != null
                ? <String, String>{'Authorization': 'Bearer $token'}
                : <String, String>{},
            validateStatus: (int? status) => status != null && status < 500,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );

  AskClient.forTesting({required Dio dio}) : _dio = dio;
  final Dio _dio;

  Future<AskResponse> ask(String question) async {
    final Response<dynamic> response = await _dio.post<dynamic>(
      '/v1/ask',
      data: <String, dynamic>{'question': question},
    );
    final int status = response.statusCode ?? 0;
    if (status >= 400) {
      final Object? data = response.data;
      throw ApiException(
        statusCode: status,
        code: 'http_error',
        message: data is Map && data['detail'] is String
            ? data['detail'] as String
            : 'HTTP $status',
      );
    }
    return AskResponse.fromJson(
      (response.data as Map).cast<String, dynamic>(),
    );
  }
}
