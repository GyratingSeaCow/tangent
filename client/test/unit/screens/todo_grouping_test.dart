// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/screens/todo/todo_grouping.dart';

/// v1.24.0: the To Do list's folder arrangement as plain data — the
/// notebook rules, plus Done-extracted-first and due-date order inside a
/// folder.
void main() {
  int counter = 0;
  TodoRow todo(
    String body, {
    String? folderId,
    String? dueDate,
    bool done = false,
  }) {
    final String stamp = '2026-09-${(counter++).toString().padLeft(2, '0')}';
    return TodoRow(
      id: 'id-$body',
      body: body,
      doneAt: done ? '2026-09-27T10:00:00Z' : null,
      dueDate: dueDate,
      source: 'manual',
      sourceRef: null,
      createdAt: stamp,
      updatedAt: stamp,
      deletedAt: null,
      syncDirty: true,
      syncedSeq: null,
      folderId: folderId,
    );
  }

  List<String> bodies(TodoSectionGroup s) =>
      s.todos.map((TodoRow t) => t.body).toList();

  const FolderSummary shop = FolderSummary(id: 'f-shop', name: 'Shop');
  const FolderSummary admin = FolderSummary(id: 'f-admin', name: 'admin');
  const FolderSummary work = FolderSummary(id: 'f-work', name: 'Work');

  test('rule 1: no folders means one flat, unheaded section', () {
    final sections = groupTodos(
      todos: <TodoRow>[todo('a'), todo('b')],
      folders: const <FolderSummary>[],
    );
    expect(sections.length, 1);
    expect(sections.single.title, isNull);
    expect(sections.single.folderId, isNull);
    expect(bodies(sections.single), <String>['a', 'b']);
  });

  test('rule 2: folders sort alphabetically, case-insensitively, first', () {
    final sections = groupTodos(
      todos: <TodoRow>[todo('x')],
      folders: const <FolderSummary>[work, shop, admin],
    );
    expect(
      sections.map((s) => s.title).toList(),
      <String?>['admin', 'Shop', 'Work', 'No folder'],
    );
  });

  test('rule 3: empty folders still appear', () {
    final sections = groupTodos(
      todos: <TodoRow>[todo('a', folderId: 'f-shop')],
      folders: const <FolderSummary>[shop, work],
    );
    expect(sections.length, 2);
    expect(sections[1].title, 'Work');
    expect(sections[1].isEmpty, isTrue);
  });

  test('rule 4: No folder comes last (before Done) and is omitted when '
      'empty', () {
    final withUnfiled = groupTodos(
      todos: <TodoRow>[todo('a', folderId: 'f-shop'), todo('loose')],
      folders: const <FolderSummary>[shop],
    );
    expect(withUnfiled.last.title, 'No folder');
    expect(withUnfiled.last.isUnfiled, isTrue);
    expect(bodies(withUnfiled.last), <String>['loose']);

    final allFiled = groupTodos(
      todos: <TodoRow>[todo('a', folderId: 'f-shop')],
      folders: const <FolderSummary>[shop],
    );
    expect(allFiled.map((s) => s.title), isNot(contains('No folder')));
  });

  test('rule 5: caller order is kept for equal due dates (never re-sorted '
      'beyond the due-date rule)', () {
    final sections = groupTodos(
      todos: <TodoRow>[todo('first'), todo('second'), todo('third')],
      folders: const <FolderSummary>[shop],
    );
    expect(bodies(sections.last), <String>['first', 'second', 'third']);
  });

  test('rule 6: a row whose folder vanished surfaces as unfiled, never '
      'dropped', () {
    final sections = groupTodos(
      todos: <TodoRow>[
        todo('orphan', folderId: 'f-gone'),
        todo('filed', folderId: 'f-shop'),
      ],
      folders: const <FolderSummary>[shop],
    );
    final all = sections.expand((s) => s.todos).map((t) => t.body);
    expect(all, contains('orphan'));
    expect(sections.last.title, 'No folder');
    expect(bodies(sections.last), <String>['orphan']);

    // And with NO folders at all it lands in the flat list.
    final flat = groupTodos(
      todos: <TodoRow>[todo('orphan2', folderId: 'f-gone')],
      folders: const <FolderSummary>[],
    );
    expect(bodies(flat.single), <String>['orphan2']);
  });

  test('done rows are extracted FIRST into one trailing Done section across '
      'all folders, omitted when empty', () {
    final sections = groupTodos(
      todos: <TodoRow>[
        todo('shop open', folderId: 'f-shop'),
        todo('shop done', folderId: 'f-shop', done: true),
        todo('loose done', done: true),
        todo('loose open'),
      ],
      folders: const <FolderSummary>[shop],
    );
    expect(
      sections.map((s) => s.title).toList(),
      <String?>['Shop', 'No folder', 'Done'],
    );
    expect(sections.last.isDone, isTrue);
    expect(bodies(sections.last), <String>['shop done', 'loose done']);
    expect(bodies(sections[0]), <String>['shop open']);
    expect(bodies(sections[1]), <String>['loose open']);

    // Only-done-items folder still shows (empty) and Done still trails.
    final onlyDone = groupTodos(
      todos: <TodoRow>[todo('d', folderId: 'f-shop', done: true)],
      folders: const <FolderSummary>[shop],
    );
    expect(onlyDone.map((s) => s.title).toList(), <String?>['Shop', 'Done']);
    expect(onlyDone.first.isEmpty, isTrue);

    // No done rows: no Done section, even in the flat case.
    final none = groupTodos(
      todos: <TodoRow>[todo('open')],
      folders: const <FolderSummary>[],
    );
    expect(none.map((s) => s.isDone), everyElement(isFalse));
  });

  test('within a folder: dated first ascending, undated after, then created '
      'order', () {
    final sections = groupTodos(
      todos: <TodoRow>[
        todo('undated 1', folderId: 'f-shop'),
        todo('later', folderId: 'f-shop', dueDate: '2026-10-05'),
        todo('undated 2', folderId: 'f-shop'),
        todo('soon', folderId: 'f-shop', dueDate: '2026-09-28'),
        todo('overdue', folderId: 'f-shop', dueDate: '2026-09-01'),
        todo('soon too', folderId: 'f-shop', dueDate: '2026-09-28'),
      ],
      folders: const <FolderSummary>[shop],
    );
    expect(
      bodies(sections.first),
      <String>[
        'overdue',
        'soon',
        'soon too',
        'later',
        'undated 1',
        'undated 2',
      ],
    );
  });
  test('a voice-captured todo with a due date lands in the dated order too '
      '(nothing filters by source)', () {
    final TodoRow voice = TodoRow(
      id: 'id-voice',
      body: 'go to the store',
      doneAt: null,
      dueDate: '2026-09-30',
      source: 'voice',
      sourceRef: 'dump-1',
      createdAt: '2026-09-27T14:03:00Z',
      updatedAt: '2026-09-27T14:03:00Z',
      deletedAt: null,
      syncDirty: true,
      syncedSeq: null,
      folderId: null,
    );
    final sections = groupTodos(
      todos: <TodoRow>[
        todo('undated'),
        todo('later', dueDate: '2026-10-05'),
        voice,
      ],
      folders: const <FolderSummary>[],
    );
    expect(
      bodies(sections.single),
      <String>['go to the store', 'later', 'undated'],
    );
  });
}
