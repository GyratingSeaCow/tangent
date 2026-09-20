// SPDX-License-Identifier: AGPL-3.0-or-later
/// Settings → Trash: deleted notebooks wait here for 7 days.
///
/// Deletion in Tangent is synced, so a slip on ONE device removes the
/// notebook from ALL of them — the trash is what makes that survivable.
/// The list shows every trashed notebook with the days it has left;
/// Restore brings one back (and pushes the resurrection to the other
/// devices), and the screen states the 7-day auto-empty plainly because
/// an unannounced purge reads as data loss.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db.dart';
import '../../theme/tangent_tokens.dart';
import '../home/home_screen.dart' show localDbProvider;

class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  List<NotebookRow>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await ref.read(localDbProvider).trashedNotebooks();
    if (mounted) setState(() => _rows = rows);
  }

  Future<void> _restore(NotebookRow row) async {
    await ref.read(localDbProvider).restoreNotebook(row.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Restored "${row.title}"')),
    );
    await _load();
  }

  String _daysLeft(NotebookRow row) {
    final DateTime deleted =
        DateTime.fromMillisecondsSinceEpoch(row.deletedAt ?? 0);
    final Duration left =
        LocalDb.trashRetention - DateTime.now().difference(deleted);
    final int days = left.inDays;
    if (days <= 0) return 'removed at next cleanup';
    return days == 1 ? '1 day left' : '$days days left';
  }

  @override
  Widget build(BuildContext context) {
    final List<NotebookRow>? rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('Trash')),
      body: rows == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Deleted notebooks stay here for 7 days, then the trash '
                    'empties itself. Restoring a notebook returns it to '
                    'every synced device.',
                    style:
                        TextStyle(fontSize: 12, color: TangentColors.textDim),
                  ),
                ),
                Expanded(
                  child: rows.isEmpty
                      ? const Center(child: Text('Trash is empty'))
                      : ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (BuildContext context, int index) {
                            final NotebookRow row = rows[index];
                            return ListTile(
                              key: ValueKey<String>('trash-row-${row.id}'),
                              leading: const Icon(Icons.delete_outline),
                              title: Text(
                                row.title.isEmpty ? '(untitled)' : row.title,
                              ),
                              subtitle: Text(_daysLeft(row)),
                              trailing: TextButton(
                                key: ValueKey<String>(
                                  'trash-restore-${row.id}',
                                ),
                                onPressed: () => _restore(row),
                                child: const Text('RESTORE'),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
