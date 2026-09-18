// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;

void main() {
  late LocalDb db;
  late DateTime now;
  var ids = 0;

  NotebookRepository build() => NotebookRepository(
        db: db,
        idFactory: () => 'notebook-${++ids}',
        now: () => now,
      );

  setUp(() {
    ids = 0;
    now = DateTime.utc(2026, 9, 17, 14, 5, 9);
    db = LocalDb.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('createNotebook persists an empty document with a dated title',
      () async {
    final repository = build();
    final created = await repository.createNotebook();

    expect(created.id, 'notebook-1');
    expect(created.title, defaultNotebookTitle(now));
    expect(created.createdAt, now);
    expect(created.updatedAt, now);
    expect(created.document.blocks, isEmpty);
    expect(created.ink.strokes, isEmpty);

    final row = await db.customSelect('SELECT * FROM notebooks').getSingle();
    expect(row.data['id'], 'notebook-1');
    expect(row.data['created_at'], now.millisecondsSinceEpoch);
    expect(row.data['updated_at'], now.millisecondsSinceEpoch);
    expect(row.data['doc_json'], '{"blocks":[]}');
    expect(row.data['ink_json'], '{"strokes":[]}');
  });

  test('createNotebook honours an explicit title', () async {
    final created = await build().createNotebook(title: 'Groceries');
    expect(created.title, 'Groceries');
    expect((await build().getNotebook(created.id))!.title, 'Groceries');
  });

  test('getNotebook returns null for an unknown id', () async {
    expect(await build().getNotebook('missing'), isNull);
  });

  test('saveNotebook persists blocks and ink and bumps updated_at', () async {
    final repository = build();
    final created = await repository.createNotebook();

    now = now.add(const Duration(minutes: 3));
    await repository.saveNotebook(
      created.copyWith(
        title: 'Renamed',
        document: NotebookDocument.decode(
          '{"blocks":['
          '{"kind":"text","id":"b1","text":"hello"},'
          '{"kind":"checkbox","id":"b2","text":"milk","checked":true},'
          '{"kind":"dumpCard","id":"b3","dumpId":"d9","x":12.0,"y":340.0}'
          ']}',
        ),
        ink: NotebookInk.decode(
          '{"strokes":[{"id":"s1","width":3.0,"points":[{"x":1.0,"y":2.0}]}]}',
        ),
      ),
    );

    final loaded = (await repository.getNotebook(created.id))!;
    expect(loaded.title, 'Renamed');
    expect(loaded.createdAt, created.createdAt);
    expect(loaded.updatedAt, now);
    expect(loaded.document.blocks, hasLength(3));
    expect(loaded.ink.strokes.single.points.single.y, 2.0);
  });

  test('an unknown block kind survives a save/load/save round trip', () async {
    final repository = build();
    final created = await repository.createNotebook();
    const source = '{"blocks":['
        '{"kind":"text","id":"b1","text":"before"},'
        '{"kind":"futureThing","id":"b2","payload":{"deep":[1,2]}}'
        ']}';

    await repository.saveNotebook(
      created.copyWith(document: NotebookDocument.decode(source)),
    );
    final loaded = (await repository.getNotebook(created.id))!;
    await repository.saveNotebook(loaded);

    final row = await db.customSelect('SELECT * FROM notebooks').getSingle();
    expect(
      jsonDecode(row.data['doc_json']! as String),
      jsonDecode(source),
    );
  });

  test('a notebook whose stored JSON is corrupt loads as an empty document',
      () async {
    final repository = build();
    final created = await repository.createNotebook();
    await db.customStatement(
      "UPDATE notebooks SET doc_json='{oops', ink_json='nope'",
    );

    final loaded = (await repository.getNotebook(created.id))!;
    expect(loaded.document.blocks, isEmpty);
    expect(loaded.ink.strokes, isEmpty);
  });

  test('watchNotebooks emits newest-updated first and reacts to writes',
      () async {
    final repository = build();
    final stream = repository.watchNotebooks();
    final first = await repository.createNotebook(title: 'First');
    now = now.add(const Duration(minutes: 1));
    final second = await repository.createNotebook(title: 'Second');

    expect(
      (await stream.firstWhere((rows) => rows.length == 2))
          .map((n) => n.title)
          .toList(),
      ['Second', 'First'],
    );

    now = now.add(const Duration(minutes: 5));
    await repository.saveNotebook(first.copyWith(title: 'First again'));
    expect(
      (await stream.firstWhere(
        (rows) => rows.isNotEmpty && rows.first.title == 'First again',
      ))
          .map((n) => n.title)
          .toList(),
      ['First again', 'Second'],
    );
    expect(second.title, 'Second');
  });

  test('deleteNotebook removes only the requested row', () async {
    final repository = build();
    final keep = await repository.createNotebook(title: 'Keep');
    final drop = await repository.createNotebook(title: 'Drop');

    await repository.deleteNotebook(drop.id);

    expect(await repository.getNotebook(drop.id), isNull);
    expect((await repository.getNotebook(keep.id))!.title, 'Keep');
    await repository.deleteNotebook('already-gone');
    expect(await repository.watchNotebooks().first, hasLength(1));
  });

  test('notebookRepositoryProvider builds against the app database', () async {
    final container = ProviderContainer(
      overrides: [localDbProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final repository = container.read(notebookRepositoryProvider);
    final created = await repository.createNotebook(title: 'Via provider');
    expect((await repository.getNotebook(created.id))!.title, 'Via provider');
    expect(created.id, isNotEmpty);
  });
}
