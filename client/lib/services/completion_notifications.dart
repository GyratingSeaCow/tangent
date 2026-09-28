// SPDX-License-Identifier: AGPL-3.0-or-later
/// Completion notifications (spec 2026-09-28, N1-N6): "Transcribed ·
/// <title>", "Transcription failed · <title>" and "Notes ready · <title>".
///
/// The progress notice (`transcription_notifications.dart`, id 1001) is
/// CLEARED when a job ends, so nothing ever announced the result, and AI
/// summaries never touched the shade at all. Jeff: "there is no
/// notification when the transcribing is done."
///
/// Pure on purpose: what to say, which fixed id it replaces, whether the
/// user is already looking at that recording, and whether the switch is
/// on all live here, reachable from a plain unit test. The platform ports
/// are thin.
library;

import 'package:flutter/foundation.dart';

import 'transcription_notifications.dart' show deliverNotificationQuietly;

/// Fixed id of the transcription outcome notice (N1). One per feature: a
/// second outcome REPLACES the first rather than stacking.
const int completionTranscribedNotificationId = 1002;

/// Fixed id of the "Notes ready" notice (N1).
const int completionNotesReadyNotificationId = 1003;

/// Both ids, for `clearFor` and for a port that must wipe the shade.
const List<int> completionNotificationIds = <int>[
  completionTranscribedNotificationId,
  completionNotesReadyNotificationId,
];

enum CompletionKind {
  transcribed,
  transcriptionFailed,
  notesReady;

  /// The shade slot this kind occupies. Transcribed and failed share one:
  /// they are two outcomes of the same job.
  int get notificationId => this == CompletionKind.notesReady
      ? completionNotesReadyNotificationId
      : completionTranscribedNotificationId;
}

/// One finished piece of work, as the shade should describe it.
@immutable
final class CompletionNotice {
  const CompletionNotice({
    required this.kind,
    required this.dumpId,
    required this.title,
    required this.body,
  });

  final CompletionKind kind;
  final String dumpId;
  final String title;
  final String body;

  int get notificationId => kind.notificationId;

  @override
  bool operator ==(Object other) =>
      other is CompletionNotice &&
      other.kind == kind &&
      other.dumpId == dumpId &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode => Object.hash(kind, dumpId, title, body);

  @override
  String toString() => 'CompletionNotice(${kind.name}, $dumpId, $title, $body)';
}

/// The recording's title as the shade shows it: never blank, because a
/// notice reading "Transcribed · " tells the user nothing.
String completionDisplayTitle(String? title) {
  final String trimmed = title?.trim() ?? '';
  return trimmed.isEmpty ? 'Untitled recording' : trimmed;
}

/// The notice for a transcription that reached a terminal status (N4).
CompletionNotice transcriptionCompletionNotice({
  required String dumpId,
  required String? title,
  required bool failed,
}) {
  final String shown = completionDisplayTitle(title);
  return failed
      ? CompletionNotice(
          kind: CompletionKind.transcriptionFailed,
          dumpId: dumpId,
          title: 'Transcription failed \u00B7 $shown',
          body: 'Open the recording to retry.',
        )
      : CompletionNotice(
          kind: CompletionKind.transcribed,
          dumpId: dumpId,
          title: 'Transcribed \u00B7 $shown',
          body: 'The transcript is ready.',
        );
}

/// The notice for a summary that just synced down, or null when it is not
/// this device's to announce (N4): only a row whose `summaryRequestedAt`
/// was set asked for it — the summaryPending contract. A summary another
/// device requested arrives here too, silently.
CompletionNotice? summaryCompletionNotice({
  required String dumpId,
  required String? title,
  required String? template,
  required int? requestedAt,
}) {
  if (requestedAt == null) return null;
  return CompletionNotice(
    kind: CompletionKind.notesReady,
    dumpId: dumpId,
    title: 'Notes ready \u00B7 ${completionDisplayTitle(title)}',
    body: template == 'meeting' ? 'Meeting notes' : 'Summary',
  );
}

/// Where a completion notice is delivered. Narrow on purpose, like
/// [TranscriptionNotificationPort]: the plugin is a detail, tests assert
/// on a double.
abstract interface class CompletionNotificationPort {
  /// Shows or REPLACES the notice under its fixed id.
  Future<void> show(CompletionNotice notice);

  /// Removes the notice under [notificationId], if any.
  Future<void> cancel(int notificationId);
}

/// Delivers nothing, successfully — tests and hosts without a port.
class NullCompletionNotificationPort implements CompletionNotificationPort {
  const NullCompletionNotificationPort();

  @override
  Future<void> show(CompletionNotice notice) async {}

  @override
  Future<void> cancel(int notificationId) async {}
}

/// Decides whether a finished piece of work reaches the shade.
///
/// Two rules: the switch (N6, [enabled]) gates everything, and opening a
/// recording by any path wipes its notices (N3, [clearFor]).
///
/// There is deliberately NO "already looking at it" suppression. The spec's
/// N3 had one, and Jeff's first live run hit it: he was sitting on the
/// recording while it transcribed, saw the text arrive, and reported the
/// notification as missing. A result the screen shows and the shade also
/// pings is unambiguous; a result the shade skips because of where the
/// user happened to be looks like a broken feature. His call: post it
/// anyway.
class CompletionNotifier {
  CompletionNotifier({
    required CompletionNotificationPort port,
    bool Function()? enabled,
  })  : _port = port,
        _enabled = enabled ?? (() => true);

  final CompletionNotificationPort _port;
  final bool Function() _enabled;

  bool _disposed = false;

  /// Serialises platform calls, for the same reason the progress notifier
  /// does: the first Android 13+ show() blocks on the permission prompt,
  /// and a cancel that overtakes it would be undone.
  Future<void> _pending = Future<void>.value();

  /// Which recording each fixed id currently describes (this process).
  final Map<int, String> _shownDumpIds = <int, String>{};

  /// The last notice handed to the port, for tests.
  @visibleForTesting
  final List<CompletionNotice> shown = <CompletionNotice>[];

  /// N1/N6: shows [notice] unless the switch is off — even when the user
  /// is looking at that recording. Returns whether it was posted.
  Future<bool> announce(CompletionNotice notice) async {
    if (_disposed) return false;
    if (!_enabled()) return false;
    shown.add(notice);
    _shownDumpIds[notice.notificationId] = notice.dumpId;
    _pending = _pending.then(
      (_) => deliverNotificationQuietly('show', () => _port.show(notice)),
    );
    await _pending;
    return true;
  }

  /// N3: the recording was opened by some path — its notices are answered.
  /// Cancels every fixed id this process posted for [dumpId], AND ids this
  /// process never posted: a notice from a previous process outlives it,
  /// and the tap that opened the recording is exactly what answers it.
  Future<void> clearFor(String dumpId) async {
    if (_disposed) return;
    final List<int> ids = <int>[
      for (final int id in completionNotificationIds)
        if (_shownDumpIds[id] == null || _shownDumpIds[id] == dumpId) id,
    ];
    if (ids.isEmpty) return;
    for (final int id in ids) {
      _shownDumpIds.remove(id);
    }
    _pending = _pending.then((_) async {
      for (final int id in ids) {
        await deliverNotificationQuietly('cancel', () => _port.cancel(id));
      }
    });
    return _pending;
  }

  /// Stops delivering. Completion notices deliberately SURVIVE the app: a
  /// result the user has not seen yet is the whole point of the feature.
  void dispose() {
    _disposed = true;
  }
}
