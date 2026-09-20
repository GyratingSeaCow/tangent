// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The folder-header long-press flow, shared by the notebooks and dumps
// lists. One implementation on purpose: the two lists present folders as
// the same concept, so rename/delete must look and behave identically —
// same keys, same wording, same guarantee that deleting a folder never
// deletes its contents.
import 'package:flutter/material.dart';

import '../data/local_db.dart';

enum _FolderAction { rename, delete }

/// Long-press menu for a folder header: rename or delete the folder itself.
///
/// Deleting a folder never deletes its contents — notebooks, recordings and
/// notes are revealed under "No folder", matching sync semantics on every
/// other device. [db] provides renameFolder/deleteFolder; errors surface in
/// snackbars (fail loud).
Future<void> showFolderHeaderActions(
  BuildContext context, {
  required String folderId,
  required String name,
  required LocalDb db,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final _FolderAction? action = await showModalBottomSheet<_FolderAction>(
    context: context,
    builder: (BuildContext sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            key: const ValueKey<String>('folder-action-rename'),
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename folder'),
            onTap: () => Navigator.of(sheetContext).pop(_FolderAction.rename),
          ),
          ListTile(
            key: const ValueKey<String>('folder-action-delete'),
            leading: Icon(
              Icons.delete_outline,
              color: Theme.of(sheetContext).colorScheme.error,
            ),
            title: Text(
              'Delete folder',
              style: TextStyle(
                color: Theme.of(sheetContext).colorScheme.error,
              ),
            ),
            onTap: () => Navigator.of(sheetContext).pop(_FolderAction.delete),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _FolderAction.rename:
      await _renameFolder(context, messenger, folderId, name, db);
    case _FolderAction.delete:
      await _deleteFolder(context, messenger, folderId, name, db);
  }
}

Future<void> _renameFolder(
  BuildContext context,
  ScaffoldMessengerState messenger,
  String folderId,
  String currentName,
  LocalDb db,
) async {
  final TextEditingController controller =
      TextEditingController(text: currentName);
  final String? name = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Rename folder'),
      content: TextField(
        key: const ValueKey<String>('folder-rename-field'),
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
          key: const ValueKey<String>('folder-rename-save'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  // Disposing immediately tears the controller down while the route is
  // still animating out; hand it to the next frame instead.
  WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  if (name == null || name.isEmpty || name == currentName) return;
  try {
    await db.renameFolder(folderId: folderId, name: name);
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not rename folder: $error')),
    );
  }
}

Future<void> _deleteFolder(
  BuildContext context,
  ScaffoldMessengerState messenger,
  String folderId,
  String name,
  LocalDb db,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text('Delete "$name"?'),
      content: const Text(
        'Only the folder is deleted. Its notebooks, recordings and notes '
        'are kept and move to "No folder".',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey<String>('folder-delete-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(
            'Delete folder',
            style: TextStyle(
              color: Theme.of(dialogContext).colorScheme.error,
            ),
          ),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await db.deleteFolder(folderId);
  } catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not delete folder: $error')),
    );
  }
}
