// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:tangent/data/storage/saf_storage_backend.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import '../../support/storage_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/capture_publication_codec.dart';
import 'package:tangent/data/storage/storage_contract.dart';

const _sourceDigest =
    '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81';
const _safMetadata =
    '{ "schemaVersion": 2, "id": "fixture-dump", "mode": "meeting", "title": "café 🧪", "transcript": null }';
CaptureReservation _safReservation({
  CapturePhase phase = CapturePhase.stopped,
}) =>
    (
      id: 'fixture-reservation',
      key: (dumpId: 'fixture-dump', incarnation: 'fixture-owner'),
      location: (
        id: 'fixture-location',
        label: 'fixture root',
        directory: (
          kind: 'saf',
          path: '',
          authority: 'capture.fixture',
          treeUri: 'content://capture.fixture/tree/primary%3Aroot',
          documentId: 'primary:root'
        )
      ),
      stagingPath: '/fixture/fixture-reservation.opus',
      mode: 'meeting',
      startedAt:
          DateTime.fromMillisecondsSinceEpoch(1893553445123, isUtc: true),
      phase: phase
    );
PreparedCapture _safPrepared() {
  final r = _safReservation();
  CaptureComponentClaim claim(
    RecordingComponent component,
    String name,
    String id,
    String encoded,
  ) =>
      (
        component: component,
        name: name,
        locator: (
          kind: 'saf',
          value:
              'content://capture.fixture/tree/primary%3Aroot/document/$encoded'
        ),
        identity: (
          kind: 'saf-document',
          scope: 'capture.fixture',
          objectId: id,
          generation: null
        )
      );
  return (
    publicationId: r.id,
    reservationId: r.id,
    key: r.key,
    location: r.location,
    stagingPath: r.stagingPath,
    sourceIdentity: (
      kind: 'posix-file',
      scope: '8:1',
      objectId: '18446744073709551615',
      generation: null
    ),
    rootIdentity: (
      kind: 'saf-document',
      scope: 'capture.fixture',
      objectId: 'primary:root',
      generation: null
    ),
    audioSizeBytes: 3,
    audioSha256: _sourceDigest,
    metadataJson: _safMetadata,
    audio: claim(
      RecordingComponent.audio,
      'fixture-dump.opus',
      'primary:opaque/path-0',
      'primary%3aopaque%2fpath-0',
    ),
    metadata: claim(
      RecordingComponent.metadata,
      'fixture-dump.meta.json',
      'primary:opaque/path-1',
      'primary%3Aopaque%2Fpath-1',
    )
  );
}

