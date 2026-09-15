// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'storage_contract.dart';

/// Version 1 named-field encodings. These validate representation, not access,
/// containment, ownership or grants: those require the bound storage backend.
/// No decoder normalizes an ID, path, URI or opaque document identity.
abstract final class StorageCodec {
  static String encodeDirectory(DirectoryRef value) {
    _validateDirectory(value);
    return jsonEncode(_directoryMap(value));
  }

  static DirectoryRef decodeDirectory(String json) => _directory(_parse(json));
  static String encodeAudio(AudioLocator value) {
    _validateAudio(value);
    return jsonEncode(_audioMap(value));
  }

  static AudioLocator decodeAudio(String json) => _audio(_parse(json));
  static String encodeKey(RecordingKey value) {
    _validateKey(value);
    return jsonEncode(_keyMap(value));
  }

  static RecordingKey decodeKey(String json) => _key(_parse(json));
  static String encodeLocation(StorageLocation value) {
    _validateLocation(value);
    return jsonEncode(_locationMap(value));
  }

  static StorageLocation decodeLocation(String json) => _location(_parse(json));
  static String encodeBinding(BoundRecording value) {
    _validateBinding(value);
    return jsonEncode(_bindingMap(value));
  }

  static BoundRecording decodeBinding(String json) => _binding(_parse(json));

  /// The grant URI is a capability, not the identity of its effective directory.
  static String canonicalKey(DirectoryRef value) {
    _validateDirectory(value);
    return jsonEncode(
      [value.kind, value.path, value.authority, value.documentId],
    );
  }

