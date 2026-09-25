// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
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

/// A port whose operations only finish when the test releases them, so a
/// second sync can be made to arrive mid-flight.
///
/// Calls are recorded AFTER the gate, mirroring the real Android adapter:
/// `show()` first awaits the runtime permission prompt and only then posts to
/// the platform. Recording at entry instead would model an adapter that posts
/// before it blocks, and would hide the very ordering bug this reproduces.
class _BlockingPort implements TranscriptionNotificationPort {
  final List<String> calls = <String>[];
  final List<Completer<void>> _gates = <Completer<void>>[];

  Completer<void> gate() {
    final Completer<void> c = Completer<void>();
    _gates.add(c);
    return c;
  }

  @override
  Future<void> show(TranscriptionNotice notice) async {
    if (_gates.isNotEmpty) await _gates.removeAt(0).future;
    calls.add('show:${notice.body}');
  }

  @override
  Future<void> cancel() async {
    if (_gates.isNotEmpty) await _gates.removeAt(0).future;
    calls.add('cancel');
  }
}

/// A port that fails the way the release build did: every platform call
/// throws. The notification plugin's init threw a PlatformException when R8
/// stripped the gson generic signatures it needs, and that throw travelled up
/// the app's init path and stopped sync from ever starting.
class _ThrowingPort implements TranscriptionNotificationPort {
  int showAttempts = 0;
  int cancelAttempts = 0;

  @override
  Future<void> show(TranscriptionNotice notice) async {
    showAttempts += 1;
    throw PlatformException(
      code: 'error',
      message: 'TypeToken must be created with a type argument',
    );
  }

  @override
  Future<void> cancel() async {
    cancelAttempts += 1;
    throw PlatformException(
      code: 'error',
      message: 'TypeToken must be created with a type argument',
    );
  }
}

