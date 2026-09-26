// SPDX-License-Identifier: AGPL-3.0-or-later
/// Client for the server's AI-summaries endpoints (mirrors
/// [OcrSettingsClient] for /v1/ocr/*).
///
/// The heavy summarizer environment (llama.cpp runtime + ~2.5 GB Qwen
/// weights) does NOT ship in the base server container: the server installs
/// it on demand into a persistent env, and these calls are how the Settings
/// wizard drives that — read capability + toggle in one poll, kick off an
/// install, watch it, tear it down again (which KEEPS stored summaries),
/// and ask for a per-dump (re)generate.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/api_exception.dart';

/// GET/POST /v1/summaries/settings — capability + toggle in one payload:
/// everything the wizard needs in a single poll.
@immutable
final class SummarySettings {
  const SummarySettings({
    required this.installed,
    required this.runtime,
    required this.gpuVisible,
    required this.diskFreeBytes,
    required this.installRunning,
    required this.enabled,
    this.customPrompt,
    this.customConfigured = false,
  });

  factory SummarySettings.fromJson(Map<String, dynamic> json) =>
      SummarySettings(
        installed: json['installed'] == true,
        runtime: json['runtime'] as String?,
        gpuVisible: json['gpu_visible'] == true,
        diskFreeBytes: (json['disk_free_bytes'] as num?)?.toInt() ?? 0,
        installRunning: json['install_running'] == true,
        enabled: json['enabled'] == true,
        // Both absent on a server predating summary templates: no custom
        // prompt, so the editor starts empty and pickers hide 'Custom'.
        customPrompt: json['custom_prompt'] as String?,
        customConfigured: json['custom_configured'] == true,
      );

  final bool installed;

  /// 'cuda' | 'cpu' when installed, null on a bare server.
  ///
  /// Both runtimes load the same Qwen GGUF — 'cuda' means faster
  /// generation, not different summaries: accuracy is identical.
  final String? runtime;
  final bool gpuVisible;
  final int diskFreeBytes;
  final bool installRunning;

  /// The SERVER-side auto-summarize toggle (gates the auto-trigger for
  /// every device, unlike the OCR toggle which is per-device).
  final bool enabled;

  /// The user-authored 'custom' template prompt (one server-side slot), or
  /// null when the slot is empty. Server-owned like [enabled]: every device
  /// edits the same text.
  final String? customPrompt;

  /// Whether the 'custom' template can be chosen — true iff [customPrompt]
  /// is non-blank on the server. Pickers hide the 'Custom' row otherwise.
  final bool customConfigured;
}

/// One entry from GET /v1/summaries/templates.
@immutable
final class SummaryTemplate {
  const SummaryTemplate({required this.id, required this.displayName});

  factory SummaryTemplate.fromJson(Map<String, dynamic> json) =>
      SummaryTemplate(
        id: json['id'] as String? ?? '',
        displayName:
            json['display_name'] as String? ?? json['id'] as String? ?? '',
      );

  /// Stable wire id ('meeting', 'brain_dump', 'lecture', 'actions_only',
  /// 'custom'). The server owns this list; the client never hardcodes it.
  final String id;
  final String displayName;
}

/// GET /v1/summaries/templates — the server's template catalogue plus
/// whether the custom slot is configured. Pickers render FROM this: the
/// client holds no template list of its own, so a server that adds a preset
/// shows it on every device without a client release.
@immutable
final class SummaryTemplates {
  const SummaryTemplates({
    required this.templates,
    required this.customConfigured,
  });

  factory SummaryTemplates.fromJson(Map<String, dynamic> json) =>
      SummaryTemplates(
        templates: <SummaryTemplate>[
          for (final Object? raw
              in json['templates'] as List<dynamic>? ?? const <dynamic>[])
            if (raw is Map<String, dynamic>) SummaryTemplate.fromJson(raw),
        ],
        customConfigured: json['custom_configured'] == true,
      );

