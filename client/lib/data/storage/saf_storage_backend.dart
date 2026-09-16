// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'storage_contract.dart';
import 'storage_codec.dart';

class SafStorageBackend implements StorageBackend {
  SafStorageBackend({
    MethodChannel channel = const MethodChannel('dev.tangent.tangent/storage'),
  }) : _channel = channel;
  final MethodChannel _channel;
  static int _sequence = 0;
  final Set<Future<void>> _pending = {};
  String _id() =>
      'native-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  Map<String, dynamic> _wire(String value) =>
      jsonDecode(value) as Map<String, dynamic>;
  StorageProblem _problem(Object? value) {
    if (value is Map) {
      final code = ProblemCode.values
              .where((c) => c.name == value['code'])
              .firstOrNull ??
          ProblemCode.unknown;
      return (
        code: code,
        message: value['message'] as String? ?? 'Native storage failed'
      );
    }
    return (
      code: ProblemCode.unavailable,
      message: 'Native storage observation unavailable'
    );
  }

  _NativeOperation<T> _track<T>(
    String id,
    T Function(Object?) decode,
    T Function(StorageProblem) failure, {
    String? method,
    Map<String, Object?>? args,
  }) {
    final op = _NativeOperation<T>(id);
    _pending.add(op.settled);
    unawaited(op.settled.then((_) => _pending.remove(op.settled)));
    unawaited(() async {
      if (method != null) {
        try {
          await _channel
              .invokeMethod<Object?>(method, {'operationId': id, ...?args});
        } on PlatformException {
          op.complete(failure(_problem(null)));
        } on MissingPluginException {
          op.complete(failure(_problem(null)));
        }
      }
      // Observation loss is not cancellation. A pending/missing channel cannot
      // release the native worker fence. Reattach by the same operation ID.
      while (true) {
        try {
          final state = await _channel.invokeMapMethod<String, dynamic>(
            'operationState',
            {'operationId': id},
          );
          if (state?['state'] == 'settled') {
            final delivered = !op.completion.isCompleted;
            try {
              op.complete(
                state!['problem'] != null
                    ? failure(_problem(state['problem']))
                    : decode(state['result']),
              );
            } on Object catch (e, st) {
              if (!op.completion.isCompleted) {
                op.completion.completeError(e, st);
              }
            }
            op.settlement.complete();
            // A failed old observer must not discard a late publication result.
            // A replacement can still observe/acknowledge the retained receipt.
            if (!delivered) return;
            try {
              await _channel.invokeMethod<void>(
                'acknowledgeOperation',
                {'operationId': id},
              );
            } on PlatformException {
              /* Retained native receipt is safe to reobserve. */
            } on MissingPluginException {/* Same operation remains retained. */}
            return;
          }
          if (state?['state'] != 'pending') {
            op.complete(failure(_problem(null)));
          }
        } on PlatformException {
          op.complete(failure(_problem(null)));
        } on MissingPluginException {
          op.complete(failure(_problem(null)));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }());
    return op;
  }

  IoOperation<Outcome<T>> _start<T>(
    String method,
    Map<String, Object?> args,
    T Function(Object?) decode,
  ) =>
      _track(
        _id(),
        (value) => Ok(decode(value)),
        (problem) => Fail<T>(problem),
        method: method,
        args: args,
      );
  Map<String, Object?> _binding(BoundRecording b) =>
      {'binding': _wire(StorageCodec.encodeBinding(b))};
  @override
  Future<List<RestoredUse>> unsettledUses() async {
    try {
      final entries =
          await _channel.invokeListMethod<dynamic>('activeOperations');
      if (entries == null) {
        throw const StorageFault(
          (
            code: ProblemCode.unavailable,
            message: 'Native inventory unavailable'
          ),
        );
      }
      return entries.map((dynamic value) {
        if (value is! Map ||
            value['operationId'] is! String ||
            value['key'] is! Map) {
          throw const StorageFault(
            (code: ProblemCode.invalid, message: 'Malformed native inventory'),
          );
        }
        final key = StorageCodec.decodeKey(
          jsonEncode(
            {'version': 1, ...Map<String, dynamic>.from(value['key'] as Map)},
          ),
        );
        final kinds =
            UseKind.values.where((kind) => kind.name == value['kind']);
        if (kinds.isEmpty) {
          throw const StorageFault(
            (code: ProblemCode.invalid, message: 'Unknown native use kind'),
          );
        }
        final op = _track<void>(value['operationId'] as String, (_) {}, (_) {});
        return (key: key, kind: kinds.first, settled: op.settled);
      }).toList();
    } on PlatformException {
      throw StorageFault(_problem(null));
    } on MissingPluginException {
      throw StorageFault(_problem(null));
    }
  }

  @override
  Future<Outcome<LegacyStorage?>> inspectLegacyStorage({
    required String filesystemLegacyDirectory,
    String? frozenAnchorJson,
  }) async {
    try {
      if (frozenAnchorJson != null) {
        StorageCodec.decodeLegacyAnchor(
          frozenAnchorJson,
          expectedKind: 'legacy-saf-selection',
        );
      }
      return await _start<LegacyStorage?>('inspectLegacyStorage', {
        if (frozenAnchorJson != null) 'frozenAnchorJson': frozenAnchorJson,
      }, (value) {
        Never invalid() => throw const StorageFault(
              (
                code: ProblemCode.invalid,
                message: 'Invalid legacy inspection protocol'
              ),
            );
        if (value == null) {
          if (frozenAnchorJson != null) invalid();
          return null;
        }
        if (value is! Map ||
            !value.containsKey('location') ||
            value['anchorJson'] is! String) {
          invalid();
        }
        final anchor = value['anchorJson'] as String;
        final envelope = StorageCodec.decodeLegacyAnchor(
          anchor,
          expectedKind: 'legacy-saf-selection',
        );
        if (frozenAnchorJson != null && anchor != frozenAnchorJson) invalid();
        final rawLocation = value['location'];
        if (rawLocation != null && rawLocation is! Map) invalid();
        StorageLocation? location;
        try {
          location = rawLocation == null
              ? null
              : StorageCodec.decodeLocation(jsonEncode(rawLocation));
        } on JsonUnsupportedObjectError {
          invalid();
        }
        if (frozenAnchorJson == null &&
            (location != null || envelope['selectedTreeUri'] == null)) {
          invalid();
        }
        if (location != null &&
            (location.directory.kind != 'saf' ||
                location.directory.treeUri != envelope['selectedTreeUri'])) {
          invalid();
        }
        return (location: location, anchorJson: anchor);
      }).result;
    } on StorageFault catch (e) {
      return Fail(e.problem);
    }
  }

  @override
  Future<Outcome<StorageLocation?>> pickDirectory() async {
    try {
      final value = await _channel.invokeMethod<Object?>('pickDirectory');
      return Ok(
        value == null ? null : StorageCodec.decodeLocation(jsonEncode(value)),
      );
    } on PlatformException catch (e) {
      return Fail(_problem({'code': e.code, 'message': e.message}));
    } on MissingPluginException {
      return Fail(_problem(null));
    }
  }

  @override
  IoOperation<Outcome<ProbeReceipt>> validateCandidate(
    String token,
    StorageLocation location,
  ) {
    StorageCodec.validateLiteralId(token);
    return _start('validateCandidate', {
      'token': token,
      'location': _wire(StorageCodec.encodeLocation(location)),
    }, (value) {
      final map = value as Map;
      return (
        owned: (map['owned'] as List)
            .map(
              (uri) => StorageCodec.decodeAudio(
                jsonEncode({'version': 1, 'kind': 'saf', 'value': uri}),
              ),
            )
            .toList(),
        cleaned: map['cleaned'] as bool
      );
    });
  }

  @override
  IoOperation<Outcome<void>> inspectLocation(StorageLocation location) =>
      _start<void>(
        'listRecordingsAt',
        {'location': _wire(StorageCodec.encodeLocation(location))},
        (_) {},
      );
  @override
  IoOperation<Outcome<Uint8List>> readAudio(BoundRecording binding) =>
      _start('readAudioAt', _binding(binding), (value) => value as Uint8List);
  @override
  IoOperation<Outcome<AudioLocator>> playbackSource(BoundRecording binding) =>
      _start(
        'playbackSourceAt',
        _binding(binding),
        (value) => StorageCodec.decodeAudio(jsonEncode(value)),
      );
  @override
  IoOperation<Outcome<void>> writeMetadata(
    BoundRecording binding,
    Map<String, dynamic> metadata,
    String operationId,
  ) {
    StorageCodec.validateLiteralId(operationId);
    return _start<void>(
      'writeMetadataAt',
      {
        ..._binding(binding),
        'publicationId': operationId,
        'metadataJson': jsonEncode(metadata),
      },
      (_) {},
    );
  }

  @override
  IoOperation<Outcome<PublishedCapture>> publishCapture(
    CaptureReservation r,
    Map<String, dynamic> metadata,
  ) =>
      _start('publishCaptureAt', {
        'reservation': {
          'id': r.id,
          'key': _wire(StorageCodec.encodeKey(r.key)),
          'location': _wire(StorageCodec.encodeLocation(r.location)),
          'stagingPath': r.stagingPath,
          'mode': r.mode,
          'startedAt': r.startedAt.toIso8601String(),
          'phase': r.phase.name,
        },
        'metadataJson': jsonEncode(metadata),
      }, (value) {
        final map = value as Map;
        return (
          binding: StorageCodec.decodeBinding(jsonEncode(map['binding'])),
          sizeBytes: (map['sizeBytes'] as num).toInt()
        );
      });
  @override
  IoOperation<ComponentResult> deleteComponent(
    BoundRecording binding,
    RecordingComponent component,
    String operationId,
  ) {
    StorageCodec.validateLiteralId(operationId);
    return _track(
      _id(),
      (value) {
        final map = value as Map;
        final states =
            ComponentState.values.where((s) => s.name == map['state']);
        if (states.isEmpty) {
          return (state: ComponentState.unknown, problem: _problem(null));
        }
        return (
          state: states.first,
          problem: map['problem'] == null ? null : _problem(map['problem'])
        );
      },
      (problem) => (state: ComponentState.unknown, problem: problem),
      method: 'deleteComponentAt',
      args: {
        ..._binding(binding),
        'component': component.name,
        'deletionId': operationId,
      },
    );
  }

  @override
  IoOperation<Outcome<List<ImportedEntry>>> listRecordingsAt(
    StorageLocation location,
  ) =>
      _start(
        'listRecordingsAt',
        {'location': _wire(StorageCodec.encodeLocation(location))},
        (value) => (value as List).map((dynamic raw) {
          final map = raw as Map;
          Map<String, dynamic>? metadata;
          StorageProblem? problem =
              map['problem'] == null ? null : _problem(map['problem']);
          try {
            if (map['metadataJson'] != null) {
              final decoded = jsonDecode(map['metadataJson'] as String);
              if (decoded is! Map<String, dynamic> ||
                  decoded['id'] != map['id'] ||
                  !const [1, 2].contains(decoded['schemaVersion'])) {
                throw const FormatException(
                  'Metadata identity/schema mismatch',
                );
              }
              metadata = decoded;
            }
          } on FormatException {
            problem =
                (code: ProblemCode.invalid, message: 'Malformed metadata');
          }
          return (
            id: map['id'] as String,
            source: location,
            audio: StorageCodec.decodeAudio(jsonEncode(map['audio'])),
            sizeBytes: (map['sizeBytes'] as num).toInt(),
            modifiedAt: DateTime.fromMillisecondsSinceEpoch(
              (map['modifiedAt'] as num).toInt(),
              isUtc: true,
            ),
            metadata: metadata,
            problem: problem
          );
        }).toList(),
      );
  @override
  Future<void> drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }
}

class _NativeOperation<T> implements IoOperation<T> {
  _NativeOperation(this.id);
  @override
  final String id;
  final completion = Completer<T>();
  final settlement = Completer<void>();
  void complete(T value) {
    if (!completion.isCompleted) completion.complete(value);
  }

  @override
  Future<T> get result => completion.future;
  @override
  Future<void> get settled => settlement.future;
}
