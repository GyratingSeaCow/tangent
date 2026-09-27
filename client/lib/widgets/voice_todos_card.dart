// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local_db.dart';
import '../data/todo_repository.dart';
import '../screens/todo/todo_list_screen.dart';

/// Live voice-captured todos for one dump, keyed by dump id.
final voiceTodosForDumpProvider =
    StreamProvider.family<List<TodoRow>, String>((ref, dumpId) {
  return ref.watch(todoRepositoryProvider).watchTodosFromSource(dumpId);
});

/// "Added to your To Do list" — what voice capture took from this recording
/// (To Do arc Phase 2, V3 "visible auto-add").
///
/// Renders NOTHING when the dump produced no voice todos, and nothing again
/// once Undo has soft-deleted them: the card is a view of the live rows, so
/// it disappears on its own rather than needing a local "hidden" flag that
/// could disagree with the database.
///
/// Matches the AI summary card's visual conventions (muted label row above a
/// plain `Card`), so an auto-added list reads as secondary to the transcript.
class VoiceTodosCard extends ConsumerWidget {
  const VoiceTodosCard({required this.dumpId, super.key});

  final String dumpId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<TodoRow> items =
        ref.watch(voiceTodosForDumpProvider(dumpId)).valueOrNull ??
            const <TodoRow>[];
    // No trigger, or already Undone: no card at all, not an empty shell.
    if (items.isEmpty) return const SizedBox.shrink();

    final ThemeData theme = Theme.of(context);
    return Column(
      key: ValueKey<String>('voice-todos-card-$dumpId'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.check_box,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              'Added to your To Do list',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The BODY is the tap target (the Undo button below sits
              // outside it, so an Undo tap can never also navigate).
              InkWell(
                key: ValueKey<String>('voice-todos-open-$dumpId'),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const TodoListScreen(),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final TodoRow item in items)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('•  ', style: theme.textTheme.bodyMedium),
                              Expanded(
                                child: Text(
                                  item.body,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  child: TextButton(
                    key: ValueKey<String>('voice-todos-undo-$dumpId'),
                    onPressed: () => _undo(context, ref, items.length),
                    child: const Text('Undo'),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Future<void> _undo(BuildContext context, WidgetRef ref, int count) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    // SOFT delete only. The rows stay as provenance so detection never
    // re-fires for this dump — a hard delete would let the next sync
    // resurrect every item the user just dismissed.
    await ref.read(todoRepositoryProvider).softDeleteFromSource(dumpId);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          count == 1 ? 'Removed 1 to-do' : 'Removed $count to-dos',
        ),
      ),
    );
  }
}
