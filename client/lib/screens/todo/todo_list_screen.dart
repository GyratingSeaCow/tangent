// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/local_db.dart';
import '../../data/notebook_repository.dart' show foldersProvider;
import '../../data/todo_repository.dart';
import '../../services/todo_sections.dart';
import '../../services/todo_due_notification_scheduler.dart';
import '../../widgets/folder_header_actions.dart';
import '../../widgets/folder_picker.dart';
import '../../widgets/item_action_sheet.dart';
import '../../services/summaries_client.dart';
import '../../widgets/sync_button.dart';
import '../home/home_providers.dart' show documentSyncEngineProvider;
import '../home/home_screen.dart' show localDbProvider;
import '../settings/ai_summaries_section.dart' show summariesClientProvider;
import '../../widgets/instrument_scaffold.dart';
import '../../widgets/top_nav_rail.dart';
import 'todo_grouping.dart';

const double _boardDragDeadZone = 8;

/// A held card becomes a drag only after leaving this lane-safe dead zone.
/// Releasing inside it resolves the same gesture as a board context-menu hold.
bool boardDragExceededDeadZone(Offset origin, Offset current) =>
    (current - origin).distance > _boardDragDeadZone;

/// The To Do screen (v1.24.0, folders): quick-add pinned at top, then one
/// collapsible section per SHARED folder (alphabetical, same rows as
/// Recordings and Notebooks), `No folder` last, one `Done` section at the
/// bottom (collapsed by default). Flat list when no folders exist.
///
/// Gesture contract (`references/list-screens-and-folders.md`):
/// long-press a row = multi-select; ⋮ on the row = Move / Edit / Delete;
/// long-press a folder header = rename/delete the folder, never selection;
/// long-press the date chip = clear the due date (it is a chip, not the row).
/// In board mode, a stationary hold opens board actions while a hold followed
/// by movement drags; column ⋮ menus enter column-scoped multi-select.
class TodoListScreen extends ConsumerStatefulWidget {
  const TodoListScreen({super.key, this.autofocusQuickAdd = false});

  /// When true the quick-add field takes focus on mount — the global
  /// create sheet's "To-do" entry lands ready to type.
  final bool autofocusQuickAdd;

  static const Key quickAddFieldKey = Key('todo-quick-add-field');
  static const Key quickAddDateChipKey = Key('todo-quick-add-date-chip');
  static const Key dueTimePickerKey = Key('todo-due-time-picker');
  static const Key doneHeaderKey = Key('todo-section-done');
  static const Key unfiledHeaderKey = Key('todo-section-unfiled');
  static Key folderHeaderKey(String folderId) => Key('todo-section-$folderId');

  static const Key selectCancelKey = Key('todo-select-cancel');
  static const Key selectAllKey = Key('todo-select-all');
  static const Key selectMoveKey = Key('todo-select-move');
  static const Key selectDoneKey = Key('todo-select-done');
  static const Key selectDeleteKey = Key('todo-select-delete');
  static const Key bulkDeleteConfirmKey = Key('todo-bulk-delete-confirm');
  static const Key viewToggleKey = Key('todo-view-toggle');
  static const Key addColumnKey = Key('todo-add-column');
  static const Key columnNameFieldKey = Key('todo-column-name-field');
  static const Key columnSaveKey = Key('todo-column-save');
  static const Key columnDeleteConfirmKey = Key('todo-column-delete-confirm');
  static Key columnKey(String id) => Key('todo-column-$id');
  static Key columnMenuKey(String id) => Key('todo-column-menu-$id');
  static Key cardKey(String id) => Key('todo-board-card-$id');
  static Key laneScrollKey(String columnId) =>
      Key('todo-lane-scroll-$columnId');
  static Key laneAppendDropKey(String columnId) =>
      Key('todo-lane-append-drop-$columnId');
  static Key cardDropKey(String columnId, String todoId) =>
      Key('todo-card-drop-$columnId-$todoId');
  static Key emptyLaneDropKey(String columnId) =>
      Key('todo-empty-drop-$columnId');
  static Key dropKey(String columnId, int index) =>
      Key('todo-drop-$columnId-$index');
  static Key boardColumnChoiceKey(String columnId) =>
      Key('todo-board-column-choice-$columnId');
  static const Key boardFolderMoveKey = Key('todo-board-folder-move');
  static const Key boardDeleteKey = Key('todo-board-delete');
  static const Key boardMenuHeaderKey = Key('todo-board-menu-header');

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
    final SummariesClient client = await ref.read(
      summariesClientProvider.future,
    );
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
  String? _pendingDueTime;

