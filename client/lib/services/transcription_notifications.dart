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

/// A port that delivers nothing, successfully.
///
/// The fallback when the real platform port cannot even be CONSTRUCTED. A
/// release build once shipped without the R8 keep rules the notification
/// plugin needs, and the resulting failure travelled up the startup path and
/// stopped auto-sync from ever starting — the user saw "can't connect to the
/// server". Notifications are a convenience; degrading to silence is always
/// better than taking the app's core down with them.
class NullTranscriptionNotificationPort
    implements TranscriptionNotificationPort {
  const NullTranscriptionNotificationPort();

  @override
  Future<void> show(TranscriptionNotice notice) async {}

  @override
  Future<void> cancel() async {}
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

  /// Serialises platform calls. The first `show()` on Android 13+ blocks on
  /// the runtime permission prompt, which waits on a human — a job can finish
  /// while it is still on screen. Without this chain the queued `show()`
  /// resumes AFTER the `cancel()` and repaints a notification describing work
  /// that is already over, leaving "Transcribing" in the shade forever.
  ///
  /// Ordering, not exclusion: every state still reaches the platform, in the
  /// order it was observed.
  Future<void> _pending = Future<void>.value();

  /// The state the shade should end up in, which is not what is on screen yet
  /// while a call is in flight. Compared against the newest intent rather than
  /// the last completed call, so a burst collapses to its final state.
  TranscriptionNotice? _intended;

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
    if (next == _intended) return;
    _intended = next;

    _pending = _pending.then((_) async {
      // Re-check on arrival: a newer sync may have superseded this one while
      // it waited its turn, and posting a stale state would undo it.
      if (_disposed || next != _intended) return;
      _shown = next;
      if (next == null) {
        await _deliver('cancel', _port.cancel);
      } else {
        await _deliver('show', () => _port.show(next));
      }
    });
    return _pending;
  }

  /// Runs one platform call so that it can NEVER fail the caller.
  ///
  /// Two things depend on this. A notification is a convenience: nothing it
  /// does may break transcription, sync, or startup — the release build that
  /// shipped without the notification plugin's R8 keep rules threw here and
  /// took the startup sequence down with it. And [_pending] is a CHAIN: one
  /// failed future in it propagates to every `.then` that follows, so a
  /// single transient platform error would silently kill the notification
  /// for the rest of the session.
  Future<void> _deliver(String operation, Future<void> Function() call) async {
    try {
      await call();
    } catch (error, stack) {
      debugPrint('tangent.notifications $operation failed: $error');
      debugPrintStack(stackTrace: stack, label: 'tangent.notifications');
    }
  }

  /// Clears anything left in the shade by a previous process.
  ///
  /// A notification outlives the process that posted it. If the app is killed
  /// mid-transcription — swiped away, or reclaimed under memory pressure — no
  /// `cancel()` ever runs and "Transcribing" survives into the next launch
  /// describing a job that no longer exists. Called once at startup, before
  /// the first sync, so the shade always starts from a state the app can
  /// actually vouch for.
  Future<void> reconcileStaleNotification() async {
    if (_disposed) return;
    if (_shown != null || _intended != null) return; // this process owns it
    _pending = _pending.then((_) => _deliver('cancel', _port.cancel));
    return _pending;
  }

  /// Clears the notification so a stale "Transcribing" cannot outlive the app.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_shown == null && _intended == null) return;
    _shown = null;
    _intended = null;
    // Queued behind any in-flight call: a cancel that overtakes a pending
    // show would be undone by it.
    _pending = _pending.then((_) => _deliver('cancel', _port.cancel));
    return _pending;
  }
}
