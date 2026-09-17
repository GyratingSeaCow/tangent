// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Notebook library: every notebook, newest-edited first.
//
// Design contract: docs/superpowers/specs/2026-09-17-notebooks-design.md
// The home screen's app-bar entry opens THIS list; the list opens or creates
// individual notebooks. Deleting a notebook never touches the dumps its cards
// referenced — the repository only drops the notebook row.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/notebook_repository.dart';
import '../../models/notebook.dart';
import 'notebook_editor_screen.dart';

class NotebookListScreen extends ConsumerStatefulWidget {
  const NotebookListScreen({super.key});

  @override
  ConsumerState<NotebookListScreen> createState() => _NotebookListScreenState();
}

class _NotebookListScreenState extends ConsumerState<NotebookListScreen> {
  /// Guards the create button so a double tap cannot spawn two notebooks.
  bool _creating = false;

  Future<void> _openNotebook(String id) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => NotebookEditorScreen(notebookId: id),
      ),
    );
  }

  /// Creates an empty notebook and drops the user straight into it, so the
  /// `+` button is one tap from writing.
  Future<void> _createNotebook() async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final Notebook created =
          await ref.read(notebookRepositoryProvider).createNotebook();
      if (!mounted) return;
      await _openNotebook(created.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create notebook: $error')),
      );
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _confirmDelete(Notebook notebook) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete notebook?'),
        content: Text(
          '“${notebook.title}” will be removed from this device. '
          'Recordings it referenced are not deleted.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(notebookRepositoryProvider).deleteNotebook(notebook.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete notebook: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Notebook>> notebooks = ref.watch(notebooksProvider);
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Notebooks')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New notebook',
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
        onPressed: _creating ? null : _createNotebook,
        child: const Icon(Icons.add),
      ),
      body: notebooks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Notebooks unavailable: $error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (List<Notebook> rows) {
          if (rows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No notebooks yet', textAlign: TextAlign.center),
              ),
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final Notebook notebook = rows[index];
              return ListTile(
                key: ValueKey<String>('notebook-row-${notebook.id}'),
                leading: const Icon(Icons.menu_book),
                title: Text(
                  notebook.title.isEmpty ? '(untitled)' : notebook.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(formatNotebookUpdated(notebook.updatedAt)),
                onTap: () => _openNotebook(notebook.id),
                onLongPress: () => _confirmDelete(notebook),
                trailing: PopupMenuButton<String>(
                  key: ValueKey<String>('notebook-menu-${notebook.id}'),
                  tooltip: 'Notebook actions',
                  onSelected: (String choice) {
                    if (choice == 'delete') _confirmDelete(notebook);
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      key: ValueKey<String>('notebook-delete-${notebook.id}'),
                      value: 'delete',
                      child: const Text('Delete notebook'),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// `Updated 2026-09-17 14:05` in local time.
///
/// Deliberately absolute: a relative label ("2 days ago") would need a clock
/// the list does not own and reads wrong for future-dated rows.
String formatNotebookUpdated(DateTime updatedAt) {
  final DateTime local = updatedAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'Updated ${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