  /// The item whose text is being edited in place, if any.
  String? _editingId;
  final TextEditingController _editController = TextEditingController();

  /// Collapsed section keys. Done starts collapsed; folders start open.
  final Set<String> _collapsed = <String>{_doneSectionKey};

  static const String _doneSectionKey = 'done';
  static const String _unfiledSectionKey = 'unfiled';
  static const String _boardPreferenceKey = 'todo_board_view';
  bool _board = false;

  // DragTarget callbacks do not await repository futures. Chain them so drop
  // indices persist in callback order, and report a failed write without
  // jamming later drops. Drift already serializes its transactions; this is
  // UI ordering and error surfacing, not a database-race fix.
  Future<void> _boardMoveTail = Future<void>.value();

  Future<void> _queueBoardOperation(
    Future<void> Function(TodoRepository repo) operation,
    String description,
  ) {
    final TodoRepository repo = ref.read(todoRepositoryProvider);
    final Future<void> move = _boardMoveTail.then((_) => operation(repo));
    _boardMoveTail = move.catchError((Object error, StackTrace stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'todo board',
          context: ErrorDescription(description),
        ),
      );
    });
    return _boardMoveTail;
  }

  void _queueBoardMove(String todoId, String columnId, int index) {
    _queueBoardOperation(
      (TodoRepository repo) => repo.moveOnBoard(todoId, columnId, index),
      'while persisting a queued card move',
    );
  }

  void _acceptBoardDrop(TodoRow todo, String columnId, int index) {
    if (_boardDraggingId != todo.id || !_boardDragMoved) return;
    _queueBoardMove(todo.id, columnId, index);
  }

  void _boardPointerStarted(PointerDownEvent event) {
    // Listener wraps every card. A resting second finger must not replace the
    // pointer and drag gate belonging to the card already in flight.
    if (_boardDraggingId != null) return;
    _boardPointerId = event.pointer;
    _boardPointerDown = event.position;
    _boardPointerCurrent = event.position;
    _boardDraggingId = null;
    _boardDragMoved = false;
    _boardDragCanceled = false;
  }

  void _boardPointerMoved(PointerMoveEvent event) {
    if (_boardPointerId != event.pointer || _boardPointerDown == null) return;
    _boardPointerCurrent = event.position;
    if (boardDragExceededDeadZone(_boardPointerDown!, event.position)) {
      _boardDragMoved = true;
    }
  }

  void _clearBoardPointer() {
    _boardPointerId = null;
    _boardPointerDown = null;
    _boardPointerCurrent = null;
    _boardDraggingId = null;
    _boardDragMoved = false;
    _boardDragCanceled = false;
  }

  /// Multi-select state. [_selecting] is the mode flag (the toolbar and
  /// PopScope key off it); [_selected] is the set, pruned every build so a
  /// row that vanished under a sync can never be acted on.
  bool _selecting = false;
  final Set<String> _selected = <String>{};
  String? _boardSelectionColumnId;

  int? _boardPointerId;
  Offset? _boardPointerDown;
  Offset? _boardPointerCurrent;
  String? _boardDraggingId;
  bool _boardDragMoved = false;
  bool _boardDragCanceled = false;

  @override
  void initState() {
    super.initState();
    _loadViewPreference();
    if (widget.autofocusQuickAdd) {
      // Post-frame: the field must be mounted before it can take focus.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _quickAddFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _quickAdd.dispose();
    _quickAddFocus.dispose();
    _editController.dispose();
    super.dispose();
  }

  Future<void> _loadViewPreference() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool board = prefs.getBool(_boardPreferenceKey) ?? false;
    if (!mounted) return;
    setState(() => _board = board);
    if (board) await ref.read(todoRepositoryProvider).ensureColumns();
  }

  Future<void> _toggleView() async {
    final bool board = !_board;
    setState(() {
      _board = board;
      if (board) {
        _selecting = false;
        _selected.clear();
        _boardSelectionColumnId = null;
      }
    });
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_boardPreferenceKey, board);
    if (board) await ref.read(todoRepositoryProvider).ensureColumns();
  }

  Future<void> _submitQuickAdd(String raw) async {
    final String text = raw.trim();
    // Focus is re-asserted even for a blank submit: the keyboard's done
    // key must never dismiss the field mid-session.
    _quickAddFocus.requestFocus();
    if (text.isEmpty) return;
    final String? due = _pendingDueDate;
    final String? dueTime = _pendingDueTime;
    _quickAdd.clear();
    setState(() {
      _pendingDueDate = null;
      _pendingDueTime = null;
    });
    // New items land unfiled; Move files them after.
    await ref
        .read(todoRepositoryProvider)
        .add(text, dueDate: due, dueTime: dueTime);
  }

  Future<({String date, String time})?> _pickDueDateTime({
    String? initialDate,
    String? initialTime,
  }) async {
    final DateTime now = todoNow();
    final DateTime initial =
        DateTime.tryParse(initialDate ?? '') ??
        DateTime(now.year, now.month, now.day);
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (pickedDate == null || !mounted) return null;
    final List<String> parts = (initialTime ?? defaultTodoDueTime).split(':');
    final TimeOfDay? pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts.first) ?? 9,
        minute: int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
      ),
      builder: (BuildContext context, Widget? child) =>
          KeyedSubtree(key: TodoListScreen.dueTimePickerKey, child: child!),
    );
    if (pickedTime == null) return null;
    return (
      date: todoDateKey(pickedDate),
      time:
          '${pickedTime.hour.toString().padLeft(2, '0')}:'
          '${pickedTime.minute.toString().padLeft(2, '0')}',
    );
  }

  Future<void> _requestDuePermissionsAtPointOfUse() async {
    try {
      await ref.read(todoDuePermissionRequesterProvider)();
    } on UnimplementedError {
      // Widget/test hosts and unsupported platforms intentionally omit a port.
    }
  }

  Future<void> _pickPendingDueDate() async {
    final ({String date, String time})? picked = await _pickDueDateTime(
      initialDate: _pendingDueDate,
      initialTime: _pendingDueTime,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pendingDueDate = picked.date;
      _pendingDueTime = picked.time;
    });
    await _requestDuePermissionsAtPointOfUse();
  }

  Future<void> _editDueDate(TodoRow todo) async {
    final ({String date, String time})? picked = await _pickDueDateTime(
      initialDate: todo.dueDate,
      initialTime: todo.dueTime,
    );
    if (picked == null) return;
    await ref
        .read(todoRepositoryProvider)
        .setDueDate(todo.id, picked.date, dueTime: picked.time);
    await _requestDuePermissionsAtPointOfUse();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not move to-do: $error')));
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
      case ItemAction.passwordProtection:
      case ItemAction.lockNow:
      case ItemAction.sendToNotebook:
      case ItemAction.sendToTodo:
      case ItemAction.download:
      case ItemAction.regenerateSummary:
      case ItemAction.nameSpeakers:
      // Shared tags cover notebooks and recordings only.
      case ItemAction.editTags:
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
      _boardSelectionColumnId = null;
      _selected.add(id);
      _editingId = null;
    });
  }

  void _enterBoardSelection(String columnId) {
    setState(() {
      _selecting = true;
      _boardSelectionColumnId = columnId;
      _selected.clear();
      _editingId = null;
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
      // Deselecting the last list row leaves selection mode, as on Android.
      // Board selection stays active at zero so Select all remains available.
      if (_selected.isEmpty && _boardSelectionColumnId == null) {
        _selecting = false;
      }
    });
  }

  void _cancelSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
      _boardSelectionColumnId = null;
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not move to-dos: $error')));
      return;
    }
    if (mounted) _cancelSelection();
  }

  Future<void> _moveSelectedOnBoard(
    List<TodoRow> rows,
    List<TodoColumnRow> columns,
  ) async {
    final String? sourceId = _boardSelectionColumnId;
    if (sourceId == null || _selected.isEmpty) return;
    final List<TodoRow> selectedRows =
        rows.where((row) => _selected.contains(row.id)).toList()
          ..sort((a, b) => a.boardOrder.compareTo(b.boardOrder));
    final List<String> ids = selectedRows
        .map((row) => row.id)
        .toList(growable: false);
    final List<TodoColumnRow> destinations = columns
        .where((column) => column.id != sourceId)
        .toList(growable: false);
    final String? destination = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Move ${ids.length} card${ids.length == 1 ? '' : 's'} to'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final TodoColumnRow column in destinations)
              ListTile(
                key: TodoListScreen.boardColumnChoiceKey(column.id),
                leading: const Icon(Icons.arrow_forward),
                title: Text(column.name),
                onTap: () => Navigator.pop(dialogContext, column.id),
              ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (destination == null || !mounted) return;
    await _queueBoardOperation(
      (TodoRepository repo) => repo.moveManyOnBoard(ids, destination),
      'while persisting a queued bulk card move',
    );
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
    final AsyncValue<List<TodoColumnRow>> columns = ref.watch(
      todoColumnsProvider,
    );
    final List<Folder> folders =
        ref.watch(foldersProvider).valueOrNull ?? const <Folder>[];
    final List<TodoRow> rows = todos.valueOrNull ?? const <TodoRow>[];

    // Prune the selection against what is live NOW, so a row deleted or
    // synced away under us can never be bulk-acted on.
    _selected.retainAll(rows.map((TodoRow t) => t.id).toSet());
    final List<TodoColumnRow>? liveColumns = columns.valueOrNull;
    if (_boardSelectionColumnId != null &&
        liveColumns != null &&
        !liveColumns.any(
          (TodoColumnRow column) => column.id == _boardSelectionColumnId,
        )) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final List<TodoColumnRow>? currentColumns = ref
            .read(todoColumnsProvider)
            .valueOrNull;
        if (currentColumns != null &&
            !currentColumns.any(
              (TodoColumnRow column) => column.id == _boardSelectionColumnId,
            )) {
          _cancelSelection();
        }
      });
    }
    if (_selecting && _selected.isEmpty && _boardSelectionColumnId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _selecting &&
            _selected.isEmpty &&
            _boardSelectionColumnId == null) {
          _cancelSelection();
        }
      });
    }

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (bool didPop, _) {
        if (!didPop && _selecting) _cancelSelection();
      },
      child: InstrumentScaffold(
        root: TangentRoot.todo,
        appBar: _selecting
            ? _buildSelectionBar(
                context,
                rows,
                columns.valueOrNull ?? const <TodoColumnRow>[],
              )
            : AppBar(
                title: const Text('To Do'),
                // Same shared button as Recordings and Notebooks: to-dos
                // ride the document sync, and a list that can only be
                // synced from ANOTHER screen hides its own staleness.
                actions: <Widget>[
                  IconButton(
                    key: TodoListScreen.viewToggleKey,
                    icon: Icon(
                      _board
                          ? Icons.view_list_outlined
                          : Icons.view_kanban_outlined,
                    ),
                    tooltip: _board ? 'Show list' : 'Show board',
                    onPressed: _toggleView,
                  ),
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
                data: (List<TodoRow> data) => _board
                    ? columns.when(
                        data: (value) => _buildBoard(context, data, value),
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (Object e, _) =>
                            Center(child: Text('Could not load columns: $e')),
                      )
                    : _buildSections(context, data, folders),
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
    List<TodoColumnRow> columns,
  ) {
    final int count = _selected.length;
    final String? boardColumnId = _boardSelectionColumnId;
    final List<String> selectableIds;
    if (boardColumnId == null) {
      selectableIds = rows.map((row) => row.id).toList(growable: false);
    } else {
      final Set<String> liveIds = columns.map((column) => column.id).toSet();
      final String? fallback = columns.isEmpty ? null : columns.first.id;
      selectableIds = rows
          .where((row) {
            final String? renderedColumn = liveIds.contains(row.columnId)
                ? row.columnId
                : fallback;
            return renderedColumn == boardColumnId;
          })
          .map((row) => row.id)
          .toList(growable: false);
    }
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
          onPressed: () => _selectAll(selectableIds),
        ),
        IconButton(
          key: TodoListScreen.selectMoveKey,
          icon: const Icon(Icons.drive_file_move_outline),
          tooltip: boardColumnId == null ? 'Move to folder' : 'Move to column',
          onPressed: count == 0
              ? null
              : boardColumnId == null
              ? _moveSelected
              : () => _moveSelectedOnBoard(rows, columns),
        ),
        if (boardColumnId == null)
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
            label: Text(
              _pendingDueDate == null
                  ? 'Due'
                  : '${_pendingDueDate!} · ${_pendingDueTime ?? defaultTodoDueTime}',
            ),
            onPressed: _pickPendingDueDate,
            onDeleted: _pendingDueDate == null
                ? null
                : () => setState(() {
                    _pendingDueDate = null;
                    _pendingDueTime = null;
                  }),
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
        SectionHeaderCard(
          child: ListTile(
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
        ),
      );
      if (!collapsed) {
        children.addAll(section.todos.map((t) => _buildRow(context, t, now)));
      }
    }
    return ListView(padding: listBottomInset(context), children: children);
  }

  Widget _buildBoard(
    BuildContext context,
    List<TodoRow> rows,
    List<TodoColumnRow> columns,
  ) {
    if (columns.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(todoRepositoryProvider).ensureColumns();
      });
      return const Center(child: CircularProgressIndicator());
    }
    final Set<String> liveIds = columns.map((c) => c.id).toSet();
    final String fallback = columns.first.id;
    final Map<String, List<TodoRow>> lanes = <String, List<TodoRow>>{
      for (final TodoColumnRow column in columns) column.id: <TodoRow>[],
    };
    for (final TodoRow row in rows) {
      final String id = liveIds.contains(row.columnId)
          ? row.columnId!
          : fallback;
      lanes[id]!.add(row);
    }
    for (final List<TodoRow> lane in lanes.values) {
      lane.sort((a, b) => a.boardOrder.compareTo(b.boardOrder));
    }
    final EdgeInsets padding = EdgeInsets.fromLTRB(
      12,
      12,
      12,
      listBottomInset(context).bottom,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double laneHeight = (constraints.maxHeight - padding.vertical)
            .clamp(180.0, double.infinity);
        return SingleChildScrollView(
          key: const Key('todo-board-scroll'),
          scrollDirection: Axis.horizontal,
          padding: padding,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (int i = 0; i < columns.length; i++) ...<Widget>[
                _buildBoardColumn(
                  context,
                  columns[i],
                  lanes[columns[i].id]!,
                  i,
                  columns,
                  laneHeight,
                ),
                const SizedBox(width: 12),
              ],
              SizedBox(
                width: 240,
                child: OutlinedButton.icon(
                  key: TodoListScreen.addColumnKey,
                  onPressed: () => _editColumnName(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add column'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBoardColumn(
    BuildContext context,
    TodoColumnRow column,
    List<TodoRow> cards,
    int columnIndex,
    List<TodoColumnRow> columns,
    double height,
  ) {
    return Container(
      key: TodoListScreen.columnKey(column.id),
      width: 300,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            dense: true,
            title: Text('${column.name} (${cards.length})'),
            trailing: PopupMenuButton<String>(
              key: TodoListScreen.columnMenuKey(column.id),
              tooltip: 'Column actions',
              onSelected: (String action) async {
                switch (action) {
                  case 'select':
                    _enterBoardSelection(column.id);
                  case 'rename':
                    await _editColumnName(column: column);
                  case 'left':
                    await ref
                        .read(todoRepositoryProvider)
                        .reorderColumn(column.id, columnIndex - 1);
                  case 'right':
                    await ref
                        .read(todoRepositoryProvider)
                        .reorderColumn(column.id, columnIndex + 1);
                  case 'delete':
                    await _deleteColumn(column, columns);
                }
              },
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                const PopupMenuItem(
                  value: 'select',
                  child: Text('Select cards'),
                ),
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                if (columnIndex > 0)
                  const PopupMenuItem(value: 'left', child: Text('Move left')),
                if (columnIndex < columns.length - 1)
                  const PopupMenuItem(
                    value: 'right',
                    child: Text('Move right'),
                  ),
                if (columns.length > 1)
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: cards.isEmpty
                ? _emptyLaneDropTarget(column.id)
                : _laneAppendDropTarget(
                    column.id,
                    cards.length,
                    ListView.builder(
                      key: TodoListScreen.laneScrollKey(column.id),
                      // Leaves a natural append zone after long lanes scroll
                      // to the end; the lane target below owns this padding.
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: cards.length * 2 + 1,
                      itemBuilder: (BuildContext context, int itemIndex) {
                        if (itemIndex.isEven) {
                          return _boardDropTarget(column.id, itemIndex ~/ 2);
                        }
                        final int cardIndex = itemIndex ~/ 2;
                        return _boardCardDropTarget(
                          column.id,
                          cardIndex,
                          cards[cardIndex],
                          _buildBoardCard(
                            context,
                            cards[cardIndex],
                            column.id,
                            columns,
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _boardDropTarget(String columnId, int index) {
    return DragTarget<TodoRow>(
      key: TodoListScreen.dropKey(columnId, index),
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) =>
          _acceptBoardDrop(details.data, columnId, index),
      builder: (context, candidates, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        height: candidates.isEmpty ? 10 : 36,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? Colors.transparent
              : Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  Widget _laneAppendDropTarget(String columnId, int appendIndex, Widget child) {
    return DragTarget<TodoRow>(
      key: TodoListScreen.laneAppendDropKey(columnId),
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) =>
          _acceptBoardDrop(details.data, columnId, appendIndex),
      builder: (context, candidates, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? Colors.transparent
              : Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
    );
  }

  Widget _emptyLaneDropTarget(String columnId) {
    return DragTarget<TodoRow>(
      key: TodoListScreen.emptyLaneDropKey(columnId),
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) =>
          _acceptBoardDrop(details.data, columnId, 0),
      builder: (context, candidates, rejected) => AnimatedContainer(
        key: TodoListScreen.dropKey(columnId, 0),
        duration: const Duration(milliseconds: 100),
        alignment: Alignment.center,
        color: candidates.isEmpty
            ? Colors.transparent
            : Theme.of(context).colorScheme.primaryContainer,
        child: Text(
          'Drop a card here',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  Widget _boardCardDropTarget(
    String columnId,
    int index,
    TodoRow todo,
    Widget child,
  ) {
    return DragTarget<TodoRow>(
      key: TodoListScreen.cardDropKey(columnId, todo.id),
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) =>
          _acceptBoardDrop(details.data, columnId, index),
      builder: (context, candidates, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: candidates.isEmpty
              ? null
              : Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
        ),
        child: child,
      ),
    );
  }

  Widget _buildBoardCard(
    BuildContext context,
    TodoRow todo,
    String renderedColumnId,
    List<TodoColumnRow> columns,
  ) {
    final bool done = todo.doneAt != null;
    final bool selectingColumn =
        _selecting && _boardSelectionColumnId == renderedColumnId;
    final bool selected = _selected.contains(todo.id);
    final TodoRepository repo = ref.read(todoRepositoryProvider);
    final Widget card = Card(
      key: TodoListScreen.cardKey(todo.id),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        dense: true,
        selected: selectingColumn && selected,
        selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
        onTap: selectingColumn ? () => _toggleSelected(todo.id) : null,
        leading: selectingColumn
            ? Checkbox(
                key: Key('todo-select-${todo.id}'),
                value: selected,
                onChanged: (_) => _toggleSelected(todo.id),
              )
            : Checkbox(
                key: Key('todo-check-${todo.id}'),
                value: done,
                onChanged: _selecting
                    ? null
                    : (bool? value) => repo.setDone(todo.id, value ?? false),
              ),
        title: Text(
          todo.body,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: done
              ? const TextStyle(decoration: TextDecoration.lineThrough)
              : null,
        ),
        subtitle: todo.dueDate == null
            ? null
            : Text('${todo.dueDate} · ${todo.dueTime ?? defaultTodoDueTime}'),
        trailing: _selecting
            ? null
            : IconButton(
                key: Key('todo-menu-${todo.id}'),
                icon: const Icon(Icons.more_vert),
                tooltip: 'More',
                onPressed: () => _showRowMenu(todo),
              ),
      ),
    );
    if (_selecting) return card;
    return Listener(
      onPointerDown: _boardPointerStarted,
      onPointerMove: _boardPointerMoved,
      onPointerUp: (PointerUpEvent event) {
        if (_boardPointerId == event.pointer && _boardDraggingId == null) {
          _clearBoardPointer();
        }
      },
      onPointerCancel: (PointerCancelEvent event) {
        if (_boardPointerId == event.pointer) {
          if (_boardDraggingId == null) {
            _clearBoardPointer();
          } else {
            _boardDragCanceled = true;
          }
        }
      },
      child: LongPressDraggable<TodoRow>(
        delay: const Duration(milliseconds: 200),
        maxSimultaneousDrags: 1,
        data: todo,
        onDragStarted: () => _boardDraggingId ??= todo.id,
        onDragUpdate: (DragUpdateDetails details) {
          if (_boardDraggingId != todo.id) return;
          _boardPointerCurrent = details.globalPosition;
          final Offset? origin = _boardPointerDown;
          if (origin != null &&
              boardDragExceededDeadZone(origin, details.globalPosition)) {
            _boardDragMoved = true;
          }
        },
        onDragEnd: (_) {
          if (_boardDraggingId != todo.id) return;
          final Offset? origin = _boardPointerDown;
          final Offset? current = _boardPointerCurrent;
          final bool moved =
              _boardDragMoved ||
              (origin != null &&
                  current != null &&
                  boardDragExceededDeadZone(origin, current));
          final bool canceled = _boardDragCanceled;
          _clearBoardPointer();
          if (!moved && !canceled && mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _showBoardCardMenu(todo, renderedColumnId, columns);
              }
            });
          }
        },
        feedback: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(width: 284, child: card),
        ),
        childWhenDragging: Opacity(opacity: .3, child: card),
        child: card,
      ),
    );
  }

  Future<void> _showBoardCardMenu(
    TodoRow todo,
    String currentColumnId,
    List<TodoColumnRow> columns,
  ) async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Text(
                  todo.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              ListTile(
                key: TodoListScreen.boardDeleteKey,
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
                title: Text(
                  'Delete',
                  style: TextStyle(
                    color: Theme.of(sheetContext).colorScheme.error,
                  ),
                ),
                onTap: () => Navigator.pop(sheetContext, 'delete'),
              ),
              ListTile(
                key: TodoListScreen.boardFolderMoveKey,
                leading: const Icon(Icons.drive_file_move_outline),
                title: const Text('Move to folder'),
                onTap: () => Navigator.pop(sheetContext, 'folder'),
              ),
              const Divider(height: 1),
              Padding(
                key: TodoListScreen.boardMenuHeaderKey,
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  'Kanban Board',
                  style: Theme.of(sheetContext).textTheme.titleSmall,
                ),
              ),
              for (final TodoColumnRow column in columns)
                ListTile(
                  key: TodoListScreen.boardColumnChoiceKey(column.id),
                  enabled: column.id != currentColumnId,
                  leading: Icon(
                    column.id == currentColumnId
                        ? Icons.check
                        : Icons.arrow_forward,
                  ),
                  title: Text(column.name),
                  onTap: column.id == currentColumnId
                      ? null
                      : () =>
                            Navigator.pop(sheetContext, 'column:${column.id}'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'delete') {
      await _delete(todo);
      return;
    }
    if (action == 'folder') {
      await _move(todo);
      return;
    }
    if (action.startsWith('column:')) {
      await _queueBoardOperation(
        (TodoRepository repo) => repo.moveOnBoard(
          todo.id,
          action.substring('column:'.length),
          1 << 30,
        ),
        'while persisting a queued menu card move',
      );
    }
  }

  Future<void> _editColumnName({TodoColumnRow? column}) async {
    String draft = column?.name ?? '';
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(column == null ? 'Add column' : 'Rename column'),
        content: TextFormField(
          key: TodoListScreen.columnNameFieldKey,
          initialValue: draft,
          autofocus: true,
          onChanged: (String value) => draft = value,
          onFieldSubmitted: (String value) =>
              Navigator.pop(dialogContext, value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: TodoListScreen.columnSaveKey,
            onPressed: () => Navigator.pop(dialogContext, draft),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final TodoRepository repo = ref.read(todoRepositoryProvider);
    if (column == null) {
      await repo.addColumn(name);
    } else {
      await repo.renameColumn(column.id, name);
    }
  }

  Future<void> _deleteColumn(
    TodoColumnRow column,
    List<TodoColumnRow> columns,
  ) async {
    final TodoRepository repo = ref.read(todoRepositoryProvider);
    final int cardCount = await repo.countTodosInColumn(column.id);
    if (!mounted) return;
    final List<TodoColumnRow> destinations = columns
        .where((c) => c.id != column.id)
        .toList();
    final String? destination = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Delete ${column.name}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              cardCount == 0
                  ? 'Choose the column that remains the default destination.'
                  : 'Move $cardCount card${cardCount == 1 ? '' : 's'} to:',
            ),
            for (final TodoColumnRow destination in destinations)
              ListTile(
                leading: const Icon(Icons.arrow_forward),
                title: Text(destination.name),
                onTap: () => Navigator.pop(dialogContext, destination.id),
              ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (destination == null || !mounted) return;
    await repo.deleteColumn(column.id, destination);
  }

  /// The due chip's label and tint, including its required wall-clock time.
  ({String label, bool overdue})? _chipFor(TodoRow todo, DateTime now) {
    final String? due = todo.dueDate;
    if (due == null) return null;
    final String time = todo.dueTime ?? defaultTodoDueTime;
    final String today = todoDateKey(now);
    final bool overdue = due.compareTo(today) < 0;
    if (overdue) {
      return (label: 'Overdue · $due · $time', overdue: true);
    }
    if (due == today) return (label: 'Today · $time', overdue: false);
    return (label: '$due · $time', overdue: false);
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
          Icon(Icons.push_pin, key: Key('todo-pin-${todo.id}'), size: 14),
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
              onChanged: (bool? value) => repo.setDone(todo.id, value ?? false),
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
