// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';

/// Background-transcription progress, surfaced in the notification shade.
///
/// Transcription runs off-screen: a recording is uploaded to the user's
/// server and the transcript arrives over SSE some time later. Without a
/// notification the only evidence that anything is happening lives on a
/// screen the user has usually already left, so a long job is
/// indistinguishable from a silent failure.
///
/// This is a PLAIN, DISMISSIBLE notification, not a foreground service. It
/// reports work that is happening; it does not keep that work alive if
/// Android freezes the app. The copy therefore never promises that
/// transcription continues in the background — saying so would be a claim the
/// system does not guarantee.

/// What the shade should say right now.
@immutable
final class TranscriptionNotice {
  const TranscriptionNotice({required this.title, required this.body});

  final String title;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is TranscriptionNotice && other.title == title && other.body == body;

  @override
  int get hashCode => Object.hash(title, body);

  @override
  String toString() => 'TranscriptionNotice($title, $body)';
}

/// Maps queue state onto the notice, or null when nothing is transcribing.
///
/// One tested function rather than a conditional inside a build method, so
/// the wording and the "is anything running?" rule cannot drift apart.
///
/// [queuedCount] counts jobs WAITING behind the active one, so the number of
/// recordings involved is `1 + queuedCount` whenever a job is active.
TranscriptionNotice? transcriptionNoticeFor({
  required bool hasActive,
  required int queuedCount,
}) {
  if (!hasActive) {
    // Nothing is being worked on. Queued-without-active is the brief instant
    // between accepting a job and starting it; announcing "transcribing"
    // there would describe work that has not begun.
    return null;
  }

  final int total = 1 + (queuedCount < 0 ? 0 : queuedCount);
  return TranscriptionNotice(
    title: 'Transcribing',
    body: total == 1 ? '1 recording' : '1 of $total recordings',
  );
}

/// Where a notice is delivered. Narrow on purpose: the platform plugin is a
/// detail, and tests need a double they can assert on.
abstract interface class TranscriptionNotificationPort {
  /// Shows or REPLACES the single transcription notification.
  Future<void> show(TranscriptionNotice notice);

  /// Removes it.
  Future<void> cancel();
}

/// Keeps the shade in step with the transcription queue.
///
/// The service notifies on every queue and stream event, which for a single
/// recording is many events a second. Re-posting an identical notification
/// each time makes Android re-alert and burns battery, so this tracks what is
/// already on screen and calls the platform only on a real change — the same
/// rule the capture path follows for idempotent platform calls.
class TranscriptionNotifier {
  TranscriptionNotifier({required TranscriptionNotificationPort port})
      : _port = port;

  final TranscriptionNotificationPort _port;

  TranscriptionNotice? _shown;
  bool _disposed = false;

  /// What is currently on screen, for tests and for debugging.
  @visibleForTesting
  TranscriptionNotice? get shown => _shown;

  Future<void> sync({
    required bool hasActive,
    required int queuedCount,
  }) async {
    if (_disposed) return;
    final TranscriptionNotice? next = transcriptionNoticeFor(
      hasActive: hasActive,
      queuedCount: queuedCount,
    );
    if (next == _shown) return;
    _shown = next;
    if (next == null) {
      await _port.cancel();
    } else {
      await _port.show(next);
    }
  }

  /// Clears the notification so a stale "Transcribing" cannot outlive the app.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_shown == null) return;
    _shown = null;
    await _port.cancel();
  }
}
