// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:tangent/data/local_db.dart';
import 'package:tangent/services/due_digest.dart';

/// Spec 2026-09-27 Half B: the digest rule as plain data.
void main() {
  int counter = 0;
  TodoRow todo(
    String body, {
    String? due,
    bool done = false,
    bool deleted = false,
  }) {
    final String stamp = '2026-09-${(counter++ % 28 + 1).toString().padLeft(2, '0')}';
    return TodoRow(
      id: 'id-$body',
      body: body,
      doneAt: done ? '2026-09-27T10:00:00Z' : null,
      dueDate: due,
      source: 'manual',
      sourceRef: null,
      createdAt: stamp,
      updatedAt: stamp,
      deletedAt: deleted ? '2026-09-27T11:00:00Z' : null,
      syncDirty: true,
      syncedSeq: null,
      folderId: null,
      boardOrder: 0,
    );
  }

  final DateTime today = DateTime(2026, 9, 27, 7);

  test('empty list → null (no notification)', () {
    expect(buildDueDigest(<TodoRow>[], today), isNull);
  });

  test('nothing due today and nothing overdue → null', () {
    expect(
      buildDueDigest(
        <TodoRow>[todo('later', due: '2026-09-28'), todo('someday')],
        today,
      ),
      isNull,
    );
  });

  test('two due today → both names, comma-joined, no suffix', () {
    final DueDigest? d = buildDueDigest(
      <TodoRow>[
        todo('pay the water bill', due: '2026-09-27'),
        todo('call the dentist', due: '2026-09-27'),
      ],
      today,
    );
    expect(d, isNotNull);
    expect(d!.title, 'Due today');
    expect(d.body, 'call the dentist, pay the water bill');
    expect(d.dueTodayCount, 2);
    expect(d.overdueCount, 0);
  });

  test('five due today → 3 names + "and 2 more"', () {
    final DueDigest? d = buildDueDigest(
      <TodoRow>[
        for (final String n in <String>['e', 'd', 'c', 'b', 'a'])
          todo(n, due: '2026-09-27'),
      ],
      today,
    );
    expect(d!.body, 'a, b, c and 2 more');
    expect(d.dueTodayCount, 5);
  });

  test('overdue suffix: " · N overdue" when live items are past due', () {
    final DueDigest? d = buildDueDigest(
      <TodoRow>[
        todo('call the dentist', due: '2026-09-27'),
        todo('renew passport', due: '2026-09-01'),
      ],
      today,
    );
    expect(d!.body, 'call the dentist \u00B7 1 overdue');
    expect(d.overdueCount, 1);
  });

  test('overdue only → title Overdue, body "N overdue: …"', () {
    final DueDigest? d = buildDueDigest(
      <TodoRow>[
        todo('renew passport', due: '2026-09-01'),
        todo('book car service', due: '2026-09-26'),
      ],
      today,
    );
    expect(d!.title, 'Overdue');
    expect(d.body, '2 overdue: book car service, renew passport');
    expect(d.dueTodayCount, 0);
    expect(d.overdueCount, 2);
  });

  test('done and soft-deleted rows are excluded', () {
    expect(
      buildDueDigest(
        <TodoRow>[
          todo('finished', due: '2026-09-27', done: true),
          todo('binned', due: '2026-09-27', deleted: true),
          todo('old and done', due: '2026-09-01', done: true),
        ],
        today,
      ),
      isNull,
    );
    final DueDigest? d = buildDueDigest(
      <TodoRow>[
        todo('finished', due: '2026-09-27', done: true),
        todo('live', due: '2026-09-27'),
      ],
      today,
    );
    expect(d!.body, 'live');
    expect(d.dueTodayCount, 1);
  });

  test('names are sorted by text, case-insensitively', () {
    final DueDigest? d = buildDueDigest(
      <TodoRow>[
        todo('zebra', due: '2026-09-27'),
        todo('Apple', due: '2026-09-27'),
        todo('mango', due: '2026-09-27'),
      ],
      today,
    );
    expect(d!.body, 'Apple, mango, zebra');
  });

  test('isoDate pads month and day', () {
    expect(isoDate(DateTime(2026, 1, 5)), '2026-01-05');
  });
}
