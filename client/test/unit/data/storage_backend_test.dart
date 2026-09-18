// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:tangent/data/storage/filesystem_capture_io.dart';
import 'package:flutter/services.dart';
import 'package:tangent/data/storage/saf_storage_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_codec.dart';
import '../../support/storage_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('legacy file invalid source stays anchored and links are not resolved',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final link = Link(f.directory('alias'));
    await link.create(f.directory('A'));
    for (final raw in ['', 'relative', f.directory('alias')]) {
      final captured = requireOk(
        await f.backend.inspectLegacyStorage(filesystemLegacyDirectory: raw),
      )!;
      expect(captured.location, isNull);
      final resolved = requireOk(
        await f.backend.inspectLegacyStorage(
          filesystemLegacyDirectory: f.directory('B'),
          frozenAnchorJson: captured.anchorJson,
        ),
      )!;
      expect(resolved.location, isNull);
      expect(resolved.anchorJson, captured.anchorJson);
    }
    for (final anchor in ['', '{', StorageCodec.encodeLegacySafAnchor(null)]) {
      expect(
        await f.backend.inspectLegacyStorage(
          filesystemLegacyDirectory: f.directory('B'),
          frozenAnchorJson: anchor,
        ),
        isA<Fail<LegacyStorage?>>(),
      );
    }
    expect(Directory(f.directory('A')).listSync(), isEmpty);
    expect(Directory(f.directory('B')).listSync(), isEmpty);
  });
  test(
      'SAF legacy protocol rejects missing null mismatched and foreign responses',
      () async {
    const channel = MethodChannel('fixture/legacy-protocol');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final anchor =
        StorageCodec.encodeLegacySafAnchor('content://Fixture.Provider/tree/A');
    Object? response;
    Map<String, Object?>? problem;
    var starts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'inspectLegacyStorage') {
        starts++;
        return null;
      }
      if (call.method == 'operationState') {
        return {'state': 'settled', 'result': response, 'problem': problem};
      }
      return null;
    });
    final backend = SafStorageBackend(channel: channel);
    addTearDown(() async {
      await backend.drain();
      messenger.setMockMethodCallHandler(channel, null);
    });
    final goodDirectory = {
      'version': 1,
      'kind': 'saf',
      'path': '',
      'authority': 'Fixture.Provider',
      'treeUri': 'content://Fixture.Provider/tree/A',
      'documentId': 'opaque-child',
    };
    final goodLocation = {
      'version': 1,
      'id': 'fixture-root',
      'label': 'Tangent',
      'directory': goodDirectory,
    };
    for (final bad in <Object?>[
      null,
      {},
      {'location': null},
      {'location': null, 'anchorJson': 1},
      {'location': null, 'anchorJson': '$anchor '},
      {
        'location': null,
        'anchorJson': StorageCodec.encodeLegacyFileAnchor('/A'),
      },
      {'location': <String, Object?>{}, 'anchorJson': anchor},
      {'location': 42, 'anchorJson': anchor},
      {
        'location': {1: 2},
        'anchorJson': anchor,
      },
      {
        'location': jsonDecode(
          StorageCodec.encodeLocation(fileLocation('fixture-file', '/A')),
        ),
        'anchorJson': anchor,
      },
      {
        'location': {
          ...goodLocation,
          'directory': {
            ...goodDirectory,
            'treeUri': 'content://Fixture.Provider/tree/B',
          },
        },
        'anchorJson': anchor,
      },
    ]) {
      response = bad;
      final result = await backend.inspectLegacyStorage(
        filesystemLegacyDirectory: 'ignored',
        frozenAnchorJson: anchor,
      );
      expect(
        result,
        isA<Fail<LegacyStorage?>>()
            .having((e) => e.problem.code, 'code', ProblemCode.invalid),
      );
    }
    response = {'location': goodLocation, 'anchorJson': anchor};
    expect(
      requireOk(
        await backend.inspectLegacyStorage(
          filesystemLegacyDirectory: 'ignored',
          frozenAnchorJson: anchor,
        ),
      )!
          .location!
          .directory
          .documentId,
      'opaque-child',
    );
    expect(
      await backend.inspectLegacyStorage(
        filesystemLegacyDirectory: 'ignored',
      ),
      isA<Fail<LegacyStorage?>>(),
    ); // capture cannot resolve
    final before = starts;
    for (final raw in ['', '{', StorageCodec.encodeLegacyFileAnchor('/A')]) {
      expect(
        await backend.inspectLegacyStorage(
          filesystemLegacyDirectory: 'ignored',
          frozenAnchorJson: raw,
        ),
        isA<Fail<LegacyStorage?>>(),
      );
    }
    expect(starts, before);
    response = null;
    expect(
      requireOk(
        await backend.inspectLegacyStorage(
          filesystemLegacyDirectory: 'ignored',
        ),
      ),
      isNull,
    );
    for (final code in ['invalid', 'denied', 'io', 'unavailable']) {
      problem = {'code': code, 'message': 'synthetic'};
      expect(
        await backend.inspectLegacyStorage(
          filesystemLegacyDirectory: 'ignored',
        ),
        isA<Fail<LegacyStorage?>>()
            .having((e) => e.problem.code.name, 'code', code),
      );
    }
  });
  test(
      'SAF legacy failed observation cannot settle native work or lose anchor on reattach',
      () async {
    const channel = MethodChannel('fixture/legacy-lifetime');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final anchor =
        StorageCodec.encodeLegacySafAnchor('content://fixture/tree/A');
    var finished = false;
    String? id;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'inspectLegacyStorage') {
        id = (call.arguments as Map)['operationId'] as String;
        throw PlatformException(code: 'unavailable');
      }
      if (call.method == 'operationState') {
        return finished
            ? {
                'state': 'settled',
                'result': {'location': null, 'anchorJson': anchor},
              }
            : {'state': 'pending'};
      }
      if (call.method == 'activeOperations') {
        return [
          {
            'operationId': id,
            'key': {'dumpId': 'fixture-native', 'incarnation': 'fixture-epoch'},
            'kind': 'read',
          }
        ];
      }
      return null;
    });
    final old = SafStorageBackend(channel: channel);
    final next = SafStorageBackend(channel: channel);
    addTearDown(() async {
      finished = true;
      await old.drain();
      await next.drain();
      messenger.setMockMethodCallHandler(channel, null);
    });
    expect(
      await old.inspectLegacyStorage(
        filesystemLegacyDirectory: 'ignored',
        frozenAnchorJson: anchor,
      ),
      isA<Fail<LegacyStorage?>>(),
    );
    var drained = false;
    final drain = old.drain().then((_) {
      drained = true;
    });
    final inventory = await next.unsettledUses();
    var settledUse = false;
    final observation = inventory.single.settled.then((_) {
      settledUse = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(drained, isFalse);
    expect(settledUse, isFalse);
    finished = true;
    await drain;
    await observation;
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    await expectLater(next.unsettledUses(), throwsA(isA<StorageFault>()));
  });
  test('legacy file capture is snapshot-only and resolve ignores later B',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final missing = f.directory('missing-A');
    final capture = requireOk(
      await f.backend.inspectLegacyStorage(filesystemLegacyDirectory: missing),
    )!;
    expect(capture.location, isNull);
    final snapshot = jsonDecode(capture.anchorJson) as Map;
    expect(snapshot, {
      'version': 1,
      'kind': 'legacy-file-root',
      'policy': 'direct-root-v1',
      'path': missing,
    });
    expect(Directory(missing).existsSync(), isFalse);
    final unavailable = requireOk(
      await f.backend.inspectLegacyStorage(
        filesystemLegacyDirectory: f.directory('B'),
        frozenAnchorJson: capture.anchorJson,
      ),
    )!;
    expect(unavailable.location, isNull);
    Directory(missing).createSync();
    final frozen = '  ${capture.anchorJson}\n';
    final resolved = requireOk(
      await f.backend.inspectLegacyStorage(
        filesystemLegacyDirectory: f.directory('B'),
        frozenAnchorJson: frozen,
      ),
    )!;
    expect(resolved.location!.directory.path, missing);
    expect(resolved.anchorJson, frozen);
    expect(Directory(missing).listSync(), isEmpty);
  });
  test('legacy file supplied anchor resolves A not mutable B', () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final anchor = jsonEncode({
      'version': 1,
      'kind': 'legacy-file-root',
      'policy': 'direct-root-v1',
      'path': f.directory('A'),
    });
    final result = requireOk(
      await f.backend.inspectLegacyStorage(
        filesystemLegacyDirectory: f.directory('B'),
        frozenAnchorJson: anchor,
      ),
    )!;
    expect(result.location!.directory.path, f.directory('A'));
    expect(result.anchorJson, anchor);
  });
  test('SAF legacy null location is intentional and frozen argument is exact',
      () async {
    const channel = MethodChannel('fixture/legacy');
    const anchor =
        ' { "version":1, "kind":"legacy-saf-selection", "policy":"tree-root-documents-or-tangent-v1", "selectedTreeUri":"content://Fixture.Provider/tree/A%2fopaque" } ';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'inspectLegacyStorage') {
        calls.add(call.arguments as Map<Object?, Object?>);
        return null;
      }
      if (call.method == 'operationState') {
        return {
          'state': 'settled',
          'result': {'location': null, 'anchorJson': anchor},
        };
      }
      return null;
    });
    final backend = SafStorageBackend(channel: channel);
    addTearDown(() async {
      await backend.drain();
      messenger.setMockMethodCallHandler(channel, null);
    });
    final result = requireOk(
      await backend.inspectLegacyStorage(
        filesystemLegacyDirectory: 'ignored-B',
        frozenAnchorJson: anchor,
      ),
    )!;
    expect(result.location, isNull);
    expect(result.anchorJson, anchor);
    expect(calls.single['frozenAnchorJson'], anchor);
    final captured = requireOk(
      await backend.inspectLegacyStorage(
        filesystemLegacyDirectory: 'ignored-B',
      ),
    )!;
    expect(captured.location, isNull);
    expect(calls.last.containsKey('frozenAnchorJson'), isFalse);
  });
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
  test(
      'restored operation the native side no longer retains settles as failed '
      'instead of polling forever', () async {
    // Regression: a reattached op whose ID the supervisor dropped (process
    // killed mid-publication) threw 'unknown' on every operationState poll.
    // The untyped decode path swallowed it and slept 50ms forever — a hot
    // loop that pinned the restored capture fence, so every later save and
    // record attempt was rejected busy while the process burned CPU until
    // Android killed it (EXCESSIVE CPU USAGE). The op must settle instead.
    const channel = MethodChannel('fixture/native-unretained');
    const key = (dumpId: 'fixture-lost', incarnation: 'inc-lost');
    var polls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'activeOperations') {
        return [
          {
            'operationId': 'op-lost',
            'key': {'dumpId': key.dumpId, 'incarnation': key.incarnation},
            'kind': 'capture',
            'method': 'publishPreparedCaptureAt',
          }
        ];
      }
      if (call.method == 'operationState') {
        polls++;
        throw PlatformException(code: 'unknown');
      }
      throw PlatformException(code: 'unsupported');
    });
    final backend = SafStorageBackend(channel: channel);
    addTearDown(() async {
      await backend.drain();
      messenger.setMockMethodCallHandler(channel, null);
    });
    final restored = await backend.unsettledUses();
    expect(restored.single.key, key);
    // Must settle promptly (releasing any fence pinned on settled) rather
    // than looping. Before the fix this timeout fired with polls unbounded.
    await restored.single.settled.timeout(const Duration(seconds: 3));
    expect(polls, 1);
  });
  test('publication keeps staging and refuses existing capture targets',
      () async {
    final f = StorageFixture.create();
    addTearDown(f.close);
    final staging = File('${f.directory('stage')}/fixture-reservation.opus');
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
      'mode': 'brain_dump',
    };
    final digest = sha256.convert([4, 5, 6]).toString();
    final prepared = await settled(
      f.backend.prepareCapture(
        reservation,
        jsonEncode(metadata),
        digest,
        'capture-${reservation.id}-prepare',
        observeOnly: false,
      ),
    );
    expect(prepared.state, CapturePreparationState.prepared);
    final published = requireOk(
      await settled(
        f.backend.publishPreparedCapture(reservation, prepared.preparation!),
      ),
    );
    expect(published.sizeBytes, 3);
    expect(await staging.readAsBytes(), [4, 5, 6]);
    expect(await f.audio('A', 'fixture-new').readAsBytes(), [4, 5, 6]);
    expect(
      FilesystemCaptureIo.prepare(reservation, jsonEncode(metadata), digest)
          .problem!
          .code,
      ProblemCode.conflict,
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
