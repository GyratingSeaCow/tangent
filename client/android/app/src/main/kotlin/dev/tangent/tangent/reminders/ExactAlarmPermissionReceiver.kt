package dev.tangent.tangent.reminders

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ListenableWorker
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager

/**
 * Reconciles every reminder family as soon as exact-alarm access is granted.
 *
 * The receiver does not launch an activity. It persists a unique WorkManager
 * request for the existing headless Flutter dispatcher, which reads the real
 * Drift database and re-arms per-todo, daily-digest, and morning-review alarms.
 */
class ExactAlarmPermissionReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action != AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED) return

        // The Android implementation package is a transitive Flutter plugin,
        // so app sources cannot link against it directly. Resolve its public
        // worker by its pinned runtime name and use Workmanager's documented
        // Dart task input key.
        val workerClass =
            Class
                .forName(BACKGROUND_WORKER_CLASS)
                .asSubclass(ListenableWorker::class.java)
        val request =
            OneTimeWorkRequest
                .Builder(workerClass)
                .setInputData(
                    Data
                        .Builder()
                        .putString(DART_TASK_KEY, TASK_NAME)
                        .build(),
                ).build()
        WorkManager
            .getInstance(context.applicationContext)
            .enqueueUniqueWork(
                UNIQUE_WORK_NAME,
                ExistingWorkPolicy.REPLACE,
                request,
            )
    }

    companion object {
        const val TASK_NAME = "tangent.exactAlarmPermission.reconcile"
        const val UNIQUE_WORK_NAME = "tangent.exactAlarmPermission.reconcile"
        const val BACKGROUND_WORKER_CLASS =
            "dev.fluttercommunity.workmanager.BackgroundWorker"
        const val DART_TASK_KEY = "dev.fluttercommunity.workmanager.DART_TASK"
    }
}
