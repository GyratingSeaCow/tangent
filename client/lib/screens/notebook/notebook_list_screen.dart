// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Notebook library: every notebook, newest-edited first.
//
// The home screen's app-bar entry opens THIS list; the list opens or creates
// individual notebooks. Deleting a notebook never touches the dumps its cards
// referenced — the repository only drops the notebook row.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/notebook_repository.dart';
import '../../models/notebook.dart';
import '../../services/notebook_persistence.dart';
import '../../widgets/folder_picker.dart';
import '../../widgets/sync_button.dart';
import '../../data/local_db.dart';
import '../home/home_screen.dart' show localDbProvider;
import '../home/home_providers.dart' show documentSyncEngineProvider;
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

  /// Cover grid instead of the named list, like Samsung Notes' book view.
  ///
  /// Defaults to the list so an existing user's screen is unchanged until they
  /// ask for covers, and persists so the choice survives a restart.
  bool _covers = false;

  static const String _viewPreferenceKey = 'notebooks.coverView';

  /// Folder ids whose sections are currently collapsed. In-memory only:
  /// collapse is a skimming aid, not a filing decision, so it resets on a
  /// fresh screen. Shared by both views — the list and the cover grid are
  /// one library, and a fold made in one must hold in the other.
  final Set<String> _collapsed = <String>{};

  void _toggleSection(String folderId) {
    setState(() {
      if (!_collapsed.remove(folderId)) _collapsed.add(folderId);
    });
  }

  @override
  void initState() {
    super.initState();
    _restoreViewPreference();
  }

  Future<void> _restoreViewPreference() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool stored = prefs.getBool(_viewPreferenceKey) ?? false;
    if (!mounted || stored == _covers) return;
    setState(() => _covers = stored);
  }

  Future<void> _toggleView() async {
    final bool next = !_covers;
    setState(() => _covers = next);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_viewPreferenceKey, next);
  }

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
      // Notebooks have no server-side audio to fetch, so this action is
      // never offered here; the branch exists to keep the switch exhaustive.
      case ItemAction.download:
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
      appBar: AppBar(
        title: const Text('Notebooks'),
        actions: <Widget>[
          SyncButton(engineProvider: documentSyncEngineProvider),
          IconButton(
            key: const ValueKey<String>('notebook-view-toggle'),
            tooltip: _covers ? 'Show as list' : 'Show as covers',
            icon: Icon(_covers ? Icons.view_list : Icons.grid_view),
            onPressed: _toggleView,
          ),
        ],
      ),
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
            // The unfiled pseudo-folder collapses under this key too — its
            // header is a name like any other, and a tap that works on
            // 'Work' but not 'No folder' would read as a broken control.
            final String sectionKey = section.folderId ?? 'unfiled';
            final bool collapsed = _collapsed.contains(sectionKey);
            if (section.title != null) {
              children.add(
                InkWell(
                  key: ValueKey<String>('notebook-section-$sectionKey'),
                  onTap: () => _toggleSection(sectionKey),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            section.title!,
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(color: colors.primary),
                          ),
                        ),
                        // The affordance: a chevron that points down when
                        // open and sideways when folded, so collapsibility
                        // is discoverable without a tooltip.
                        AnimatedRotation(
                          turns: collapsed ? -0.25 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(
                            Icons.expand_more,
                            size: 20,
                            color: colors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            if (collapsed && section.title != null) {
              // A folded section shows only its header. The items stay in
              // the tree's data, not the tree itself.
              continue;
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
            if (_covers) {
              // One grid per section, shrink-wrapped inside the outer list, so
              // folder headers keep their place between grids.
              children.add(
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      childAspectRatio: 0.72,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                    ),
                    itemCount: section.notebooks.length,
                    itemBuilder: (BuildContext _, int index) =>
                        _notebookCover(section.notebooks[index]),
                  ),
                ),
              );
            } else {
              for (final Notebook notebook in section.notebooks) {
                children.add(_notebookTile(notebook));
                children.add(const Divider(height: 1));
              }
            }
          }

          return ListView(children: children);
        },
      ),
    );
  }

  /// Builds one cover for the grid view.
  ///
  /// The cover carries the SAME gestures as the row -- tap opens, long-press
  /// opens the action sheet -- so switching view never costs the user an
  /// affordance. The title is always drawn: a grid of identical covers with no
  /// names cannot be navigated.
  Widget _notebookCover(Notebook notebook) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey<String>('notebook-cover-${notebook.id}'),
      onTap: () => _openNotebook(notebook.id),
      onLongPress: () => _showActions(notebook),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Center(
                child: Icon(
                  Icons.menu_book,
                  size: 40,
                  color: colors.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            notebook.title.isEmpty ? '(untitled)' : notebook.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            formatNotebookUpdated(notebook.updatedAt),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
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
