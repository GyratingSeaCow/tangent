// SPDX-License-Identifier: AGPL-3.0-or-later
/// Client for the server's Whisper model-selection endpoints (mirrors
/// [SummariesClient] for /v1/summaries/*).
///
/// Whisper weights are multi-gigabyte downloads that live on the user's
/// server, and until this existed the active model was frozen by
/// `TANGENT_WHISPER_MODEL` at container start with the weights fetched
/// silently on first use. These five calls are how the Settings section
/// drives the real thing instead: read the catalogue, switch the active
/// model, install a missing one, watch that install, and delete weights
/// the user no longer wants.
///
/// The three 409s are all DIFFERENT outcomes, so each gets its own type —
/// the section routes "not installed" into the install wizard, treats
/// "already running" as attach-and-watch (never an error), and reports
/// "cannot delete the active model" as a rule the user must work around.
/// String-matching the server's wording at each call site would put that
/// coupling in three places instead of one.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/api_exception.dart';

/// One row of GET /v1/transcription/models.
@immutable
final class WhisperModelInfo {
  const WhisperModelInfo({
    required this.name,
    required this.installed,
    required this.sizeBytesOnDisk,
    required this.approxDownloadBytes,
  });

  factory WhisperModelInfo.fromJson(Map<String, dynamic> json) =>
      WhisperModelInfo(
        name: json['name'] as String? ?? '',
        installed: json['installed'] == true,
        sizeBytesOnDisk: (json['size_bytes_on_disk'] as num?)?.toInt() ?? 0,
        approxDownloadBytes:
            (json['approx_download_bytes'] as num?)?.toInt() ?? 0,
      );

  final String name;

  /// True only when the weights are COMPLETE on the server — a partial
  /// download is not installed, so the badge never promises a model that
  /// would fail to load.
  final bool installed;

  /// What the installed weights occupy now; 0 when not installed.
  final int sizeBytesOnDisk;

  /// Approximate download size, from the server's static table. Used for
  /// the confirm dialog's "this downloads about N" copy, which is why it is
  /// present even for a model that is already installed.
  final int approxDownloadBytes;
}

/// GET /v1/transcription/models — the catalogue plus which one is active.
@immutable
final class WhisperModelCatalog {
  const WhisperModelCatalog({required this.active, required this.models});

