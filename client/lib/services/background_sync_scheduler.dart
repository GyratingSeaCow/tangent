// SPDX-License-Identifier: AGPL-3.0-or-later
/// Periodic background document sync.
///
/// Android will not run this on a precise schedule and saying otherwise would
/// be a lie in the UI: the platform minimum for a periodic task is 15 minutes,
/// and Doze batches work into maintenance windows, so a tablet asleep in a bag
/// may go considerably longer. The contract is "roughly every 30 minutes while
/// there is a network", not a timer.
///
/// Registration is idempotent by unique name, so launching the app repeatedly
/// does not stack up duplicate workers.
library;

import 'package:workmanager/workmanager.dart';

/// Identifies the periodic task. Reused on every registration so the platform
/// replaces the existing schedule rather than adding another one.
const String kDocumentSyncTaskName = 'tangent.documentSync.periodic';

/// The cadence the user asked for. Android treats this as a floor and a hint.
const Duration kDocumentSyncInterval = Duration(minutes: 30);

/// Registers the periodic sync.
///
/// [existingWorkPolicy] is `keep`: an app restart must not reset the clock,
/// or a user who opens Tangent every few minutes would never reach the
/// interval and background sync would silently never run.
Future<void> registerPeriodicDocumentSync(Workmanager workmanager) async {
  await workmanager.registerPeriodicTask(
    kDocumentSyncTaskName,
    kDocumentSyncTaskName,
    frequency: kDocumentSyncInterval,
    existingWorkPolicy: ExistingWorkPolicy.keep,
    constraints: Constraints(
      // Without a network the task wakes, fails, and burns battery for
      // nothing. Deliberately `connected` rather than `unmetered`: document
      // sync is kilobytes and the user asked for it to work on cellular.
      networkType: NetworkType.connected,
    ),
    // A first run immediately after launch would collide with the foreground
    // sync that already happens at startup.
    initialDelay: kDocumentSyncInterval,
  );
}
