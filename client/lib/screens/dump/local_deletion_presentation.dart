// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import '../../data/storage/storage_contract.dart';

const localDeletionWarning =
    'Local audio, transcripts/notes, and metadata will be removed. Server copies are not deleted and server jobs are not canceled.';
Future<bool> confirmLocalDeletion(BuildContext context, int count,
    {bool retry = false,}) async {
  var resolved = false;
  try {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) {
            void resolve(bool yes) {
              if (resolved ||
                  !ctx.mounted ||
                  ModalRoute.of(ctx)?.isCurrent != true) {
                return;
              }
              resolved = true;
              Navigator.of(ctx).pop(yes);
            }

            return AlertDialog(
              scrollable: true,
              title: Text(retry
                  ? 'Retry deletion of $count local recordings?'
                  : 'Delete $count local recordings?',),
              content: const Text(localDeletionWarning),
              actions: [
                TextButton(
                    key: const ValueKey('local-delete-cancel'),
                    autofocus: true,
                    onPressed: () => resolve(false),
                    child: const Text('Cancel'),),
                FilledButton(
                    key: const ValueKey('local-delete-confirm'),
                    onPressed: () => resolve(true),
                    child: Text(retry ? 'Retry' : 'Delete'),),
              ],
            );
          },
        ) ??
        false;
  } finally {
    resolved = true;
  }
}

/// Mounted-route presentation only: not durable history or storage authority.
/// A replaceable operation summary must never own the only recovery handle.
class LocalDeletionRecoveryState {
  BulkDeletionResult? _latest;
  final _pending = <String, DeletionItemResult>{};
  BulkDeletionResult? get latest => _latest;
  List<DeletionItemResult> get pending => List.unmodifiable(_pending.values);
  List<String> get ticketIds => List.unmodifiable(_pending.keys);
  bool get hasPending => _pending.isNotEmpty;

  void record(BulkDeletionResult result) {
    _latest = (items: List.unmodifiable(result.items), replayed: result.replayed);
    for (final item in result.items) {
      final ticket = item.ticketId;
      if (ticket == null) continue;
      final previous = _pending[ticket];
      if (previous != null && previous.id != item.id) continue;
      // Accepted backend reports completed tickets as deleted + both gone.
      // Missing, ticketless, failed and skipped results cannot resolve one.
      bool gone(ComponentResult c) => c.problem == null &&
          (c.state == ComponentState.removed || c.state == ComponentState.absent);
      if (item.state == DeleteState.deleted && item.problem == null &&
          gone(item.audio) && gone(item.metadata)) {
        _pending.remove(ticket);
      } else if (item.state == DeleteState.failed) {
        _pending[ticket] = item;
      }
    }
  }
}

class LocalDeletionResults extends StatelessWidget {
  const LocalDeletionResults(
      {super.key,
      required this.result,
      required this.pending,
      required this.onRetry,
      this.busy = false,});
  final BulkDeletionResult result;
  final List<DeletionItemResult> pending;
  final VoidCallback? onRetry;
  String _component(ComponentResult result) =>
      '${result.state.name}${result.problem == null ? '' : ' (${result.problem!.message})'}';
  final bool busy;
  @override
  Widget build(BuildContext context) {
    int count(DeleteState state) =>
        result.items.where((i) => i.state == state).length;
    return Card(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 210),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${result.replayed ? 'Previously recorded result: ' : ''}${count(DeleteState.deleted)} deleted, ${count(DeleteState.failed)} failed, ${count(DeleteState.skipped)} skipped',
                    key: const ValueKey('local-delete-totals'),
                    style: Theme.of(context).textTheme.titleSmall,),
                for (final item in result.items.where((i) =>
                    i.state != DeleteState.deleted &&
                    !pending.any((p) => p.ticketId == i.ticketId && p.id == i.id),))
                  Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                          '${item.id}: ${item.state.name}\naudio: ${_component(item.audio)}; metadata: ${_component(item.metadata)}${item.problem == null ? '' : ' (${item.problem!.code.name})'}',),),
                if (pending.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Pending local deletions (${pending.length})',
                      key: const ValueKey('local-delete-pending-count'),
                      style: Theme.of(context).textTheme.titleSmall,),
                  for (final item in pending)
                    Padding(
                        key: ValueKey('local-delete-pending-${item.ticketId}'),
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                            '${item.id}: ${item.state.name}\naudio: ${_component(item.audio)}; metadata: ${_component(item.metadata)}${item.problem == null ? '' : ' (${item.problem!.code.name})'}',),),
                  TextButton(
                      key: const ValueKey('local-delete-retry'),
                      onPressed: busy ? null : onRetry,
                      child: const Text('Retry failed local deletions'),),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
