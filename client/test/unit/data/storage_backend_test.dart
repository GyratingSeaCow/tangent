// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:tangent/data/storage/saf_storage_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import '../../support/storage_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final cleanup in ['false', 'throwing']) {
    test('SAF probe preserves exact renamed receipts after $cleanup cleanup',
        () async {
      const channel = MethodChannel('fixture/probe-receipts');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // Same literal provider returns asserted at the native ProbeReceipts /
      // StorageChannel seam. This tests transport/decoding, not a real provider.
      const a =
          'content://Fixture.Provider/tree/root%2Fgrant/document/A%2fopaque';
      const b =
          'content://Fixture.Provider/tree/root%2Fgrant/document/%42%2FOpaque';
      final location = (
        id: 'fixture-location',
        label: 'fixture',
        directory: (
          kind: 'saf',
          path: '',
          treeUri: 'content://Fixture.Provider/tree/root%2Fgrant',
          authority: 'Fixture.Provider',
          documentId: 'root/grant'
        )
      );
      String? operationId;
      final acknowledged = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        if (call.method == 'validateCandidate') {
          expect(args['token'], 'fixture-probe');
          operationId = args['operationId'] as String;
          return {'operationId': operationId};
        }
        expect(args['operationId'], operationId);
        if (call.method == 'operationState') {
          return {
            'state': 'settled',
            'result': {
              'owned': [a, b],
              'cleaned': false,
            },
          };
        }
        if (call.method == 'acknowledgeOperation') {
          acknowledged.complete();
          return null;
        }
        throw PlatformException(code: 'unsupported');
      });
      final backend = SafStorageBackend(channel: channel);
      addTearDown(() async {
        await backend.drain();
        messenger.setMockMethodCallHandler(channel, null);
      });
      final receipt = requireOk(
        await settled(backend.validateCandidate('fixture-probe', location)),
      );
      expect(receipt.cleaned, isFalse);
      expect(receipt.owned, [(kind: 'saf', value: a), (kind: 'saf', value: b)]);
      await acknowledged.future.timeout(const Duration(seconds: 3));
    });
  }
  test(
      'SAF listing isolates malformed per-file metadata and preserves valid peers',
      () async {
    const channel = MethodChannel('fixture/import');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final location = (
      id: 'fixture-location',
      label: 'fixture',
      directory: (
        kind: 'saf',
        path: '',
        treeUri: 'content://fixture/tree/root',
        authority: 'fixture',
        documentId: 'root'
      )
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listRecordingsAt') {
        return {'operationId': (call.arguments as Map)['operationId']};
      }
      if (call.method == 'acknowledgeOperation') return null;
      return {
        'state': 'settled',
        'result': [
          for (final meta in [
            '[]',
            '{"schemaVersion":2,"id":"fixture-a","title":"valid"}',
          ])
            {
              'id': 'fixture-a',
              'audio': {
                'version': 1,
                'kind': 'saf',
                'value': 'content://fixture/document/audio',
              },
              'sizeBytes': 3,
              'modifiedAt': 1234,
              'metadataJson': meta,
              'problem': null,
            },
        ],
      };
    });
    final backend = SafStorageBackend(channel: channel);
    addTearDown(() async {
      await backend.drain();
      messenger.setMockMethodCallHandler(channel, null);
    });
    final rows = requireOk(await settled(backend.listRecordingsAt(location)));
    expect(rows.first.problem?.code, ProblemCode.invalid);
    expect(rows.last.metadata?['title'], 'valid');
    expect(rows.last.problem, isNull);
  });
  test(
      'SAF channel loss cannot settle outstanding native work and replacement reattaches',
      () async {
    const channel = MethodChannel('fixture/storage');
    var online = true;
    var nativeSettled = false;
    var started = false;
    var acknowledged = false;
    final key = (dumpId: 'fixture-native', incarnation: 'inc-native');
    final binding = (
      key: key,
      location: (
        id: 'fixture-location',
        label: 'fixture',
        directory: (
          kind: 'saf',
          path: '',
          treeUri: 'content://fixture/tree/root',
          authority: 'fixture',
          documentId: 'root'
        )
      ),
      audio: (kind: 'saf', value: 'content://fixture/document/audio'),
      metadataName: 'fixture-native.meta.json'
    );
    String? operationId;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?) ?? {};
      if (call.method == 'readAudioAt') {
        started = true;
        operationId = args['operationId'] as String;
        return {'operationId': operationId};
      }
      if (!online) throw PlatformException(code: 'unavailable');
      if (call.method == 'activeOperations') {
        return [
          {
            'operationId': operationId,
            'key': {'dumpId': key.dumpId, 'incarnation': key.incarnation},
            'kind': 'read',
          }
        ];
      }
      if (call.method == 'operationState') {
        return nativeSettled
            ? {
                'state': 'settled',
                'result': Uint8List.fromList([1, 2]),
              }
            : {'state': 'pending'};
      }
      if (call.method == 'acknowledgeOperation') {
        acknowledged = true;
        return null;
      }
      throw PlatformException(code: 'unsupported');
    });
    final backend = SafStorageBackend(channel: channel);
    addTearDown(() async {
      online = true;
      nativeSettled = true;
      await backend.drain();
      messenger.setMockMethodCallHandler(channel, null);
    });
    final op = backend.readAudio(binding);
    var settled = false;
    unawaited(
      op.settled.then((_) {
        settled = true;
      }),
    );
    while (!started) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    online = false;
    expect(await op.result, isA<Fail<Uint8List>>());
    expect(settled, isFalse);
    expect(acknowledged, isFalse);
    final replacement = SafStorageBackend(channel: channel);
    await expectLater(
      replacement.unsettledUses(),
      throwsA(isA<StorageFault>()),
    );
    online = true;
    final restored = await replacement.unsettledUses();
    expect(restored.single.key, key);
    nativeSettled = true;
    await restored.single.settled.timeout(const Duration(seconds: 3));
    await op.settled.timeout(const Duration(seconds: 3));
    expect(settled, isTrue);
    await replacement.drain();
  });
  test('publication keeps staging and refuses existing capture targets',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final staging = File('${f.directory('stage')}/fixture-new.opus');
    await staging.writeAsBytes([4, 5, 6]);
    final reservation = (
      id: 'fixture-reservation',
      key: (dumpId: 'fixture-new', incarnation: 'inc-new'),
      location: fileLocation('A', f.directory('A')),
      stagingPath: staging.path,
      mode: 'brain_dump',
      startedAt: DateTime.utc(2030),
      phase: CapturePhase.stopped
    );
    final metadata = <String, dynamic>{
      'schemaVersion': 2,
      'id': 'fixture-new',
      'title': 'new',
    };
    final published = requireOk(
      await settled(f.backend.publishCapture(reservation, metadata)),
    );
    expect(published.sizeBytes, 3);
    expect(await staging.readAsBytes(), [4, 5, 6]);
    expect(await f.audio('A', 'fixture-new').readAsBytes(), [4, 5, 6]);
    expect(
      await settled(f.backend.publishCapture(reservation, metadata)),
      isA<Fail<PublishedCapture>>(),
    );
    expect(await f.audio('A', 'fixture-new').readAsBytes(), [4, 5, 6]);
  });
  test(
      'metadata, probe and listing stay at explicit root without touching unrelated partials',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-a');
    final foreign = File('${f.directory('A')}/fixture-a.meta.json.partial');
    await foreign.writeAsString('foreign');
    requireOk(
      await settled(
        f.backend.writeMetadata(
          a,
          {'schemaVersion': 2, 'id': 'fixture-a', 'title': 'edited'},
          'fixture-write',
        ),
      ),
    );
    expect(
      await f.metadata('A', 'fixture-a').readAsString(),
      contains('edited'),
    );
    final receipt = requireOk(
      await settled(
        f.backend.validateCandidate('fixture-probe', a.location),
      ),
    );
    expect(receipt.cleaned, isTrue);
    expect(receipt.owned, isNotEmpty);
    for (final owned in receipt.owned) {
      expect(await File(owned.value).exists(), isFalse);
    }
    final listed =
        requireOk(await settled(f.backend.listRecordingsAt(a.location)));
    expect(listed.single.id, 'fixture-a');
    expect(listed.single.metadata?['title'], 'edited');
    expect(await foreign.readAsString(), 'foreign');
  });
  test(
      'outside binding and linked component are rejected, unavailable root is not absence',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-a');
    await f.audio('B', 'fixture-a').writeAsBytes([9]);
    final bad = (
      key: a.key,
      location: a.location,
      audio: (kind: 'file', value: f.audio('B', 'fixture-a').path),
      metadataName: a.metadataName
    );
    expect(await settled(f.backend.readAudio(bad)), isA<Fail<Uint8List>>());
    expect(
      (await settled(
        f.backend.deleteComponent(bad, RecordingComponent.audio, 'fixture-bad'),
      ))
          .state,
      ComponentState.failed,
    );
    await f.audio('A', 'fixture-a').delete();
    await Link(f.audio('A', 'fixture-a').path)
        .create(f.audio('B', 'fixture-a').path);
    expect(
      (await settled(
        f.backend.deleteComponent(a, RecordingComponent.audio, 'fixture-link'),
      ))
          .state,
      ComponentState.failed,
    );
    expect(await f.audio('B', 'fixture-a').readAsBytes(), [9]);
    await Link(f.audio('A', 'fixture-a').path).delete();
    await f.metadata('A', 'fixture-a').delete();
    await Directory(f.directory('A')).delete();
    expect(
      (await settled(
        f.backend.deleteComponent(a, RecordingComponent.audio, 'fixture-gone'),
      ))
          .state,
      ComponentState.failed,
    );
  });
  test('bound A read/delete never follows same-ID B decoy', () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-a');
    await f.audio('B', 'fixture-a').writeAsBytes([9, 9, 9]);
    await f.metadata('B', 'fixture-a').writeAsString('unrelated');
    expect(requireOk(await settled(f.backend.readAudio(a))), [1, 2, 3]);
    final removed = await settled(
      f.backend.deleteComponent(a, RecordingComponent.audio, 'op-audio'),
    );
    expect(removed.state, ComponentState.removed);
    final absent = await settled(
      f.backend.deleteComponent(a, RecordingComponent.audio, 'op-audio-again'),
    );
    expect(absent.state, ComponentState.absent);
    expect(await f.audio('B', 'fixture-a').readAsBytes(), [9, 9, 9]);
    expect(await f.metadata('B', 'fixture-a').readAsString(), 'unrelated');
  });
  test('directory masquerading as metadata is never recursively deleted',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final a = await f.seed('fixture-a');
    await f.metadata('A', 'fixture-a').delete();
    final directory =
        await Directory(f.metadata('A', 'fixture-a').path).create();
    await File('${directory.path}/keep').writeAsString('unrelated');
    final result = await settled(
      f.backend.deleteComponent(a, RecordingComponent.metadata, 'op-directory'),
    );
    expect(result.state, ComponentState.failed);
    expect(await File('${directory.path}/keep').readAsString(), 'unrelated');
  });
}