  factory WhisperModelCatalog.fromJson(Map<String, dynamic> json) =>
      WhisperModelCatalog(
        active: json['active'] as String? ?? '',
        models: ((json['models'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map<dynamic, dynamic>>()
            .map(
              (Map<dynamic, dynamic> e) =>
                  WhisperModelInfo.fromJson(Map<String, dynamic>.from(e)),
            )
            .toList(growable: false),
      );

  final String active;

  /// In the SERVER's accuracy order (large-v3 … tiny). Never re-sorted here:
  /// the order is part of the contract and the radio list renders it as-is.
  final List<WhisperModelInfo> models;

  /// The row for [name], or null when the server does not offer it.
  WhisperModelInfo? byName(String name) {
    for (final WhisperModelInfo model in models) {
      if (model.name == name) return model;
    }
    return null;
  }
}

/// GET /v1/transcription/models/install/progress — where a running install
/// is. Mirrors the summaries progress contract, plus which model it is for
/// (the user can only run one at a time, but the UI must name it).
@immutable
final class WhisperInstallProgress {
  const WhisperInstallProgress({
    required this.phase,
    required this.percent,
    required this.detail,
    this.model,
  });

  factory WhisperInstallProgress.fromJson(Map<String, dynamic> json) =>
      WhisperInstallProgress(
        phase: json['phase'] as String? ?? 'idle',
        percent: (json['percent'] as num?)?.toInt() ?? 0,
        detail: json['detail'] as String? ?? '',
        model: json['model'] as String?,
      );

  /// 'idle' | 'downloading' | 'verifying' | 'done' | 'failed'.
  final String phase;
  final int percent;
  final String detail;
  final String? model;
}

/// GET/PUT /v1/transcription/vocabulary — the one global boost-word list
/// (spec docs/design/2026-09-26-custom-vocabulary.md §3). Server-owned,
/// never cached in Drift; the Settings editor fetches it live.
@immutable
final class VocabularySettings {
  const VocabularySettings({
    required this.terms,
    required this.text,
    required this.tokenEstimate,
    required this.overBudget,
  });

  /// Defensive like `SummaryTemplate.fromJson`: every field has a safe
  /// default so a partial or older-server body never throws in the section.
  factory VocabularySettings.fromJson(Map<String, dynamic> json) =>
      VocabularySettings(
        terms: ((json['terms'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<String>()
            .toList(growable: false),
        text: json['text'] as String? ?? '',
        tokenEstimate: (json['token_estimate'] as num?)?.toInt() ?? 0,
        overBudget: json['over_budget'] == true,
      );

  static const VocabularySettings empty = VocabularySettings(
    terms: <String>[],
    text: '',
    tokenEstimate: 0,
    overBudget: false,
  );

  /// Canonical terms: split, trimmed, de-duped case-insensitively.
  final List<String> terms;

  /// The canonical comma-joined text (`"Hermes, CachyOS, Tangent"`).
  final String text;

  /// The server's count with its tokenizer when loaded, else `len // 4`.
  final int tokenEstimate;

  /// `tokenEstimate > 223`: faster-whisper will silently drop later terms.
  final bool overBudget;
}

/// PUT /v1/transcription/model refused: the model exists but its weights are
/// not on the server. The fix is an install, not an error banner.
final class WhisperModelNotInstalledException extends ApiException {
  const WhisperModelNotInstalledException({
    required this.model,
    required super.message,
  }) : super(statusCode: 409, code: 'conflict');

  final String model;
}

/// POST install refused: one is already running. That is the outcome the
/// user wanted, so the section attaches and watches it.
final class WhisperInstallAlreadyRunningException extends ApiException {
  const WhisperInstallAlreadyRunningException({required super.message})
      : super(statusCode: 409, code: 'conflict');
}

/// DELETE refused: those weights are what the server transcribes with.
/// Selecting something else first is the only way through.
final class CannotDeleteActiveModelException extends ApiException {
  const CannotDeleteActiveModelException({
    required this.model,
    required super.message,
  }) : super(statusCode: 409, code: 'conflict');

  final String model;
}

/// 400: the server does not know that name at all (a client/server version
/// skew, or a hand-made request) — distinct from "known but not installed".
final class UnsupportedWhisperModelException extends ApiException {
  const UnsupportedWhisperModelException({
    required this.model,
    required super.message,
  }) : super(statusCode: 400, code: 'bad_request');

  final String model;
}

/// Talks to /v1/transcription/models* with the same Dio conventions as
/// [SummariesClient]: bearer token, sub-500 statuses surfaced as
/// [ApiException] (or one of the typed subclasses above) via _checkStatus.
class WhisperModelClient {
  WhisperModelClient({required String baseUrl, String? token})
      : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            contentType: 'application/json',
            headers: token != null ? {'Authorization': 'Bearer $token'} : {},
            validateStatus: (status) => status != null && status < 500,
            // Same transport deadlines as the summaries client: a dead route
            // must FAIL, not wedge the Settings screen.
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );

  WhisperModelClient.forTesting({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// The server this client talks to; lets a test prove the provider rebuilt
  /// against a new server rather than handing back a cached client.
  String get baseUrl => _dio.options.baseUrl;

  /// The Authorization header this client will send, or null if it has none.
  String? get authorizationHeader =>
      _dio.options.headers['Authorization'] as String?;

  Future<WhisperModelCatalog> getModels() async {
    final resp = await _dio.get<dynamic>('/v1/transcription/models');
    _checkStatus(resp);
    return _catalogOf(resp);
  }

  /// PUT /v1/transcription/model — switch what the next job transcribes
  /// with. 409 means the weights are missing (install first); 400 means the
  /// server does not support that name at all.
  Future<WhisperModelCatalog> selectModel(String name) async {
    final resp = await _dio.put<dynamic>(
      '/v1/transcription/model',
      data: <String, dynamic>{'name': name},
    );
    final int status = resp.statusCode ?? 0;
    if (status == 409) {
      throw WhisperModelNotInstalledException(
        model: name,
        message: _detailOf(resp, "Model '$name' is not installed"),
      );
    }
    if (status == 400) {
      throw UnsupportedWhisperModelException(
        model: name,
        message: _detailOf(resp, "Unsupported model '$name'"),
      );
    }
    _checkStatus(resp);
    return _catalogOf(resp);
  }

  /// POST /v1/transcription/models/{name}/install — start the download.
  ///
  /// Installing deliberately does NOT change the active model; selection
  /// stays an explicit second step (the section chains them, but the server
  /// never decides that on its own).
  Future<void> startInstall(String name) async {
    final resp =
        await _dio.post<dynamic>('/v1/transcription/models/$name/install');
    final int status = resp.statusCode ?? 0;
    if (status == 409) {
      throw WhisperInstallAlreadyRunningException(
        message: _detailOf(resp, 'A model install is already running'),
      );
    }
    if (status == 400) {
      throw UnsupportedWhisperModelException(
        model: name,
        message: _detailOf(resp, "Unsupported model '$name'"),
      );
    }
    _checkStatus(resp);
  }

  /// Non-blocking; safe to poll every couple of seconds while installing.
  Future<WhisperInstallProgress> getInstallProgress() async {
    final resp =
        await _dio.get<dynamic>('/v1/transcription/models/install/progress');
    _checkStatus(resp);
    return WhisperInstallProgress.fromJson(
      (resp.data as Map<String, dynamic>?) ?? const {},
    );
  }

  /// DELETE /v1/transcription/models/{name} — free the disk again. Refused
  /// with a typed 409 when it is the active model, because the server would
  /// then be unable to transcribe anything.
  Future<WhisperModelCatalog> deleteModel(String name) async {
    final resp = await _dio.delete<dynamic>('/v1/transcription/models/$name');
    final int status = resp.statusCode ?? 0;
    if (status == 409) {
      throw CannotDeleteActiveModelException(
        model: name,
        message: _detailOf(resp, 'Cannot delete the active model'),
      );
    }
    _checkStatus(resp);
    return _catalogOf(resp);
  }

  WhisperModelCatalog _catalogOf(Response<dynamic> resp) =>
      WhisperModelCatalog.fromJson(
        (resp.data as Map<String, dynamic>?) ?? const {},
      );

  /// GET /v1/transcription/vocabulary — the saved boost-word list.
  Future<VocabularySettings> fetchVocabulary() async {
    final resp = await _dio.get<dynamic>('/v1/transcription/vocabulary');
    _checkStatus(resp);
    return _vocabularyOf(resp);
  }

  /// PUT /v1/transcription/vocabulary with the RAW editor text; the server
  /// canonicalises and answers with what it kept. Blank clears. A 422 (term
  /// over 64 chars, more than 200 terms) surfaces as an [ApiException]
  /// whose message is the server's detail — the section shows it verbatim.
  Future<VocabularySettings> setVocabulary(String text) async {
    final resp = await _dio.put<dynamic>(
      '/v1/transcription/vocabulary',
      data: <String, dynamic>{'text': text},
    );
    _checkStatus(resp);
    return _vocabularyOf(resp);
  }

  VocabularySettings _vocabularyOf(Response<dynamic> resp) =>
      VocabularySettings.fromJson(
        (resp.data as Map<String, dynamic>?) ?? const {},
      );

  /// FastAPI's plain HTTPException shape ({'detail': '...'}) — the detail is
  /// exactly what the user needs to see.
  String _detailOf(Response<dynamic> resp, String fallback) {
    final Object? body = resp.data;
    if (body is Map && body['detail'] is String) return body['detail'] as String;
    if (body is Map && body['error'] is Map && body['error']['message'] is String) {
      return body['error']['message'] as String;
    }
    return fallback;
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
