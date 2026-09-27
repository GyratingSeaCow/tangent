// SPDX-License-Identifier: AGPL-3.0-or-later
/// The "summary in progress" rule (v1.18.0): pending = this device asked
/// more recently than the server last answered, and asked under ten
/// minutes ago. Imported from production, never restated here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/services/summary_pending.dart';

DumpRow _row({
  int? requestedAt,
  int? summarizedAt,
  String? template,
  String? status,
  int? queuePosition,
  int? dismissedAt,
}) =>
    DumpRow(
      id: 'p-1',
      createdAt: DateTime.utc(2026, 9, 26),
      updatedAt: DateTime.utc(2026, 9, 26),
      mode: 'meeting',
      durationSeconds: 4,
      title: 'Planning',
      audioPath: '/audio/p-1.opus',
      audioSizeBytes: 3,
      syncStatus: 'synced',
      syncAttempts: 0,
      transcriptionStatus: 'completed',
      transcriptionAttempt: 1,
      transcript: 'hello',
      summarizedAt: summarizedAt,
      summaryRequestedAt: requestedAt,
      summaryTemplate: template,
      summaryStatus: status,
      summaryQueuePosition: queuePosition,
      summaryErrorDismissedAt: dismissedAt,
    );

void main() {
  // 2026-09-26T12:00:00Z as unix seconds.
  const int t0 = 1790424000;
  final DateTime now = DateTime.fromMillisecondsSinceEpoch(
    (t0 + 42) * 1000,
    isUtc: true,
  );

  group('summaryPending', () {
    test('nothing requested -> false', () {
      expect(summaryPending(_row(), now: now), isFalse);
      expect(summaryPending(_row(summarizedAt: t0), now: now), isFalse);
    });

    test('requested after the last summary -> true', () {
      expect(
        summaryPending(_row(requestedAt: t0, summarizedAt: t0 - 100), now: now),
        isTrue,
      );
    });

    test('requested with no summary ever -> true', () {
      expect(summaryPending(_row(requestedAt: t0), now: now), isTrue);
    });

    test('summarized at or after the request -> false', () {
      expect(
        summaryPending(_row(requestedAt: t0, summarizedAt: t0), now: now),
        isFalse,
        reason: 'equal timestamps: the answer is at least as new as the ask',
      );
      expect(
        summaryPending(_row(requestedAt: t0, summarizedAt: t0 + 30), now: now),
        isFalse,
      );
    });

    test('a request older than ten minutes is given up on', () {
      final DumpRow row = _row(requestedAt: t0);
      final DateTime justUnder = DateTime.fromMillisecondsSinceEpoch(
        (t0 + 10 * 60 - 1) * 1000,
        isUtc: true,
      );
      final DateTime exactly = DateTime.fromMillisecondsSinceEpoch(
        (t0 + 10 * 60) * 1000,
        isUtc: true,
      );
      expect(summaryPending(row, now: justUnder), isTrue);
      expect(summaryPending(row, now: exactly), isFalse);
      expect(summaryPendingTimeout, const Duration(minutes: 10));
    });
  });

  group('summaryPendingElapsed', () {
    test('counts from the request, clamped at zero', () {
      expect(
        summaryPendingElapsed(_row(requestedAt: t0), now),
        const Duration(seconds: 42),
      );
      expect(
        summaryPendingElapsed(_row(requestedAt: t0 + 100), now),
        Duration.zero,
      );
      expect(summaryPendingElapsed(_row(), now), Duration.zero);
    });
  });

  group('summaryTemplateDisplayName', () {
    test('presets and custom read as the server names them', () {
      expect(summaryTemplateDisplayName('meeting'), 'Meeting');
      expect(summaryTemplateDisplayName('brain_dump'), 'Brain dump');
      expect(summaryTemplateDisplayName('lecture'), 'Lecture');
      expect(summaryTemplateDisplayName('actions_only'), 'Actions only');
      expect(summaryTemplateDisplayName('custom'), 'Custom');
    });

    test('an unknown id falls back to spaced, capitalised text', () {
      expect(summaryTemplateDisplayName('daily_standup'), 'Daily standup');
      expect(summaryTemplateDisplayName(null), 'AI');
      expect(summaryTemplateDisplayName(''), 'AI');
    });
  });

  group('summaryPending with the server status (v1.19.0)', () {
    test('queued -> true, with or without a local request', () {
      expect(summaryPending(_row(status: 'queued'), now: now), isTrue);
      expect(
        summaryPending(_row(status: 'queued', queuePosition: 3), now: now),
        isTrue,
      );
    });

    test('running -> true even 30 minutes after the local request', () {
      expect(
        summaryPending(
          _row(status: 'running', requestedAt: t0),
          now: now.add(const Duration(minutes: 30)),
        ),
        isTrue,
        reason: 'a server running never expires client-side',
      );
    });

    test('failed with no local request -> false', () {
      expect(summaryPending(_row(status: 'failed'), now: now), isFalse);
    });

    test('failed with a fresh local request (a Retry 202) -> the local '
        'bridge decides', () {
      // applyRemoteDump spends the marker on every failed verdict, so a
      // surviving marker is newer than the failure: pending, with the
      // ten-minute give-up still in force.
      expect(
        summaryPending(_row(status: 'failed', requestedAt: t0), now: now),
        isTrue,
      );
      expect(
        summaryPending(
          _row(status: 'failed', requestedAt: t0),
          now: now.add(const Duration(minutes: 11)),
        ),
        isFalse,
      );
    });

    test('null status -> the local heuristic decides', () {
      expect(
        summaryPending(_row(requestedAt: t0, summarizedAt: t0 - 100), now: now),
        isTrue,
      );
      expect(
        summaryPending(
          _row(requestedAt: t0),
          now: now.add(const Duration(minutes: 11)),
        ),
        isFalse,
        reason: 'the ten-minute give-up still applies locally',
      );
      expect(summaryPending(_row(), now: now), isFalse);
    });
  });

  group('summaryFailed', () {
    test('failed and not dismissed -> true', () {
      expect(summaryFailed(_row(status: 'failed')), isTrue);
    });

    test('failed but dismissed -> false', () {
      expect(summaryFailed(_row(status: 'failed', dismissedAt: t0)), isFalse);
    });

    test('any other status -> false', () {
      expect(summaryFailed(_row()), isFalse);
      expect(summaryFailed(_row(status: 'queued')), isFalse);
      expect(summaryFailed(_row(status: 'running')), isFalse);
    });
  });

  group('summaryQueued', () {
    test('needs both queued and a position', () {
      expect(summaryQueued(_row(status: 'queued', queuePosition: 2)), isTrue);
      expect(summaryQueued(_row(status: 'queued')), isFalse);
      expect(summaryQueued(_row(status: 'running', queuePosition: 2)), isFalse);
    });
  });

  group('ordinal', () {
    test('English ordinals including the teens', () {
      expect(ordinal(1), '1st');
      expect(ordinal(2), '2nd');
      expect(ordinal(3), '3rd');
      expect(ordinal(4), '4th');
      expect(ordinal(11), '11th');
      expect(ordinal(12), '12th');
      expect(ordinal(13), '13th');
      expect(ordinal(21), '21st');
      expect(ordinal(22), '22nd');
      expect(ordinal(23), '23rd');
      expect(ordinal(101), '101st');
      expect(ordinal(111), '111th');
      expect(ordinal(112), '112th');
    });
  });
}
