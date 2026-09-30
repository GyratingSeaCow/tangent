// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../data/notebook_repository.dart' show foldersProvider;
import '../../data/todo_repository.dart';
import '../../services/todo_sections.dart';
import '../../widgets/folder_header_actions.dart';
import '../../widgets/folder_picker.dart';
import '../../widgets/item_action_sheet.dart';
import '../../services/summaries_client.dart';
import '../../widgets/sync_button.dart';
import '../home/home_providers.dart' show documentSyncEngineProvider;
import '../home/home_screen.dart' show localDbProvider;
import '../settings/ai_summaries_section.dart' show summariesClientProvider;
import 'todo_grouping.dart';

/// The To Do screen (v1.24.0, folders): quick-add pinned at top, then one
/// collapsible section per SHARED folder (alphabetical, same rows as
/// Recordings and Notebooks), `No folder` last, one `Done` section at the
/// bottom (collapsed by default). Flat list when no folders exist.
///
/// Gesture contract (`references/list-screens-and-folders.md`):
/// long-press a row = multi-select; ⋮ on the row = Move / Edit / Delete;
/// long-press a folder header = rename/delete the folder, never selection;
/// long-press the date chip = clear the due date (it is a chip, not the row).
class TodoListScreen extends ConsumerStatefulWidget {
  const TodoListScreen({super.key});

  static const Key quickAddFieldKey = Key('todo-quick-add-field');
  static const Key quickAddDateChipKey = Key('todo-quick-add-date-chip');
  static const Key doneHeaderKey = Key('todo-section-done');
  static const Key unfiledHeaderKey = Key('todo-section-unfiled');
  static Key folderHeaderKey(String folderId) => Key('todo-section-$folderId');

  static const Key selectCancelKey = Key('todo-select-cancel');
  static const Key selectAllKey = Key('todo-select-all');
  static const Key selectMoveKey = Key('todo-select-move');
  static const Key selectDoneKey = Key('todo-select-done');
  static const Key selectDeleteKey = Key('todo-select-delete');
  static const Key bulkDeleteConfirmKey = Key('todo-bulk-delete-confirm');

  @override
  ConsumerState<TodoListScreen> createState() => _TodoListScreenState();
}

class _TodoListScreenState extends ConsumerState<TodoListScreen> {
  final TextEditingController _quickAdd = TextEditingController();

  /// The ↻ follow-up (spec L4): one Google Tasks cycle right after the
  /// device push, so the to-do the user just ticked is what Google gets
  /// instead of waiting up to five minutes for the server's timer.
  ///
  /// Returns the snackbar suffix, or null when Google is not connected so
  /// the message reads exactly as on every other screen. Only a `connected`
  /// link is pushed: `reauth_required` / `error` would fail again and
  /// Settings already shows those states with the right verb.
  Future<String?> _pushToGoogle() async {
    final SummariesClient client =
        await ref.read(summariesClientProvider.future);
    final GoogleTasksStatus before = await client.getGoogleTasksStatus();
    if (before.status != GoogleTasksLinkStatus.connected) return null;
    final GoogleTasksStatus after = await client.syncGoogleTasksNow();
    final String? error = after.lastError;
    if (error != null && error.isNotEmpty) return ' · Google: $error';
    return ' · Google updated';
  }

  /// Keeps the keyboard up across submits: chained entry is the whole
  /// point of quick-add, and losing focus after every item would make the
  /// user re-tap the field between "milk", "eggs", "email Dan".
  final FocusNode _quickAddFocus = FocusNode();

  /// Due date armed for the NEXT added item, as ISO `YYYY-MM-DD`; spent
  /// (cleared) by the add so a date never leaks onto later items.
  String? _pendingDueDate;

  /// The item whose text is being edited in place, if any.
  String? _editingId;
  final TextEditingController _editController = TextEditingController();

  /// Collapsed section keys. Done starts collapsed; folders start open.
  final Set<String> _collapsed = <String>{_doneSectionKey};

  static const String _doneSectionKey = 'done';
  static const String _unfiledSectionKey = 'unfiled';

