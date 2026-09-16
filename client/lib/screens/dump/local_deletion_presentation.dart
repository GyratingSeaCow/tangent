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

List<String> failedDeletionTickets(BulkDeletionResult result) =>
    List.unmodifiable(
      result.items
          .where((i) => i.state == DeleteState.failed && i.ticketId != null)
          .map((i) => i.ticketId!)
          .toSet(),
    );

class LocalDeletionResults extends StatelessWidget {
  const LocalDeletionResults(
      {super.key,
      required this.result,
      required this.onRetry,
      this.busy = false,});
  final BulkDeletionResult result;
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
                for (final item in result.items
                    .where((i) => i.state != DeleteState.deleted))
                  Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                          '${item.id}: ${item.state.name}\naudio: ${_component(item.audio)}; metadata: ${_component(item.metadata)}${item.problem == null ? '' : ' (${item.problem!.code.name})'}',),),
                if (failedDeletionTickets(result).isNotEmpty)
                  TextButton(
                      key: const ValueKey('local-delete-retry'),
                      onPressed: busy ? null : onRetry,
                      child: const Text('Retry failed local deletions'),),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
