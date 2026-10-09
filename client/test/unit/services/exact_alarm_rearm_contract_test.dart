// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exact-alarm grant enqueues headless reconciliation', () {
    final String manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final String receiver = File(
      'android/app/src/main/kotlin/dev/tangent/tangent/reminders/'
      'ExactAlarmPermissionReceiver.kt',
    ).readAsStringSync();
    final String dispatcher = File('lib/main.dart').readAsStringSync();

    expect(
      manifest,
      contains(
        'android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED',
      ),
    );
    expect(manifest, contains('.reminders.ExactAlarmPermissionReceiver'));
    expect(
      manifest,
      matches(
        RegExp(
          r'android:name="\.reminders\.ExactAlarmPermissionReceiver"\s+'
          r'android:exported="false"',
        ),
      ),
    );
    expect(manifest, contains('android.permission.SCHEDULE_EXACT_ALARM'));
    expect(manifest, isNot(contains('android.permission.USE_EXACT_ALARM')));
    expect(receiver, contains('OneTimeWorkRequest'));
    expect(receiver, contains('Class'));
    expect(receiver, contains('.forName(BACKGROUND_WORKER_CLASS)'));
    expect(
      receiver,
      contains('dev.fluttercommunity.workmanager.BackgroundWorker'),
    );
    expect(receiver, contains('dev.fluttercommunity.workmanager.DART_TASK'));
    expect(receiver, contains('ExistingWorkPolicy.REPLACE'));
    expect(receiver, contains('tangent.exactAlarmPermission.reconcile'));
    expect(dispatcher, contains('kExactAlarmReconcileTaskName'));
    expect(dispatcher, contains('_runExactAlarmPermissionReconcileTask'));
    expect(dispatcher, contains('TodoDueNotificationScheduler('));
    expect(dispatcher, contains('settings.remindersEnabled'));
    expect(dispatcher, contains('settings.morningReviewEnabled'));
  });
}
