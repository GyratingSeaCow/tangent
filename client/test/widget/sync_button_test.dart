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
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/screens/dump/dumps_list_screen.dart';
import 'package:tangent/screens/dump/dumps_providers.dart';
import 'package:tangent/screens/home/home_providers.dart'
    show documentSyncEngineProvider;
import 'package:tangent/screens/settings/ai_summaries_section.dart'
    show summariesClientProvider;
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/services/summaries_client.dart';
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

/// A client that syncs instantly and moves nothing.
class _IdleClient implements TranscriptionClient {
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
  }) async =>
      SyncPullPage(changes: const [], headSeq: sinceSeq, hasMore: false);

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

/// A Google client that FAILS the test if any screen but To Do reaches it.
class _ForbiddenGoogleClient extends SummariesClient {
  _ForbiddenGoogleClient() : super(baseUrl: 'http://unused.invalid');

  @override
  Future<GoogleTasksStatus> getGoogleTasksStatus() async =>
      fail('Recordings must not consult Google Tasks on sync');

  @override
  Future<GoogleTasksStatus> syncGoogleTasksNow() async =>
      fail('Recordings must not push to Google Tasks on sync');
}

class _OfflineConnectivity implements ConnectivityService {
  @override
  Future<ConnectivityStatus> currentStatus() async => ConnectivityStatus.offline;

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

  group('afterSync hook (v1.30.0)', () {
    Future<void> mountAndTap(
      WidgetTester tester, {
      required AfterSyncHook? afterSync,
      ConnectivityService? connectivity,
    }) async {
      final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final DocumentSyncEngine engine = DocumentSyncEngine(
        db: () => db,
        client: () => _IdleClient(),
        connectivity: connectivity ?? _OnlineConnectivity(),
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
                actions: [
                  SyncButton(
                    engineProvider: engineProvider,
                    afterSync: afterSync,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('sync-button')));
      await tester.pumpAndSettle();
    }

    Future<void> unmount(WidgetTester tester) async {
      // The snackbar's dismiss timer outlives the test otherwise.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }

    testWidgets('no hook: the message is exactly what syncMessageFor says',
        (tester) async {
      await mountAndTap(tester, afterSync: null);
      expect(find.text('Already up to date'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a hook returning null leaves the message untouched',
        (tester) async {
      int calls = 0;
      await mountAndTap(tester, afterSync: () async {
        calls++;
        return null;
      });
      expect(calls, 1);
      expect(find.text('Already up to date'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a hook\'s text is appended to the message', (tester) async {
      await mountAndTap(tester, afterSync: () async => ' · Google updated');
      expect(find.text('Already up to date · Google updated'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a hook that throws does not break the snackbar',
        (tester) async {
      await mountAndTap(
        tester,
        afterSync: () async => throw const ApiException(
          statusCode: 502,
          code: 'upstream',
          message: 'Google unreachable',
        ),
      );
      expect(
        find.text('Already up to date · Google: Google unreachable'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    testWidgets('the hook is skipped when the device sync did not run',
        (tester) async {
      // Offline: there is nothing fresh to forward, and "Google updated"
      // after "No connection" would be a lie.
      int calls = 0;
      await mountAndTap(
        tester,
        connectivity: _OfflineConnectivity(),
        afterSync: () async {
          calls++;
          return ' · Google updated';
        },
      );
      expect(calls, 0);
      expect(find.text('No connection — nothing synced'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('Recordings passes no hook: Google is never consulted and '
        'the message is unchanged', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final LocalDb db = LocalDb.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final DocumentSyncEngine engine = DocumentSyncEngine(
        db: () => db,
        client: () => _IdleClient(),
        connectivity: _OnlineConnectivity(),
        deviceLabel: () async => 'test-device',
        newDeviceId: 'device-1',
      );
      addTearDown(engine.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            deletionEligibilityProvider.overrideWith(
              (_) => Stream.value(const <String, Eligibility>{}),
            ),
            dumpsProvider.overrideWith((_) => Stream.value(const <DumpRow>[])),
            documentSyncEngineProvider.overrideWithValue(engine),
            summariesClientProvider.overrideWith(
              (ref) => Future<SummariesClient>.value(_ForbiddenGoogleClient()),
            ),
          ],
          child: const MaterialApp(home: DumpsListScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final SyncButton button =
          tester.widget<SyncButton>(find.byType(SyncButton));
      expect(button.afterSync, isNull, reason: 'only To Do forwards to Google');

      await tester.tap(find.byKey(const ValueKey<String>('sync-button')));
      await tester.pumpAndSettle();
      expect(find.text('Already up to date'), findsOneWidget);
      expect(find.textContaining('Google'), findsNothing);
      await unmount(tester);
    });
  });

  group('afterSyncErrorSuffix', () {
    test('an ApiException contributes its message only', () {
      expect(
        afterSyncErrorSuffix(const ApiException(
          statusCode: 502,
          code: 'upstream',
          message: 'Google unreachable',
        )),
        ' · Google: Google unreachable',
      );
    });

    test('a generic exception loses its type prefix and stays one line', () {
      expect(
        afterSyncErrorSuffix(Exception('boom\nstack line')),
        ' · Google: boom',
      );
    });

    test('a long message is cut so the snackbar stays one line', () {
      final String suffix = afterSyncErrorSuffix(Exception('x' * 200));
      expect(suffix.length, lessThan(100));
      expect(suffix, endsWith('…'));
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
