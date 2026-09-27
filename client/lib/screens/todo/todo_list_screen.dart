// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../data/todo_repository.dart';
import '../../services/todo_sections.dart';

/// The To Do screen (Phase 1): quick-add pinned at top, then the sections
/// Overdue / Today / Upcoming / Someday / Done, empty ones hidden, Done
/// collapsed by default.
class TodoListScreen extends ConsumerStatefulWidget {
  const TodoListScreen({super.key});

  static const Key quickAddFieldKey = Key('todo-quick-add-field');
  static const Key quickAddDateChipKey = Key('todo-quick-add-date-chip');
  static const Key doneHeaderKey = Key('todo-done-header');

  @override
  ConsumerState<TodoListScreen> createState() => _TodoListScreenState();
}

class _TodoListScreenState extends ConsumerState<TodoListScreen> {
  final TextEditingController _quickAdd = TextEditingController();

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

  bool _doneExpanded = false;

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
    final DateTime initial =
        DateTime.tryParse(todo.dueDate ?? '') ?? DateTime(now.year, now.month, now.day);
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

  Future<void> _commitEdit() async {
    final String? id = _editingId;
    if (id == null) return;
    final String text = _editController.text.trim();
    setState(() => _editingId = null);
    if (text.isEmpty) return;
    await ref.read(todoRepositoryProvider).editText(id, text);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<TodoRow>> todos = ref.watch(todosProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('To Do')),
      body: Column(
        children: [
          _buildQuickAdd(context),
          const Divider(height: 1),
          Expanded(
            child: todos.when(
              data: (rows) => _buildSections(context, rows),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Could not load: $e')),
            ),
          ),
        ],
      ),
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

  Widget _buildSections(BuildContext context, List<TodoRow> rows) {
    final Map<TodoSection, List<TodoRow>> sections =
        sectionTodos(rows, now: todoNow());
    final List<Widget> children = <Widget>[];
    for (final TodoSection section in TodoSection.values) {
      final List<TodoRow> items = sections[section]!;
      if (items.isEmpty) continue;
      if (section == TodoSection.done) {
        children.add(
          ListTile(
            key: TodoListScreen.doneHeaderKey,
            title: Text('Done (${items.length})'),
            trailing: Icon(
              _doneExpanded ? Icons.expand_less : Icons.expand_more,
            ),
            onTap: () => setState(() => _doneExpanded = !_doneExpanded),
          ),
        );
        if (_doneExpanded) {
          children.addAll(
            items.map((t) => _buildRow(context, t, section)),
          );
        }
        continue;
      }
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            '${todoSectionTitles[section]} (${items.length})',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      );
      children.addAll(items.map((t) => _buildRow(context, t, section)));
    }
    if (children.isEmpty) {
      return const Center(child: Text('Nothing to do. Add one above.'));
    }
    return ListView(children: children);
  }

  Widget _buildRow(BuildContext context, TodoRow todo, TodoSection section) {
    final bool done = todo.doneAt != null;
    final TodoRepository repo = ref.read(todoRepositoryProvider);
    return ListTile(
      key: Key('todo-row-${todo.id}'),
      leading: Checkbox(
        key: Key('todo-check-${todo.id}'),
        value: done,
        onChanged: (_) => repo.toggle(todo.id),
      ),
      title: _editingId == todo.id
          ? TextField(
              key: Key('todo-edit-${todo.id}'),
              controller: _editController,
              autofocus: true,
              onSubmitted: (_) => _commitEdit(),
              onTapOutside: (_) => _commitEdit(),
            )
          : GestureDetector(
              onTap: () {
                _editController.text = todo.body;
                setState(() => _editingId = todo.id);
              },
              child: Text(
                todo.body,
                style: done
                    ? const TextStyle(
                        decoration: TextDecoration.lineThrough,
                      )
                    : null,
              ),
            ),
      subtitle: todo.dueDate == null
          ? null
          : GestureDetector(
              key: Key('todo-date-${todo.id}'),
              onTap: () => _editDueDate(todo),
              // Long-press clears the date; the row drops to Someday.
              onLongPress: () => repo.setDueDate(todo.id, null),
              child: Text(
                todo.dueDate!,
                style: TextStyle(
                  color: section == TodoSection.overdue
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
            ),
      trailing: PopupMenuButton<String>(
        key: Key('todo-menu-${todo.id}'),
        onSelected: (value) {
          if (value == 'delete') _delete(todo);
        },
        itemBuilder: (_) => const [
          PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
