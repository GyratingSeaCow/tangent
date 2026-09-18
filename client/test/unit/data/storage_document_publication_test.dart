// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/storage/filesystem_storage_backend.dart';
import 'package:tangent/data/storage/saf_storage_backend.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import '../../support/storage_fixture.dart';

/// Sidecar-free durable documents (notebooks) publish into a named child of
/// the owned tree. The backend owns directory resolution so neither caller
/// ever builds a path out of a provider-opaque document ID.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('filesystem publication creates the child directory and replaces in it',
      () async {
    final fixture = StorageFixture.create();
    addTearDown(fixture.close);
    final backend = FilesystemStorageBackend();
    final location = fileLocation('A', fixture.directory('A'));
    final published = requireOk(
      await settled(
        backend.publishDocument(
          location,
          notebookSubdirectoryName,
          'fixture-one$notebookFileSuffix',
          '{"schema":1}',
          'fixture-publish-1',
        ),
      ),
    );
    final child = p.join(fixture.directory('A'), notebookSubdirectoryName);
    expect(published.name, 'fixture-one$notebookFileSuffix');
    expect(p.dirname(published.locator.value), child);
    expect(published.locator.kind, 'file');
    expect(
      await File(p.join(child, 'fixture-one$notebookFileSuffix'))
          .readAsString(),
      '{"schema":1}',
    );
    // Republication replaces the same document; no temp file survives.
    requireOk(
      await settled(
        backend.publishDocument(
          location,
          notebookSubdirectoryName,
          'fixture-one$notebookFileSuffix',
          '{"schema":1,"v":2}',
          'fixture-publish-2',
        ),
      ),
    );
    expect(Directory(child).listSync().length, 1);
    expect(
      await File(p.join(child, 'fixture-one$notebookFileSuffix'))
          .readAsString(),
      '{"schema":1,"v":2}',
    );
    expect(
      Directory(fixture.directory('A'))
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith(notebookFileSuffix)),
      isEmpty,
      reason: 'documents never publish at the selected folder root',
    );
  });

  test('filesystem enumeration returns only matching documents with content',
      () async {
    final fixture = StorageFixture.create();
    addTearDown(fixture.close);
    final backend = FilesystemStorageBackend();
    final location = fileLocation('A', fixture.directory('A'));
    // Absent directory enumerates as empty rather than failing.
    expect(
      requireOk(
        await settled(
          backend.listDocuments(
            location,
            notebookSubdirectoryName,
            notebookFileSuffix,
          ),
        ),
      ),
      isEmpty,
    );
    final child =
        Directory(p.join(fixture.directory('A'), notebookSubdirectoryName));
    await child.create(recursive: true);
    await File(p.join(child.path, 'fixture-a$notebookFileSuffix'))
        .writeAsString('{"a":1}', flush: true);
    await File(p.join(child.path, 'fixture-b$notebookFileSuffix'))
        .writeAsString('{"b":2}', flush: true);
    await File(p.join(child.path, 'unrelated.txt'))
        .writeAsString('ignored', flush: true);
    final documents = requireOk(
      await settled(
        backend.listDocuments(
          location,
          notebookSubdirectoryName,
          notebookFileSuffix,
        ),
      ),
    )..sort((a, b) => a.name.compareTo(b.name));
    expect(documents.map((d) => d.name), [
      'fixture-a$notebookFileSuffix',
      'fixture-b$notebookFileSuffix',
    ]);
    expect(documents.map((d) => d.content), ['{"a":1}', '{"b":2}']);
    expect(
      documents.every((d) => p.dirname(d.locator.value) == child.path),
      isTrue,
    );
  });

  test('filesystem deletion resolves the exact enumerated locator', () async {
    final fixture = StorageFixture.create();
    addTearDown(fixture.close);
    final backend = FilesystemStorageBackend();
    final location = fileLocation('A', fixture.directory('A'));
    final published = requireOk(
      await settled(
        backend.publishDocument(
          location,
          notebookSubdirectoryName,
          'fixture-doomed$notebookFileSuffix',
          '{"schema":1}',
          'fixture-publish-3',
        ),
      ),
    );
    final removed = await settled(
      backend.deleteDocument(
        location,
        notebookSubdirectoryName,
        published.name,
        published.locator,
        'fixture-delete-1',
      ),
    );
    expect(removed.state, ComponentState.removed);
    expect(File(published.locator.value).existsSync(), isFalse);
    // A repeat delete is absent, never an error: deletion stays idempotent.
    final again = await settled(
      backend.deleteDocument(
        location,
        notebookSubdirectoryName,
        published.name,
        published.locator,
        'fixture-delete-2',
      ),
    );
    expect(again.state, ComponentState.absent);
    // A locator that does not belong to the named child is refused outright.
    final foreign = await settled(
      backend.deleteDocument(
        location,
        notebookSubdirectoryName,
        published.name,
        (
          kind: 'file',
          value: p.join(fixture.directory('B'), published.name)
        ),
        'fixture-delete-3',
      ),
    );
    expect(foreign.state, ComponentState.failed);
    expect(foreign.problem!.code, ProblemCode.invalid);
  });

  test('a non-directory holding the child name faults instead of publishing',
      () async {
    final fixture = StorageFixture.create();
    addTearDown(fixture.close);
    final backend = FilesystemStorageBackend();
    final location = fileLocation('A', fixture.directory('A'));
    await File(p.join(fixture.directory('A'), notebookSubdirectoryName))
        .writeAsString('not a directory', flush: true);
    final result = await settled(
      backend.publishDocument(
        location,
        notebookSubdirectoryName,
        'fixture-one$notebookFileSuffix',
        '{"schema":1}',
        'fixture-publish-4',
      ),
    );
    expect(result, isA<Fail<DurableDocument>>());
    expect(
      (result as Fail<DurableDocument>).problem.code,
      ProblemCode.conflict,
    );
    expect(
      File(p.join(fixture.directory('A'), 'fixture-one$notebookFileSuffix'))
          .existsSync(),
      isFalse,
      reason: 'a blocked child directory must never fall back to the root',
    );
  });

  test('SAF document calls carry the exact wire payload and decode typed rows',
      () async {
    const channel = MethodChannel('fixture/notebook-documents');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final backend = SafStorageBackend(channel: channel);
    final location = (
      id: 'fixture-saf-notebooks',
      label: 'Fixture',
      directory: (
        kind: 'saf',
        path: '',
        treeUri: 'content://fixture/tree/root',
        authority: 'fixture',
        documentId: 'root'
      )
    );
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map;
      if (call.method == 'acknowledgeOperation') return null;
      if (call.method != 'operationState') {
        return {'operationId': args['operationId']};
      }
      final previous = calls[calls.length - 2];
      return {
        'state': 'settled',
        'result': switch (previous.method) {
          'publishDocumentAt' => {
              'name': 'fixture-x$notebookFileSuffix',
              'locator': {
                'version': 1,
                'kind': 'saf',
                'value': 'content://fixture/document/opaque%2Fx',
              },
              'content': '{"schema":1}',
            },
          'listDocumentsAt' => [
              {
                'name': 'fixture-x$notebookFileSuffix',
                'locator': {
                  'version': 1,
                  'kind': 'saf',
                  'value': 'content://fixture/document/opaque%2Fx',
                },
                'content': '{"schema":1}',
              },
            ],
          _ => {'state': 'removed', 'problem': null},
        },
      };
    });
    addTearDown(() async {
      await backend.drain();
      messenger.setMockMethodCallHandler(channel, null);
    });
    final published = requireOk(
      await settled(
        backend.publishDocument(
          location,
          notebookSubdirectoryName,
          'fixture-x$notebookFileSuffix',
          '{"schema":1}',
          'fixture-publish-saf',
        ),
      ),
    );
    expect(published.name, 'fixture-x$notebookFileSuffix');
    expect(
      published.locator,
      (kind: 'saf', value: 'content://fixture/document/opaque%2Fx'),
    );
    final publishCall = calls.firstWhere(
      (c) => c.method == 'publishDocumentAt',
    );
    final publishArgs = publishCall.arguments as Map;
    expect(publishArgs['directoryName'], notebookSubdirectoryName);
    expect(publishArgs['name'], 'fixture-x$notebookFileSuffix');
    expect(publishArgs['content'], '{"schema":1}');
    expect(publishArgs['publicationId'], 'fixture-publish-saf');
    expect(
      jsonDecode(jsonEncode(publishArgs['location']))['directory']['treeUri'],
      'content://fixture/tree/root',
    );
    final documents = requireOk(
      await settled(
        backend.listDocuments(
          location,
          notebookSubdirectoryName,
          notebookFileSuffix,
        ),
      ),
    );
    expect(documents.single.content, '{"schema":1}');
    final listArgs =
        calls.firstWhere((c) => c.method == 'listDocumentsAt').arguments as Map;
    expect(listArgs['directoryName'], notebookSubdirectoryName);
    expect(listArgs['suffix'], notebookFileSuffix);
    final removed = await settled(
      backend.deleteDocument(
        location,
        notebookSubdirectoryName,
        published.name,
        published.locator,
        'fixture-delete-saf',
      ),
    );
    expect(removed.state, ComponentState.removed);
    final deleteArgs = calls
        .firstWhere((c) => c.method == 'deleteDocumentAt')
        .arguments as Map;
    expect(deleteArgs['name'], 'fixture-x$notebookFileSuffix');
    expect(
      (deleteArgs['locator'] as Map)['value'],
      'content://fixture/document/opaque%2Fx',
      reason: 'deletion resolves by the opaque locator, never by a path',
    );
  });
}
