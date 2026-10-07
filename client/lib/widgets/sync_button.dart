// SPDX-License-Identifier: AGPL-3.0-or-later
/// The sync button that sits in the app bar of every list screen.
///
/// One widget, used in four places, so the icon, the spinner, and the result
/// message cannot drift apart between screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/api_exception.dart';
import '../services/document_sync_engine.dart';

/// Runs after a SUCCESSFUL device sync and may add to its snackbar message.
///
/// Returns the text to append (e.g. ` · Google updated`) or null to leave the
/// message exactly as [syncMessageFor] wrote it. The To Do screen uses this
/// to push the just-synced change on to Google Tasks in the same press.
typedef AfterSyncHook = Future<String?> Function();

/// The suffix shown when an [AfterSyncHook] throws instead of answering.
///
/// The device sync already succeeded, so its sentence stands; the hook's
/// failure is appended rather than replacing it. Kept short: a snackbar is
/// one line, and a Dio stack trace is not a message.
String afterSyncErrorSuffix(Object error) {
  final String text = switch (error) {
    ApiException(:final String message) => message,
    final Exception e => e.toString().replaceFirst(
      RegExp(r'^\w*Exception:\s*'),
      '',
    ),
    _ => error.toString(),
  };
  final String firstLine = text.split('\n').first.trim();
  final String short = firstLine.length > 80
      ? '${firstLine.substring(0, 77)}…'
      : firstLine;
  return ' · Google: ${short.isEmpty ? 'unknown error' : short}';
}

/// Turns a finished sync into the sentence shown to the user.
///
/// Pure and separately tested: this is the only thing most syncs ever say, so
/// a wrong word here is the whole feature as far as the user is concerned.
/// In particular a no-op sync must not claim success it cannot back up, and a
/// local edit replaced by a newer other-device version must be named plainly.
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
        if (report.conflicts == 1) {
          return 'Synced, but a local edit was replaced by a newer version '
              'from another device';
        }
        return 'Synced, but ${report.conflicts} local edits were replaced by '
            'newer versions from other devices';
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
  const SyncButton({required this.engineProvider, this.afterSync, super.key});

  final ProviderListenable<DocumentSyncEngine> engineProvider;

  /// Optional follow-up that runs AFTER the device sync succeeds, so whatever
  /// it forwards (Google Tasks, for To Do) is the state the server just
  /// received — never the state from before the push. Screens with nothing
  /// to forward pass nothing and their message is unchanged.
  final AfterSyncHook? afterSync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DocumentSyncEngine engine = ref.watch(engineProvider);

    // The engine is a ChangeNotifier and this button is its display: it must
    // repaint when the engine starts and stops, not whenever some unrelated
    // stream happens to rebuild the screen. On a screen where a sync moves
    // nothing, nothing else rebuilds — an unwatched spinner spins forever.
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, _) {
        final bool busy = engine.isSyncing;
        return IconButton(
          key: const ValueKey<String>('sync-button'),
          tooltip: busy ? 'Syncing…' : 'Sync now',
          // Disabled while running rather than queueing a second pass: the
          // engine refuses reentrant cycles anyway, and a button that
          // silently does nothing is worse than one that visibly cannot be
          // pressed.
          onPressed: busy
              ? null
              : () async {
                  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
                    context,
                  );
                  final SyncReport report = await engine.syncNow();
                  String message = syncMessageFor(report);
                  // Ordering is the contract: the hook must see the world
                  // AFTER the push, or Google gets yesterday's to-do. And it
                  // only runs when there was a sync to follow — forwarding
                  // after an offline or failed cycle would claim a freshness
                  // the server does not have.
                  final AfterSyncHook? hook = afterSync;
                  if (hook != null && report.outcome == SyncOutcome.success) {
                    try {
                      final String? suffix = await hook();
                      if (suffix != null) message += suffix;
                    } catch (e) {
                      // The device sync DID succeed; say so, then say what
                      // the follow-up could not do.
                      message += afterSyncErrorSuffix(e);
                    }
                  }
                  // The screen can be gone by the time the server answers.
                  if (!context.mounted) return;
                  messenger.showSnackBar(SnackBar(content: Text(message)));
                },
          icon: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync),
        );
      },
    );
  }
}
