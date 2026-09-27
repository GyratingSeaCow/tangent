// SPDX-License-Identifier: AGPL-3.0-or-later
/// Sectioning rules for the To Do screen (Phase 1 spec).
///
/// Pure functions over the rows so the screen and the tests share ONE
/// rule. Order: Overdue, Today, Upcoming, Someday, Done. Empty sections
/// are hidden by the UI; Done shows the latest 50 and starts collapsed.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../data/local_db.dart';

/// The wall clock behind sectioning. Tests swap it so boundary cases
/// (due yesterday / today / tomorrow) pin to a fixed date; production
/// never touches it. Same pattern as `summaryPendingClock`.
@visibleForTesting
DateTime Function() todoClock = DateTime.now;

/// Now, as the sectioning rule sees it.
DateTime todoNow() => todoClock();

enum TodoSection { overdue, today, upcoming, someday, done }

/// Section headers, in display order.
const Map<TodoSection, String> todoSectionTitles = <TodoSection, String>{
  TodoSection.overdue: 'Overdue',
  TodoSection.today: 'Today',
  TodoSection.upcoming: 'Upcoming',
  TodoSection.someday: 'Someday',
  TodoSection.done: 'Done',
};

/// How many done items the Done section shows.
const int doneSectionLimit = 50;

/// ISO `YYYY-MM-DD` for [day] in local time — the format `due_date`
/// stores, so string comparison IS date comparison.
String todoDateKey(DateTime day) {
  final String m = day.month.toString().padLeft(2, '0');
  final String d = day.day.toString().padLeft(2, '0');
  return '${day.year}-$m-$d';
}

/// Which section one row belongs to, judged at [now].
///
/// Done wins over everything: a checked item leaves the dated sections
/// the moment it is checked, whatever its due date says. Due dates are
/// compared as date STRINGS against today's key — `YYYY-MM-DD` collates
/// chronologically, and parsing would only add failure modes.
TodoSection sectionForTodo(TodoRow todo, {required DateTime now}) {
  if (todo.doneAt != null) return TodoSection.done;
  final String? due = todo.dueDate;
  if (due == null) return TodoSection.someday;
  final String today = todoDateKey(now);
  if (due == today) return TodoSection.today;
  return due.compareTo(today) < 0 ? TodoSection.overdue : TodoSection.upcoming;
}

/// Splits [todos] into display sections at [now].
///
/// Open sections keep the incoming (entry) order except Upcoming, which
/// sorts by due date so the soonest is first. Done sorts newest-done
/// first and keeps only the latest [doneSectionLimit].
Map<TodoSection, List<TodoRow>> sectionTodos(
  List<TodoRow> todos, {
  required DateTime now,
}) {
  final Map<TodoSection, List<TodoRow>> sections = <TodoSection, List<TodoRow>>{
    for (final TodoSection section in TodoSection.values)
      section: <TodoRow>[],
  };
  for (final TodoRow todo in todos) {
    sections[sectionForTodo(todo, now: now)]!.add(todo);
  }
  sections[TodoSection.upcoming]!
      .sort((a, b) => (a.dueDate ?? '').compareTo(b.dueDate ?? ''));
  final List<TodoRow> done = sections[TodoSection.done]!
    ..sort((a, b) => (b.doneAt ?? '').compareTo(a.doneAt ?? ''));
  if (done.length > doneSectionLimit) {
    sections[TodoSection.done] = done.sublist(0, doneSectionLimit);
  }
  return sections;
}
