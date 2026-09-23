// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Placement-time setup for the notebook widget: pick which notebook this
// tile opens. Reads titles straight from the app's SQLite database
// (read-only; drift owns writes) — no Flutter engine spin-up for a
// 200ms picker.

package dev.tangent.tangent.widget

import android.app.Activity
import android.app.AlertDialog
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Bundle
import java.io.File

class NotebookWidgetConfigActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Cancelled until the user actually picks: backing out of the
        // dialog must abort widget placement, not place a dead tile.
        setResult(RESULT_CANCELED)

        val widgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        val notebooks = loadNotebooks()
        if (notebooks.isEmpty()) {
            AlertDialog.Builder(this)
                .setTitle("No notebooks yet")
                .setMessage("Create a notebook in Tangent first, then add the widget.")
                .setPositiveButton("OK") { _, _ -> finish() }
                .setOnCancelListener { finish() }
                .show()
            return
        }

        AlertDialog.Builder(this)
            .setTitle("Open which notebook?")
            .setItems(notebooks.map { it.second }.toTypedArray()) { _, which ->
                val (id, title) = notebooks[which]
                NotebookWidgetProvider.prefs(this).edit()
                    .putString(NotebookWidgetProvider.keyId(widgetId), id)
                    .putString(NotebookWidgetProvider.keyTitle(widgetId), title)
                    .apply()
                NotebookWidgetProvider.render(
                    this, AppWidgetManager.getInstance(this), widgetId,
                )
                setResult(
                    RESULT_OK,
                    Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId),
                )
                finish()
            }
            .setOnCancelListener { finish() }
            .show()
    }

    /** id→title pairs, newest first, trash excluded — the same order and
     *  filter the in-app list uses. */
    private fun loadNotebooks(): List<Pair<String, String>> {
        val dbFile = File(filesDir.parentFile, "app_flutter/tangent.sqlite")
        if (!dbFile.exists()) return emptyList()
        val result = mutableListOf<Pair<String, String>>()
        try {
            SQLiteDatabase.openDatabase(
                dbFile.path, null, SQLiteDatabase.OPEN_READONLY,
            ).use { db ->
                db.rawQuery(
                    "SELECT id, title FROM notebooks WHERE deleted_at IS NULL " +
                        "ORDER BY updated_at DESC",
                    null,
                ).use { cursor ->
                    while (cursor.moveToNext()) {
                        result.add(cursor.getString(0) to cursor.getString(1))
                    }
                }
            }
        } catch (_: Exception) {
            // Unreadable DB = same UX as no notebooks; never crash the
            // launcher's config flow.
            return emptyList()
        }
        return result
    }
}