  static void validateLiteralId(String value) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains('\\') ||
        value.contains('\u0000')) {
      _invalid('Invalid literal storage identifier');
    }
  }

  static Never _invalid(String message) =>
      throw StorageFault((code: ProblemCode.invalid, message: message));

  static Map<String, dynamic> _parse(String json) {
    try {
      return _object(jsonDecode(json));
    } on FormatException {
      // Do not expose payload contents in diagnostics persisted by later owners.
      _invalid('Malformed storage JSON');
    }
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map<String, dynamic>) _invalid('Expected a storage object');
    if (value['version'] is! int || value['version'] != 1) {
      _invalid('Unsupported storage encoding version');
    }
    return value;
  }

  static String _string(Map<String, dynamic> value, String field) {
    final result = value[field];
    if (result is! String) _invalid('Missing or invalid storage field: $field');
    return result;
  }

  static void _nonempty(String value, String field) {
    if (value.isEmpty || value.contains('\u0000')) {
      _invalid('Invalid storage field: $field');
    }
  }

  static void _absolutePath(String value) {
    _nonempty(value, 'path');
    // Explicit cross-platform syntax, never Uri.hasScheme (C: is not a URI).
    final absolute = value.startsWith('/') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
        RegExp(r'^\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$)').hasMatch(value);
    if (!absolute) _invalid('Expected an absolute filesystem path');
  }

  static ({String authority, List<String> pathSegments}) _contentParts(
    String value,
  ) {
    _nonempty(value, 'content URI');
    if (RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(value)) {
      _invalid('Malformed content URI escape');
    }
    // Uri parsing is only a syntax/envelope check. Its normalized path/host
    // cannot establish the literal Android document shape or provider identity.
    final uri = Uri.tryParse(value);
    final literal = RegExp(
      r'^content://([^/?#]+)(/[^?#]*)$',
      caseSensitive: false,
    ).firstMatch(value);
    if (uri == null ||
        literal == null ||
        uri.scheme != 'content' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment) {
      _invalid('Expected a content document capability');
    }
    final authority = literal.group(1)!;
    // Split BEFORE decoding: encoded slashes stay inside opaque IDs, and dot
    // IDs stay in their original position instead of resolving as traversal.
    final encodedSegments = literal.group(2)!.substring(1).split('/');
    final segments = <String>[];
    try {
      for (final encoded in encodedSegments) {
        // Combine literal Unicode and escaped octets without URI path
        // normalization. decodeComponent alone expects ASCII encoded input.
        final pieces = encoded.split('%');
        final bytes = <int>[...utf8.encode(pieces.first)];
        for (final piece in pieces.skip(1)) {
          bytes.add(int.parse(piece.substring(0, 2), radix: 16));
          bytes.addAll(utf8.encode(piece.substring(2)));
        }
        final segment = utf8.decode(bytes);
        if (segment.contains('\u0000')) {
          _invalid('Invalid content document identity');
        }
        segments.add(segment);
      }
    } on FormatException {
      _invalid('Malformed content document identity');
    }
    return (authority: authority, pathSegments: segments);
  }

  static void _validateDirectory(DirectoryRef value) {
    switch (value.kind) {
      case 'file':
        _absolutePath(value.path);
        if (value.treeUri.isNotEmpty ||
            value.authority.isNotEmpty ||
            value.documentId.isNotEmpty) {
          _invalid('Filesystem directory contains SAF fields');
        }
      case 'saf':
        if (value.path.isNotEmpty) {
          _invalid('SAF directory contains a filesystem path');
        }
        _nonempty(value.authority, 'authority');
        _nonempty(value.documentId, 'documentId');
        final parts = _contentParts(value.treeUri);
        final segments = parts.pathSegments;
        final tree = segments.length == 2 ||
            (segments.length == 4 &&
                segments[2] == 'document' &&
                segments[3].isNotEmpty);
        if (parts.authority != value.authority ||
            !tree ||
            segments[0] != 'tree' ||
            segments[1].isEmpty) {
          _invalid('Missing or inconsistent SAF tree capability');
        }
      default:
        _invalid('Unknown directory kind');
    }
  }

  static void _validateAudio(AudioLocator value) {
    switch (value.kind) {
      case 'file':
        _absolutePath(value.value);
      case 'saf':
        final segments = _contentParts(value.value).pathSegments;
        final direct = segments.length == 2 &&
            segments[0] == 'document' &&
            segments[1].isNotEmpty;
        final tree = segments.length == 4 &&
            segments[0] == 'tree' &&
            segments[1].isNotEmpty &&
            segments[2] == 'document' &&
            segments[3].isNotEmpty;
        if (!direct && !tree) _invalid('Missing SAF audio document identity');
      default:
        _invalid('Unknown audio kind');
    }
  }

  static void _validateKey(RecordingKey value) {
    validateLiteralId(value.dumpId);
    validateLiteralId(value.incarnation);
  }

  static void _validateLocation(StorageLocation value) {
    validateLiteralId(value.id);
    _validateDirectory(value.directory);
  }

  static void _validateBinding(BoundRecording value) {
    _validateKey(value.key);
    _validateLocation(value.location);
    _validateAudio(value.audio);
    validateLiteralId(value.metadataName);
    if (value.audio.kind != value.location.directory.kind) {
      _invalid('Binding locator kind mismatch');
    }
    if (value.audio.kind == 'saf' &&
        _contentParts(value.audio.value).authority !=
            value.location.directory.authority) {
      _invalid('Binding authority mismatch');
    }
  }

  static Map<String, Object?> _directoryMap(DirectoryRef value) => {
        'version': 1,
        'kind': value.kind,
        'path': value.path,
        'authority': value.authority,
        'treeUri': value.treeUri,
        'documentId': value.documentId,
      };
  static DirectoryRef _directory(Map<String, dynamic> value) {
    final result = (
      kind: _string(value, 'kind'),
      path: _string(value, 'path'),
      authority: _string(value, 'authority'),
      treeUri: _string(value, 'treeUri'),
      documentId: _string(value, 'documentId')
    );
    _validateDirectory(result);
    return result;
  }

  static Map<String, Object?> _audioMap(AudioLocator value) => {
        'version': 1,
        'kind': value.kind,
        'value': value.value,
      };
  static AudioLocator _audio(Map<String, dynamic> value) {
    final result =
        (kind: _string(value, 'kind'), value: _string(value, 'value'));
    _validateAudio(result);
    return result;
  }

  static Map<String, Object?> _keyMap(RecordingKey value) => {
        'version': 1,
        'dumpId': value.dumpId,
        'incarnation': value.incarnation,
      };
  static RecordingKey _key(Map<String, dynamic> value) {
    final result = (
      dumpId: _string(value, 'dumpId'),
      incarnation: _string(value, 'incarnation')
    );
    _validateKey(result);
    return result;
  }

  static Map<String, Object?> _locationMap(StorageLocation value) => {
        'version': 1,
        'id': value.id,
        'directory': _directoryMap(value.directory),
        'label': value.label,
      };
  static StorageLocation _location(Map<String, dynamic> value) {
    final result = (
      id: _string(value, 'id'),
      directory: _directory(_object(value['directory'])),
      label: _string(value, 'label')
    );
    _validateLocation(result);
    return result;
  }

  static Map<String, Object?> _bindingMap(BoundRecording value) => {
        'version': 1,
        'key': _keyMap(value.key),
        'location': _locationMap(value.location),
        'audio': _audioMap(value.audio),
        'metadataName': value.metadataName,
      };
  static BoundRecording _binding(Map<String, dynamic> value) {
    final result = (
      key: _key(_object(value['key'])),
      location: _location(_object(value['location'])),
      audio: _audio(_object(value['audio'])),
      metadataName: _string(value, 'metadataName')
    );
    _validateBinding(result);
    return result;
  }
}