  /// Multi-select state. [_selecting] is the mode flag (the toolbar and
  /// PopScope key off it); [_selected] is the set, pruned every build so a
  /// row that vanished under a sync can never be acted on.
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  @override
  void dispose() {
    _quickAdd.dispose();
    _quickAddFocus.dispose();
    _editController.dispose();
    super.dispose();
  }

  Future<void> _submitQuickAdd(String raw) async {
    final String text = raw.trim();
    // Focus is re-asserted even for a blank submit: the keyboard's done
    // key must never dismiss the field mid-session.
    _quickAddFocus.requestFocus();
    if (text.isEmpty) return;
    final String? due = _pendingDueDate;
    _quickAdd.clear();
    setState(() => _pendingDueDate = null);
    // New items land unfiled; Move files them after.
    await ref.read(todoRepositoryProvider).add(text, dueDate: due);
  }

  Future<void> _pickPendingDueDate() async {
    final DateTime now = todoNow();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (picked == null) return;
    setState(() => _pendingDueDate = todoDateKey(picked));
  }

  Future<void> _editDueDate(TodoRow todo) async {
    final DateTime now = todoNow();
    final DateTime initial = DateTime.tryParse(todo.dueDate ?? '') ??
        DateTime(now.year, now.month, now.day);
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (picked == null) return;
    await ref
        .read(todoRepositoryProvider)
        .setDueDate(todo.id, todoDateKey(picked));
  }