Map<String, dynamic> _safResult() {
  final p = _safPrepared();
  return jsonDecode(
    CapturePublicationCodec.encodeResult(
      (
        state: CapturePreparationState.prepared,
        preparation: p,
        rawReturnedLocators: [
          p.audio!.locator.value,
          p.metadata!.locator.value,
        ],
        problem: null
      ),
    ),
  ) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('frozen reservation rejects a zero startedAtMs before dispatch', () {
    final r = _safReservation();
    final invalid = (
      id: r.id,
      key: r.key,
      location: r.location,
      stagingPath: r.stagingPath,
      mode: r.mode,
      startedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      phase: r.phase
    );
    expect(
      () => CapturePublicationCodec.reservationMap(invalid),
      throwsA(isA<StorageFault>()),
    );
  });
  test(
      'restored preparation inventory observes settlement without consuming receipt',
      () async {
    const channel = MethodChannel('fixture-capture-inventory');
    var acknowledgements = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'activeOperations':
          return [
            {
              'operationId': 'capture-fixture-inventory-prepare',
              'key': {
                'version': 1,
                'dumpId': 'fixture-dump',
                'incarnation': 'fixture-owner',
              },
              'kind': 'capture',
              'method': 'prepareCaptureAt',
            },
          ];
        case 'operationState':
          return {
            'state': 'settled',
            'result': {'version': 1, 'state': 'uncertain'},
          };
        case 'acknowledgeOperation':
          acknowledgements++;
          return null;
        default:
          fail('Unexpected dispatch ${call.method}');
      }
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final backend = SafStorageBackend(channel: channel);
    final uses = await backend.unsettledUses();
    await uses.single.settled;
    await backend.drain();
    await pumpEventQueue();
    expect(acknowledgements, 0);
  });
  test('unknown capture observation settles finitely without dispatch',
      () async {
    const channel = MethodChannel('fixture-capture-unknown');
    final backend = SafStorageBackend(channel: channel);
    var cleanup = false;
    var polls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'operationState');
      polls++;
      if (cleanup) {
        return {
          'state': 'settled',
          'problem': {'code': 'unresolved', 'message': 'fixture cleanup'},
        };
      }
      throw PlatformException(
        code: 'unknown',
        message: 'Operation is not retained',
      );
    });
    addTearDown(() async {
      cleanup = true;
      await backend.drain().timeout(const Duration(seconds: 3));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final r = _safReservation();
    final op = backend.prepareCapture(
      r,
      _safMetadata,
      _sourceDigest,
      'capture-${r.id}-prepare',
      observeOnly: true,
    );
    await op.settled.timeout(const Duration(milliseconds: 250));
    final result = await op.result;
    expect(result.state, CapturePreparationState.uncertain);
    expect(result.problem!.code, ProblemCode.unresolved);
    expect(polls, 1);
  });
  test(
      'failed observer retains worker fence and exact receipt until explicit ack',
      () async {
    const channel = MethodChannel('fixture-capture-lifetime');
    final worker = Completer<void>();
    var starts = 0;
    var acks = 0;
    var ackFails = true;
    Map<dynamic, dynamic>? frozen;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      if (call.method == 'prepareCaptureAt') {
        starts++;
        frozen = args;
        expect(args['metadataJson'], _safMetadata);
        expect((args['reservation'] as Map)['startedAtMs'], 1893553445123);
        expect((args['reservation'] as Map).containsKey('phase'), isFalse);
        throw PlatformException(
          code: 'io',
          message: 'lost method response after dispatch',
        );
      }
      if (call.method == 'operationState') {
        expect(args['capturePayload'], frozen);
        await worker.future;
        return {'state': 'settled', 'result': _safResult()};
      }
      if (call.method == 'acknowledgeOperation') {
        acks++;
        expect(args['preparationOnly'], true);
        if (ackFails) {
          throw PlatformException(
            code: 'denied',
            message: 'fixture ack failed',
          );
        }
        return null;
      }
      fail('Unexpected method ${call.method}');
    });
    final backend = SafStorageBackend(channel: channel);
    final replacement = SafStorageBackend(channel: channel);
    addTearDown(() async {
      if (!worker.isCompleted) worker.complete();
      await backend.drain();
      await replacement.drain();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final r = _safReservation();
    final id = 'capture-${r.id}-prepare';
    final old = backend.prepareCapture(
      r,
      _safMetadata,
      _sourceDigest,
      id,
      observeOnly: false,
    );
    expect((await old.result).state, CapturePreparationState.uncertain);
    var settledEarly = false;
    final observing = old.settled.then((_) {
      settledEarly = true;
    });
    await pumpEventQueue();
    expect(settledEarly, isFalse);
    expect(acks, 0);
    worker.complete();
    await observing;
    final recovered = await settled(
      replacement.prepareCapture(
        _safReservation(phase: CapturePhase.failed),
        _safMetadata,
        _sourceDigest,
        id,
        observeOnly: true,
      ),
    );
    expect(recovered.preparation, _safPrepared());
    expect(starts, 1);
    expect(acks, 0);
    expect(
      await replacement.acknowledgeCapturePreparation(id),
      isA<Fail<void>>(),
    );
    expect(
      (await settled(
        replacement.prepareCapture(
          r,
          _safMetadata,
          _sourceDigest,
          id,
          observeOnly: true,
        ),
      ))
          .state,
      CapturePreparationState.prepared,
    );
    ackFails = false;
    requireOk(await replacement.acknowledgeCapturePreparation(id));
    expect(acks, 2);
    expect(starts, 1);
  });
  test(
      'malformed preparation retains raw returns without TypeError or authority',
      () async {
    const channel = MethodChannel('fixture-capture-malformed');
    final malformed = _safResult();
    malformed['state'] = 'notStarted';
    malformed['rawReturnedLocators'] = [
      'not a URI',
      ...malformed['rawReturnedLocators'] as List,
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'operationState');
      return {'state': 'settled', 'result': malformed};
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final backend = SafStorageBackend(channel: channel);
    final r = _safReservation();
    final observed = await settled(
      backend.prepareCapture(
        r,
        _safMetadata,
        _sourceDigest,
        'capture-${r.id}-prepare',
        observeOnly: true,
      ),
    );
    expect(observed.state, CapturePreparationState.uncertain);
    expect(observed.problem!.code, ProblemCode.invalid);
    expect(observed.rawReturnedLocators.first, 'not a URI');
    expect(observed.preparation, _safPrepared());
  });
  test(
      'inspection and publication strictly decode wire and never call old publisher',
      () async {
    const channel = MethodChannel('fixture-capture-decoders');
    final p = _safPrepared();
    final r = _safReservation();
    final methods = <String>[];
    String? active;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'inspectPreparedCaptureAt' ||
          call.method == 'publishPreparedCaptureAt') {
        active = call.method;
        expect(
          (call.arguments as Map)['preparation'],
          CapturePublicationCodec.preparationMap(p),
        );
        return {'operationId': (call.arguments as Map)['operationId']};
      }
      if (call.method == 'operationState') {
        return {
          'state': 'settled',
          'result': active == 'inspectPreparedCaptureAt'
              ? {
                  'version': 1,
                  'audio': {'version': 1, 'state': 'complete', 'problem': null},
                  'metadata': {'version': 1, 'state': 'empty', 'problem': null},
                }
              : {'binding': <String, Object?>{}, 'sizeBytes': 3.5},
        };
      }
      if (call.method == 'acknowledgeOperation') return null;
      fail('Unapproved method ${call.method}');
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final backend = SafStorageBackend(channel: channel);
    final inspection =
        requireOk(await settled(backend.inspectPreparedCapture(r, p)));
    expect(inspection.audio.state, CaptureContentState.complete);
    expect(inspection.metadata.state, CaptureContentState.empty);
    expect(
      await settled(backend.publishPreparedCapture(r, p)),
      isA<Fail<PublishedCapture>>(),
    );
    await pumpEventQueue();
    expect(methods, isNot(contains('publishCaptureAt')));
  });
  test(
      'strict prepared codec preserves nullable partial claims and exact escaped URIs',
      () {
    final p = _safPrepared();
    final raw = CapturePublicationCodec.preparationMap(p);
    raw['metadata'] = null;
    final partial = CapturePublicationCodec.decodePreparation(jsonEncode(raw));
    expect(partial.metadata, isNull);
    expect(partial.audio!.locator.value, p.audio!.locator.value);
    final uncertain = (
      state: CapturePreparationState.uncertain,
      preparation: partial,
      rawReturnedLocators: ['raw-malformed-diagnostic'],
      problem: (code: ProblemCode.unavailable, message: 'fixture query')
    );
    expect(
      CapturePublicationCodec.decodeResult(
        CapturePublicationCodec.encodeResult(uncertain),
      ).preparation,
      partial,
    );
    expect(sha256.convert([1, 2, 3]).toString(), _sourceDigest);
    expect(utf8.encode(partial.metadataJson), utf8.encode(_safMetadata));
  });
  for (final field in [
    'version',
    'extra',
    'audioSizeBytes',
    'audioSha256',
    'rootIdentity',
    'audio',
  ]) {
    test('strict prepared codec rejects malformed $field before mutation', () {
      final raw = CapturePublicationCodec.preparationMap(_safPrepared());
      switch (field) {
        case 'version':
          raw[field] = 2;
        case 'extra':
          raw[field] = true;
        case 'audioSizeBytes':
          raw[field] = 3.5;
        case 'audioSha256':
          raw[field] = _sourceDigest.toUpperCase();
        case 'rootIdentity':
          (raw[field] as Map)['objectId'] = 'other-root';
        case 'audio':
          (raw[field] as Map)['locator'] = {
            'version': 1,
            'kind': 'saf',
            'value': 'content://wrong/document/foreign',
          };
      }
      expect(
        () => CapturePublicationCodec.decodePreparation(jsonEncode(raw)),
        throwsA(isA<StorageFault>()),
      );
    });
  }
  group('real prepared filesystem publication', () {
    late Directory root;
    late CaptureReservation reservation;
    late FilesystemStorageBackend backend;
    late String metadata;
    late String digest;
    var serial = 0;
    setUp(() {
      root = Directory.systemTemp.createTempSync('tangent-prepared-fixture-');
      final destination = Directory(p.join(root.path, 'destination'))
        ..createSync();
      final id = 'fixture-prepare-${serial++}';
      final source = File(p.join(root.path, '$id.opus'))
        ..writeAsBytesSync([1, 2, 3]);
      reservation = (
        id: id,
        key: (dumpId: '$id-dump', incarnation: '$id-incarnation'),
        location: fileLocation('fixture-root', destination.path),
        stagingPath: source.path,
        mode: 'meeting',
        startedAt: DateTime.utc(2030, 1, 2, 3, 4, 5, 123),
        phase: CapturePhase.stopped
      );
      metadata =
          '{ "schemaVersion": 2, "id": "${reservation.key.dumpId}", "mode": "meeting", "title": "café 🧪", "transcript": null }';
      digest = sha256.convert(source.readAsBytesSync()).toString();
      backend = FilesystemStorageBackend();
    });
    tearDown(() async {
      await backend.drain();
      await backend
          .acknowledgeCapturePreparation('capture-${reservation.id}-prepare');
      root.deleteSync(recursive: true);
    });
    Future<CapturePreparationResult> prepare({bool observeOnly = false}) =>
        settled(
          backend.prepareCapture(
            reservation,
            metadata,
            digest,
            'capture-${reservation.id}-prepare',
            observeOnly: observeOnly,
          ),
        );
    test(
        'empty claims freeze before content and complete pair replays read-only',
        () async {
      final prepared = await prepare();
      expect(prepared.state, CapturePreparationState.prepared);
      final frozen = CapturePublicationCodec.decodePreparation(
        CapturePublicationCodec.encodePreparation(prepared.preparation!),
      );
      expect(File(frozen.audio!.locator.value).lengthSync(), 0);
      expect(File(frozen.metadata!.locator.value).lengthSync(), 0);
      expect(frozen.metadataJson, metadata);
      expect(
        requireOk(
          await settled(
            backend.inspectPreparedCapture(reservation, frozen),
          ),
        ).audio.state,
        CaptureContentState.empty,
      );
      final published = requireOk(
        await settled(backend.publishPreparedCapture(reservation, frozen)),
      );
      expect(published.binding.location, reservation.location);
      expect(File(frozen.audio!.locator.value).readAsBytesSync(), [1, 2, 3]);
      expect(
        File(frozen.metadata!.locator.value).readAsBytesSync(),
        utf8.encode(metadata),
      );
      final second = FilesystemStorageBackend();
      final inspected = requireOk(
        await settled(second.inspectPreparedCapture(reservation, frozen)),
      );
      expect(inspected.audio.state, CaptureContentState.complete);
      expect(inspected.metadata.state, CaptureContentState.complete);
      expect(
        requireOk(
          await settled(
            second.publishPreparedCapture(reservation, frozen),
          ),
        ),
        published,
      );
      expect(File(reservation.stagingPath).readAsBytesSync(), [1, 2, 3]);
      final roundtrip = CapturePublicationCodec.decodeResult(
        CapturePublicationCodec.encodeResult(prepared),
      );
      expect(roundtrip.preparation, frozen);
    });
    test(
        'unknown observation creates nothing and replacement observer does not consume receipt',
        () async {
      expect(
        (await prepare(observeOnly: true)).state,
        CapturePreparationState.uncertain,
      );
      expect(
        Directory(reservation.location.directory.path).listSync(),
        isEmpty,
      );
      final first = await prepare();
      final replacement = FilesystemStorageBackend();
      for (final use in await replacement.unsettledUses()) {
        await use.settled;
      }
      final observed = await settled(
        replacement.prepareCapture(
          reservation,
          metadata,
          digest,
          'capture-${reservation.id}-prepare',
          observeOnly: true,
        ),
      );
      expect(observed.preparation, first.preparation);
      requireOk(
        await replacement
            .acknowledgeCapturePreparation('capture-${reservation.id}-prepare'),
      );
      expect((await prepare()).state, CapturePreparationState.uncertain);
      expect(File(first.preparation!.audio!.locator.value).lengthSync(), 0);
    });
    for (final component in ['audio', 'metadata', 'both']) {
      test('foreign preexisting $component targets cannot be claimed',
          () async {
        final audio = File(
          p.join(
            reservation.location.directory.path,
            '${reservation.key.dumpId}.opus',
          ),
        );
        final meta = File(
          p.join(
            reservation.location.directory.path,
            '${reservation.key.dumpId}.meta.json',
          ),
        );
        if (component != 'metadata') audio.writeAsBytesSync([1, 2, 3]);
        if (component != 'audio') meta.writeAsStringSync(metadata);
        final result = await prepare();
        expect(result.state, CapturePreparationState.notStarted);
        expect(result.problem!.code, ProblemCode.conflict);
        expect(result.rawReturnedLocators, isEmpty);
        if (component != 'metadata') expect(audio.readAsBytesSync(), [1, 2, 3]);
        if (component != 'audio') expect(meta.readAsStringSync(), metadata);
      });
    }
    test('partial metadata prevents even empty audio initialization', () async {
      final frozen = (await prepare()).preparation!;
      File(frozen.metadata!.locator.value).writeAsBytesSync([9]);
      expect(
        await settled(backend.publishPreparedCapture(reservation, frozen)),
        isA<Fail<PublishedCapture>>(),
      );
      expect(File(frozen.audio!.locator.value).lengthSync(), 0);
      expect(File(frozen.metadata!.locator.value).readAsBytesSync(), [9]);
    });
    test('equal-size source modification fails before any target write',
        () async {
      final frozen = (await prepare()).preparation!;
      File(reservation.stagingPath).writeAsBytesSync([9, 8, 7]);
      expect(
        await settled(backend.inspectPreparedCapture(reservation, frozen)),
        isA<Fail<CaptureInspection>>(),
      );
      expect(
        await settled(backend.publishPreparedCapture(reservation, frozen)),
        isA<Fail<PublishedCapture>>(),
      );
      expect(File(frozen.audio!.locator.value).lengthSync(), 0);
      expect(File(frozen.metadata!.locator.value).lengthSync(), 0);
    });
    if (Platform.isWindows) {
      test('complete filesystem pair reconciles with read-only targets',
          () async {
        final frozen = (await prepare()).preparation!;
        final published = requireOk(
          await settled(backend.publishPreparedCapture(reservation, frozen)),
        );
        final paths = [
          frozen.audio!.locator.value,
          frozen.metadata!.locator.value,
        ];
        try {
          for (final path in paths) {
            expect(Process.runSync('attrib.exe', ['+R', path]).exitCode, 0);
          }
          expect(
            requireOk(
              await settled(
                FilesystemStorageBackend()
                    .publishPreparedCapture(reservation, frozen),
              ),
            ),
            published,
          );
        } finally {
          for (final path in paths) {
            expect(Process.runSync('attrib.exe', ['-R', path]).exitCode, 0);
          }
        }
      });
    }
    test('missing claimed component is absent and never recreated', () async {
      final frozen = (await prepare()).preparation!;
      File(frozen.audio!.locator.value).deleteSync();
      final inspection = requireOk(
        await settled(backend.inspectPreparedCapture(reservation, frozen)),
      );
      expect(inspection.audio.state, CaptureContentState.absent);
      expect(
        await settled(backend.publishPreparedCapture(reservation, frozen)),
        isA<Fail<PublishedCapture>>(),
      );
      expect(File(frozen.audio!.locator.value).existsSync(), isFalse);
      expect(File(reservation.stagingPath).readAsBytesSync(), [1, 2, 3]);
    });
    test('byte-identical foreign replacement cannot be reconciled', () async {
      final frozen = (await prepare()).preparation!;
      requireOk(
        await settled(backend.publishPreparedCapture(reservation, frozen)),
      );
      final audio = File(frozen.audio!.locator.value);
      audio.renameSync('${audio.path}.original');
      audio.writeAsBytesSync([1, 2, 3]);
      expect(
        requireOk(
          await settled(
            backend.inspectPreparedCapture(reservation, frozen),
          ),
        ).audio.state,
        CaptureContentState.foreign,
      );
      expect(
        await settled(backend.publishPreparedCapture(reservation, frozen)),
        isA<Fail<PublishedCapture>>(),
      );
      expect(audio.readAsBytesSync(), [1, 2, 3]);
    });
  });
  const windows = (
    kind: 'windows-file',
    scope: 'fedcba9876543210',
    objectId: '000102030405060708090a0b0c0d0e0f',
    generation: '18446744073709551615'
  );
  test('capture identity preserves exact unsigned native representation', () {
    expect(
      CapturePublicationCodec.decodeIdentity(
        CapturePublicationCodec.encodeIdentity(windows),
      ),
      windows,
    );
  });
  for (final mutation in <String, Object?>{
    'version': 2,
    'extra': true,
    'scope': 'FEDCBA9876543210',
    'objectId': '000102030405060708090A0B0C0D0E0F',
    'generation': '18446744073709551616',
    'kind': 'path-only',
  }.entries) {
    test('capture identity rejects malformed ${mutation.key}', () {
      final raw = jsonDecode(CapturePublicationCodec.encodeIdentity(windows))
          as Map<String, dynamic>;
      raw[mutation.key] = mutation.value;
      expect(
        () => CapturePublicationCodec.decodeIdentity(jsonEncode(raw)),
        throwsA(isA<StorageFault>()),
      );
    });
  }
}
