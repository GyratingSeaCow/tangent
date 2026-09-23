// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Home-screen widget: one 2x2 tile, one notebook, one tap.
// Jeff (2026-09-23): "just be a little 2x2 square that allows you to
// click it and go directly into the Notebook you selected during the
// setup process."
//
// Each widget instance remembers its own notebook (multiple widgets,
// multiple notebooks). Configuration happens in
// NotebookWidgetConfigActivity at placement time.

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

class NotebookWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) {
        for (id in ids) render(context, manager, id)
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        val prefs = prefs(context).edit()
        for (id in ids) {
            prefs.remove(keyId(id))
            prefs.remove(keyTitle(id))
        }
        prefs.apply()
    }

    companion object {
        private const val PREFS = "notebook_widget"
        internal fun prefs(context: Context) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        internal fun keyId(widgetId: Int) = "notebook_id_$widgetId"
        internal fun keyTitle(widgetId: Int) = "notebook_title_$widgetId"

        /** The tap intent: VIEW tangent://notebook/<id>, routed by
         *  MainActivity. Unique request code per widget so two widgets'
         *  PendingIntents never collapse into one. */
        internal fun render(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
        ) {
            val prefs = prefs(context)
            val notebookId = prefs.getString(keyId(widgetId), null)
            val title = prefs.getString(keyTitle(widgetId), null)

            val views = RemoteViews(context.packageName, R.layout.widget_notebook)
            views.setTextViewText(
                R.id.widget_notebook_title,
                title ?: context.getString(R.string.widget_notebook_unset),
            )

            if (notebookId != null) {
                val intent = Intent(context, MainActivity::class.java).apply {
                    action = Intent.ACTION_VIEW
                    data = Uri.parse("tangent://notebook/$notebookId")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                val pending = PendingIntent.getActivity(
                    context,
                    widgetId,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(R.id.widget_notebook_root, pending)
            }

            manager.updateAppWidget(widgetId, views)
        }
    }
}
