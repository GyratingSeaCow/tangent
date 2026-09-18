// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/data/storage/storage_contract.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/services/notebook_persistence.dart';
import '../../support/scripted_storage_backend.dart';

/// Durable notebooks: every notebook publishes as ONE `<id>.notebook.json`
/// inside the 'Tangent Notebooks' child of the selected folder, and those
/// files are re-adopted on import so an uninstall cannot destroy a notebook.
void main() {
  NotebookRepository repositoryFor(CatalogHarness h, {DateTime? now}) =>
      NotebookRepository(
        db: h.f.db,
        idFactory: () => 'fixture-notebook-${h.counter++}',
        now: () => now ?? DateTime.utc(2030, 5, 6, 7, 8, 9),
      );

  NotebookPersistence persistenceFor(
    CatalogHarness h, {
    NotebookRepository? repository,
  }) =>
      NotebookPersistence(
        repository: repository ?? repositoryFor(h),
        backend: h.backend,
        catalog: h.catalog,
      );

  String notebookDirectory(CatalogHarness h) =>
      p.join(h.f.directory('A'), notebookSubdirectoryName);
  File notebookFile(CatalogHarness h, String id) =>
      File(p.join(notebookDirectory(h), '$id$notebookFileSuffix'));

  Notebook sampleNotebook(String id, {required DateTime when}) => Notebook(
        id: id,
        title: 'Durable notebook',
        createdAt: when,
        updatedAt: when,
        document: NotebookDocument([
          const NotebookTextBlock(id: 'block-text', text: 'typed words'),
          const NotebookCheckboxBlock(
            id: 'block-check',
            text: 'milk',
            checked: true,
          ),
          const NotebookDumpCardBlock(
            id: 'block-card',
            dumpId: 'fixture-dump',
            x: 12,
            y: 340,
          ),
          NotebookUnknownBlock(const {
            'kind': 'from-the-future',
            'id': 'block-unknown',
            'payload': {'deep': 1},
          }),
        ]),
        ink: const NotebookInk([
          InkStroke(
            id: 'stroke-1',
            width: 7.5,
            points: [InkPoint(x: 1, y: 2), InkPoint(x: 3, y: 4)],
          ),
        ]),
      );

  test(
      'saveNotebook publishes <id>.notebook.json into the Tangent Notebooks '
      'child, never the folder root', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final repository = repositoryFor(h);
    final created = await persistenceFor(h, repository: repository)
        .createNotebook(title: 'Groceries');
    final published = notebookFile(h, created.id);
    expect(
      await published.exists(),
      isTrue,
      reason: 'notebooks publish into the Tangent Notebooks subdirectory',
    );
    expect(
      File(p.join(h.f.directory('A'), '${created.id}$notebookFileSuffix'))
          .existsSync(),
      isFalse,
      reason: 'publication must never land at the selected folder root',
    );
    final payload =
        jsonDecode(await published.readAsString()) as Map<String, dynamic>;
    expect(payload['schema'], 1);
    expect(payload['id'], created.id);
    expect(payload['title'], 'Groceries');
    expect(payload['createdAt'], created.createdAt.millisecondsSinceEpoch);
    expect(payload['updatedAt'], created.updatedAt.millisecondsSinceEpoch);
    expect(payload['doc'], isA<Map<String, dynamic>>());
    expect(payload['ink'], isA<Map<String, dynamic>>());
    expect(
      payload.keys.toSet(),
      {'schema', 'id', 'title', 'createdAt', 'updatedAt', 'doc', 'ink'},
      reason: 'one self-contained file per notebook, no sidecar',
    );
    expect(
      Directory(notebookDirectory(h)).listSync().length,
      1,
      reason: 'no sidecar and no leftover temporary file',
    );
  });

  test('the published payload round-trips ink and unknown block kinds',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final repository = repositoryFor(h);
    final persistence = persistenceFor(h, repository: repository);
    final created = await persistence.createNotebook();
    final saved = await persistence.saveNotebook(
      sampleNotebook(created.id, when: created.createdAt)
          .copyWith(title: 'Round trip'),
    );
    final decoded = decodeNotebookFile(
      await notebookFile(h, created.id).readAsString(),
    );
    expect(decoded.id, saved.id);
    expect(decoded.title, 'Round trip');
    expect(decoded.updatedAt, saved.updatedAt);
    expect(decoded.createdAt, saved.createdAt);
    expect(decoded.ink.strokes.single.width, 7.5);
    expect(decoded.ink.strokes.single.points.length, 2);
    expect(decoded.ink.strokes.single.points.last.y, 4);
    expect(decoded.document.blocks.length, 4);
    final unknown = decoded.document.blocks.last;
    expect(unknown, isA<NotebookUnknownBlock>());
    expect(
      (unknown as NotebookUnknownBlock).raw,
      {
        'kind': 'from-the-future',
        'id': 'block-unknown',
        'payload': {'deep': 1},
      },
      reason: 'a newer build\'s blocks must survive verbatim',
    );
    final card = decoded.document.blocks[2] as NotebookDumpCardBlock;
    expect(card.dumpId, 'fixture-dump');
    expect(card.x, 12);
    expect(card.y, 340);
  });

  test('import adopts a durable file that has no database row', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final repository = repositoryFor(h);
    final persistence = persistenceFor(h, repository: repository);
    // Simulate a reinstall: the file survives, the row does not.
    const id = 'fixture-orphan-notebook';
    final when = DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true);
    await Directory(notebookDirectory(h)).create(recursive: true);
    await notebookFile(h, id).writeAsString(
      encodeNotebookFile(sampleNotebook(id, when: when)),
      flush: true,
    );
    expect(await repository.getNotebook(id), isNull);
    final result = await persistence.importNotebooks();
    expect(result.problems, isEmpty);
    expect(result.adoptedIds, [id]);
    final adopted = await repository.getNotebook(id);
    expect(adopted, isNotNull);
    expect(adopted!.title, 'Durable notebook');
    expect(adopted.createdAt, when);
    expect(adopted.updatedAt, when);
    expect(adopted.ink.strokes.single.id, 'stroke-1');
    expect(adopted.document.blocks.length, 4);
    expect(
      await notebookFile(h, id).exists(),
      isTrue,
      reason: 'import must never delete a user file',
    );
  });

  test('import resolves conflicts by newer updated_at in both directions',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final older = DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true);
    final newer = DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true);
    final repository = repositoryFor(h);
    final persistence = persistenceFor(h, repository: repository);

    // 1. File newer than row -> the file wins.
    const fileWins = 'fixture-file-wins';
    await repository.upsertNotebook(
      sampleNotebook(fileWins, when: older).copyWith(title: 'stale row'),
    );
    await Directory(notebookDirectory(h)).create(recursive: true);
    await notebookFile(h, fileWins).writeAsString(
      encodeNotebookFile(
        sampleNotebook(fileWins, when: newer).copyWith(title: 'fresh file'),
      ),
      flush: true,
    );

    // 2. Row newer than file -> the row survives untouched.
    const rowWins = 'fixture-row-wins';
    await repository.upsertNotebook(
      sampleNotebook(rowWins, when: newer).copyWith(title: 'fresh row'),
    );
    await notebookFile(h, rowWins).writeAsString(
      encodeNotebookFile(
        sampleNotebook(rowWins, when: older).copyWith(title: 'stale file'),
      ),
      flush: true,
    );

    // 3. Equal timestamps -> the local row is kept.
    const tie = 'fixture-tie';
    await repository.upsertNotebook(
      sampleNotebook(tie, when: newer).copyWith(title: 'local row'),
    );
    await notebookFile(h, tie).writeAsString(
      encodeNotebookFile(
        sampleNotebook(tie, when: newer).copyWith(title: 'remote file'),
      ),
      flush: true,
    );

    final result = await persistence.importNotebooks();
    expect(result.problems, isEmpty);
    expect(result.adoptedIds, [fileWins]);
    expect(result.keptLocalIds..sort(), [rowWins, tie]);
    expect((await repository.getNotebook(fileWins))!.title, 'fresh file');
    expect((await repository.getNotebook(rowWins))!.title, 'fresh row');
    expect((await repository.getNotebook(tie))!.title, 'local row');
    for (final id in [fileWins, rowWins, tie]) {
      expect(
        await notebookFile(h, id).exists(),
        isTrue,
        reason: 'import never deletes a user file',
      );
    }
  });

  test('a malformed durable file is reported but never deleted or adopted',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final repository = repositoryFor(h);
    await Directory(notebookDirectory(h)).create(recursive: true);
    final broken =
        File(p.join(notebookDirectory(h), 'fixture-broken$notebookFileSuffix'));
    await broken.writeAsString('{ not json', flush: true);
    final result =
        await persistenceFor(h, repository: repository).importNotebooks();
    expect(result.adoptedIds, isEmpty);
    expect(result.problems.single.code, ProblemCode.invalid);
    expect(await broken.exists(), isTrue);
    expect(await repository.getNotebook('fixture-broken'), isNull);
  });

  test('a dropped publication still leaves the edit durable in the database',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final repository = repositoryFor(h);
    final persistence = persistenceFor(h, repository: repository);
    final created = await persistence.createNotebook(title: 'Survivor');
    h.backend.documentPublication = (location, directory, name, content, id) =>
        ImmediateIo(
      'fixture-notebook-publish-fail',
      const Fail<DurableDocument>(
        (code: ProblemCode.io, message: 'fixture notebook publication died'),
      ),
    );
    final edited = sampleNotebook(created.id, when: created.createdAt)
        .copyWith(title: 'Edited while storage was broken');
    await expectLater(
      persistence.saveNotebook(edited),
      throwsA(
        isA<StorageFault>().having(
          (e) => e.problem.message,
          'message',
          'fixture notebook publication died',
        ),
      ),
    );
    final row = await repository.getNotebook(created.id);
    expect(
      row,
      isNotNull,
      reason: 'a publication fault must never lose the user edit',
    );
    expect(row!.title, 'Edited while storage was broken');
    expect(row.document.blocks.length, 4);
    // The prior publication is intact: the last durable copy is still the
    // last successfully published one, never a truncated file.
    expect(
      decodeNotebookFile(await notebookFile(h, created.id).readAsString())
          .title,
      'Survivor',
    );
    h.backend.documentPublication = null;
    final repaired = await persistence.saveNotebook(row);
    expect(
      decodeNotebookFile(await notebookFile(h, created.id).readAsString())
          .title,
      repaired.title,
      reason: 'a later successful save republishes the durable file',
    );
  });

  test('deleteNotebook removes both the row and the durable file', () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final repository = repositoryFor(h);
    final persistence = persistenceFor(h, repository: repository);
    final keep = await persistence.createNotebook(title: 'Keep');
    final drop = await persistence.createNotebook(title: 'Drop');
    expect(await notebookFile(h, drop.id).exists(), isTrue);
    await persistence.deleteNotebook(drop.id);
    expect(await repository.getNotebook(drop.id), isNull);
    expect(
      await notebookFile(h, drop.id).exists(),
      isFalse,
      reason: 'the durable file must go with the row',
    );
    expect(await repository.getNotebook(keep.id), isNotNull);
    expect(await notebookFile(h, keep.id).exists(), isTrue);
    // A deleted notebook must not resurrect on the next folder import.
    final result = await persistence.importNotebooks();
    expect(result.adoptedIds, isEmpty);
    expect(await repository.getNotebook(drop.id), isNull);
  });

  test('repeated saves reuse one directory and one file per notebook',
      () async {
    final h = CatalogHarness();
    addTearDown(h.close);
    await h.bootstrap();
    final repository = repositoryFor(h);
    final persistence = persistenceFor(h, repository: repository);
    final created = await persistence.createNotebook(title: 'First');
    for (final title in ['Second', 'Third']) {
      await persistence.saveNotebook(
        (await repository.getNotebook(created.id))!.copyWith(title: title),
      );
    }
    expect(
      Directory(h.f.directory('A'))
          .listSync()
          .where((e) => p.basename(e.path) == notebookSubdirectoryName)
          .length,
      1,
      reason: 'the notebooks directory resolves idempotently',
    );
    expect(Directory(notebookDirectory(h)).listSync().length, 1);
    expect(
      decodeNotebookFile(await notebookFile(h, created.id).readAsString())
          .title,
      'Third',
    );
  });
}
