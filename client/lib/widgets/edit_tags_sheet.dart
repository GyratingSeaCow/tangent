// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The one "Edit tags" sheet, opened from the ⋮ menu of a notebook row, a
// notebook cover, or a recording row.
//
// Every control writes immediately through [TagStore] (which marks the change
// dirty for sync); there is no Save step to forget. The sheet re-renders from
// the live projections, so what it shows is what the database holds.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_db.dart' show TagNameException;
import '../data/tag_repository.dart';
import 'sheet_drag_handle.dart';

Future<void> showEditTagsSheet(
  BuildContext context, {
  required String targetType,
  required String targetId,
  required String itemTitle,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // The keyboard comes up for the name field; the sheet must ride above it.
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => EditTagsSheet(
      targetType: targetType,
      targetId: targetId,
      itemTitle: itemTitle,
    ),
  );
}

class EditTagsSheet extends ConsumerStatefulWidget {
  const EditTagsSheet({
    super.key,
    required this.targetType,
    required this.targetId,
    required this.itemTitle,
  });

  final String targetType;
  final String targetId;
  final String itemTitle;

  static const Key fieldKey = ValueKey<String>('edit-tags-field');
  static const Key createKey = ValueKey<String>('edit-tags-create');
  static const Key doneKey = ValueKey<String>('edit-tags-done');
  static const Key errorKey = ValueKey<String>('edit-tags-error');
  static Key toggleKey(String tagId) =>
      ValueKey<String>('edit-tags-toggle-$tagId');
  static Key menuKey(String tagId) => ValueKey<String>('edit-tags-menu-$tagId');
  static Key renameKey(String tagId) =>
      ValueKey<String>('edit-tags-rename-$tagId');
  static Key deleteKey(String tagId) =>
      ValueKey<String>('edit-tags-delete-$tagId');

  @override
  ConsumerState<EditTagsSheet> createState() => _EditTagsSheetState();
}

class _EditTagsSheetState extends ConsumerState<EditTagsSheet> {
  final TextEditingController _query = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  TagStore get _store => ref.read(tagStoreProvider);

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on TagNameException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not update tags: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Attach the tag named in the field, creating it when no tag has that
  /// name. [TagStore.createTag] returns the existing id for a taken name, so
  /// typing "work" next to an existing "Work" attaches it, never a twin.
  Future<void> _submit() async {
    final String name = _query.text;
    if (name.trim().isEmpty) return;
    await _run(() async {
      final String id = await _store.createTag(name);
      await _store.assignTag(
        tagId: id,
        targetType: widget.targetType,
        targetId: widget.targetId,
      );
      _query.clear();
    });
  }

  Future<void> _toggle(TagSummary tag, bool attach) => _run(() async {
    if (attach) {
      await _store.assignTag(
        tagId: tag.id,
        targetType: widget.targetType,
        targetId: widget.targetId,
      );
    } else {
      await _store.unassignTag(
        tagId: tag.id,
        targetType: widget.targetType,
        targetId: widget.targetId,
      );
    }
  });

  Future<void> _rename(TagSummary tag) async {
    final TextEditingController controller = TextEditingController(
      text: tag.name,
    );
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Rename tag'),
        content: TextField(
          key: const ValueKey<String>('tag-rename-field'),
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (String value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey<String>('tag-rename-save'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // The dialog's TextField still builds during the exit animation.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (name == null || !mounted) return;
    await _run(() => _store.renameTag(tag.id, name));
  }

  Future<void> _delete(TagSummary tag) async {
    final int count = await _store.usageCount(tag.id);
    if (!mounted) return;
    final String uses = count == 1 ? '1 item' : '$count items';
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Delete tag “${tag.name}”?'),
        content: Text(
          'This removes “${tag.name}” from every notebook and recording that '
          'uses it ($uses), on all your synced devices. The notebooks and '
          'recordings themselves are not deleted.',
          key: const ValueKey<String>('tag-delete-message'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey<String>('tag-delete-confirm'),
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
    await _run(() => _store.deleteTag(tag.id));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<TagSummary> tags =
        ref.watch(tagsProvider).valueOrNull ?? const <TagSummary>[];
    final Set<String> attached =
        ref
            .watch(tagLinksProvider(widget.targetType))
            .valueOrNull?[widget.targetId] ??
        const <String>{};
    final String typed = _query.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final String folded = typed.toLowerCase();
    final bool exact = tags.any(
      (TagSummary t) => t.name.toLowerCase() == folded,
    );
    final List<TagSummary> shown = folded.isEmpty
        ? tags
        : tags
              .where((TagSummary t) => t.name.toLowerCase().contains(folded))
              .toList(growable: false);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('Edit tags', style: theme.textTheme.titleMedium),
                        Text(
                          widget.itemTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    key: EditTagsSheet.doneKey,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: TextField(
                key: EditTagsSheet.fieldKey,
                controller: _query,
                enabled: !_busy,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  hintText: 'Find or create a tag',
                  prefixIcon: Icon(Icons.sell_outlined, size: 18),
                  isDense: true,
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 2),
                child: Text(
                  _error!,
                  key: EditTagsSheet.errorKey,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (typed.isNotEmpty && !exact)
              ListTile(
                key: EditTagsSheet.createKey,
                enabled: !_busy,
                leading: const Icon(Icons.add),
                title: Text(
                  'Create “$typed”',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: _submit,
              ),
            const Divider(height: 1),
            Flexible(
              child: shown.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        tags.isEmpty
                            ? 'No tags yet — type a name to create one.'
                            : 'No tag matches',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      children: <Widget>[
                        for (final TagSummary tag in shown)
                          ListTile(
                            minTileHeight: 52,
                            leading: Checkbox(
                              key: EditTagsSheet.toggleKey(tag.id),
                              value: attached.contains(tag.id),
                              onChanged: _busy
                                  ? null
                                  : (bool? on) => _toggle(tag, on == true),
                            ),
                            title: Text(
                              tag.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: _busy
                                ? null
                                : () =>
                                      _toggle(tag, !attached.contains(tag.id)),
                            trailing: PopupMenuButton<String>(
                              key: EditTagsSheet.menuKey(tag.id),
                              tooltip: 'Tag actions',
                              enabled: !_busy,
                              onSelected: (String choice) => choice == 'rename'
                                  ? _rename(tag)
                                  : _delete(tag),
                              itemBuilder: (_) => <PopupMenuEntry<String>>[
                                PopupMenuItem<String>(
                                  key: EditTagsSheet.renameKey(tag.id),
                                  value: 'rename',
                                  child: const Text('Rename tag'),
                                ),
                                PopupMenuItem<String>(
                                  key: EditTagsSheet.deleteKey(tag.id),
                                  value: 'delete',
                                  child: const Text('Delete tag everywhere'),
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
      ),
    );
  }
}
