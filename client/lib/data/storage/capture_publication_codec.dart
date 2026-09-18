// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'storage_contract.dart';
import 'storage_codec.dart';
import '../recording_metadata.dart';

/// Closed capture v1 envelopes. Never normalize identities or semantic JSON.
abstract final class CapturePublicationCodec {
  static Never _bad(String message, [ProblemCode code = ProblemCode.invalid]) =>
      throw StorageFault((code: code, message: message));
  static Map<String, dynamic> _object(Object? raw, Set<String> fields) {
    if (raw is! Map<String, dynamic>) _bad('Expected capture object');
    if (raw['version'] is! int) _bad('Invalid capture version');
    if (raw['version'] != 1) {
      _bad('Unsupported capture version', ProblemCode.unsupported);
    }
    if (raw.length != fields.length + 1 || !fields.every(raw.containsKey)) {
      _bad('Missing or extra capture fields');
    }
    return raw;
  }

  static Object? _parse(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      _bad('Malformed capture JSON');
    }
  }

  static String _text(Map<String, dynamic> m, String field) {
    final value = m[field];
    if (value is! String || value.isEmpty || value.contains('\u0000')) {
      _bad('Invalid capture $field');
    }
    return value;
  }

  static int _positive(Map<String, dynamic> m, String field) {
    final value = m[field];
    if (value is! int || value <= 0) _bad('Invalid capture $field');
    return value;
  }

  static Map<String, dynamic> _nested(String encoded) =>
      jsonDecode(encoded) as Map<String, dynamic>;
  static bool _unsigned(String value, int bits) =>
      RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value) &&
      BigInt.parse(value) < (BigInt.one << bits);
  static bool sameObject(CaptureObjectIdentity a, CaptureObjectIdentity b) =>
      a.kind == b.kind && a.scope == b.scope && a.objectId == b.objectId;

  static CaptureObjectIdentity _identity(Object? raw) {
    final m = _object(raw, {'kind', 'scope', 'objectId', 'generation'});
    final kind = _text(m, 'kind');
    final scope = _text(m, 'scope');
    final id = _text(m, 'objectId');
    final generation = m['generation'];
    if (generation != null && generation is! String) {
      _bad('Invalid capture generation');
    }
    switch (kind) {
      case 'windows-file':
        if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(scope) ||
            !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
            (generation != null && !_unsigned(generation as String, 64))) {
          _bad('Invalid Windows identity');
        }
      case 'posix-file':
        final device = scope.split(':');
        if (device.length != 2 ||
            !device.every((v) => _unsigned(v, 32)) ||
            !_unsigned(id, 64)) {
          _bad('Invalid POSIX identity');
        }
        if (generation != null) {
          final birth = (generation as String).split(':');
          if (birth.length != 2 ||
              !RegExp(r'^(0|-?[1-9][0-9]*)$').hasMatch(birth[0]) ||
              !RegExp(r'^[0-9]{9}$').hasMatch(birth[1])) {
            _bad('Invalid POSIX birth time');
          }
          final seconds = BigInt.parse(birth[0]);
          if (seconds < -(BigInt.one << 63) || seconds >= (BigInt.one << 63)) {
            _bad('Invalid POSIX birth range');
          }
        }
      case 'saf-document':
        if (generation != null) _bad('SAF generation must be null');
        StorageCodec.encodeAudio(
          (
            kind: 'saf',
            value: 'content://$scope/document/${Uri.encodeComponent(id)}'
          ),
        );
      default:
        _bad('Unknown capture identity kind');
    }
    return (
      kind: kind,
      scope: scope,
      objectId: id,
      generation: generation as String?
    );
  }

  static Map<String, dynamic> identityMap(CaptureObjectIdentity value) {
    final m = <String, dynamic>{
      'version': 1,
      'kind': value.kind,
      'scope': value.scope,
      'objectId': value.objectId,
      'generation': value.generation,
    };
    _identity(m);
    return m;
  }

  static String encodeIdentity(CaptureObjectIdentity value) =>
      jsonEncode(identityMap(value));
  static CaptureObjectIdentity decodeIdentity(String text) =>
      _identity(_parse(text));

  static CaptureComponentClaim _claim(Object? raw) {
    final m = _object(raw, {'component', 'name', 'locator', 'identity'});
    final values =
        RecordingComponent.values.where((v) => v.name == m['component']);
    if (values.isEmpty) _bad('Unknown capture component');
    final name = _text(m, 'name');
    StorageCodec.validateLiteralId(name);
    final locator = StorageCodec.decodeAudio(jsonEncode(m['locator']));
    final identity = _identity(m['identity']);
    if ((locator.kind == 'saf') != (identity.kind == 'saf-document')) {
      _bad('Claim locator kind mismatch');
    }
    if (locator.kind == 'saf' &&
        !StorageCodec.sameAudioIdentity(
          locator,
          (
            kind: 'saf',
            value:
                'content://${identity.scope}/document/${Uri.encodeComponent(identity.objectId)}'
          ),
        )) {
      _bad('Claim document identity mismatch');
    }
    return (
      component: values.single,
      name: name,
      locator: locator,
      identity: identity
    );
  }

  static Map<String, dynamic> claimMap(CaptureComponentClaim c) {
    final m = <String, dynamic>{
      'version': 1,
      'component': c.component.name,
      'name': c.name,
      'locator': _nested(StorageCodec.encodeAudio(c.locator)),
      'identity': identityMap(c.identity),
    };
    _claim(m);
    return m;
  }

  static String encodeClaim(CaptureComponentClaim c) => jsonEncode(claimMap(c));
  static CaptureComponentClaim decodeClaim(String text) => _claim(_parse(text));

  static Map<String, dynamic> metadata(String text, String dumpId) {
    final value = _parse(text);
    if (value is! Map<String, dynamic>) _bad('Invalid initial metadata');
    validateImportedMetadata(dumpId, value);
    if (value['schemaVersion'] != 2) _bad('Initial metadata must be schema 2');
    return value;
  }

  static void digest(String value) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      _bad('Invalid frozen SHA-256');
    }
  }

  static PreparedCapture _prepared(Object? raw) {
    final m = _object(raw, {
      'publicationId',
      'reservationId',
      'key',
      'location',
      'stagingPath',
      'sourceIdentity',
      'rootIdentity',
      'audioSizeBytes',
      'audioSha256',
      'metadataJson',
      'audio',
      'metadata',
    });
    final id = _text(m, 'reservationId');
    StorageCodec.validateLiteralId(id);
    if (_text(m, 'publicationId') != id) _bad('Publication identity mismatch');
    final key = StorageCodec.decodeKey(jsonEncode(m['key']));
    final location = StorageCodec.decodeLocation(jsonEncode(m['location']));
    final staging = _text(m, 'stagingPath');
    StorageCodec.encodeAudio((kind: 'file', value: staging));
    final source = _identity(m['sourceIdentity']);
    final root = _identity(m['rootIdentity']);
    if (source.kind == 'saf-document' || sameObject(source, root)) {
      _bad('Invalid staging object');
    }
    if (location.directory.kind == 'saf') {
      if (root.kind != 'saf-document' ||
          root.scope != location.directory.authority ||
          root.objectId != location.directory.documentId) {
        _bad('Root identity mismatch');
      }
    } else if (root.kind != source.kind) {
      _bad('Filesystem identity kind mismatch');
    }
    final size = _positive(m, 'audioSizeBytes');
    final hash = _text(m, 'audioSha256');
    digest(hash);
    final json = _text(m, 'metadataJson');
    final modeRaw = metadata(json, key.dumpId)['mode'];
    final contentName = '${key.dumpId}.'
        '${contentExtensionForReservation(modeRaw is String ? modeRaw : '', staging)}';
    final audio = m['audio'] == null ? null : _claim(m['audio']);
    final meta = m['metadata'] == null ? null : _claim(m['metadata']);
    for (final entry in [
      (audio, RecordingComponent.audio, contentName),
      (meta, RecordingComponent.metadata, '${key.dumpId}.meta.json'),
    ]) {
      final claim = entry.$1;
      if (claim == null) continue;
      if (claim.component != entry.$2 ||
          claim.name != entry.$3 ||
          claim.identity.kind != root.kind ||
          claim.identity.scope != root.scope ||
          sameObject(claim.identity, root) ||
          sameObject(claim.identity, source) ||
          claim.locator.kind != location.directory.kind) {
        _bad('Incoherent component claim');
      }
    }
    if (audio != null &&
        meta != null &&
        (sameObject(audio.identity, meta.identity) ||
            audio.locator == meta.locator)) {
      _bad('Aliased component claims');
    }
    return (
      publicationId: id,
      reservationId: id,
      key: key,
      location: location,
      stagingPath: staging,
      sourceIdentity: source,
      rootIdentity: root,
      audioSizeBytes: size,
      audioSha256: hash,
      metadataJson: json,
      audio: audio,
      metadata: meta
    );
  }

  static Map<String, dynamic> preparationMap(PreparedCapture p) {
    final m = <String, dynamic>{
      'version': 1,
      'publicationId': p.publicationId,
      'reservationId': p.reservationId,
      'key': _nested(StorageCodec.encodeKey(p.key)),
      'location': _nested(StorageCodec.encodeLocation(p.location)),
      'stagingPath': p.stagingPath,
      'sourceIdentity': identityMap(p.sourceIdentity),
      'rootIdentity': identityMap(p.rootIdentity),
      'audioSizeBytes': p.audioSizeBytes,
      'audioSha256': p.audioSha256,
      'metadataJson': p.metadataJson,
      'audio': p.audio == null ? null : claimMap(p.audio!),
      'metadata': p.metadata == null ? null : claimMap(p.metadata!),
    };
    _prepared(m);
    return m;
  }

  static String encodePreparation(PreparedCapture p) =>
      jsonEncode(preparationMap(p));
  static PreparedCapture decodePreparation(String text) =>
      _prepared(_parse(text));
  static void validateReservation(CaptureReservation r, PreparedCapture p) {
    preparationMap(p);
    reservationMap(r);
    if (p.reservationId != r.id ||
        p.key != r.key ||
        p.location != r.location ||
        p.stagingPath != r.stagingPath ||
        metadata(p.metadataJson, r.key.dumpId)['mode'] != r.mode) {
      _bad('Preparation does not match reservation');
    }
  }

  static Map<String, dynamic> reservationMap(CaptureReservation r) {
    if (r.startedAt.millisecondsSinceEpoch <= 0) {
      _bad('Invalid capture startedAtMs');
    }
    StorageCodec.validateLiteralId(r.id);
    StorageCodec.encodeAudio((kind: 'file', value: r.stagingPath));
    if (r.mode != 'meeting' && r.mode != 'brain_dump' && r.mode != 'text_note') {
      _bad('Invalid capture mode');
    }
    return {
      'version': 1,
      'id': r.id,
      'key': _nested(StorageCodec.encodeKey(r.key)),
      'location': _nested(StorageCodec.encodeLocation(r.location)),
      'stagingPath': r.stagingPath,
      'mode': r.mode,
      'startedAtMs': r.startedAt.millisecondsSinceEpoch,
    };
  }

  static void operationId(CaptureReservation r, String id) {
    StorageCodec.validateLiteralId(id);
    if (id != 'capture-${r.id}-prepare') {
      _bad('Invalid preparation operation ID');
    }
  }

  static StorageProblem? _problem(Object? raw) {
    if (raw == null) return null;
    final m = _object(raw, {'code', 'message'});
    final code = ProblemCode.values.where((c) => c.name == m['code']);
    if (code.isEmpty) _bad('Unknown capture problem');
    return (code: code.single, message: _text(m, 'message'));
  }

  static Map<String, dynamic>? _problemMap(StorageProblem? p) => p == null
      ? null
      : {'version': 1, 'code': p.code.name, 'message': p.message};
  static CapturePreparationResult _result(Object? raw) {
    final m = _object(
      raw,
      {'state', 'preparation', 'rawReturnedLocators', 'problem'},
    );
    final states =
        CapturePreparationState.values.where((s) => s.name == m['state']);
    if (states.isEmpty) _bad('Unknown preparation state');
    final state = states.single;
    final p = m['preparation'] == null ? null : _prepared(m['preparation']);
    final locators = m['rawReturnedLocators'];
    if (locators is! List || locators.any((v) => v is! String)) {
      _bad('Invalid raw preparation receipts');
    }
    final problem = _problem(m['problem']);
    if (state == CapturePreparationState.prepared) {
      if (p?.audio == null || p?.metadata == null || problem != null) {
        _bad('Incomplete prepared outcome');
      }
      if (!locators.contains(p!.audio!.locator.value) ||
          !locators.contains(p.metadata!.locator.value)) {
        _bad('Missing creation receipt');
      }
    } else if (state == CapturePreparationState.notStarted) {
      if (p != null || locators.isNotEmpty || problem == null) {
        _bad('Incoherent notStarted outcome');
      }
    } else if (problem == null) {
      _bad('Uncertain preparation requires a problem');
    }
    return (
      state: state,
      preparation: p,
      rawReturnedLocators: List<String>.from(locators),
      problem: problem
    );
  }

  static String encodeResult(CapturePreparationResult r) {
    final m = <String, dynamic>{
      'version': 1,
      'state': r.state.name,
      'preparation':
          r.preparation == null ? null : preparationMap(r.preparation!),
      'rawReturnedLocators': r.rawReturnedLocators,
      'problem': _problemMap(r.problem),
    };
    _result(m);
    return jsonEncode(m);
  }

  static CapturePreparationResult decodeResult(String text) =>
      _result(_parse(text));
  static CaptureComponentInspection _componentInspection(Object? raw) {
    final m = _object(raw, {'state', 'problem'});
    final states =
        CaptureContentState.values.where((s) => s.name == m['state']);
    if (states.isEmpty) _bad('Unknown capture content state');
    final problem = _problem(m['problem']);
    if ((states.single == CaptureContentState.empty ||
            states.single == CaptureContentState.complete) &&
        problem != null) {
      _bad('Contradictory component observation');
    }
    return (state: states.single, problem: problem);
  }

  static String encodeInspection(CaptureInspection i) {
    Map<String, dynamic> component(CaptureComponentInspection c) => {
          'version': 1,
          'state': c.state.name,
          'problem': _problemMap(c.problem),
        };
    final m = {
      'version': 1,
      'audio': component(i.audio),
      'metadata': component(i.metadata),
    };
    final encoded = jsonEncode(m);
    decodeInspection(encoded);
    return encoded;
  }

  static CaptureInspection decodeInspection(String text) {
    final m = _object(_parse(text), {'audio', 'metadata'});
    return (
      audio: _componentInspection(m['audio']),
      metadata: _componentInspection(m['metadata'])
    );
  }
}
