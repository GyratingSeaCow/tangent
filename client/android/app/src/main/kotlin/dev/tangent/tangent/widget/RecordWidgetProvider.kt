// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Home-screen widget: one 1x1 red mic, one tap, recording. Jeff
// (2026-09-28): "build a small 1x1 recording icon widget … clicked and it
// immediately starts a brain dump … the mic from the main screen with the
// icon's color scheme."
//
// No state, no config: every instance fires the same tangent://record,
// which MainActivity routes into the SAME toggle path as the on-screen
// button and the desktop hotkey (H1 instant start, H2 second tap stops).

package dev.tangent.tangent.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import dev.tangent.tangent.MainActivity
import dev.tangent.tangent.R

class RecordWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) {
        for (id in ids) render(context, manager, id)
    }

    companion object {
        /** The exact data URI the tap fires. Pure so the unit suite can pin
         *  it without a PendingIntent: what the widget sends must be what
         *  MainActivity's record filter (and LaunchRouter) accepts. */
        fun tapUri(): String = WidgetLaunchIntents.RECORD_URI

        internal fun render(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_record)
            val intent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                data = Uri.parse(tapUri())
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            // Unique request code per widget: with a shared code,
            // FLAG_UPDATE_CURRENT would collapse every tile into one target.
            val pending = PendingIntent.getActivity(
                context,
                widgetId,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_record_root, pending)
            manager.updateAppWidget(widgetId, views)
        }
    }
}