  /// In server order.
  final List<SummaryTemplate> templates;
  final bool customConfigured;
}

/// GET /v1/summaries/install/progress — where the running install is.
@immutable
final class SummaryInstallProgress {
  const SummaryInstallProgress({
    required this.phase,
    required this.percent,
    required this.detail,
  });

  factory SummaryInstallProgress.fromJson(Map<String, dynamic> json) =>
      SummaryInstallProgress(
        phase: json['phase'] as String? ?? 'idle',
        percent: (json['percent'] as num?)?.toInt() ?? 0,
        detail: json['detail'] as String? ?? '',
      );

  /// 'idle' | 'venv' | 'runtime' | 'weights' | 'verify' | 'done' | 'failed'.
  final String phase;
  final int percent;
  final String detail;
}

/// Why POST /v1/dumps/{id}/summarize refused with a 409.
enum SummarizeConflictReason {
  /// The dump exists but has no transcript text to summarize.
  noTranscript,

  /// The summarizer environment is not installed on the server; the fix is
  /// the Settings wizard, not this dump.
  notInstalled,
}

/// A typed 409 from [SummariesClient.summarizeDump], so the dump screen can
/// route "install the capability first" differently from "this dump has no
/// transcript" without string-matching the server's wording at the call
/// site (Task 4 needs the distinction; the wording lives here, once).
final class SummarizeConflictException extends ApiException {
  const SummarizeConflictException({
    required this.reason,
    required super.message,
  }) : super(statusCode: 409, code: 'conflict');

  final SummarizeConflictReason reason;
}

/// A typed 422 from [SummariesClient.summarizeDump]: the template id was
/// unknown, or 'custom' was requested while the custom slot is empty. The
/// server's detail is the user-facing wording (it names which case).
final class SummaryTemplateException extends ApiException {
  const SummaryTemplateException({required super.message})
      : super(statusCode: 422, code: 'invalid_template');
}

/// Talks to /v1/summaries/* with the same Dio conventions as
/// [OcrSettingsClient]: bearer token, sub-500 statuses surfaced as
/// [ApiException] via _checkStatus.
class SummariesClient {
  SummariesClient({required String baseUrl, String? token})
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

  SummariesClient.forTesting({required Dio dio}) : _dio = dio;

  final Dio _dio;

  /// The server this client talks to. Mirrors [OcrSettingsClient.baseUrl];
  /// lets a test prove the provider rebuilt against a new server rather
  /// than handing back a cached client pointed at the old one.
  String get baseUrl => _dio.options.baseUrl;

  /// The Authorization header this client will send, or null if it has none.
  ///
  /// Exposed so a test can prove the stored token actually reaches the
  /// request options: asserting [baseUrl] alone passes even when the token
  /// is dropped, and every /v1/summaries/* call would then 401 behind a UI
  /// that just shows a dead toggle.
  String? get authorizationHeader =>
      _dio.options.headers['Authorization'] as String?;

  Future<SummarySettings> getSettings() async {
    final resp = await _dio.get<dynamic>('/v1/summaries/settings');
    _checkStatus(resp);
    return SummarySettings.fromJson(
      (resp.data as Map<String, dynamic>?) ?? const {},
    );
  }

  /// POST the server-side auto-summarize toggle. Returns the fresh state.
  Future<SummarySettings> setEnabled(bool enabled) async {
    final resp = await _dio.post<dynamic>(
      '/v1/summaries/settings',
      data: <String, dynamic>{'enabled': enabled},
    );
    _checkStatus(resp);
    return SummarySettings.fromJson(
      (resp.data as Map<String, dynamic>?) ?? const {},
    );
  }

