// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/saf_storage_backend.dart';
import 'package:tangent/data/storage/storage_contract.dart';

/// `inspectLocation` answers one question: is the recording folder still
/// reachable? It used to answer it by invoking `listRecordingsAt`, which
/// enumerates and parses every recording in the folder and then throws the
/// result away.
///
/// Measured on device: that made a record tap cost 5.8 s on an 81-file folder,
/// paid EVERY time, before the microphone was touched. reserveCapture was 6650
/// of 6795 ms total, and _present (this call) was 5799 ms of that.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fixture/inspect-location');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const location = (
    id: 'fixture-location',
    label: 'Fixture',
    directory: (
      kind: 'saf',
      path: '',
      treeUri: 'content://fixture/tree/root',
      authority: 'fixture',
      documentId: 'root'
    )
  );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('inspectLocation probes reachability without enumerating the folder',
      () async {
    final invoked = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      invoked.add(call.method);
      if (call.method == 'activeOperations') return <dynamic>[];
      if (call.method == 'acknowledgeOperation') return null;
      // Native starts an operation, then the poll settles it with no payload.
      if (call.method == 'probeLocationAt' ||
          call.method == 'listRecordingsAt') {
        return {'operationId': (call.arguments as Map)['operationId']};
      }
      return {'state': 'settled', 'result': null};
    });

    final backend = SafStorageBackend(channel: channel);
    final result = await backend.inspectLocation(location).result;

    expect(result, isA<Ok<void>>());
    expect(
      invoked,
      isNot(contains('listRecordingsAt')),
      reason: 'Reachability must not enumerate every recording in the folder — '
          'that cost 5.8s per record tap on the real device.',
    );
    expect(invoked, contains('probeLocationAt'));
  });

  test('an unreachable folder still fails the reservation', () async {
    // The probe must keep its guarantee: if the folder is gone, reserving a
    // capture has to fail rather than record into nowhere.
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'activeOperations') return <dynamic>[];
      if (call.method == 'acknowledgeOperation') return null;
      if (call.method == 'probeLocationAt') {
        return {'operationId': (call.arguments as Map)['operationId']};
      }
      return {
        'state': 'settled',
        'problem': {
          'code': 'absent',
          'message': 'Recording folder is unavailable',
        },
      };
    });

    final backend = SafStorageBackend(channel: channel);
    final result = await backend.inspectLocation(location).result;

    expect(result, isA<Fail<void>>());
    expect((result as Fail<void>).problem.code, ProblemCode.absent);
  });
}
