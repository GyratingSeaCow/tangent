// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/services/todo_sections.dart';

/// Sectioning boundaries around a FIXED clock (spec: overdue/today/
/// upcoming/someday/done). The clock is injected per call; nothing here
/// touches the swappable global, so these stay order-independent.
void main() {
  // Saturday 2026-09-26, mid-afternoon local. Chosen mid-month so ±1 day
  // never crosses a month boundary by accident.
  final DateTime now = DateTime(2026, 9, 26, 15, 30);

  TodoRow row({
    String id = 't',
    String? dueDate,
    String? doneAt,
  }) =>
      TodoRow(
        id: id,
        body: 'x',
        doneAt: doneAt,
        dueDate: dueDate,
        source: 'manual',
        sourceRef: null,
        createdAt: '2026-09-20T00:00:00Z',
        updatedAt: '2026-09-20T00:00:00Z',
        deletedAt: null,
        syncDirty: false,
        syncedSeq: null,
      );

  test('due yesterday is overdue', () {
    expect(
      sectionForTodo(row(dueDate: '2026-09-25'), now: now),
      TodoSection.overdue,
    );
  });

  test('due today is today, whatever the hour', () {
    expect(
      sectionForTodo(row(dueDate: '2026-09-26'), now: now),
      TodoSection.today,
    );
    // The boundary holds at the edges of the day too.
    expect(
      sectionForTodo(
        row(dueDate: '2026-09-26'),
        now: DateTime(2026, 9, 26, 0, 0, 1),
      ),
      TodoSection.today,
    );
    expect(
      sectionForTodo(
        row(dueDate: '2026-09-26'),
        now: DateTime(2026, 9, 26, 23, 59, 59),
      ),
      TodoSection.today,
    );
  });

  test('due tomorrow is upcoming', () {
    expect(
      sectionForTodo(row(dueDate: '2026-09-27'), now: now),
      TodoSection.upcoming,
    );
  });

  test('no due date is someday', () {
    expect(sectionForTodo(row(), now: now), TodoSection.someday);
  });

  test('done wins over every due date, even an overdue one', () {
    expect(
      sectionForTodo(
        row(dueDate: '2026-09-01', doneAt: '2026-09-26T10:00:00Z'),
        now: now,
      ),
      TodoSection.done,
    );
    expect(
      sectionForTodo(row(doneAt: '2026-09-26T10:00:00Z'), now: now),
      TodoSection.done,
    );
  });

  test('sectionTodos sorts upcoming by due date and caps done at 50, '
      'newest first', () {
    final List<TodoRow> todos = <TodoRow>[
      row(id: 'u2', dueDate: '2026-10-05'),
      row(id: 'u1', dueDate: '2026-09-28'),
      for (int i = 0; i < 60; i++)
        row(
          id: 'd$i',
          doneAt: '2026-09-${(i % 20 + 1).toString().padLeft(2, '0')}'
              'T00:00:${(i ~/ 20).toString().padLeft(2, '0')}Z',
        ),
    ];

    final Map<TodoSection, List<TodoRow>> sections =
        sectionTodos(todos, now: now);

    expect(
      sections[TodoSection.upcoming]!.map((t) => t.id).toList(),
      <String>['u1', 'u2'],
    );
    final List<TodoRow> done = sections[TodoSection.done]!;
    expect(done, hasLength(doneSectionLimit));
    for (int i = 1; i < done.length; i++) {
      expect(
        done[i - 1].doneAt!.compareTo(done[i].doneAt!) >= 0,
        isTrue,
        reason: 'done sorts newest-first',
      );
    }
  });

  test('todoDateKey pads to the wire format', () {
    expect(todoDateKey(DateTime(2026, 1, 5)), '2026-01-05');
    expect(todoDateKey(DateTime(2026, 11, 15)), '2026-11-15');
  });
}