  /// POST the custom template prompt. Null or blank CLEARS the slot (the
  /// server then reports custom_configured=false and pickers hide 'Custom');
  /// the enabled toggle is deliberately not sent alongside. Returns the
  /// fresh state. Over-long text is a 422 [ApiException] with the limit.
  Future<SummarySettings> setCustomPrompt(String? prompt) async {
    final String? text =
        (prompt == null || prompt.trim().isEmpty) ? null : prompt;
    final resp = await _dio.post<dynamic>(
      '/v1/summaries/settings',
      data: <String, dynamic>{'custom_prompt': text},
    );
    _checkStatus(resp);
    return SummarySettings.fromJson(
      (resp.data as Map<String, dynamic>?) ?? const {},
    );
  }

  /// GET /v1/summaries/templates — ids + display names in server order and
  /// whether 'custom' is configured. An older server without the route
  /// 404s as a plain [ApiException]; the caller decides what to show.
  Future<SummaryTemplates> listTemplates() async {
    final resp = await _dio.get<dynamic>('/v1/summaries/templates');
    _checkStatus(resp);
    return SummaryTemplates.fromJson(
      (resp.data as Map<String, dynamic>?) ?? const {},
    );
  }

  /// POST /v1/summaries/install — a 202 means the background install
  /// started. A second install while one runs is a 409 [ApiException]; the
  /// wizard treats that as attach-and-watch, never an error.
  Future<void> startInstall() async {
    final resp = await _dio.post<dynamic>('/v1/summaries/install');
    _checkStatus(resp);
  }

  /// Non-blocking; safe to poll every couple of seconds while installing.
  Future<SummaryInstallProgress> getInstallProgress() async {
    final resp = await _dio.get<dynamic>('/v1/summaries/install/progress');
    _checkStatus(resp);
    return SummaryInstallProgress.fromJson(
      (resp.data as Map<String, dynamic>?) ?? const {},
    );
  }

  /// Deletes the summarizer env + model weights. Existing summaries are
  /// KEPT server-side — they are user data; uninstall only removes the
  /// ability to generate new ones. The caller owns naming both facts to
  /// the user before posting this.
  Future<void> uninstall() async {
    final resp = await _dio.post<dynamic>('/v1/summaries/uninstall');
    _checkStatus(resp);
  }

  /// POST /v1/dumps/{id}/summarize — (re)generate one dump's summary.
  ///
  /// 202 means enqueued (the dump's own synced fields change when it
  /// lands). 404 unknown dump. A 409 is thrown as a typed
  /// [SummarizeConflictException] so callers can tell "no transcript"
  /// (this dump can never summarize) from "capability not installed"
  /// (the Settings wizard is the fix) without matching server strings.
  ///
  /// [template] is a template id from [listTemplates]; when given, the
  /// server persists it on the dump and summarizes with it. When omitted
  /// NO body is sent and the server uses the dump's effective template. A
  /// 422 (unknown id / custom not configured) is a typed
  /// [SummaryTemplateException].
  Future<void> summarizeDump(String dumpId, {String? template}) async {
    final resp = template == null
        ? await _dio.post<dynamic>('/v1/dumps/$dumpId/summarize')
        : await _dio.post<dynamic>(
            '/v1/dumps/$dumpId/summarize',
            data: <String, dynamic>{'template': template},
          );
    if (resp.statusCode == 422) {
      throw SummaryTemplateException(
        message: switch (resp.data) {
          {'detail': final String d} => d,
          _ => 'Summary template is not available',
        },
      );
    }
    if (resp.statusCode == 409) {
      final String detail = switch (resp.data) {
        {'detail': final String d} => d,
        _ => 'HTTP 409',
      };
      // The server's two 409 details (summaries.py): "Dump has no
      // transcript to summarize" / "Summarizer environment is not
      // installed". Matched HERE so the string coupling lives in exactly
      // one place; anything unrecognized defaults to notInstalled because
      // that path has a user-visible fix.
      throw SummarizeConflictException(
        reason: detail.toLowerCase().contains('transcript')
            ? SummarizeConflictReason.noTranscript
            : SummarizeConflictReason.notInstalled,
        message: detail,
      );
    }
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
    // FastAPI's plain HTTPException shape ({'detail': '...'}): the detail
    // is exactly what the user needs to see ("an install is already
    // running").
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
