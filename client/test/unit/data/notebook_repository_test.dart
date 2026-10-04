// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow, Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/notebook_repository.dart';
import 'package:tangent/models/notebook.dart';
import 'package:tangent/screens/home/home_screen.dart' show localDbProvider;
import 'package:tangent/services/notebook_persistence.dart';

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

  test(
    'createNotebook persists an empty document with a dated title',
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
    },
  );

  test('createNotebook honours an explicit title', () async {
    final created = await build().createNotebook(title: 'Groceries');
    expect(created.title, 'Groceries');
    expect((await build().getNotebook(created.id))!.title, 'Groceries');
  });

  test('getNotebook returns null for an unknown id', () async {
    expect(await build().getNotebook('missing'), isNull);
  });

  test(
    'password protection stores only verifier metadata and verifies removal',
    () async {
      final NotebookRepository repository = build();
      final Notebook created = await repository.createNotebook(
        title: 'Private notes',
      );

      await repository.setPassword(created.id, 'correct horse battery staple');

      final Notebook protected = (await repository.getNotebook(created.id))!;
      expect(protected.passwordProtected, isTrue);
      expect(protected.passwordHash, isNot(contains('correct horse')));
      expect(protected.passwordSalt, isNotEmpty);
      expect(protected.passwordIterations, greaterThanOrEqualTo(100000));
      final QueryRow raw = await db.customSelect(
        'SELECT * FROM notebooks WHERE id = ?',
        variables: [Variable<String>(created.id)],
      ).getSingle();
      expect(raw.data.values, isNot(contains('correct horse battery staple')));
      expect(
        await repository.verifyPassword(created.id, 'wrong password'),
        isFalse,
      );
      expect(
        await repository.verifyPassword(
          created.id,
          'correct horse battery staple',
        ),
        isTrue,
      );
      expect(
        await repository.removePassword(created.id, 'wrong password'),
        isFalse,
      );
      expect(
        await repository.removePassword(
          created.id,
          'correct horse battery staple',
        ),
        isTrue,
      );
      final Notebook open = (await repository.getNotebook(created.id))!;
      expect(open.passwordHash, isNull);
      expect(open.passwordSalt, isNull);
      expect(open.passwordIterations, isNull);
      expect(open.passwordHashPrev, protected.passwordHash);
    },
  );

  test('each protected notebook receives a different random salt', () async {
    final NotebookRepository repository = build();
    final Notebook one = await repository.createNotebook(title: 'One');
    final Notebook two = await repository.createNotebook(title: 'Two');

    await repository.setPassword(one.id, 'same password');
    await repository.setPassword(two.id, 'same password');

    final Notebook protectedOne = (await repository.getNotebook(one.id))!;
    final Notebook protectedTwo = (await repository.getNotebook(two.id))!;
    expect(protectedOne.passwordSalt, isNot(protectedTwo.passwordSalt));
    expect(protectedOne.passwordHash, isNot(protectedTwo.passwordHash));
  });

  test(
    'durable clear requires prev and tombstone rejects stale verifier',
    () async {
      final NotebookRepository repository = build();
      final Notebook created = await repository.createNotebook(
        title: 'Private',
      );
      await repository.setPassword(created.id, 'first password');
      Notebook protected = (await repository.getNotebook(created.id))!;

      final Map<String, dynamic> explicitOpen =
          jsonDecode(encodeNotebookFile(protected)) as Map<String, dynamic>;
      explicitOpen
        ..['passwordHash'] = null
        ..['passwordSalt'] = null
        ..['passwordIterations'] = null;
      await repository.upsertNotebook(
        decodeNotebookFile(jsonEncode(explicitOpen)),
      );
      expect(
        (await repository.getNotebook(created.id))!.passwordHash,
        protected.passwordHash,
        reason: 'explicit null without predecessor is not authenticated',
      );

      explicitOpen['passwordHashPrev'] = 'wrong-hash';
      await repository.upsertNotebook(
        decodeNotebookFile(jsonEncode(explicitOpen)),
      );
      expect(
        (await repository.getNotebook(created.id))!.passwordHash,
        protected.passwordHash,
      );

      explicitOpen['passwordHashPrev'] = protected.passwordHash;
      await repository.upsertNotebook(
        decodeNotebookFile(jsonEncode(explicitOpen)),
      );
      expect((await repository.getNotebook(created.id))!.passwordHash, isNull);
      expect(
        (await repository.getNotebook(created.id))!.passwordHashPrev,
        protected.passwordHash,
      );

      await repository.upsertNotebook(protected);
      expect(
        (await repository.getNotebook(created.id))!.passwordHash,
        isNull,
        reason: 'a stale durable tuple cannot restore the cleared generation',
      );

      await repository.setPassword(created.id, 'second password');
      protected = (await repository.getNotebook(created.id))!;
      final String heldHash = protected.passwordHash!;
      final Map<String, dynamic> legacy =
          jsonDecode(encodeNotebookFile(protected)) as Map<String, dynamic>
            ..remove('passwordHash')
            ..remove('passwordSalt')
            ..remove('passwordIterations');
      await repository.upsertNotebook(decodeNotebookFile(jsonEncode(legacy)));
      expect(
        (await repository.getNotebook(created.id))!.passwordHash,
        heldHash,
      );
    },
  );

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
    expect(jsonDecode(row.data['doc_json']! as String), jsonDecode(source));
  });

  test(
    'a notebook whose stored JSON is corrupt loads as an empty document',
    () async {
      final repository = build();
      final created = await repository.createNotebook();
      await db.customStatement(
        "UPDATE notebooks SET doc_json='{oops', ink_json='nope'",
      );

      final loaded = (await repository.getNotebook(created.id))!;
      expect(loaded.document.blocks, isEmpty);
      expect(loaded.ink.strokes, isEmpty);
    },
  );

  test(
    'watchNotebooks emits newest-updated first and reacts to writes',
    () async {
      final repository = build();
      final stream = repository.watchNotebooks();
      final first = await repository.createNotebook(title: 'First');
      now = now.add(const Duration(minutes: 1));
      final second = await repository.createNotebook(title: 'Second');

      expect(
        (await stream.firstWhere(
          (rows) => rows.length == 2,
        ))
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
    },
  );

  test('deleteNotebook removes only the requested row', () async {
    final repository = build();
    final keep = await repository.createNotebook(title: 'Keep');
    final drop = await repository.createNotebook(title: 'Drop');

    await repository.deleteNotebook(drop.id);

    expect(await repository.getNotebook(drop.id), isNull);
    expect((await repository.getNotebook(keep.id))!.title, 'Keep');
    await repository.deleteNotebook('already-gone');
    expect(await repository.watchNotebooks().first, hasLength(1));

    // Deletion is a move to the trash, not oblivion (user decision): the
    // row survives 7 days for restore from Settings → Trash.
    final trashed = await db.trashedNotebooks();
    expect(trashed.map((r) => r.id), contains(drop.id));
    await db.restoreNotebook(drop.id);
    expect((await repository.getNotebook(drop.id))!.title, 'Drop');
    expect(await repository.watchNotebooks().first, hasLength(2));
  });

  test(
    'purgeExpiredTrash drops only rows older than the 7-day window',
    () async {
      final repository = build();
      final old = await repository.createNotebook(title: 'Old garbage');
      final fresh = await repository.createNotebook(title: 'Fresh regret');
      await repository.deleteNotebook(old.id);
      await repository.deleteNotebook(fresh.id);
      // Age the first deletion past the window by writing its timestamp back.
      final int eightDaysAgo = DateTime.now()
          .subtract(const Duration(days: 8))
          .millisecondsSinceEpoch;
      await (db.update(db.notebooks)..where((t) => t.id.equals(old.id))).write(
        NotebooksCompanion(deletedAt: Value(eightDaysAgo)),
      );

      final int purged = await db.purgeExpiredTrash();

      expect(purged, 1, reason: 'only the 8-day-old row crosses the cutoff');
      final trashedIds = (await db.trashedNotebooks()).map((r) => r.id);
      expect(trashedIds, contains(fresh.id));
      expect(trashedIds, isNot(contains(old.id)));
    },
  );

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
