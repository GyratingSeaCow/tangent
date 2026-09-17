// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';

import '../models/dump.dart';
import '../models/dump_mode.dart';
import 'notebook_dump_card.dart' show dumpModeIcon, formatDumpDuration;

/// Modal bottom-sheet body for multi-selecting dumps to embed in a notebook.
///
/// Pops a `Set<String>` of selected dump ids on Add, or null on Cancel.
/// Purely presentational: it never reads or mutates the database.
class DumpPickerSheet extends StatefulWidget {
  const DumpPickerSheet({
    super.key,
    required this.dumps,
    this.initiallySelected = const <String>{},
  });

  /// Candidate dumps, in the order they should be listed.
  final List<Dump> dumps;

  /// Dump ids that start checked (e.g. already embedded in the notebook).
  final Set<String> initiallySelected;

  /// Shows the picker and resolves with the chosen ids, or null if cancelled.
  static Future<Set<String>?> show(
    BuildContext context, {
    required List<Dump> dumps,
    Set<String> initiallySelected = const <String>{},
  }) {
    return showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DumpPickerSheet(
        dumps: dumps,
        initiallySelected: initiallySelected,
      ),
    );
  }

  @override
  State<DumpPickerSheet> createState() => _DumpPickerSheetState();
}

class _DumpPickerSheetState extends State<DumpPickerSheet> {
  late final Set<String> _selected = {...widget.initiallySelected};
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Dump> get _visible {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return widget.dumps;
    return widget.dumps
        .where((d) => d.title.toLowerCase().contains(needle))
        .toList(growable: false);
  }

  String _subtitle(Dump dump) {
    final date = dump.createdAt.toLocal().toString().split('.').first;
    if (dump.mode == DumpMode.textNote || dump.durationSeconds <= 0) {
      return date;
    }
    return '${formatDumpDuration(dump.durationSeconds)} · $date';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _visible;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Add recordings',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  key: const ValueKey('dump-picker-search'),
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: 'Search recordings…',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: visible.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: Text('No matching recordings')),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final dump = visible[index];
                          return CheckboxListTile(
                            key: ValueKey('dump-pick-${dump.id}'),
                            value: _selected.contains(dump.id),
                            controlAffinity: ListTileControlAffinity.leading,
                            secondary: Icon(dumpModeIcon(dump.mode)),
                            title: Text(
                              dump.title.isEmpty ? '(untitled)' : dump.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              _subtitle(dump),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onChanged: (checked) => setState(() {
                              if (checked ?? false) {
                                _selected.add(dump.id);
                              } else {
                                _selected.remove(dump.id);
                              }
                            }),
                          );
                        },
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const ValueKey('dump-picker-cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('dump-picker-add'),
                      onPressed: () => Navigator.of(context)
                          .pop(Set<String>.unmodifiable(_selected)),
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
