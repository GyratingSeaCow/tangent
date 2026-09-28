// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:tangent/services/due_digest.dart';
import 'package:tangent/services/due_reminder_scheduler.dart';

/// Records every platform call; no plugin is ever touched.
class FakeDueReminderPort implements DueReminderPort {
  bool grant = true;
  bool exact = true;
  bool canOpenSettings = true;
  int permissionRequests = 0;
  int cancels = 0;
  int withdraws = 0;
  int openSettingsCalls = 0;
  final List<DateTime> scheduledAt = <DateTime>[];
  final List<DueDigest?> scheduledDigests = <DueDigest?>[];
  final List<bool> scheduledExact = <bool>[];
  final List<DueDigest> posted = <DueDigest>[];

  @override
  Future<bool> requestNotificationPermission() async {
    permissionRequests++;
    return grant;
  }

  @override
  Future<bool> canScheduleExact() async => exact;

  @override
  Future<void> schedule({
    required DateTime fireAt,
    required DueDigest? digest,
    required bool exact,
  }) async {
    scheduledAt.add(fireAt);
    scheduledDigests.add(digest);
    scheduledExact.add(exact);
  }

  @override
  Future<void> post(DueDigest digest) async => posted.add(digest);

  @override
  Future<void> withdraw() async => withdraws++;

  @override
  Future<void> cancel() async => cancels++;

  @override
  Future<void> openSystemSettings() async => openSettingsCalls++;

  @override
  bool get canOpenSystemSettings => canOpenSettings;
}
