// SPDX-License-Identifier: AGPL-3.0-or-later
/// The morning digest as plain data (spec 2026-09-27, Half B, N2).
///
/// Pure and unit-tested: everything that decides WHAT the reminder says
/// lives here, because none of it is reachable once entangled with the
/// notification plugin. The platform layer only posts what this returns —
/// and posts NOTHING when it returns null.
library;

import '../data/local_db.dart';

/// One day's reminder text.
class DueDigest {
  const DueDigest({
    required this.title,
    required this.body,
    required this.dueTodayCount,
    required this.overdueCount,
  });

  final String title;
  final String body;
  final int dueTodayCount;
  final int overdueCount;

  @override
  String toString() => 'DueDigest($title: $body)';
}

/// How many item names are spelled out before "and N more".
const int kDigestNamedItems = 3;

/// ISO `YYYY-MM-DD` for [day] in its own calendar (no time-zone shifting:
/// the caller passes a local date).
String isoDate(DateTime day) {
  final String m = day.month.toString().padLeft(2, '0');
  final String d = day.day.toString().padLeft(2, '0');
  return '${day.year}-$m-$d';
}

/// Builds the digest for [today], or null when nothing is due today AND
/// nothing is overdue — the caller must then post no notification at all.
///
/// Only LIVE rows count: done (`doneAt` set) and soft-deleted (`deletedAt`
/// set) items are excluded, as are undated ones. Overdue means
/// `due_date < today`. Names are sorted by text, case-insensitively.
DueDigest? buildDueDigest(List<TodoRow> todos, DateTime today) {
  final String todayIso = isoDate(today);
  final List<TodoRow> dueToday = <TodoRow>[];
  final List<TodoRow> overdue = <TodoRow>[];
  for (final TodoRow t in todos) {
    if (t.doneAt != null || t.deletedAt != null) continue;
    final String? due = t.dueDate;
    if (due == null) continue;
    // ISO dates compare correctly as strings.
    if (due == todayIso) {
      dueToday.add(t);
    } else if (due.compareTo(todayIso) < 0) {
      overdue.add(t);
    }
  }
  if (dueToday.isEmpty && overdue.isEmpty) return null;

  if (dueToday.isEmpty) {
    return DueDigest(
      title: 'Overdue',
      body: '${overdue.length} overdue: ${_names(overdue)}',
      dueTodayCount: 0,
      overdueCount: overdue.length,
    );
  }
  final String suffix =
      overdue.isEmpty ? '' : ' \u00B7 ${overdue.length} overdue';
  return DueDigest(
    title: 'Due today',
    body: '${_names(dueToday)}$suffix',
    dueTodayCount: dueToday.length,
    overdueCount: overdue.length,
  );
}

String _names(List<TodoRow> rows) {
  final List<String> names = rows.map((TodoRow t) => t.body.trim()).toList()
    ..sort((String a, String b) {
      final int byFold = a.toLowerCase().compareTo(b.toLowerCase());
      return byFold != 0 ? byFold : a.compareTo(b);
    });
  if (names.length <= kDigestNamedItems) return names.join(', ');
  final int more = names.length - kDigestNamedItems;
  return '${names.take(kDigestNamedItems).join(', ')} and $more more';
}
