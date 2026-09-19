// SPDX-License-Identifier: AGPL-3.0-or-later
/// Merge rules for multi-device sync.
///
/// These are the decisions that decide whether a user keeps their work, so
/// they are tested as pure functions rather than only through the engine.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/sync_change.dart';

void main() {
  group('decideMerge', () {
    test('an entity this device has never seen is accepted', () {
      expect(
        decideMerge(
          localExists: false,
          localDirty: false,
          localUpdatedAt: 0,
          remoteUpdatedAt: 500,
        ),
        MergeDecision.accept,
      );
    });

    test('a clean local copy accepts the server version', () {
      // Nothing local is at risk, so there is nothing to lose.
      expect(
        decideMerge(
          localExists: true,
          localDirty: false,
          localUpdatedAt: 100,
          remoteUpdatedAt: 500,
        ),
        MergeDecision.accept,
      );
    });

    test('a clean local copy accepts even an OLDER server version', () {
      // Counterintuitive but deliberate: a clean row holds no unsynced work,
      // and the alternative is a device that never converges.
      expect(
        decideMerge(
          localExists: true,
          localDirty: false,
          localUpdatedAt: 900,
          remoteUpdatedAt: 100,
        ),
        MergeDecision.accept,
      );
    });

    test('a genuine two-sided conflict forks instead of overwriting', () {
      // THE RULE THAT MATTERS. Last-write-wins here would silently destroy a
      // page of ink when the other device saved a title edit a second later.
      expect(
        decideMerge(
          localExists: true,
          localDirty: true,
          localUpdatedAt: 400,
          remoteUpdatedAt: 500,
        ),
        MergeDecision.fork,
        reason: 'both sides edited; neither may be discarded',
      );
    });

    test('a dirty local copy still forks when it is NEWER than the remote',
        () {
      // Being newer is not ownership: the remote edit is somebody's work too.
      expect(
        decideMerge(
          localExists: true,
          localDirty: true,
          localUpdatedAt: 900,
          remoteUpdatedAt: 500,
        ),
        MergeDecision.fork,
      );
    });

    test('our own push echoing back is not a conflict', () {
      // Identical timestamps mean the same save arriving back, which must not
      // fork the notebook in two.
      expect(
        decideMerge(
          localExists: true,
          localDirty: true,
          localUpdatedAt: 500,
          remoteUpdatedAt: 500,
        ),
        MergeDecision.keepLocal,
      );
    });
  });

  group('forkedTitle', () {
    test('names the source so the conflict is visible in the list', () {
      expect(
        forkedTitle('Groceries', 'SM-X520'),
        'Groceries (conflict from SM-X520)',
      );
    });
  });

  group('RemoteChange', () {
    test('a delete carries no payload', () {
      final RemoteChange change = RemoteChange.fromJson(<String, dynamic>{
        'seq': 7,
        'entity_type': 'notebook',
        'entity_id': 'nb-1',
        'op': 'delete',
        'payload': null,
      });

      expect(change.op, SyncOp.delete);
      expect(change.payload, isNull);
    });

    test('an unknown op decodes as an upsert rather than throwing', () {
      // A newer server must not be able to crash an older client.
      final RemoteChange change = RemoteChange.fromJson(<String, dynamic>{
        'seq': 1,
        'entity_type': 'notebook',
        'entity_id': 'nb-1',
        'op': 'something_new',
      });

      expect(change.op, SyncOp.upsert);
    });
  });

  group('PushResult', () {
    test('a rejection is not mistaken for an acceptance', () {
      final PushResult result = PushResult.fromJson(<String, dynamic>{
        'entity_id': 'nb-1',
        'entity_type': 'notebook',
        'seq': 0,
        'status': 'rejected',
        'reason': 'bad payload',
      });

      expect(result.applied, isFalse);
      expect(result.reason, 'bad payload');
    });
  });
}
