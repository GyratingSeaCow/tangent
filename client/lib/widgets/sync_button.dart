// SPDX-License-Identifier: AGPL-3.0-or-later
/// The sync button that sits in the app bar of every list screen.
///
/// One widget, used in four places, so the icon, the spinner, and the result
/// message cannot drift apart between screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/document_sync_engine.dart';

/// Turns a finished sync into the sentence shown to the user.
///
/// Pure and separately tested: this is the only thing most syncs ever say, so
/// a wrong word here is the whole feature as far as the user is concerned.
/// In particular a no-op sync must not claim success it cannot back up — and
/// conflicts must be named, because a forked notebook the user never hears
/// about looks exactly like a bug.
String syncMessageFor(SyncReport report) {
  switch (report.outcome) {
    case SyncOutcome.offline:
      return 'No connection — nothing synced';
    case SyncOutcome.alreadyRunning:
      return 'Already syncing';
    case SyncOutcome.failed:
      return 'Sync failed: ${report.error ?? 'unknown error'}';
    case SyncOutcome.success:
      if (report.conflicts > 0) {
        final String copies =
            report.conflicts == 1 ? 'a copy' : '${report.conflicts} copies';
        return 'Synced, but $copies were edited on two devices — '
            'both versions kept';
      }
      if (report.pulled == 0 && report.pushed == 0) {
        return 'Already up to date';
      }
      final List<String> parts = <String>[
        if (report.pulled > 0) 'received ${report.pulled}',
        if (report.pushed > 0) 'sent ${report.pushed}',
      ];
      return 'Synced: ${parts.join(', ')}';
  }
}

/// An app-bar action that runs a sync and reports what happened.
class SyncButton extends ConsumerWidget {
  const SyncButton({required this.engineProvider, super.key});

  final ProviderListenable<DocumentSyncEngine> engineProvider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DocumentSyncEngine engine = ref.watch(engineProvider);
    final bool busy = engine.isSyncing;

    return IconButton(
      key: const ValueKey<String>('sync-button'),
      tooltip: busy ? 'Syncing…' : 'Sync now',
      // Disabled while running rather than queueing a second pass: the engine
      // refuses reentrant cycles anyway, and a button that silently does
      // nothing is worse than one that visibly cannot be pressed.
      onPressed: busy
          ? null
          : () async {
              final ScaffoldMessengerState messenger =
                  ScaffoldMessenger.of(context);
              final SyncReport report = await engine.syncNow();
              // The screen can be gone by the time the server answers.
              if (!context.mounted) return;
              messenger.showSnackBar(
                SnackBar(content: Text(syncMessageFor(report))),
              );
            },
      icon: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync),
    );
  }
}
