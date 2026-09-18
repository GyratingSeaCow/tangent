// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Notebook library: every notebook, newest-edited first.
//
// The home screen's app-bar entry opens THIS list; the list opens or creates
// individual notebooks. Deleting a notebook never touches the dumps its cards
// referenced — the repository only drops the notebook row.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/notebook_repository.dart';
import '../../models/notebook.dart';
import '../../services/notebook_persistence.dart';
import '../../widgets/folder_picker.dart';
import '../../data/local_db.dart';
import '../home/home_screen.dart' show localDbProvider;
import '../../widgets/item_action_sheet.dart';
import 'notebook_grouping.dart';
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

  /// Long-press opens the shared menu instead of deleting outright.
  Future<void> _showActions(Notebook notebook) async {
    final ItemAction? action = await showItemActionSheet(
      context,
      title: notebook.title.isEmpty ? '(untitled)' : notebook.title,
      subtitle: formatNotebookUpdated(notebook.updatedAt),
      actions: const <ItemAction>[
        ItemAction.open,
        ItemAction.rename,
        ItemAction.move,
        ItemAction.delete,
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case ItemAction.open:
        await _openNotebook(notebook.id);
      case ItemAction.rename:
        await _rename(notebook);
      case ItemAction.move:
        await _move(notebook);
      case ItemAction.delete:
        await _confirmDelete(notebook);
      case ItemAction.duplicate:
      case ItemAction.share:
      case ItemAction.select:
        break;
    }
  }

  Future<void> _move(Notebook notebook) async {
    final LocalDb db = ref.read(localDbProvider);
    final List<Folder> folders =
        ref.read(foldersProvider).valueOrNull ?? const <Folder>[];

    final FolderChoice? choice = await showFolderPicker(
      context,
      folders: folders
          .map((Folder f) => FolderOption(id: f.id, name: f.name))
          .toList(growable: false),
      currentFolderId: notebook.folderId,
    );
    // Null means the user dismissed the sheet: nothing moves. An explicit
    // "No folder" arrives as a FolderChoice with a null id instead.
    if (choice == null || !mounted) return;

    try {
      String? destination = choice.folderId;
      if (choice.isNewFolder) {
        destination = await db.createFolder(name: choice.newFolderName!);
      }
      await db.moveNotebookToFolder(
        notebookId: notebook.id,
        folderId: destination,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not move notebook: $error')),
      );
    }
  }

  Future<void> _rename(Notebook notebook) async {
    final TextEditingController controller =
        TextEditingController(text: notebook.title);
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Rename notebook'),
        content: TextField(
          key: const ValueKey<String>('notebook-rename-field'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (String value) =>
              Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey<String>('notebook-rename-save'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // The dialog's route is still animating out and its TextField still builds
    // against this controller; disposing here throws "used after being
    // disposed". Hand it to the next frame instead.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (name == null || name.isEmpty || !mounted) return;
    try {
      // Persistence rewrites the durable file too; the bare repository would
      // leave the on-disk copy carrying the old title for the next import.
      await ref
          .read(notebookPersistenceProvider)
          .saveNotebook(notebook.copyWith(title: name));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not rename notebook: $error')),
      );
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
      // Persistence deletes the row AND its durable file; the bare repository
      // would leave an orphan in 'Tangent Notebooks' that import resurrects.
      await ref.read(notebookPersistenceProvider).deleteNotebook(notebook.id);
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
          // Folders are watched via a provider (not the database directly) so
          // the screen stays testable, and filing shows up immediately: move a
          // notebook and the section it left collapses without a refresh.
          final List<FolderSummary> folders = ref
              .watch(foldersProvider)
              .maybeWhen(
                data: (List<Folder> rows) => rows
                    .map((Folder f) => FolderSummary(id: f.id, name: f.name))
                    .toList(growable: false),
                orElse: () => const <FolderSummary>[],
              );
          final List<NotebookSection> sections = groupNotebooks(
            notebooks: rows,
            folders: folders,
          );

          // Flatten sections into a single list: a header, then its rows.
          final List<Widget> children = <Widget>[];
          for (final NotebookSection section in sections) {
            if (section.title != null) {
              children.add(
                Padding(
                  key: ValueKey<String>(
                    'notebook-section-${section.folderId ?? 'unfiled'}',
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    section.title!,
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: colors.primary),
                  ),
                ),
              );
            }
            if (section.isEmpty && section.title != null) {
              children.add(
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Empty',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              );
            }
            for (final Notebook notebook in section.notebooks) {
              children.add(_notebookTile(notebook));
              children.add(const Divider(height: 1));
            }
          }

          return ListView(children: children);
        },
      ),
    );
  }

  Widget _notebookTile(Notebook notebook) => ListTile(
        key: ValueKey<String>('notebook-row-${notebook.id}'),
        leading: const Icon(Icons.menu_book),
        title: Text(
          notebook.title.isEmpty ? '(untitled)' : notebook.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(formatNotebookUpdated(notebook.updatedAt)),
        onTap: () => _openNotebook(notebook.id),
        onLongPress: () => _showActions(notebook),
        trailing: IconButton(
          key: ValueKey<String>('notebook-menu-${notebook.id}'),
          tooltip: 'Notebook actions',
          icon: const Icon(Icons.more_vert),
          onPressed: () => _showActions(notebook),
        ),
      );
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
