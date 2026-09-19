// SPDX-License-Identifier: AGPL-3.0-or-later
/// Device registration, as the server actually sees it.
///
/// The first version of this shipped reading Platform.environment for the
/// Android model, which is always empty on Android, so BOTH physical devices
/// registered as the literal string "Android device" and the server's device
/// list could not tell the tablet from the phone. Unit tests passed the whole
/// time because nothing ever constructed the engine and watched what it sent.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/models/sync_change.dart';
import 'package:tangent/services/connectivity_service.dart';
import 'package:tangent/services/document_sync_engine.dart';
import 'package:tangent/services/transcription_client.dart';

class _RecordingClient implements TranscriptionClient {
  String? registeredName;
  String? registeredId;

  @override
  Future<void> registerDevice({
    required String deviceId,
    required String displayName,
    required String platform,
  }) async {
    registeredId = deviceId;
    registeredName = displayName;
  }

  @override
  Future<SyncPullPage> pullChanges({
    required String deviceId,
    required int sinceSeq,
  }) async =>
      const SyncPullPage(changes: [], headSeq: 0, hasMore: false);

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
  // Returns a real ConnectivityStatus, not a bare bool: noSuchMethod would
  // happily hand back the wrong type and the engine would treat this device
  // as offline, making every test in this file pass for the wrong reason.
  @override
  Future<ConnectivityStatus> currentStatus() async => ConnectivityStatus.wifi;

  @override
  Stream<ConnectivityStatus> get statusStream =>
      Stream<ConnectivityStatus>.value(ConnectivityStatus.wifi);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

void main() {
  late LocalDb db;
  late _RecordingClient client;

  setUp(() {
    db = LocalDb.forTesting(NativeDatabase.memory());
    client = _RecordingClient();
  });

  tearDown(() async => db.close());

  DocumentSyncEngine build({required Future<String> Function() label}) =>
      DocumentSyncEngine(
        db: () => db,
        client: () => client,
        connectivity: _OnlineConnectivity(),
        deviceLabel: label,
        newDeviceId: 'device-under-test',
      );

  test('the label the platform reports is what the server is told', () async {
    final DocumentSyncEngine engine = build(label: () async => 'SM-X520');

    await engine.syncNow();

    expect(
      client.registeredName,
      'SM-X520',
      reason: 'the server device list must name real hardware',
    );
    expect(client.registeredId, 'device-under-test');
  });

  test('a device that cannot name itself still syncs', () async {
    // A naming failure is cosmetic. Letting it abort the cycle would turn a
    // trivial problem into no sync at all.
    final DocumentSyncEngine engine = build(
      label: () async => throw StateError('platform channel unavailable'),
    );

    final SyncReport report = await engine.syncNow();

    expect(report.outcome, isNot(SyncOutcome.failed));
  });

  test('identity is minted once and then reused', () async {
    final DocumentSyncEngine engine = build(label: () async => 'SM-X520');

    await engine.syncNow();
    final String? first = client.registeredId;
    client.registeredId = null;
    await engine.syncNow();

    // Second cycle reuses the stored identity rather than minting a new one,
    // or every sync would add another phantom device to the server's list.
    expect(client.registeredId ?? first, first);
    final SyncStateRow state = await db.syncState(newDeviceId: 'unused');
    expect(state.deviceId, first);
  });
}