void main() {
  group('transcriptionNoticeFor', () {
    test('nothing active means no notification at all', () {
      expect(
        transcriptionNoticeFor(hasActive: false, queuedCount: 0, model: null),
        isNull,
        reason: 'an idle app must not sit in the shade',
      );
    });

    test('a queue with no active job is not yet transcribing', () {
      // The instant between accepting a job and starting it. Announcing
      // "transcribing" here would describe work that has not begun.
      expect(
        transcriptionNoticeFor(hasActive: false, queuedCount: 3, model: null),
        isNull,
        reason: 'queued is not the same as running',
      );
    });

    test('a single active job names one recording', () {
      final TranscriptionNotice? notice = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 0,
        model: null,
      );

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
      final TranscriptionNotice? notice = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 3,
        model: null,
      );

      expect(notice!.body, '1 of 4 recordings');
    });

    test('the notice never promises background survival', () {
      // This is a dismissible notification, not a foreground service: it
      // reports work, it does not keep it alive. Copy claiming otherwise
      // would be a promise the system does not make.
      final TranscriptionNotice notice = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 2,
        model: 'large-v3',
      )!;
      final String text = '${notice.title} ${notice.body}'.toLowerCase();

      expect(
        text,
        isNot(contains('background')),
        reason: 'never claim the work continues in the background',
      );
      expect(text, isNot(contains('keep')));
    });
  });

  group('transcriptionNoticeFor names the active model', () {
    // The model became selectable, so "faster-whisper" (the engine) stopped
    // answering the question the user actually asks of this notification:
    // which model is working on my recording right now. The name has to be
    // in the COLLAPSED shade line, so it goes in the body next to the count
    // rather than behind an expand.

    test('a single active job names the model in the shade line', () {
      final TranscriptionNotice notice = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 0,
        model: 'large-v3',
      )!;

      expect(
        notice.title,
        'Transcribing',
        reason: 'the title is the stable anchor; the model rides in the body',
      );
      expect(
        notice.body,
        '1 recording · large-v3',
        reason: 'the model must be visible without expanding the notification',
      );
    });

    test('a backlog names the model as well as the count', () {
      final TranscriptionNotice notice = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 3,
        model: 'large-v3',
      )!;

      expect(notice.body, '1 of 4 recordings · large-v3');
    });

    test('the model name is passed through verbatim, not prettified', () {
      // The server's catalogue owns these names; re-spelling them here would
      // make the shade disagree with the picker the user just used.
      final TranscriptionNotice notice = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 0,
        model: 'distil-large-v3.5',
      )!;

      expect(notice.body, '1 recording · distil-large-v3.5');
    });

    test('an unknown model falls back to exactly today wording', () {
      // The mirror is empty before the first catalogue fetch, and on a device
      // that has never reached the server. Naming nothing is correct there;
      // naming "null" would be a bug the user reads as a broken app.
      final TranscriptionNotice notice = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 0,
        model: null,
      )!;

      expect(notice.body, '1 recording');
    });

    test('an unknown model never renders a dangling separator', () {
      final TranscriptionNotice single = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 0,
        model: null,
      )!;
      final TranscriptionNotice batch = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 2,
        model: null,
      )!;

      for (final TranscriptionNotice notice in <TranscriptionNotice>[
        single,
        batch,
      ]) {
        expect(
          notice.body,
          isNot(contains('·')),
          reason: 'a separator with nothing after it reads as truncated copy',
        );
        expect(
          notice.body.toLowerCase(),
          isNot(contains('null')),
          reason: 'the literal word null must never reach the shade',
        );
      }
      expect(batch.body, '1 of 3 recordings');
    });

    test('an empty or whitespace model counts as unknown', () {
      // SharedPreferences can hold '' from a cleared mirror, and a trimmed
      // blank is the same absence of knowledge as null.
      for (final String blank in <String>['', '   ', '\n']) {
        final TranscriptionNotice notice = transcriptionNoticeFor(
          hasActive: true,
          queuedCount: 1,
          model: blank,
        )!;

        expect(
          notice.body,
          '1 of 2 recordings',
          reason: 'blank is not a model name: "$blank"',
        );
      }
    });

    test('a model name is trimmed before it is shown', () {
      final TranscriptionNotice notice = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 0,
        model: '  small  ',
      )!;

      expect(notice.body, '1 recording · small');
    });

    test('an unknown model still says nothing about the engine', () {
      // The fallback is today's wording, which deliberately does NOT name
      // faster-whisper in the shade. Reintroducing the engine name here
      // would put back the thing Jeff asked to have removed.
      final TranscriptionNotice notice = transcriptionNoticeFor(
        hasActive: true,
        queuedCount: 0,
        model: null,
      )!;

      expect(notice.body.toLowerCase(), isNot(contains('whisper')));
    });
  });

  group('TranscriptionNotifier', () {
    test('shows a notification when a job starts', () async {
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0, model: null);

      expect(port.shown, hasLength(1));
      expect(port.shown.single.body, '1 recording');
      expect(port.cancels, 0);
    });

    test('clears the notification when the queue drains', () async {
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0, model: null);
      await notifier.sync(hasActive: false, queuedCount: 0, model: null);

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

      await notifier.sync(hasActive: true, queuedCount: 1, model: null);
      await notifier.sync(hasActive: true, queuedCount: 1, model: null);
      await notifier.sync(hasActive: true, queuedCount: 1, model: null);

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

      await notifier.sync(hasActive: true, queuedCount: 2, model: null);
      await notifier.sync(hasActive: true, queuedCount: 1, model: null);
      await notifier.sync(hasActive: true, queuedCount: 0, model: null);

      expect(port.shown.map((TranscriptionNotice n) => n.body), <String>[
        '1 of 3 recordings',
        '1 of 2 recordings',
        '1 recording',
      ]);
    });

    test('a model change re-posts the notification', () async {
      // The mirror is refreshed whenever the catalogue is fetched, which can
      // land mid-job. Suppression keys on the whole notice, so a model that
      // changed under a steady count must still reach the shade — otherwise
      // the notification keeps naming the model the user just switched away
      // from.
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0, model: 'small');
      await notifier.sync(hasActive: true, queuedCount: 0, model: 'large-v3');

      expect(port.shown.map((TranscriptionNotice n) => n.body), <String>[
        '1 recording · small',
        '1 recording · large-v3',
      ]);
    });

    test('the model reaches the platform alongside the count', () async {
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 2, model: 'large-v3');

      expect(port.shown.single.body, '1 of 3 recordings · large-v3');
    });

    test('an idle app never posts anything', () async {
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: false, queuedCount: 0, model: null);
      await notifier.sync(hasActive: false, queuedCount: 0, model: null);

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

      await notifier.sync(hasActive: true, queuedCount: 0, model: null);
      await notifier.sync(hasActive: false, queuedCount: 0, model: null);
      await notifier.sync(hasActive: true, queuedCount: 0, model: null);

      expect(port.shown, hasLength(2));
      expect(port.cancels, 1);
    });

    test('dispose clears a live notification', () async {
      // A stale "Transcribing" outliving the process is the shape of bug the
      // user reads as "it is still running".
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0, model: null);
      await notifier.dispose();

      expect(port.cancels, 1);
    });

    test('dispose with nothing shown does not post a stray cancel', () async {
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.dispose();

      expect(port.cancels, 0);
    });

    test('a slow show cannot post after a cancel has overtaken it', () async {
      // THE DEVICE DEFECT. On Android 13+ the first show() blocks on the
      // runtime permission prompt, which waits on a human. A 14s job finished
      // while the prompt was still up; cancel() ran, then the permission was
      // granted and the queued show() resumed and posted. The shade was left
      // reading "Transcribing" indefinitely with nothing transcribing.
      final _BlockingPort port = _BlockingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      final Completer<void> prompt = port.gate();
      final Future<void> showing =
          notifier.sync(hasActive: true, queuedCount: 0, model: null);

      // The job finishes while the prompt is still on screen.
      final Future<void> cancelling =
          notifier.sync(hasActive: false, queuedCount: 0, model: null);

      prompt.complete(); // the user finally taps Allow
      await showing;
      await cancelling;

      expect(
        port.calls.last,
        'cancel',
        reason: 'the last thing the platform sees must be the cancel, '
            'never a show that outlived the work it described',
      );
    });

    test('serialised syncs still reach the newest state', () async {
      // Guard against "fix" by dropping work: overlapping syncs must still
      // converge on the latest state, not silently skip it.
      final _BlockingPort port = _BlockingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      final Completer<void> first = port.gate();
      final Future<void> a = notifier.sync(hasActive: true, queuedCount: 0, model: null);
      final Future<void> b = notifier.sync(hasActive: true, queuedCount: 2, model: null);

      first.complete();
      await a;
      await b;

      expect(port.calls, contains('show:1 of 3 recordings'));
    });

    test('a superseded state is never posted after the newer one', () async {
      // Three syncs, the middle one obsolete before its turn arrives. Without
      // the supersede check the queue faithfully replays it and the shade
      // ends up one state behind reality.
      final _BlockingPort port = _BlockingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      final Completer<void> first = port.gate();
      final Future<void> a = notifier.sync(hasActive: true, queuedCount: 0, model: null);
      final Future<void> b = notifier.sync(hasActive: true, queuedCount: 5, model: null);
      final Future<void> c = notifier.sync(hasActive: false, queuedCount: 0, model: null);

      first.complete();
      await a;
      await b;
      await c;

      expect(
        port.calls,
        isNot(contains('show:1 of 6 recordings')),
        reason: 'a state that was obsolete before it reached the platform '
            'must be dropped, not replayed',
      );
      expect(port.calls.last, 'cancel');
    });

    test('startup clears a notification left by a killed process', () async {
      // Nothing in this process posted it, so the only safe assumption is
      // that a previous launch died mid-job.
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.reconcileStaleNotification();

      expect(port.cancels, 1);
    });

    test('startup reconcile does not clear this process own notice', () async {
      // A recovery resumed at launch announces itself before reconcile runs;
      // clearing it would erase a live job's notification.
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0, model: null);
      await notifier.reconcileStaleNotification();

      expect(port.cancels, 0);
      expect(port.shown, hasLength(1));
    });

    test('a disposed notifier ignores later queue changes', () async {
      // The service can notify once more while teardown is in flight.
      final _RecordingPort port = _RecordingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.dispose();
      await notifier.sync(hasActive: true, queuedCount: 0, model: null);

      expect(port.shown, isEmpty);
    });
  });

  group('a broken notification plugin never takes the app down', () {
    // THE FOURTH E2E DEFECT. The release APK shipped without the R8 keep
    // rules flutter_local_notifications needs, so the plugin threw
    // "TypeToken must be created with a type argument" at init. That throw
    // travelled up the Dart init path, the startup sequence never reached
    // auto-sync, and the user read it as "can't connect to the server".
    // Keep rules fix the cause; these pin the containment.

    test('a throwing port does not fail the caller that syncs it', () async {
      final _ThrowingPort port = _ThrowingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await expectLater(
        notifier.sync(hasActive: true, queuedCount: 0, model: null),
        completes,
        reason: 'startup awaits this; a throw here stops everything after it',
      );
      expect(port.showAttempts, 1, reason: 'it must still have TRIED');
    });

    test('startup reconcile survives a plugin that cannot even cancel',
        () async {
      // reconcileStaleNotification() is the FIRST platform call the app
      // makes, on the startup path, before sync is wired up.
      final _ThrowingPort port = _ThrowingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await expectLater(notifier.reconcileStaleNotification(), completes);
      expect(port.cancelAttempts, 1);
    });

    test('one failed call does not poison every later notification', () async {
      // The platform calls are chained through a single pending future. An
      // error left in that chain propagates to every `.then` after it, so a
      // transient failure would silently kill the shade for the session —
      // and each later sync would hand its caller a failed future too.
      final _ThrowingPort port = _ThrowingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0, model: null);
      await expectLater(
        notifier.sync(hasActive: true, queuedCount: 2, model: null),
        completes,
      );
      await expectLater(
        notifier.sync(hasActive: false, queuedCount: 0, model: null),
        completes,
      );

      expect(
        port.showAttempts,
        2,
        reason: 'every state must still reach the platform after a failure',
      );
      expect(port.cancelAttempts, 1);
    });

    test('dispose survives a throwing port', () async {
      final _ThrowingPort port = _ThrowingPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await notifier.sync(hasActive: true, queuedCount: 0, model: null);
      await expectLater(notifier.dispose(), completes);
    });

    test('the null port is a silent, successful stand-in', () async {
      // What the providers fall back to when the plugin cannot even be
      // CONSTRUCTED. It must satisfy the notifier without doing anything.
      const TranscriptionNotificationPort port =
          NullTranscriptionNotificationPort();
      final TranscriptionNotifier notifier = TranscriptionNotifier(port: port);

      await expectLater(
        notifier.sync(hasActive: true, queuedCount: 1, model: null),
        completes,
      );
      await expectLater(notifier.dispose(), completes);
    });
  });
}
