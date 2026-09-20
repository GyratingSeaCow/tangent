// SPDX-License-Identifier: AGPL-3.0-or-later
/// What the sync button tells the user.
///
/// This message is the entire feature as far as the user is concerned: most
/// syncs produce no visible change, so the sentence is the only evidence the
/// button did anything. A wrong word here is a wrong feature.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';
import 'package:tangent/widgets/sync_button.dart';

/// A client whose pull blocks until the test releases it, so the widget can
/// be observed while the engine is genuinely mid-sync.
class _GatedClient implements TranscriptionClient {
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> registerDevice({
    required String deviceId,
    required String displayName,
    required String platform,
  }) async {}

  @override
  Future<SyncPullPage> pullChanges({
    required String deviceId,
    required int sinceSeq,
  }) async {
    await gate.future;
    return SyncPullPage(changes: const [], headSeq: sinceSeq, hasMore: false);
  }

  @override
  Future<List<PushResult>> pushChanges({
    required String deviceId,
    required List<Map<String, dynamic>> changes,
  }) async =>
      const <PushResult>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _OnlineConnectivity implements ConnectivityService {
  @override
  Future<ConnectivityStatus> currentStatus() async => ConnectivityStatus.wifi;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

void main() {
  group('SyncButton spinner', () {
    testWidgets('clears when the engine finishes even if nothing else '
        'rebuilds the screen', (tester) async {
      // The Fold bug: on a screen where the sync pulls nothing, no stream
      // fires, nothing rebuilds, and an unwatched spinner spins forever.
      // The button itself must listen to the engine it is showing.
      final _GatedClient client = _GatedClient();
      final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final DocumentSyncEngine engine = DocumentSyncEngine(
        db: () => db,
        client: () => client,
        connectivity: _OnlineConnectivity(),
        deviceLabel: () async => 'test-device',
        newDeviceId: 'device-1',
      );
      addTearDown(engine.dispose);
      final Provider<DocumentSyncEngine> engineProvider =
          Provider<DocumentSyncEngine>((ref) => engine);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(
                actions: [SyncButton(engineProvider: engineProvider)],
              ),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.sync), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('sync-button')));
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator),
        findsOneWidget,
        reason: 'mid-sync the button must show it is working',
      );

      client.gate.complete();
      await tester.pump();
      await tester.pump();

      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'the sync ended; a spinner that outlives it reads as a hang',
      );
      expect(find.byIcon(Icons.sync), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });

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