  Future<void> _delete(TodoRow todo) async {
    final TodoRepository repo = ref.read(todoRepositoryProvider);
    // Soft delete first, THEN offer undo: the row survives under
    // deleted_at, so Undo is a plain restore and nothing races the
    // snackbar timer. Nothing is ever hard-deleted here.
    await repo.softDelete(todo.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted "${todo.body}"'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => repo.restore(todo.id),
          ),
        ),
      );
  }

  void _startEdit(TodoRow todo) {
    _editController.text = todo.body;
    setState(() => _editingId = todo.id);
  }

  Future<void> _commitEdit() async {
    final String? id = _editingId;
    if (id == null) return;
    final String text = _editController.text.trim();
    setState(() => _editingId = null);
    if (text.isEmpty) return;
    await ref.read(todoRepositoryProvider).editText(id, text);
  }

  // ---- folders -----------------------------------------------------------

  /// Runs the shared picker and resolves the destination, creating the
  /// folder when the user typed a new one. Null means "nothing moves"
  /// (dismissed); an explicit "No folder" arrives as a present null id.
  Future<({String? folderId})?> _pickDestination(
    String? currentFolderId,
  ) async {
    final LocalDb db = ref.read(localDbProvider);
    final List<Folder> folders =
        ref.read(foldersProvider).valueOrNull ?? const <Folder>[];
    final FolderChoice? choice = await showFolderPicker(
      context,
      folders: folders
          .map((Folder f) => FolderOption(id: f.id, name: f.name))
          .toList(growable: false),
      currentFolderId: currentFolderId,
    );
    if (choice == null || !mounted) return null;
    String? destination = choice.folderId;
    if (choice.isNewFolder) {
      destination = await db.createFolder(name: choice.newFolderName!);
    }
    return (folderId: destination);
  }

  Future<void> _move(TodoRow todo) async {
    try {
      final ({String? folderId})? dest = await _pickDestination(todo.folderId);
      if (dest == null) return;
      await ref
          .read(todoRepositoryProvider)
          .moveToFolder(todo.id, dest.folderId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not move to-do: $error')),
      );
    }
  }

  Future<void> _showRowMenu(TodoRow todo) async {
    final ItemAction? action = await showItemActionSheet(
      context,
      title: todo.body,
      actions: <ItemAction>[
        ItemAction.move,
        ItemAction.rename,
        todo.pinned == true ? ItemAction.unpin : ItemAction.pin,
        ItemAction.delete,
      ],
      labelOverrides: const <ItemAction, String>{ItemAction.rename: 'Edit'},
    );
    if (action == null || !mounted) return;
    switch (action) {
      case ItemAction.move:
        await _move(todo);
      case ItemAction.rename:
        _startEdit(todo);
      case ItemAction.pin:
        await ref.read(todoRepositoryProvider).setPinned(todo.id, true);
      case ItemAction.unpin:
        await ref.read(todoRepositoryProvider).setPinned(todo.id, false);
      case ItemAction.delete:
        await _delete(todo);
      case ItemAction.open:
      case ItemAction.duplicate:
      case ItemAction.share:
      case ItemAction.exportPdf:
      case ItemAction.exportMarkdown:
      case ItemAction.sendToNotebook:
      case ItemAction.download:
      case ItemAction.regenerateSummary:
      case ItemAction.nameSpeakers:
      case ItemAction.select:
        break;
    }
  }

  Future<void> _folderHeaderActions(TodoSectionGroup section) async {
    final String? folderId = section.folderId;
    if (folderId == null) return;
    await showFolderHeaderActions(
      context,
      folderId: folderId,
      name: section.title ?? '',
      db: ref.read(localDbProvider),
    );
  }

  // ---- multi-select --------------------------------------------------------

  void _enterSelection(String id) {
    setState(() {
      _selecting = true;
      _selected.add(id);
      _editingId = null;
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
      // Deselecting the last row leaves selection mode, as on Android.
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _cancelSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _selectAll(Iterable<String> ids) {
    setState(() => _selected.addAll(ids));
  }

  Future<void> _moveSelected() async {
    final List<String> ids = _selected.toList(growable: false);
    if (ids.isEmpty) return;
    try {
      final ({String? folderId})? dest = await _pickDestination(null);
      if (dest == null || !mounted) return;
      await ref
          .read(todoRepositoryProvider)
          .moveManyToFolder(ids, dest.folderId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not move to-dos: $error')),
      );
      return;
    }
    if (mounted) _cancelSelection();
  }

  Future<void> _markSelectedDone() async {
    final List<String> ids = _selected.toList(growable: false);
    if (ids.isEmpty) return;
    await ref.read(todoRepositoryProvider).markManyDone(ids);
    if (mounted) _cancelSelection();
  }

  Future<void> _deleteSelected() async {
    final List<String> ids = _selected.toList(growable: false);
    if (ids.isEmpty) return;
    // ONE confirmation for the set, then ONE soft delete and ONE undo that
    // restores the whole set. Nothing is hard-deleted.
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(
          ids.length == 1 ? 'Delete 1 to-do?' : 'Delete ${ids.length} to-dos?',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: TodoListScreen.bulkDeleteConfirmKey,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              'Delete',
              style: TextStyle(
                color: Theme.of(dialogContext).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final TodoRepository repo = ref.read(todoRepositoryProvider);
    await repo.softDeleteMany(ids);
    if (!mounted) return;
    _cancelSelection();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ids.length == 1
                ? 'Deleted 1 to-do'
                : 'Deleted ${ids.length} to-dos',
          ),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => repo.restoreMany(ids),
          ),
        ),
      );
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<TodoRow>> todos = ref.watch(todosProvider);
    final List<Folder> folders =
        ref.watch(foldersProvider).valueOrNull ?? const <Folder>[];
    final List<TodoRow> rows = todos.valueOrNull ?? const <TodoRow>[];

    // Prune the selection against what is live NOW, so a row deleted or
    // synced away under us can never be bulk-acted on.
    _selected.retainAll(rows.map((TodoRow t) => t.id).toSet());
    if (_selecting && _selected.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selecting && _selected.isEmpty) _cancelSelection();
      });
    }

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop && _selecting) _cancelSelection();
      },
      child: Scaffold(
        appBar: _selecting
            ? _buildSelectionBar(context, rows)
            : AppBar(
                title: const Text('To Do'),
                // Same shared button as Recordings and Notebooks: to-dos
                // ride the document sync, and a list that can only be
                // synced from ANOTHER screen hides its own staleness.
                actions: <Widget>[
                  SyncButton(
                    engineProvider: documentSyncEngineProvider,
                    afterSync: _pushToGoogle,
                  ),
                ],
              ),
        body: Column(
          children: [
            _buildQuickAdd(context),
            const Divider(height: 1),
            Expanded(
              child: todos.when(
                data: (List<TodoRow> data) =>
                    _buildSections(context, data, folders),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (Object e, _) =>
                    Center(child: Text('Could not load: $e')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildSelectionBar(
    BuildContext context,
    List<TodoRow> rows,
  ) {
    final int count = _selected.length;
    return AppBar(
      leading: IconButton(
        key: TodoListScreen.selectCancelKey,
        icon: const Icon(Icons.close),
        tooltip: 'Cancel selection',
        onPressed: _cancelSelection,
      ),
      title: Text('$count selected'),
      actions: <Widget>[
        IconButton(
          key: TodoListScreen.selectAllKey,
          icon: const Icon(Icons.select_all),
          tooltip: 'Select all',
          onPressed: () => _selectAll(rows.map((TodoRow t) => t.id)),
        ),
        IconButton(
          key: TodoListScreen.selectMoveKey,
          icon: const Icon(Icons.drive_file_move_outline),
          tooltip: 'Move to folder',
          onPressed: count == 0 ? null : _moveSelected,
        ),
        IconButton(
          key: TodoListScreen.selectDoneKey,
          icon: const Icon(Icons.check_circle_outline),
          tooltip: 'Mark done',
          onPressed: count == 0 ? null : _markSelectedDone,
        ),
        IconButton(
          key: TodoListScreen.selectDeleteKey,
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
          onPressed: count == 0 ? null : _deleteSelected,
        ),
      ],
    );
  }

  Widget _buildQuickAdd(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: TodoListScreen.quickAddFieldKey,
              controller: _quickAdd,
              focusNode: _quickAddFocus,
              decoration: const InputDecoration(
                hintText: 'Add a to-do…',
                border: InputBorder.none,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: _submitQuickAdd,
            ),
          ),
          InputChip(
            key: TodoListScreen.quickAddDateChipKey,
            avatar: const Icon(Icons.calendar_today, size: 18),
            label: Text(_pendingDueDate ?? 'Due'),
            onPressed: _pickPendingDueDate,
            onDeleted: _pendingDueDate == null
                ? null
                : () => setState(() => _pendingDueDate = null),
          ),
        ],
      ),
    );
  }

  String _sectionKeyOf(TodoSectionGroup section) {
    if (section.isDone) return _doneSectionKey;
    return section.folderId ?? _unfiledSectionKey;
  }

  Widget _buildSections(
    BuildContext context,
    List<TodoRow> rows,
    List<Folder> folders,
  ) {
    final List<TodoSectionGroup> sections = groupTodos(
      todos: rows,
      folders: folders
          .map((Folder f) => FolderSummary(id: f.id, name: f.name))
          .toList(growable: false),
    );
    if (rows.isEmpty && folders.isEmpty) {
      return const Center(child: Text('Nothing to do. Add one above.'));
    }
    final DateTime now = todoNow();
    final List<Widget> children = <Widget>[];
    for (final TodoSectionGroup section in sections) {
      if (section.title == null) {
        // Rule 1: flat, no header.
        children.addAll(section.todos.map((t) => _buildRow(context, t, now)));
        continue;
      }
      final String key = _sectionKeyOf(section);
      final bool collapsed = _collapsed.contains(key);
      children.add(
        ListTile(
          key: section.isDone
              ? TodoListScreen.doneHeaderKey
              : section.folderId == null
                  ? TodoListScreen.unfiledHeaderKey
                  : TodoListScreen.folderHeaderKey(section.folderId!),
          leading: Icon(
            section.isDone
                ? Icons.check_circle_outline
                : section.folderId == null
                    ? Icons.folder_off_outlined
                    : Icons.folder_outlined,
          ),
          title: Text(
            '${section.title} (${section.todos.length})',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          trailing: Icon(collapsed ? Icons.expand_more : Icons.expand_less),
          onTap: () => setState(() {
            if (!_collapsed.remove(key)) _collapsed.add(key);
          }),
          // Folder headers long-press into the shared rename/delete sheet —
          // NEVER selection. `No folder` and `Done` have no actions.
          onLongPress: section.folderId == null
              ? null
              : () => _folderHeaderActions(section),
        ),
      );
      if (!collapsed) {
        children.addAll(section.todos.map((t) => _buildRow(context, t, now)));
      }
    }
    return ListView(children: children);
  }

  /// The time chip's label and tint: Overdue (red) / Today / the date.
  ({String label, bool overdue})? _chipFor(TodoRow todo, DateTime now) {
    final String? due = todo.dueDate;
    if (due == null) return null;
    final String today = todoDateKey(now);
    if (due.compareTo(today) < 0) {
      return (label: 'Overdue · $due', overdue: true);
    }
    if (due == today) return (label: 'Today', overdue: false);
    return (label: due, overdue: false);
  }

  Widget _buildRow(BuildContext context, TodoRow todo, DateTime now) {
    final bool done = todo.doneAt != null;
    final bool selected = _selected.contains(todo.id);
    final TodoRepository repo = ref.read(todoRepositoryProvider);
    final ({String label, bool overdue})? chip = _chipFor(todo, now);
    final Widget body = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (todo.pinned == true) ...<Widget>[
          Icon(
            Icons.push_pin,
            key: Key('todo-pin-${todo.id}'),
            size: 14,
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            todo.body,
            style: done
                ? const TextStyle(decoration: TextDecoration.lineThrough)
                : null,
          ),
        ),
      ],
    );
    // v1.25.0: a to-do the server pulled from Google Tasks wears a tiny "G"
    // so its origin is visible; 'manual' and 'voice' rows are unchanged.
    final Widget text = todo.source == 'google'
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(child: body),
              const SizedBox(width: 6),
              _GoogleChip(key: Key('todo-google-chip-${todo.id}')),
            ],
          )
        : body;
    return ListTile(
      key: Key('todo-row-${todo.id}'),
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
      onTap: _selecting ? () => _toggleSelected(todo.id) : null,
      onLongPress: _selecting ? null : () => _enterSelection(todo.id),
      leading: _selecting
          ? Checkbox(
              key: Key('todo-select-${todo.id}'),
              value: selected,
              onChanged: (_) => _toggleSelected(todo.id),
            )
          : Checkbox(
              key: Key('todo-check-${todo.id}'),
              value: done,
              onChanged: (_) => repo.toggle(todo.id),
            ),
      title: _editingId == todo.id && !_selecting
          ? TextField(
              key: Key('todo-edit-${todo.id}'),
              controller: _editController,
              autofocus: true,
              onSubmitted: (_) => _commitEdit(),
              onTapOutside: (_) => _commitEdit(),
            )
          : _selecting
              ? text
              : GestureDetector(onTap: () => _startEdit(todo), child: text),
      subtitle: chip == null || _selecting
          ? (chip == null ? null : Text(chip.label))
          : GestureDetector(
              key: Key('todo-chip-${todo.id}'),
              onTap: () => _editDueDate(todo),
              // Long-press clears the date; the row drops to undated.
              onLongPress: () => repo.setDueDate(todo.id, null),
              child: Text(
                chip.label,
                style: TextStyle(
                  color: chip.overdue && !done
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
            ),
      // ⋮ hides while selecting: the toolbar is the only verb source then.
      trailing: _selecting
          ? null
          : IconButton(
              key: Key('todo-menu-${todo.id}'),
              icon: const Icon(Icons.more_vert),
              tooltip: 'More',
              onPressed: () => _showRowMenu(todo),
            ),
    );
  }
}

/// The "G" origin chip on Google-sourced to-do rows.
class _GoogleChip extends StatelessWidget {
  const _GoogleChip({super.key});

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.outline;
    return Tooltip(
      message: 'From Google Tasks',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'G',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
    );
  }
}
