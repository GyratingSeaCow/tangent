// SPDX-License-Identifier: AGPL-3.0-or-later
/// What the sync button tells the user.
///
/// This message is the entire feature as far as the user is concerned: most
/// syncs produce no visible change, so the sentence is the only evidence the
/// button did anything. A wrong word here is a wrong feature.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/widgets/sync_button.dart';

void main() {
  group('syncMessageFor', () {
    test('a sync that moved nothing says so plainly', () {
      // "Synced: " with no numbers reads like something happened. It did not.
      expect(
        syncMessageFor(const SyncReport(outcome: SyncOutcome.success)),
        'Already up to date',
      );
    });

    test('a one-way sync names the direction', () {
      expect(
        syncMessageFor(
          const SyncReport(outcome: SyncOutcome.success, pulled: 3),
        ),
        'Synced: received 3',
      );
      expect(
        syncMessageFor(
          const SyncReport(outcome: SyncOutcome.success, pushed: 2),
        ),
        'Synced: sent 2',
      );
    });

    test('a two-way sync names both directions', () {
      expect(
        syncMessageFor(
          const SyncReport(outcome: SyncOutcome.success, pulled: 3, pushed: 2),
        ),
        'Synced: received 3, sent 2',
      );
    });

    test('a conflict is surfaced, never buried under a success message', () {
      // A forked notebook the user is not told about looks exactly like a bug
      // — and the fork exists precisely so nothing was silently overwritten.
      final String message = syncMessageFor(
        const SyncReport(
          outcome: SyncOutcome.success,
          pulled: 1,
          conflicts: 1,
        ),
      );

      expect(message, contains('two devices'));
      expect(
        message,
        contains('both versions kept'),
        reason: 'the user must know nothing was thrown away',
      );
    });

    test('several conflicts are counted', () {
      expect(
        syncMessageFor(
          const SyncReport(outcome: SyncOutcome.success, conflicts: 3),
        ),
        contains('3 copies'),
      );
    });

    test('offline does not claim a successful sync', () {
      expect(
        syncMessageFor(const SyncReport(outcome: SyncOutcome.offline)),
        'No connection — nothing synced',
      );
    });

    test('a failure surfaces the real reason', () {
      // Swallowing the error leaves the user with nothing to act on.
      expect(
        syncMessageFor(
          const SyncReport(
            outcome: SyncOutcome.failed,
            error: 'Connection refused',
          ),
        ),
        'Sync failed: Connection refused',
      );
    });

    test('a failure with no error text still reports failure', () {
      expect(
        syncMessageFor(const SyncReport(outcome: SyncOutcome.failed)),
        startsWith('Sync failed:'),
      );
    });

    test('a second press while running is not reported as success', () {
      expect(
        syncMessageFor(const SyncReport(outcome: SyncOutcome.alreadyRunning)),
        'Already syncing',
      );
    });
  });
}
