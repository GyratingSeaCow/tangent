// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/data/storage/storage_codec.dart';

DirectoryRef fileDirectory(String path) =>
    (kind: 'file', path: path, treeUri: '', authority: '', documentId: '');
const safDirectory = (
  kind: 'saf',
  path: '',
  treeUri: 'content://fixture/tree/opaque-root',
  authority: 'fixture',
  documentId: 'opaque-effective-child',
);

final invalidStorage = throwsA(
  isA<StorageFault>()
      .having((fault) => fault.problem.code, 'code', ProblemCode.invalid),
);

void main() {
  test('rejects unsafe literal keys on encode and decode without normalization',
      () {
    for (final id in ['', '.', '..', 'a/b', r'a\b', 'a\u0000b']) {
      expect(
        () => StorageCodec.encodeKey((dumpId: id, incarnation: 'fixture-inc')),
        invalidStorage,
      );
      expect(
        () => StorageCodec.decodeKey(
          jsonEncode(
            {'version': 1, 'dumpId': id, 'incarnation': 'fixture-inc'},
          ),
        ),
        invalidStorage,
      );
      expect(
        () => StorageCodec.encodeKey((dumpId: 'fixture-one', incarnation: id)),
        invalidStorage,
      );
    }
    const literal = (dumpId: ' Mixed Case ', incarnation: 'fixture-inc');
    expect(StorageCodec.decodeKey(StorageCodec.encodeKey(literal)), literal);
  });
  test('rejects malformed JSON, versions and fields with typed boundary faults',
      () {
    for (final input in [
      '{',
      'null',
      '[]',
      '42',
      '{"version":1,"dumpId":"fixture-one"}',
      '{"version":1,"dumpId":42,"incarnation":"fixture-inc"}',
      '{"dumpId":"fixture-one","incarnation":"fixture-inc"}',
      '{"version":2,"dumpId":"fixture-one","incarnation":"fixture-inc"}',
      '{"version":1.0,"dumpId":"fixture-one","incarnation":"fixture-inc"}',
    ]) {
      expect(
        () => StorageCodec.decodeKey(input),
        invalidStorage,
        reason: input,
      );
    }
  });
  test('rejects unknown directory tags, mixed fields and relative file paths',
      () {
    final valid =
        jsonDecode(StorageCodec.encodeDirectory(fileDirectory(r'C:\fixture')))
            as Map<String, dynamic>;
    for (final change in <Map<String, dynamic>>[
      {'kind': 'uri'},
      {'kind': ''},
      {'treeUri': safDirectory.treeUri},
      {'authority': 'fixture'},
      {'documentId': 'opaque'},
      {'path': ''},
      {'path': 'relative/audio'},
      {'path': r'C:relative'},
      {'path': r'\relative'},
      {'path': 'a\u0000b'},
      {'path': null},
      {'version': 2},
    ]) {
      expect(
        () => StorageCodec.decodeDirectory(jsonEncode({...valid, ...change})),
        invalidStorage,
      );
    }
    expect(
      () => StorageCodec.encodeDirectory(fileDirectory('relative')),
      invalidStorage,
    );
    expect(
      () => StorageCodec.canonicalKey(fileDirectory('relative')),
      invalidStorage,
    );
  });
  test('rejects missing or inconsistent SAF effective identity', () {
    final valid = jsonDecode(StorageCodec.encodeDirectory(safDirectory))
        as Map<String, dynamic>;
    for (final change in <Map<String, dynamic>>[
      {'documentId': ''},
      {'documentId': null},
      {'authority': ''},
      {'treeUri': ''},
      {'treeUri': 'file:///fixture'},
      {'treeUri': 'content://other/tree/opaque-root'},
      {'treeUri': 'content://fixture/document/audio'},
      {'treeUri': 'content://fixture/tree/'},
      {'treeUri': 'content://fixture/tree/opaque-root?query=1'},
      {'treeUri': 'content://fixture/tree/opaque-root/not-a-document'},
      {'treeUri': 'content://fixture/tree/%ZZ'},
      {'treeUri': 'content://fixture/tree/%00'},
      {'path': '/inferred/parent'},
    ]) {
      expect(
        () => StorageCodec.decodeDirectory(jsonEncode({...valid, ...change})),
        invalidStorage,
      );
    }
  });
  test('rejects malformed tagged audio on both boundaries', () {
    for (final audio in <AudioLocator>[
      (kind: 'url', value: 'https://fixture/audio'),
      (kind: 'file', value: 'content://fixture/document/audio'),
      (kind: 'file', value: 'relative.opus'),
      (kind: 'saf', value: r'C:\fixture\audio.opus'),
      (kind: 'saf', value: 'content://fixture/tree/opaque-root'),
      (kind: 'saf', value: 'content://fixture/document/'),
      (kind: 'saf', value: 'content://fixture/document/audio#fragment'),
    ]) {
      expect(() => StorageCodec.encodeAudio(audio), invalidStorage);
      expect(
        () => StorageCodec.decodeAudio(
          jsonEncode(
            {'version': 1, 'kind': audio.kind, 'value': audio.value},
          ),
        ),
        invalidStorage,
      );
    }
  });
  test('nested binding fields and platform tags are validated', () {
    const binding = (
      key: (dumpId: 'fixture-one', incarnation: 'fixture-inc'),
      location: (
        id: 'fixture-location',
        directory: safDirectory,
        label: 'Original'
      ),
      audio: (kind: 'saf', value: 'content://fixture/document/audio'),
      metadataName: 'fixture-one.meta.json'
    );
    final valid =
        jsonDecode(StorageCodec.encodeBinding(binding)) as Map<String, dynamic>;
    for (final change in <Map<String, dynamic>>[
      {'key': null},
      {'location': <Object?>[]},
      {
        'audio': {
          'version': 1,
          'kind': 'file',
          'value': r'C:\fixture\audio.opus',
        },
      },
      {
        'audio': {
          'version': 1,
          'kind': 'saf',
          'value': 'content://other/document/audio',
        },
      },
      {'metadataName': '../foreign.meta.json'},
      {'metadataName': ''},
      {'metadataName': null},
    ]) {
      expect(
        () => StorageCodec.decodeBinding(jsonEncode({...valid, ...change})),
        invalidStorage,
      );
    }
    final location = jsonDecode(StorageCodec.encodeLocation(binding.location))
        as Map<String, dynamic>;
    for (final change in <Map<String, dynamic>>[
      {'id': '../outside'},
      {'directory': null},
      {'label': 1},
    ]) {
      expect(
        () => StorageCodec.decodeLocation(jsonEncode({...location, ...change})),
        invalidStorage,
      );
    }
  });
  test('C1 keys have value equality and typed outcomes retain their value', () {
    const key = (dumpId: 'fixture-one', incarnation: 'incarnation-one');
    expect(
      {key}.contains((dumpId: 'fixture-one', incarnation: 'incarnation-one')),
      isTrue,
    );
    expect(const Ok<RecordingKey>(key).value, key);
    expect(
      const Fail<RecordingKey>(
        (code: ProblemCode.invalid, message: 'invalid'),
      ).problem.code,
      ProblemCode.invalid,
    );
  });
  for (final path in [
    r'C:\Recordings\Mixed Case',
    r'\\server\share\Voice notes',
    '/home/fixture/audio',
  ]) {
    test('literal file directory and audio round-trip: $path', () {
      final directory = fileDirectory(path);
      final audio = (kind: 'file', value: '$path/fixture-one.opus');
      expect(
        StorageCodec.decodeDirectory(StorageCodec.encodeDirectory(directory)),
        directory,
      );
      expect(StorageCodec.decodeAudio(StorageCodec.encodeAudio(audio)), audio);
      expect(
        StorageCodec.canonicalKey(directory),
        jsonEncode(['file', path, '', '']),
      );
    });
  }
  test('SAF identities round-trip without inferring the effective parent', () {
    const audio = (
      kind: 'saf',
      value: 'content://fixture/tree/opaque-root/document/opaque-audio'
    );
    expect(
      StorageCodec.decodeDirectory(
        StorageCodec.encodeDirectory(safDirectory),
      ),
      safDirectory,
    );
    expect(StorageCodec.decodeAudio(StorageCodec.encodeAudio(audio)), audio);
    final equivalentGrant = (
      kind: safDirectory.kind,
      path: '',
      treeUri: 'content://fixture/tree/another-grant',
      authority: 'fixture',
      documentId: safDirectory.documentId
    );
    expect(
      StorageCodec.canonicalKey(equivalentGrant),
      StorageCodec.canonicalKey(safDirectory),
    );
    expect(
      jsonDecode(StorageCodec.encodeDirectory(safDirectory))['version'],
      1,
    );
  });
  test(
      'key, location and binding preserve explicit named fields deterministically',
      () {
    const key = (dumpId: 'fixture-one', incarnation: 'incarnation-one');
    const location = (
      id: 'fixture-location',
      directory: safDirectory,
      label: 'Original folder'
    );
    const binding = (
      key: key,
      location: location,
      audio: (
        kind: 'saf',
        value: 'content://fixture/tree/opaque-root/document/opaque-audio'
      ),
      metadataName: 'fixture-one.meta.json'
    );
    expect(StorageCodec.decodeKey(StorageCodec.encodeKey(key)), key);
    expect(
      StorageCodec.decodeLocation(StorageCodec.encodeLocation(location)),
      location,
    );
    final encoded = StorageCodec.encodeBinding(binding);
    expect(StorageCodec.decodeBinding(encoded), binding);
    expect(
      StorageCodec.encodeBinding(StorageCodec.decodeBinding(encoded)),
      encoded,
    );
    expect(
      (jsonDecode(encoded) as Map).keys,
      ['version', 'key', 'location', 'audio', 'metadataName'],
    );
  });
}
