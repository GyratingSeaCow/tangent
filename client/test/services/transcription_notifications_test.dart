// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/transcription_notifications.dart';

/// Records what reached the platform, so tests assert on the OBSERVABLE
/// effect rather than on internal state.
class _RecordingPort implements TranscriptionNotificationPort {
  final List<TranscriptionNotice> shown = <TranscriptionNotice>[];
  int cancels = 0;

  @override
  Future<void> show(TranscriptionNotice notice) async => shown.add(notice);

  @override
  Future<void> cancel() async => cancels++;
}

void main() {
  group('transcriptionNoticeFor', () {
    test('nothing active means no notification at all', () {
      expect(
        transcriptionNoticeFor(hasActive: false, queuedCount: 0),
        isNull,
        reason: 'an idle app must not sit in the shade',
      );
    });

    test('a queue with no active job is not yet transcribing', () {
      // The instant between accepting a job and starting it. Announcing
      // "transcribing" here would describe work that has not begun.
      expect(
        transcriptionNoticeFor(hasActive: false, queuedCount: 3),
        isNull,
        reason: 'queued is not the same as running',
      );
    });

    test('a single active job names one recording', () {
      final TranscriptionNotice? notice =
          transcriptionNoticeFor(hasActive: true, queuedCount: 0);

      expect(notice, isNotNull);
      expect(notice!.title, 'Transcribing');
      expect(
        notice.body,
        '1 recording',
        reason: 'one job must not be described as a batch',
      );
    });

    test('a backlog counts the active job plus everything waiting', () {
      // queuedCount excludes the running job, so three waiting is four total.
      final TranscriptionNotice? notice =
          transcriptionNoticeFor(hasActive: true, queuedCount: 3);

      expect(notice!.body, '1 of 4 recordings');
    });

    test('the notice never promises background survival', () {
      // This is a dismissible notification, not a foreground service: it
      // reports work, it does not keep it alive. Copy claiming otherwise
      // would be a promise the system does not make.
      final TranscriptionNotice notice =
          transcriptionNoticeFor(hasActive: true, queuedCount: 2)!;
      final String text = '${notice.title} ${notice.body}'.toLowerCase();

      expect(
        text,
        isNot(contains('background')),
        reason: 'never claim the work continues in the background',
      );
      expect(text, isNot(contains('keep')));
    });
  });

  group('TranscriptionNotifier', () {
    test('shows a notification when a job starts', () async {
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0);

      expect(port.shown, hasLength(1));
      expect(port.shown.single.body, '1 recording');
      expect(port.cancels, 0);
    });

    test('clears the notification when the queue drains', () async {
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0);
      await notifier.sync(hasActive: false, queuedCount: 0);

      expect(
        port.cancels,
        1,
        reason: 'a finished run must not leave "Transcribing" in the shade',
      );
      expect(notifier.shown, isNull);
    });

    test('repeated identical progress does not re-post the notification',
        () async {
      // The service notifies on every stream event — many per second. Posting
      // an identical notification each time re-alerts and drains battery.
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 1);
      await notifier.sync(hasActive: true, queuedCount: 1);
      await notifier.sync(hasActive: true, queuedCount: 1);

      expect(
        port.shown,
        hasLength(1),
        reason: 'only a real change may reach the platform',
      );
    });

    test('a changed backlog does update the notification', () async {
      // The counterpart to the rule above: suppression must not swallow real
      // progress, or the shade freezes on a stale count.
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 2);
      await notifier.sync(hasActive: true, queuedCount: 1);
      await notifier.sync(hasActive: true, queuedCount: 0);

      expect(port.shown.map((TranscriptionNotice n) => n.body), <String>[
        '1 of 3 recordings',
        '1 of 2 recordings',
        '1 recording',
      ]);
    });

    test('an idle app never posts anything', () async {
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: false, queuedCount: 0);
      await notifier.sync(hasActive: false, queuedCount: 0);

      expect(port.shown, isEmpty);
      expect(
        port.cancels,
        0,
        reason: 'cancelling a notification that was never shown is noise',
      );
    });

    test('a second run after a drain shows again', () async {
      // Guards the state tracking: clearing must reset it, or the next
      // recording transcribes with nothing in the shade.
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0);
      await notifier.sync(hasActive: false, queuedCount: 0);
      await notifier.sync(hasActive: true, queuedCount: 0);

      expect(port.shown, hasLength(2));
      expect(port.cancels, 1);
    });

    test('dispose clears a live notification', () async {
      // A stale "Transcribing" outliving the process is the shape of bug the
      // user reads as "it is still running".
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0);
      await notifier.dispose();

      expect(port.cancels, 1);
    });

    test('dispose with nothing shown does not post a stray cancel', () async {
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.dispose();

      expect(port.cancels, 0);
    });

    test('a disposed notifier ignores later queue changes', () async {
      // The service can notify once more while teardown is in flight.
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.dispose();
      await notifier.sync(hasActive: true, queuedCount: 0);

      expect(port.shown, isEmpty);
    });
  });
}
