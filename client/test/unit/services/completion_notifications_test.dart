// SPDX-License-Identifier: AGPL-3.0-or-later
/// Completion notifications (spec 2026-09-28), the pure layer: what the
/// shade says for each outcome, which fixed id it replaces, the
/// summaryRequestedAt gate (N4), suppression while on that recording (N3),
/// clearFor on open (N3), and the Settings switch (N6).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/completion_notifications.dart';

class _RecordingPort implements CompletionNotificationPort {
  final List<CompletionNotice> shown = <CompletionNotice>[];
  final List<int> cancelled = <int>[];

  @override
  Future<void> show(CompletionNotice notice) async => shown.add(notice);

  @override
  Future<void> cancel(int notificationId) async => cancelled.add(notificationId);
}

class _ThrowingPort implements CompletionNotificationPort {
  int attempts = 0;

  @override
  Future<void> show(CompletionNotice notice) async {
    attempts++;
    throw StateError('plugin missing');
  }

  @override
  Future<void> cancel(int notificationId) async {
    attempts++;
    throw StateError('plugin missing');
  }
}

void main() {
  group('notices', () {
    test('transcribed -> id 1002 with the title', () {
      final CompletionNotice notice = transcriptionCompletionNotice(
        dumpId: 'd1',
        title: 'Standup',
        failed: false,
      );
      expect(notice.notificationId, 1002);
      expect(notice.kind, CompletionKind.transcribed);
      expect(notice.title, 'Transcribed \u00B7 Standup');
      expect(notice.dumpId, 'd1');
    });

    test('failed -> failed wording, SAME id 1002 (replaces, never stacks)',
        () {
      final CompletionNotice notice = transcriptionCompletionNotice(
        dumpId: 'd1',
        title: 'Standup',
        failed: true,
      );
      expect(notice.notificationId, 1002);
      expect(notice.kind, CompletionKind.transcriptionFailed);
      expect(notice.title, 'Transcription failed \u00B7 Standup');
    });

    test('a blank title never renders a dangling separator', () {
      expect(
        transcriptionCompletionNotice(dumpId: 'd', title: '  ', failed: false)
            .title,
        'Transcribed \u00B7 Untitled recording',
      );
    });

    test('summary landed with requestedAt set -> 1003, body by template', () {
      final CompletionNotice? meeting = summaryCompletionNotice(
        dumpId: 'd2',
        title: 'Planning',
        template: 'meeting',
        requestedAt: 1790000000,
      );
      expect(meeting, isNotNull);
      expect(meeting!.notificationId, 1003);
      expect(meeting.title, 'Notes ready \u00B7 Planning');
      expect(meeting.body, 'Meeting notes');

      final CompletionNotice? brainDump = summaryCompletionNotice(
        dumpId: 'd2',
        title: 'Planning',
        template: 'brain_dump',
        requestedAt: 1790000000,
      );
      expect(brainDump!.body, 'Summary');
      expect(
        summaryCompletionNotice(
          dumpId: 'd2',
          title: 'Planning',
          template: null,
          requestedAt: 1,
        )!
            .body,
        'Summary',
      );
    });

    test("summary landed WITHOUT requestedAt (someone else's device asked) "
        '-> no notice', () {
      expect(
        summaryCompletionNotice(
          dumpId: 'd2',
          title: 'Planning',
          template: 'meeting',
          requestedAt: null,
        ),
        isNull,
        reason: 'only the device that asked is told',
      );
    });
  });

  group('CompletionNotifier', () {
    final CompletionNotice transcribed = transcriptionCompletionNotice(
      dumpId: 'd1',
      title: 'Standup',
      failed: false,
    );
    final CompletionNotice notes = summaryCompletionNotice(
      dumpId: 'd1',
      title: 'Standup',
      template: 'meeting',
      requestedAt: 5,
    )!;

    test('announce reaches the port', () async {
      final _RecordingPort port = _RecordingPort();
      final CompletionNotifier notifier = CompletionNotifier(port: port);
      expect(await notifier.announce(transcribed), isTrue);
      expect(port.shown, <CompletionNotice>[transcribed]);
    });

    test('suppressed while on that dump; other dumps still announced',
        () async {
      final _RecordingPort port = _RecordingPort();
      final CompletionNotifier notifier = CompletionNotifier(port: port)
        ..suppressFor('d1');
      expect(await notifier.announce(transcribed), isFalse);
      expect(port.shown, isEmpty, reason: 'the user is looking at it');

      final CompletionNotice other = transcriptionCompletionNotice(
        dumpId: 'd9',
        title: 'Other',
        failed: false,
      );
      expect(await notifier.announce(other), isTrue);
      expect(port.shown, <CompletionNotice>[other]);

      notifier.suppressFor(null);
      expect(await notifier.announce(transcribed), isTrue);
    });

    test('clearFor cancels both ids', () async {
      final _RecordingPort port = _RecordingPort();
      final CompletionNotifier notifier = CompletionNotifier(port: port);
      await notifier.announce(transcribed);
      await notifier.announce(notes);
      await notifier.clearFor('d1');
      expect(port.cancelled, unorderedEquals(<int>[1002, 1003]));
    });

    test('clearFor leaves a notice that describes ANOTHER recording',
        () async {
      final _RecordingPort port = _RecordingPort();
      final CompletionNotifier notifier = CompletionNotifier(port: port);
      await notifier.announce(transcribed); // d1 in 1002
      await notifier.announce(
        summaryCompletionNotice(
          dumpId: 'd2',
          title: 'Two',
          template: null,
          requestedAt: 1,
        )!,
      ); // d2 in 1003
      await notifier.clearFor('d1');
      expect(port.cancelled, <int>[1002]);
    });

    test('clearFor with nothing posted this process still wipes both ids '
        '(a notice outlives the process that posted it)', () async {
      final _RecordingPort port = _RecordingPort();
      final CompletionNotifier notifier = CompletionNotifier(port: port);
      await notifier.clearFor('d1');
      expect(port.cancelled, unorderedEquals(<int>[1002, 1003]));
    });

    test('switch off -> nothing shown', () async {
      final _RecordingPort port = _RecordingPort();
      bool enabled = false;
      final CompletionNotifier notifier =
          CompletionNotifier(port: port, enabled: () => enabled);
      expect(await notifier.announce(transcribed), isFalse);
      expect(await notifier.announce(notes), isFalse);
      expect(port.shown, isEmpty);
      enabled = true;
      expect(await notifier.announce(transcribed), isTrue);
    });

    test('a throwing port never fails the caller, and the chain survives',
        () async {
      final _ThrowingPort port = _ThrowingPort();
      final CompletionNotifier notifier = CompletionNotifier(port: port);
      await notifier.announce(transcribed);
      await notifier.clearFor('d1');
      await notifier.announce(notes);
      expect(port.attempts, 4, reason: 'show, 2 cancels, show all attempted');
    });

    test('after dispose nothing is delivered', () async {
      final _RecordingPort port = _RecordingPort();
      final CompletionNotifier notifier = CompletionNotifier(port: port)
        ..dispose();
      expect(await notifier.announce(transcribed), isFalse);
      await notifier.clearFor('d1');
      expect(port.shown, isEmpty);
      expect(port.cancelled, isEmpty);
    });
  });
}
