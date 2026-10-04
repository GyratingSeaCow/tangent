// SPDX-License-Identifier: AGPL-3.0-or-later
//
// LocalDb tag semantics: vocabulary rules, the polymorphic assignment table,
// the delete cascade, dirty-marking/tombstones (what sync will see), and the
// remote-apply guards.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/data/tag_repository.dart';

void main() {
  late LocalDb db;

  setUp(() => db = LocalDb.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<List<SyncTombstoneRow>> stones() => db.pendingTombstones();
  Future<List<TagAssignmentRow>> assignments() =>
      db.select(db.tagAssignments).get();

  Future<void> insertNotebook(String id) => db.into(db.notebooks).insert(
        NotebooksCompanion.insert(
          id: id,
          title: 'Notebook',
          createdAt: 1,
          updatedAt: 2,
          docJson: '{}',
          inkJson: '{}',
        ),
      );

  Future<void> insertDump(String id) => db.into(db.dumps).insert(
        DumpsCompanion.insert(
          id: id,
          createdAt: DateTime.utc(2026, 10, 4),
          updatedAt: DateTime.utc(2026, 10, 4),
          mode: 'dump',
          durationSeconds: 30,
          title: 'Recording',
          audioPath: '/tmp/$id.opus',
          audioSizeBytes: 4096,
          syncStatus: 'synced',
        ),
      );

  test('assignment id is deterministic and matches the server derivation', () {
    // The same literal is pinned in server/tests/test_tag_sync.py.
    expect(
      LocalDb.tagAssignmentId('tag-1', 'notebook', 'nb-1'),
      'ta-155235622e337c16b47339b6ff7e9ba60586247b',
    );
    expect(
      LocalDb.tagAssignmentId('tag-1', 'dump', 'nb-1'),
      isNot(LocalDb.tagAssignmentId('tag-1', 'notebook', 'nb-1')),
    );
  });

  group('vocabulary', () {
    test('create normalises, marks dirty, and never mints a twin', () async {
      final String id = await db.createTag('  Deep   work ');
      final TagRow row = (await db.allTags()).single;
      expect(row.name, 'Deep work');
      expect(row.syncDirty, isTrue);
      expect(await db.createTag('deep WORK'), id, reason: 'case-insensitive');
      expect(await db.allTags(), hasLength(1));
    });

    test('blank and over-long names are refused', () async {
      expect(() => db.createTag('   '), throwsA(isA<TagNameException>()));
      expect(
        () => db.createTag('x' * (LocalDb.maxTagNameLength + 1)),
        throwsA(isA<TagNameException>()),
      );
    });

    test('rename refuses a taken name and otherwise marks dirty', () async {
      final String work = await db.createTag('Work');
      await db.createTag('Home');
      await (db.update(
        db.tags,
      )).write(const TagsCompanion(syncDirty: Value<bool?>(false)));
      expect(
        () => db.renameTag(work, 'home'),
        throwsA(isA<TagNameException>()),
      );
      await db.renameTag(work, 'Job', now: DateTime.utc(2030));
      final TagRow row = (await db.allTags()).firstWhere((t) => t.id == work);
      expect(row.name, 'Job');
      expect(row.syncDirty, isTrue);
      expect(row.updatedAt, DateTime.utc(2030).millisecondsSinceEpoch);
      // Renaming to its own name in a different case is not a conflict.
      await db.renameTag(work, 'JOB');
    });

    test('watchTags is alphabetical regardless of case', () async {
      await db.createTag('beta');
      await db.createTag('Alpha');
      await db.createTag('gamma');
      expect((await db.watchTags().first).map((TagRow t) => t.name), <String>[
        'Alpha',
        'beta',
        'gamma',
      ]);
    });
  });

  group('assignments', () {
    test(
      'assign is idempotent and polymorphic over notebooks and dumps',
      () async {
        final String tag = await db.createTag('Work');
        for (int i = 0; i < 2; i++) {
          await db.assignTag(
            tagId: tag,
            targetType: 'notebook',
            targetId: 'n1',
          );
        }
        await db.assignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
        expect(await assignments(), hasLength(2));
        expect(await db.watchTagLinks('notebook').first, <TagLink>[
          (targetId: 'n1', tagId: tag),
        ]);
        expect(await db.watchTagLinks('dump').first, <TagLink>[
          (targetId: 'd1', tagId: tag),
        ]);
        expect(
          () => db.assignTag(tagId: tag, targetType: 'todo', targetId: 't'),
          throwsArgumentError,
        );
        expect(
          () => db.assignTag(tagId: 'nope', targetType: 'dump', targetId: 'd'),
          throwsStateError,
        );
      },
    );

    test(
      'unassign tombstones; a re-add cancels the undelivered removal',
      () async {
        final String tag = await db.createTag('Work');
        await db.assignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
        await db.unassignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
        expect(await assignments(), isEmpty);
        final String id = LocalDb.tagAssignmentId(tag, 'dump', 'd1');
        expect(
          (await stones()).map((s) => (s.entityType, s.entityId)),
          <(String, String)>[('tag_assignment', id)],
        );

        await db.assignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
        expect(
          (await stones()).where((s) => s.entityType == 'tag_assignment'),
          isEmpty,
          reason:
              'otherwise the removal would push after, and undo, the re-add',
        );
      },
    );

    test('removing an absent tag writes no tombstone', () async {
      final String tag = await db.createTag('Work');
      await db.unassignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
      expect(await stones(), isEmpty);
    });
  });

  test('deleting a tag removes it from every notebook AND dump, with one '
      'tombstone, and leaves other tags alone', () async {
    await insertNotebook('n1');
    await insertDump('d1');
    final String work = await db.createTag('Work');
    final String home = await db.createTag('Home');
    await db.assignTag(tagId: work, targetType: 'notebook', targetId: 'n1');
    await db.assignTag(tagId: work, targetType: 'dump', targetId: 'd1');
    await db.assignTag(tagId: home, targetType: 'dump', targetId: 'd1');
    expect(await db.tagAssignmentCount(work), 2);

    await db.deleteTag(work);

    expect((await db.allTags()).map((TagRow t) => t.id), <String>[home]);
    expect(await db.watchTagLinks('notebook').first, isEmpty);
    expect(await db.watchTagLinks('dump').first, <TagLink>[
      (targetId: 'd1', tagId: home),
    ]);
    expect(
      (await stones()).map((s) => (s.entityType, s.entityId)),
      <(String, String)>[('tag', work)],
    );
    // Assert the TABLE, not only the projection: watchTagLinks joins to live
    // tags, so an orphaned dump assignment would be invisible there while
    // still sitting in the database (a sabotage once proved exactly that).
    expect(
      (await assignments()).map((a) => (a.tagId, a.targetType, a.targetId)),
      <(String, String, String)>[(home, 'dump', 'd1')],
    );
  });

  test('usage count covers only notebooks and recordings that are live here',
      () async {
    await insertNotebook('n-live');
    await insertNotebook('n-trashed');
    await insertDump('d-live');
    await db.trashNotebook('n-trashed');
    final String work = await db.createTag('Work');
    for (final (String type, String id) in <(String, String)>[
      ('notebook', 'n-live'),
      ('notebook', 'n-trashed'), // kept for a restore, not shown
      ('notebook', 'n-never-pulled'),
      ('dump', 'd-live'),
      ('dump', 'd-deleted'), // permanently deleted recording
    ]) {
      await db.assignTag(tagId: work, targetType: type, targetId: id);
    }

    expect(await db.tagAssignmentCount(work), 2);
    expect(await assignments(), hasLength(5), reason: 'rows are untouched');

    await db.restoreNotebook('n-trashed');
    expect(await db.tagAssignmentCount(work), 3);
  });

  group('remote apply', () {
    test('a pulled tag lands clean; a local unpushed rename wins', () async {
      await db.applyRemoteTag(
        id: 't1',
        name: 'Remote',
        createdAt: 1,
        updatedAt: 2,
        seq: 7,
      );
      TagRow row = (await db.allTags()).single;
      expect((row.name, row.syncDirty, row.syncedSeq), ('Remote', false, 7));

      await db.renameTag('t1', 'Mine');
      await db.applyRemoteTag(
        id: 't1',
        name: 'Theirs',
        createdAt: 1,
        updatedAt: 3,
        seq: 8,
      );
      row = (await db.allTags()).single;
      expect(row.name, 'Mine', reason: 'the dirty local edit pushes next');
    });

    test('a pulled tag does not resurrect one deleted here', () async {
      await db.applyRemoteTag(
        id: 't1',
        name: 'X',
        createdAt: 1,
        updatedAt: 1,
        seq: 1,
      );
      await db.deleteTag('t1');
      await db.applyRemoteTag(
        id: 't1',
        name: 'X',
        createdAt: 1,
        updatedAt: 2,
        seq: 2,
      );
      expect(await db.allTags(), isEmpty);
    });

    test(
      'a pulled tag deletion cascades through dirty and clean assignments',
      () async {
        await db.applyRemoteTag(
          id: 't1',
          name: 'X',
          createdAt: 1,
          updatedAt: 1,
          seq: 1,
        );
        await db.applyRemoteTagAssignment(
          id: LocalDb.tagAssignmentId('t1', 'notebook', 'n1'),
          tagId: 't1',
          targetType: 'notebook',
          targetId: 'n1',
          createdAt: 1,
          seq: 2,
        );
        await db.assignTag(tagId: 't1', targetType: 'dump', targetId: 'd1');

        await db.applyRemoteTagDeletion('t1');

        expect(await db.allTags(), isEmpty);
        expect(await assignments(), isEmpty);
        expect(await stones(), isEmpty, reason: 'never echoed back');
      },
    );

    test('a pulled assignment removal spares a dirty local re-add', () async {
      final String tag = await db.createTag('Work');
      await db.assignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
      final String id = LocalDb.tagAssignmentId(tag, 'dump', 'd1');

      await db.applyRemoteTagAssignmentDeletion(id);
      expect(await assignments(), hasLength(1));

      await db.markTagAssignmentSynced(id, seq: 3);
      await db.applyRemoteTagAssignmentDeletion(id);
      expect(await assignments(), isEmpty);
    });

    test('a pulled assignment never lands for a tag absent here', () async {
      Future<void> pullAssignment(String tagId, int seq) =>
          db.applyRemoteTagAssignment(
            id: LocalDb.tagAssignmentId(tagId, 'dump', 'd1'),
            tagId: tagId,
            targetType: 'dump',
            targetId: 'd1',
            createdAt: 1,
            seq: seq,
          );

      // Deleted here AND the deletion already pushed: no tombstone is left
      // to guard it, only the tag's absence.
      final String tag = await db.createTag('Work');
      await db.deleteTag(tag);
      await db.clearTombstone(entityType: 'tag', entityId: tag);
      expect(await stones(), isEmpty);
      await pullAssignment(tag, 5);

      // A tag this device has never held.
      await pullAssignment('never-seen', 6);

      // Assert the TABLE: watchTagLinks joins live tags and would hide an
      // orphan that still inflates counts and lingers forever.
      expect(await assignments(), isEmpty);
    });

    test('a pulled assignment yields to a pending local removal', () async {
      final String tag = await db.createTag('Work');
      await db.assignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
      await db.unassignTag(tagId: tag, targetType: 'dump', targetId: 'd1');
      await db.applyRemoteTagAssignment(
        id: LocalDb.tagAssignmentId(tag, 'dump', 'd1'),
        tagId: tag,
        targetType: 'dump',
        targetId: 'd1',
        createdAt: 1,
        seq: 4,
      );
      expect(await assignments(), isEmpty);
    });
  });

  test(
    'LocalTagStore projects ids and names only, grouped by target',
    () async {
      await insertNotebook('n1');
      final LocalTagStore store = LocalTagStore(db);
      final String a = await store.createTag('Alpha');
      final String b = await store.createTag('beta');
      await store.assignTag(tagId: b, targetType: 'notebook', targetId: 'n1');
      await store.assignTag(tagId: a, targetType: 'notebook', targetId: 'n1');
      final List<TagSummary> tags = await store.watchTags().first;
      expect(tags, <TagSummary>[(id: a, name: 'Alpha'), (id: b, name: 'beta')]);
      final Map<String, Set<String>> links = groupTagLinks(
        await store.watchTagLinks('notebook').first,
      );
      expect(links, <String, Set<String>>{
        'n1': <String>{a, b},
      });
      expect(tagNamesFor(links['n1'], tags), <String>['Alpha', 'beta']);
      expect(effectiveTagFilter(a, tags), a);
      expect(effectiveTagFilter('deleted', tags), isNull);
      expect(await store.usageCount(a), 1);
    },
  );
}
