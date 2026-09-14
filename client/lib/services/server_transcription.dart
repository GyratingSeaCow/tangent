// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart' show immutable;

/// Status of a server-side transcription job, as observed by the phone.
///
/// Mirrors the server's `/v1/jobs/<id>` and `/v1/jobs/<id>/stream` events.
enum ServerTranscriptionStatus {
  /// No active job for this dump (idle state).
  idle,

  /// Audio is being uploaded to the server.
  uploading,

  /// Server has accepted the job; waiting for the SSE stream to emit
  /// `running`.
  queued,

  /// Server is actively decoding audio.
  running,

  /// User requested cancellation; waiting for the active SSE event to
  /// finish (the server doesn't expose a cancellation endpoint in v1, so
  /// the local state is purely advisory).
  cancelling,

  /// Server returned a transcript and we persisted it.
  complete,

  /// Job failed (server `failed` event, network error, or non-2xx response).
  error,
}

@immutable
final class ServerTranscriptionOperation {
  const ServerTranscriptionOperation({
    required this.status,
    this.dumpId,
    this.startedAt,
    this.transcript,
    this.error,
  });

  const ServerTranscriptionOperation.idle()
      : status = ServerTranscriptionStatus.idle,
        dumpId = null,
        startedAt = null,
        transcript = null,
        error = null;

  final ServerTranscriptionStatus status;
  final String? dumpId;
  final DateTime? startedAt;
  final String? transcript;
  final String? error;

  bool get isActive =>
      status == ServerTranscriptionStatus.uploading ||
      status == ServerTranscriptionStatus.queued ||
      status == ServerTranscriptionStatus.running ||
      status == ServerTranscriptionStatus.cancelling;
}
