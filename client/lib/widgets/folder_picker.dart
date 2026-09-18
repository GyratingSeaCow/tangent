// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The destination step of Move.
//
// Move is only as safe as its picker. Three things it must always offer:
// a way OUT of a folder (unfiling is a destination, not a cancel), a way to
// create a folder that does not exist yet without leaving the flow, and a
// dismissal that files nothing. Returning null for both "cancel" and "no
// folder" would make the two indistinguishable and quietly unfile notebooks
// whenever someone changed their mind.
import 'package:flutter/material.dart';

/// A folder the user can file something into.
@immutable
class FolderOption {
  const FolderOption({required this.id, required this.name});

  final String id;
  final String name;
}

/// What the user picked.
///
/// A null [folderId] with [isNewFolder] false means "no folder" — an explicit
/// unfile. The picker resolving to null instead means the user dismissed it
/// and nothing should move.
@immutable
class FolderChoice {
  const FolderChoice.folder(String this.folderId)
      : isNewFolder = false,
        newFolderName = null;

  const FolderChoice.none()
      : folderId = null,
        isNewFolder = false,
        newFolderName = null;

  const FolderChoice.create(String this.newFolderName)
      : folderId = null,
        isNewFolder = true;

  final String? folderId;
  final bool isNewFolder;
  final String? newFolderName;
}

class FolderPicker extends StatefulWidget {
  const FolderPicker({
    super.key,
    required this.folders,
    this.currentFolderId,
  });

  final List<FolderOption> folders;
  final String? currentFolderId;

  static const Key noFolderKey = ValueKey<String>('folder-picker-none');
  static const Key newFolderKey = ValueKey<String>('folder-picker-new');
  static const Key newFolderFieldKey =
      ValueKey<String>('folder-picker-new-field');
  static const Key newFolderCreateKey =
      ValueKey<String>('folder-picker-new-create');

  static Key folderKey(String id) => ValueKey<String>('folder-picker-$id');

  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  final TextEditingController _newFolderController = TextEditingController();
  bool _creating = false;

  @override
  void dispose() {
    _newFolderController.dispose();
    super.dispose();
  }

  void _submitNewFolder() {
    final String name = _newFolderController.text.trim();
    // Whitespace is not a folder name: creating one would leave an unnamed
    // row the user cannot identify or find again.
    if (name.isEmpty) {
      setState(() => _creating = false);
      return;
    }
    Navigator.of(context).pop(FolderChoice.create(name));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Text('Move to', style: theme.textTheme.titleMedium),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: <Widget>[
                ListTile(
                  key: FolderPicker.noFolderKey,
                  leading: const Icon(Icons.inbox_outlined),
                  title: const Text('No folder'),
                  selected: widget.currentFolderId == null,
                  onTap: () =>
                      Navigator.of(context).pop(const FolderChoice.none()),
                ),
                for (final FolderOption folder in widget.folders)
                  ListTile(
                    key: FolderPicker.folderKey(folder.id),
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(folder.name),
                    selected: folder.id == widget.currentFolderId,
                    trailing: folder.id == widget.currentFolderId
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: folder.id == widget.currentFolderId
                        ? null
                        : () => Navigator.of(context)
                            .pop(FolderChoice.folder(folder.id)),
                  ),
                const Divider(height: 1),
                if (!_creating)
                  ListTile(
                    key: FolderPicker.newFolderKey,
                    leading: const Icon(Icons.create_new_folder_outlined),
                    title: const Text('New folder'),
                    onTap: () => setState(() => _creating = true),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            key: FolderPicker.newFolderFieldKey,
                            controller: _newFolderController,
                            autofocus: true,
                            decoration: const InputDecoration(
                              labelText: 'Folder name',
                            ),
                            onSubmitted: (_) => _submitNewFolder(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          key: FolderPicker.newFolderCreateKey,
                          onPressed: _submitNewFolder,
                          child: const Text('Create'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Shows the folder picker.
///
/// Resolves to null when dismissed (nothing moves), or a [FolderChoice]
/// describing where the item should go.
Future<FolderChoice?> showFolderPicker(
  BuildContext context, {
  required List<FolderOption> folders,
  String? currentFolderId,
}) {
  return showModalBottomSheet<FolderChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => Padding(
      // Keep the name field above the keyboard when creating a folder.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: FolderPicker(
        folders: folders,
        currentFolderId: currentFolderId,
      ),
    ),
  );
}
