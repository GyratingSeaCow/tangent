// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Which notebook?" — the picker behind "Send to notebook…" (transcript-to-
// notebook spec §A). A searchable list of the user's notebooks, newest-edited
// first, with "New notebook" pinned on top so starting a fresh page from a
// recording is one tap.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/notebook_repository.dart';
import '../models/notebook.dart';
import 'sheet_drag_handle.dart';

/// Shows the picker and resolves to the chosen notebook's id, or null when
/// dismissed. "New notebook" creates one titled [suggestedTitle] through the
/// repository and resolves to its id.
Future<String?> showNotebookPickerSheet(
  BuildContext context, {
  required WidgetRef ref,
  required String suggestedTitle,
}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => _NotebookPickerSheet(
        suggestedTitle: suggestedTitle,
        onCreate: () => ref
            .read(notebookRepositoryProvider)
            .createNotebook(title: suggestedTitle),
      ),
    );

class _NotebookPickerSheet extends ConsumerStatefulWidget {
  const _NotebookPickerSheet({
    required this.suggestedTitle,
    required this.onCreate,
  });

  final String suggestedTitle;
  final Future<Notebook> Function() onCreate;

  @override
  ConsumerState<_NotebookPickerSheet> createState() =>
      _NotebookPickerSheetState();
}

class _NotebookPickerSheetState extends ConsumerState<_NotebookPickerSheet> {
  final TextEditingController _query = TextEditingController();
  bool _creating = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _createAndPick() async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      final Notebook created = await widget.onCreate();
      if (!mounted) return;
      Navigator.of(context).pop(created.id);
    } catch (error) {
      if (!mounted) return;
      setState(() => _creating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the notebook: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<NotebookListEntry>> headers =
        ref.watch(notebookHeadersProvider);
    final String needle = _query.text.trim().toLowerCase();
    final List<NotebookListEntry> rows = <NotebookListEntry>[
      for (final NotebookListEntry entry
          in headers.valueOrNull ?? const <NotebookListEntry>[])
        if (needle.isEmpty || entry.title.toLowerCase().contains(needle))
          entry,
    ]..sort(
        (NotebookListEntry a, NotebookListEntry b) =>
            b.updatedAt.compareTo(a.updatedAt),
      );

    return SafeArea(
      key: const ValueKey<String>('notebook-picker'),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: <Widget>[
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: TextField(
                key: const ValueKey<String>('notebook-picker-search'),
                controller: _query,
                autofocus: false,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search notebooks',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            ListTile(
              key: const ValueKey<String>('notebook-picker-new'),
              minTileHeight: 52,
              leading: const Icon(Icons.add),
              title: const Text('New notebook'),
              subtitle: Text(
                'Titled "${widget.suggestedTitle}"',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              enabled: !_creating,
              onTap: _createAndPick,
            ),
            const Divider(height: 1),
            Expanded(
              child: headers.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (Object error, _) =>
                    Center(child: Text('Could not load notebooks: $error')),
                data: (_) => rows.isEmpty
                    ? Center(
                        child: Text(
                          needle.isEmpty
                              ? 'No notebooks yet'
                              : 'No notebooks match "$needle"',
                        ),
                      )
                    : ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (BuildContext context, int index) {
                          final NotebookListEntry entry = rows[index];
                          return ListTile(
                            key: ValueKey<String>(
                              'notebook-picker-${entry.id}',
                            ),
                            minTileHeight: 52,
                            leading: const Icon(Icons.menu_book_outlined),
                            title: Text(
                              entry.title.isEmpty ? '(untitled)' : entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => Navigator.of(context).pop(entry.id),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
