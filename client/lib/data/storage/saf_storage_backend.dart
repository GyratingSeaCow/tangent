// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'storage_contract.dart';
import 'storage_codec.dart';
import 'capture_publication_codec.dart';

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
        message: value['message'] is String
            ? value['message'] as String
            : 'Native storage failed'
      );
    }
    return (
      code: ProblemCode.unavailable,
      message: 'Native storage observation unavailable'
    );
  }

  StorageProblem _platformProblem(PlatformException e) =>
      _problem({'code': e.code, 'message': e.message});
  IoOperation<T> _local<T>(String id, T value) {
    final operation = _NativeOperation<T>(id)..complete(value);
    operation.settlement.complete();
    return operation;
  }

  CapturePreparationResult _uncertain(StorageProblem problem, [Object? raw]) {
    PreparedCapture? preparation;
    if (raw is Map && raw['preparation'] != null) {
      try {
        preparation = CapturePublicationCodec.decodePreparation(
          jsonEncode(raw['preparation']),
        );
      } on Object {/* Invalid claims remain non-authoritative. */}
    }
    return (
      state: CapturePreparationState.uncertain,
      preparation: preparation,
      rawReturnedLocators: raw is Map && raw['rawReturnedLocators'] is List
          ? (raw['rawReturnedLocators'] as List).whereType<String>().toList()
          : <String>[],
      problem: problem
    );
  }

  @override
  IoOperation<CapturePreparationResult> prepareCapture(
    CaptureReservation r,
    String metadataJson,
    String audioSha256,
    String operationId, {
    required bool observeOnly,
  }) {
    late Map<String, Object?> payload;
    try {
      CapturePublicationCodec.operationId(r, operationId);
      CapturePublicationCodec.digest(audioSha256);
      final reservation = CapturePublicationCodec.reservationMap(r);
      if (r.location.directory.kind != 'saf' ||
          CapturePublicationCodec.metadata(
                metadataJson,
                r.key.dumpId,
              )['mode'] !=
              r.mode) {
        throw const StorageFault(
          (
            code: ProblemCode.invalid,
            message: 'Invalid SAF capture reservation'
          ),
        );
      }
      payload = {
        'operationId': operationId,
        'reservation': reservation,
        'metadataJson': metadataJson,
        'audioSha256': audioSha256,
      };
    } on StorageFault catch (e) {
      return _local(
        operationId,
        (
          state: observeOnly
              ? CapturePreparationState.uncertain
              : CapturePreparationState.notStarted,
          preparation: null,
          rawReturnedLocators: <String>[],
          problem: e.problem
        ),
      );
    }
    return _track(
      operationId,
      (raw) {
        try {
          final result = CapturePublicationCodec.decodeResult(jsonEncode(raw));
          if (result.preparation case final preparation?) {
            CapturePublicationCodec.validateReservation(r, preparation);
            if (preparation.metadataJson != metadataJson ||
                preparation.audioSha256 != audioSha256) {
              throw const StorageFault(
                (
                  code: ProblemCode.conflict,
                  message: 'Preparation payload differs'
                ),
              );
            }
          }
          return result;
        } on StorageFault catch (e) {
          return _uncertain(e.problem, raw);
        } on Object {
          return _uncertain(
            (
              code: ProblemCode.invalid,
              message: 'Malformed native preparation'
            ),
            raw,
          );
        }
      },
      _uncertain,
      method: observeOnly ? null : 'prepareCaptureAt',
      args: payload,
      consumeResult: false,
      stateArgs: {'capturePayload': payload},
      typedDecode: true,
    );
  }

  Map<String, Object?> _preparedArgs(
    CaptureReservation r,
    PreparedCapture preparation,
  ) {
    CapturePublicationCodec.validateReservation(r, preparation);
    if (r.location.directory.kind != 'saf' ||
        preparation.audio == null ||
        preparation.metadata == null) {
      throw const StorageFault(
        (
          code: ProblemCode.invalid,
          message: 'Incomplete SAF capture preparation'
        ),
      );
    }
    return {
      'reservation': CapturePublicationCodec.reservationMap(r),
      'preparation': CapturePublicationCodec.preparationMap(preparation),
    };
  }

  IoOperation<Outcome<T>> _captureStart<T>(
    String method,
    CaptureReservation r,
    PreparedCapture preparation,
    T Function(Object?) decode,
  ) {
    final id = _id();
    try {
      final args = _preparedArgs(r, preparation);
      return _track(
        id,
        (value) => Ok(decode(value)),
        (problem) => Fail<T>(problem),
        method: method,
        args: args,
        typedDecode: true,
      );
    } on StorageFault catch (e) {
      return _local(id, Fail<T>(e.problem));
    }
  }

  @override
  IoOperation<Outcome<CaptureInspection>> inspectPreparedCapture(
    CaptureReservation r,
    PreparedCapture preparation,
  ) =>
      _captureStart(
        'inspectPreparedCaptureAt',
        r,
        preparation,
        (raw) => CapturePublicationCodec.decodeInspection(jsonEncode(raw)),
      );
  @override
  IoOperation<Outcome<PublishedCapture>> publishPreparedCapture(
    CaptureReservation r,
    PreparedCapture preparation,
  ) =>
      _captureStart('publishPreparedCaptureAt', r, preparation, (raw) {
        if (raw is! Map ||
            raw.length != 2 ||
            !raw.containsKey('binding') ||
            raw['sizeBytes'] is! int ||
            raw['sizeBytes'] != preparation.audioSizeBytes) {
          throw const StorageFault(
            (
              code: ProblemCode.invalid,
              message: 'Malformed prepared publication'
            ),
          );
        }
        final binding = StorageCodec.decodeBinding(jsonEncode(raw['binding']));
        if (binding.key != r.key ||
            binding.location != r.location ||
            binding.audio != preparation.audio!.locator ||
            binding.metadataName != preparation.metadata!.name) {
          throw const StorageFault(
            (
              code: ProblemCode.conflict,
              message: 'Prepared publication owner differs'
            ),
          );
        }
        return (binding: binding, sizeBytes: raw['sizeBytes'] as int);
      });
  @override
  Future<Outcome<void>> acknowledgeCapturePreparation(
    String operationId,
  ) async {
    try {
      StorageCodec.validateLiteralId(operationId);
      if (!operationId.startsWith('capture-') ||
          !operationId.endsWith('-prepare')) {
        throw const StorageFault(
          (
            code: ProblemCode.invalid,
            message: 'Invalid preparation acknowledgement ID'
          ),
        );
      }
      final result = await _channel.invokeMethod<Object?>(
        'acknowledgeOperation',
        {'operationId': operationId, 'preparationOnly': true},
      );
      if (result != null) {
        return const Fail(
          (
            code: ProblemCode.invalid,
            message: 'Malformed preparation acknowledgement'
          ),
        );
      }
      return const Ok(null);
    } on StorageFault catch (e) {
      return Fail(e.problem);
    } on PlatformException catch (e) {
      return Fail(_platformProblem(e));
    } on MissingPluginException {
      return Fail(_problem(null));
    }
  }

  _NativeOperation<T> _track<T>(
    String id,
    T Function(Object?) decode,
    T Function(StorageProblem) failure, {
    String? method,
    Map<String, Object?>? args,
    bool consumeResult = true,
    Map<String, Object?>? stateArgs,
    bool typedDecode = false,
  }) {
    final op = _NativeOperation<T>(id);
    _pending.add(op.settled);
    unawaited(op.settled.then((_) => _pending.remove(op.settled)));
    unawaited(() async {
      if (method != null) {
        try {
          await _channel
              .invokeMethod<Object?>(method, {'operationId': id, ...?args});
        } on PlatformException catch (e) {
          op.complete(
            failure(typedDecode ? _platformProblem(e) : _problem(null)),
          );
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
            {'operationId': id, ...?stateArgs},
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
                if (typedDecode) {
                  op.complete(
                    failure(
                      e is StorageFault
                          ? e.problem
                          : (
                              code: ProblemCode.invalid,
                              message: 'Malformed native capture response'
                            ),
                    ),
                  );
                } else {
                  op.completion.completeError(e, st);
                }
              }
            }
            op.settlement.complete();
            // A failed old observer must not discard a late publication result.
            // A replacement can still observe/acknowledge the retained receipt.
            if (!delivered || !consumeResult) return;
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
        } on PlatformException catch (e) {
          if (e.code == 'unknown' ||
              (typedDecode && stateArgs != null && e.code == 'conflict')) {
            // Positive current-process lookup classification, not a transport
            // timeout. 'unknown' means the native supervisor does not retain
            // this operation (e.g. the process that issued it was killed), so
            // it can never settle: deliver the failure AND settle the
            // operation, releasing any restored fence pinned on op.settled.
            // Before this exit existed the untyped path fell through to the
            // 50ms retry sleep forever — a hot loop that pinned the capture
            // fence (freezing every later save/record) until Android killed
            // the process for excessive CPU.
            op.complete(
              failure(
                typedDecode
                    ? (
                        code: e.code == 'unknown'
                            ? ProblemCode.unresolved
                            : ProblemCode.conflict,
                        message: e.code == 'unknown'
                            ? 'Preparation/worker is not retained'
                            : 'Preparation payload differs'
                      )
                    : _problem(null),
              ),
            );
            op.settlement.complete();
            return;
          }
          op.complete(
            failure(typedDecode ? _platformProblem(e) : _problem(null)),
          );
        } on MissingPluginException {
          op.complete(failure(_problem(null)));
        } on Object catch (e, st) {
          if (typedDecode) {
            op.complete(
              failure(
                (
                  code: ProblemCode.invalid,
                  message: 'Malformed native operation state'
                ),
              ),
            );
          } else if (!op.completion.isCompleted) {
            op.completion.completeError(e, st);
          }
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
        final op = _track<void>(
          value['operationId'] as String,
          (_) {},
          (_) {},
          consumeResult: value['method'] != 'prepareCaptureAt',
        );
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
        // Reachability, not inventory. This used to invoke 'listRecordingsAt',
        // enumerating and parsing every recording in the folder only to discard
        // the result — 5.8 s on an 81-file folder, paid on EVERY record tap
        // before the microphone was even touched.
        'probeLocationAt',
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
        (value) => (value as List)
            .map((dynamic raw) => _decodeEntry(raw as Map, location))
            .toList(),
      );

  /// Decodes one native recording row. Shared by [listRecordingsAt] and
  /// [readRecordingAt] so a single-entry read can never disagree with the
  /// listing about what an entry means.
  ImportedEntry _decodeEntry(Map<dynamic, dynamic> map, StorageLocation location) {
    Map<String, dynamic>? metadata;
    StorageProblem? problem =
        map['problem'] == null ? null : _problem(map['problem']);
    try {
      if (map['metadataJson'] != null) {
        final decoded = jsonDecode(map['metadataJson'] as String);
        if (decoded is! Map<String, dynamic> ||
            decoded['id'] != map['id'] ||
            !const [1, 2].contains(decoded['schemaVersion'])) {
          throw const FormatException('Metadata identity/schema mismatch');
        }
        metadata = decoded;
      }
    } on FormatException {
      problem = (code: ProblemCode.invalid, message: 'Malformed metadata');
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
  }

  /// Reads one published entry by id instead of enumerating the folder (T8).
  ///
  /// Publication proves its receipt by re-reading what it just wrote; doing
  /// that through [listRecordingsAt] parsed every recording's metadata and
  /// cost 4.4s of a 5.9s stop with 56 recordings. The native side reads only
  /// this dump's two documents. Nothing is cached, so the proof is unchanged.
  @override
  IoOperation<Outcome<ImportedEntry?>>? readRecordingAt(
    StorageLocation location,
    String dumpId,
  ) =>
      _start(
        'readRecordingAt',
        {
          'location': _wire(StorageCodec.encodeLocation(location)),
          'dumpId': dumpId,
        },
        (value) => value == null
            ? null
            : _decodeEntry(value as Map<dynamic, dynamic>, location),
      );

  @override
  Future<void> drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  /// Decodes one native durable-document row. The locator stays the exact
  /// provider-issued string; it is validated as a document capability and
  /// never parsed into a path.
  DurableDocument _document(Object? raw) {
    if (raw is! Map ||
        raw['name'] is! String ||
        raw['content'] is! String ||
        raw['locator'] == null) {
      throw const StorageFault(
        (code: ProblemCode.invalid, message: 'Malformed durable document'),
      );
    }
    return (
      name: raw['name']! as String,
      locator: StorageCodec.decodeAudio(jsonEncode(raw['locator'])),
      content: raw['content']! as String
    );
  }

  Map<String, Object?> _documentArgs(
    StorageLocation location,
    String directoryName,
  ) {
    StorageCodec.validateLiteralId(directoryName);
    return {
      'location': _wire(StorageCodec.encodeLocation(location)),
      'directoryName': directoryName,
    };
  }

  @override
  IoOperation<Outcome<DurableDocument>> publishDocument(
    StorageLocation location,
    String directoryName,
    String name,
    String content,
    String publicationId,
  ) {
    final id = _id();
    try {
      StorageCodec.validateLiteralId(publicationId);
      StorageCodec.validateLiteralId(name);
      final args = {
        ..._documentArgs(location, directoryName),
        'name': name,
        'content': content,
        'publicationId': publicationId,
      };
      return _track(
        id,
        (value) => Ok(_document(value)),
        (problem) => Fail<DurableDocument>(problem),
        method: 'publishDocumentAt',
        args: args,
        typedDecode: true,
      );
    } on StorageFault catch (e) {
      return _local(id, Fail<DurableDocument>(e.problem));
    }
  }

  @override
  IoOperation<Outcome<List<DurableDocument>>> listDocuments(
    StorageLocation location,
    String directoryName,
    String suffix,
  ) {
    final id = _id();
    try {
      final args = {
        ..._documentArgs(location, directoryName),
        'suffix': suffix,
      };
      return _track(
        id,
        (value) {
          if (value is! List) {
            throw const StorageFault(
              (
                code: ProblemCode.invalid,
                message: 'Malformed durable document listing'
              ),
            );
          }
          return Ok(value.map(_document).toList());
        },
        (problem) => Fail<List<DurableDocument>>(problem),
        method: 'listDocumentsAt',
        args: args,
        typedDecode: true,
      );
    } on StorageFault catch (e) {
      return _local(id, Fail<List<DurableDocument>>(e.problem));
    }
  }

  @override
  IoOperation<ComponentResult> deleteDocument(
    StorageLocation location,
    String directoryName,
    String name,
    AudioLocator locator,
    String operationId,
  ) {
    final id = _id();
    ComponentResult failure(StorageProblem problem) =>
        (state: ComponentState.failed, problem: problem);
    try {
      StorageCodec.validateLiteralId(operationId);
      StorageCodec.validateLiteralId(name);
      final args = {
        ..._documentArgs(location, directoryName),
        'name': name,
        'locator': _wire(StorageCodec.encodeAudio(locator)),
        'deletionId': operationId,
      };
      return _track(
        id,
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
        failure,
        method: 'deleteDocumentAt',
        args: args,
      );
    } on StorageFault catch (e) {
      return _local(id, failure(e.problem));
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
