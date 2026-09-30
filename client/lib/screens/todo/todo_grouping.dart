// SPDX-License-Identifier: AGPL-3.0-or-later
//
// How a filed to-do list is arranged (v1.24.0, F2: folders outermost).
//
// Same six rules as `notebook_grouping.dart`, typed for [TodoRow], plus two
// of its own: Done rows are pulled out FIRST into one trailing section
// across all folders, and rows inside a folder sort by due date (dated
// first ascending, undated after, then the caller's created order) — the
// old Overdue/Today/Upcoming headers are gone, so the order and the row's
// time chip are what convey urgency now.
import '../../data/local_db.dart';
import '../notebook/notebook_grouping.dart' show FolderSummary;

export '../notebook/notebook_grouping.dart' show FolderSummary;

/// Label for to-dos that are not in any folder (shared wording).
const String kTodoUnfiledSectionTitle = 'No folder';

/// Label for the one trailing Done section.
const String kTodoDoneSectionTitle = 'Done';

/// One block of the list: an optional header and its to-dos.
class TodoSectionGroup {
  const TodoSectionGroup({
    required this.title,
    required this.todos,
    this.folderId,
    this.isDone = false,
  });

  /// Null for the single flat section shown when no folders exist.
  final String? title;

  /// Set only for real folder sections; null for flat, unfiled and Done.
  final String? folderId;

  /// True for the trailing Done section.
  final bool isDone;
  final List<TodoRow> todos;

  bool get isEmpty => todos.isEmpty;

  /// True for the "No folder" section (headed, but not a folder).
  bool get isUnfiled => !isDone && folderId == null && title != null;
}

/// Due-date order inside a section: dated rows first, ascending by ISO
/// date (string order IS date order for `YYYY-MM-DD`), undated after, and
/// the caller's order (created ascending) breaks ties. Stable.
List<TodoRow> sortTodosByDue(List<TodoRow> rows) {
  final List<TodoRow> out = List<TodoRow>.from(rows);
  // List.sort is not guaranteed stable; sort indexed pairs instead.
  final List<int> order = List<int>.generate(out.length, (int i) => i)
    ..sort((int a, int b) {
      final String? da = out[a].dueDate;
      final String? db = out[b].dueDate;
      if (da == null && db == null) return a.compareTo(b);
      if (da == null) return 1;
      if (db == null) return -1;
      final int c = da.compareTo(db);
      return c != 0 ? c : a.compareTo(b);
    });
  final List<TodoRow> dueSorted = <TodoRow>[for (final int i in order) out[i]];
  return _pinnedFirst(dueSorted);
}

/// Stable partition used after the existing order has been established.
List<TodoRow> _pinnedFirst(Iterable<TodoRow> rows) => <TodoRow>[
      ...rows.where((TodoRow row) => row.pinned == true),
      ...rows.where((TodoRow row) => row.pinned != true),
    ];

/// Arranges [todos] into sections.
///
/// Rules, in order of how much they matter:
///
/// 0. Done rows (`done_at` set) come out FIRST into one trailing Done
///    section, whatever folder they are in. The Done section is always
///    last and omitted when empty.
/// 1. No folders at all means one unheaded section — a user who never opted
///    into folders sees exactly the flat list they had before.
/// 2. Folders sort alphabetically (case-insensitively) and come first.
/// 3. Empty folders still appear, so there is somewhere visible to file into.
/// 4. Unfiled to-dos come last (before Done), omitted when empty.
/// 5. Order inside a section: due-date order ([sortTodosByDue]) over the
///    caller's order; the caller's order is never otherwise re-sorted.
/// 6. A to-do pointing at a folder that no longer exists is shown as
///    unfiled rather than dropped: losing sight of work is worse than
///    showing it in the wrong place.
List<TodoSectionGroup> groupTodos({
  required List<TodoRow> todos,
  required List<FolderSummary> folders,
}) {
  final List<TodoRow> open = <TodoRow>[];
  final List<TodoRow> done = <TodoRow>[];
  for (final TodoRow row in todos) {
    (row.doneAt == null ? open : done).add(row);
  }

  final List<TodoSectionGroup> sections = <TodoSectionGroup>[];

  if (folders.isEmpty) {
    // Rule 1. Deliberately also covers rows whose folder was deleted: they
    // land here rather than vanishing.
    sections.add(
      TodoSectionGroup(title: null, todos: sortTodosByDue(open)),
    );
  } else {
    final Set<String> knownFolderIds =
        folders.map((FolderSummary f) => f.id).toSet();

    final List<FolderSummary> sorted = List<FolderSummary>.from(folders)
      ..sort(
        (FolderSummary a, FolderSummary b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );

    for (final FolderSummary folder in sorted) {
      sections.add(
        TodoSectionGroup(
          title: folder.name,
          folderId: folder.id,
          todos: sortTodosByDue(
            open.where((TodoRow t) => t.folderId == folder.id).toList(),
          ),
        ),
      );
    }

    final List<TodoRow> unfiled = open
        .where(
          (TodoRow t) =>
              t.folderId == null || !knownFolderIds.contains(t.folderId),
        )
        .toList();
    if (unfiled.isNotEmpty) {
      sections.add(
        TodoSectionGroup(
          title: kTodoUnfiledSectionTitle,
          todos: sortTodosByDue(unfiled),
        ),
      );
    }
  }

  if (done.isNotEmpty) {
    sections.add(
      TodoSectionGroup(
        title: kTodoDoneSectionTitle,
        isDone: true,
        todos: _pinnedFirst(done),
      ),
    );
  }
  return sections;
}
