// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../data/local_db.dart';
import '../data/todo_repository.dart';
import 'sheet_drag_handle.dart';

/// Picks one current Kanban lane, seeding the conventional board if needed.
Future<String?> showTodoColumnPickerSheet(
  BuildContext context, {
  required TodoRepository repository,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) =>
        _TodoColumnPickerSheet(repository: repository),
  );
}

class _TodoColumnPickerSheet extends StatefulWidget {
  const _TodoColumnPickerSheet({required this.repository});

  final TodoRepository repository;

  @override
  State<_TodoColumnPickerSheet> createState() => _TodoColumnPickerSheetState();
}

class _TodoColumnPickerSheetState extends State<_TodoColumnPickerSheet> {
  late final Future<List<TodoColumnRow>> _columns = widget.repository
      .ensureColumns();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      key: const ValueKey<String>('todo-column-picker'),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'Choose a To-Do column',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<TodoColumnRow>>(
                future: _columns,
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<List<TodoColumnRow>> snapshot,
                    ) {
                      if (snapshot.hasError) {
                        return Center(
                          child: Text(
                            'Could not load To-Do columns: ${snapshot.error}',
                          ),
                        );
                      }
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final List<TodoColumnRow> columns = snapshot.requireData;
                      return ListView.builder(
                        itemCount: columns.length,
                        itemBuilder: (BuildContext context, int index) {
                          final TodoColumnRow column = columns[index];
                          return ListTile(
                            key: ValueKey<String>(
                              'todo-column-picker-${column.id}',
                            ),
                            minTileHeight: 52,
                            leading: const Icon(Icons.view_kanban_outlined),
                            title: Text(
                              column.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => Navigator.of(context).pop(column.id),
                          );
                        },
                      );
                    },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Lets one transcript be edited before it becomes a card. A null result is a
/// cancellation; a non-null result is returned byte-for-byte from the field.
Future<String?> showTodoTranscriptEditor(
  BuildContext context, {
  required String transcript,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) =>
        _TodoTranscriptEditor(transcript: transcript),
  );
}

class _TodoTranscriptEditor extends StatefulWidget {
  const _TodoTranscriptEditor({required this.transcript});

  final String transcript;

  @override
  State<_TodoTranscriptEditor> createState() => _TodoTranscriptEditorState();
}

class _TodoTranscriptEditorState extends State<_TodoTranscriptEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.transcript,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      key: const ValueKey<String>('todo-transcript-editor'),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SheetDragHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  'Add transcript to To-Do',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    key: const ValueKey<String>('todo-transcript-field'),
                    controller: _controller,
                    autofocus: true,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      labelText: 'Card text',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      key: const ValueKey<String>('todo-transcript-cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey<String>('todo-transcript-add'),
                      onPressed: _controller.text.trim().isEmpty
                          ? null
                          : () => Navigator.of(context).pop(_controller.text),
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
