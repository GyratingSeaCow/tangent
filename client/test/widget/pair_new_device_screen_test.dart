// SPDX-License-Identifier: AGPL-3.0-or-later
/// The pair-a-new-device display: an already-paired device shows the 6-digit
/// codes from /v1/pair/pending so nobody has to read docker logs. Codes are
/// polled every 5 s while the screen is up; the poll dies with the screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/models/api_exception.dart';
import 'package:tangent/models/pair_pending.dart';
import 'package:tangent/screens/server/pair_new_device_screen.dart';
import 'package:tangent/screens/server/server_connection_screen.dart'
    show transcriptionClientProvider;
import 'package:tangent/services/transcription_client.dart';

/// Serves whatever [entries] currently holds; flip [failWith] to make the
/// next fetch throw. Counts fetches so tests can see polling happen (and
/// stop).
class _FakePendingClient extends TranscriptionClient {
  _FakePendingClient() : super(baseUrl: 'http://unused.invalid');

  List<PairPendingEntry> entries = <PairPendingEntry>[];
  Object? failWith;
  int fetchCount = 0;

  @override
  Future<List<PairPendingEntry>> pairPending() async {
    fetchCount += 1;
    final Object? error = failWith;
    if (error != null) throw error;
    return List<PairPendingEntry>.of(entries);
  }
}

PairPendingEntry _entry({
  String pairId = 'pair-1',
  String displayName = "Jeff's tablet",
  String platform = 'android',
  required DateTime requestedAt,
  String code = '123456',
}) {
  return PairPendingEntry(
    pairId: pairId,
    displayName: displayName,
    platform: platform,
    requestedAt: requestedAt,
    code: code,
  );
}

Future<void> _mount(
  WidgetTester tester,
  _FakePendingClient client, {
  DateTime Function()? clock,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        transcriptionClientProvider.overrideWith((ref) => client),
      ],
      child: MaterialApp(home: PairNewDeviceScreen(clock: clock)),
    ),
  );
  // Let the initState fetch complete. pumpAndSettle would spin forever on
  // the poll timer, so pump discrete frames instead.
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('shows a pending request: name, platform, and the code BIG',
      (tester) async {
    final DateTime base = DateTime.utc(2026, 1, 1, 12);
    final _FakePendingClient client = _FakePendingClient()
      ..entries = <PairPendingEntry>[_entry(requestedAt: base)];
    await _mount(tester, client, clock: () => base);

    expect(find.text("Jeff's tablet"), findsOneWidget);
    expect(find.textContaining('android'), findsOneWidget);
    // The code is the payload — split 123 456 for read-across-the-room.
    final Finder codeFinder =
        find.byKey(const ValueKey<String>('pair-pending-code-pair-1'));
    expect(codeFinder, findsOneWidget);
    final Text codeText = tester.widget<Text>(codeFinder);
    expect(codeText.data, '123 456');
    expect(
      codeText.style?.fontSize,
      greaterThanOrEqualTo(40),
      reason: 'the code is read across the room — it must be BIG',
    );
  });

  testWidgets('counts down to expiry as the clock advances', (tester) async {
    DateTime now = DateTime.utc(2026, 1, 1, 12);
    final _FakePendingClient client = _FakePendingClient()
      ..entries = <PairPendingEntry>[_entry(requestedAt: now)];
    await _mount(tester, client, clock: () => now);

    // Fresh request: full 120 s TTL remains.
    expect(find.textContaining('120 s'), findsOneWidget);

    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('117 s'), findsOneWidget);
  });

  testWidgets('empty state INSTRUCTS: start pairing on the new device first',
      (tester) async {
    final _FakePendingClient client = _FakePendingClient();
    await _mount(tester, client);

    expect(
      find.textContaining('On the new device'),
      findsOneWidget,
      reason: 'an empty list must teach the flow, not shrug',
    );
    expect(find.textContaining('Find my server'), findsOneWidget);
  });

  testWidgets('says so and offers retry when the fetch fails', (tester) async {
    final _FakePendingClient client = _FakePendingClient()
      ..failWith = const ApiException(
        statusCode: 401,
        code: 'http_error',
        message: 'HTTP 401',
      );
    await _mount(tester, client);

    expect(find.textContaining('not authorized'), findsOneWidget);

    // Recovery: the server likes us again, Retry refetches and shows codes.
    final DateTime base = DateTime.utc(2026, 1, 1, 12);
    client
      ..failWith = null
      ..entries = <PairPendingEntry>[_entry(requestedAt: base)];
    await tester.tap(
      find.byKey(const ValueKey<String>('pair-pending-retry')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text("Jeff's tablet"), findsOneWidget);
  });

  testWidgets('a poll tick picks up newly arrived requests', (tester) async {
    final DateTime base = DateTime.utc(2026, 1, 1, 12);
    final _FakePendingClient client = _FakePendingClient();
    await _mount(tester, client, clock: () => base);
    expect(client.fetchCount, 1, reason: 'one fetch on open');
    expect(find.textContaining('On the new device'), findsOneWidget);

    // The other device taps "Find my server" → a request appears server-side.
    client.entries = <PairPendingEntry>[_entry(requestedAt: base)];
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(
      client.fetchCount,
      greaterThanOrEqualTo(2),
      reason: 'the 5 s poll must refetch',
    );
    expect(find.text("Jeff's tablet"), findsOneWidget);
  });

  testWidgets('dispose cancels the poll — no fetches after the screen dies',
      (tester) async {
    final _FakePendingClient client = _FakePendingClient();
    await _mount(tester, client);
    expect(client.fetchCount, 1);

    // Navigate away: unmount the screen entirely.
    await tester.pumpWidget(const MaterialApp(home: Placeholder()));
    await tester.pump(const Duration(seconds: 30));

    expect(
      client.fetchCount,
      1,
      reason: 'a disposed screen must not keep polling',
    );
    // flutter_test additionally fails this test on its own if the periodic
    // timer leaked past the end of the test body.
  });
}
